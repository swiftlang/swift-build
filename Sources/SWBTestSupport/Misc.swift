//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_spi(TestSupport) package import SWBUtil
package import class Foundation.FileManager
package import class Foundation.ProcessInfo
package import struct Foundation.URL
package import SWBCore
import SWBLibc
package import SWBProtocol
package import Testing

#if os(Windows)
import WinSDK
#endif

package extension Sequence where Element: Equatable {
    func contains<S: Sequence>(anyOf other: S) -> Bool where S.Element == Element {
        return other.contains { self.contains($0) }
    }
}

/// Runs the process with the specified command line, working directory, and environment and returns the output if it succeeds.
///
/// - parameter args: The command line to run. The first element is the executable to run, and the remaining elements are the arguments.
/// - parameter workingDirectory: The working directory in which to execute the process. `nil` to inherit the current process working directory.
/// - parameter environment: The environment variables to to pass to the executed process.
/// - parameter interruptible: Whether the process should respond to task cancellation. If `true`, task cancellation will cause `SIGTERM` to be sent to the process if it starts running by the time the task is cancelled. If `false`, the process will always run to completion regardless of the task's cancellation status.
/// - parameter redirectStderr: `true` to return the merged stdout and stderr streams, `false` to return only stdout.
/// - throws: ``StubError`` if the arguments list is an empty array.
/// - throws: ``RunProcessNonZeroExitError`` if the process exited with a nonzero status code or uncaught signal.
@discardableResult
package func runProcess(_ args: [String], workingDirectory: String? = nil, environment: Environment = .init(), interruptible: Bool = true, redirectStderr: Bool = false) async throws -> String {
    guard let first = args.first else {
        throw StubError.error("Invalid number of arguments")
    }
    guard let url = StackedSearchPath(environment: environment, fs: localFS).lookup(Path(first)).map({ URL(fileURLWithPath: $0.str) }) else {
        throw StubError.error("Cannot find '\(first)' in PATH: \(environment["PATH"] ?? "")")
    }
    let arguments = Array(args.dropFirst())
    if redirectStderr {
        let (exitStatus, output) = try await Process.getMergedOutput(url: url, arguments: arguments, currentDirectoryURL: workingDirectory.map(URL.init(fileURLWithPath:)), environment: environment, interruptible: interruptible)
        guard exitStatus.isSuccess else {
            throw RunProcessNonZeroExitError(args: args, workingDirectory: workingDirectory, environment: environment, status: exitStatus, mergedOutput: ByteString(output))
        }
        return String(decoding: output, as: UTF8.self)
    } else {
        let executionResult = try await Process.getOutput(url: url, arguments: arguments, currentDirectoryURL: workingDirectory.map(URL.init(fileURLWithPath:)), environment: environment, interruptible: interruptible)
        guard executionResult.exitStatus.isSuccess else {
            throw RunProcessNonZeroExitError(args: args, workingDirectory: workingDirectory, environment: environment, status: executionResult.exitStatus, stdout: ByteString(executionResult.stdout), stderr: ByteString(executionResult.stderr))
        }
        return String(decoding: executionResult.stdout, as: UTF8.self)
    }
}

/// Runs the command specified by `args` with the `DEVELOPER_DIR` environment variable set.
///
/// This method will use the current value of `DEVELOPER_DIR` in the environment by default, or the value of `overrideDeveloperDirectory` if specified.
package func runProcessWithDeveloperDirectory(_ args: [String], workingDirectory: String? = nil, overrideDeveloperDirectory: String? = nil, interruptible: Bool = true, redirectStderr: Bool = true) async throws -> String {
    let environment = Environment.current
        .filter(keys: ["DEVELOPER_DIR", "LLVM_PROFILE_FILE"])
        .addingContents(of: overrideDeveloperDirectory.map { Environment(["DEVELOPER_DIR": $0]) } ?? .init())
    return try await runProcess(args, workingDirectory: workingDirectory, environment: environment, interruptible: interruptible, redirectStderr: redirectStderr)
}

package func runHostProcess(_ args: [String], workingDirectory: String? = nil, interruptible: Bool = true, redirectStderr: Bool = true) async throws -> String {
    switch try ProcessInfo.processInfo.hostOperatingSystem() {
    case .macOS:
        return try await InstalledXcode.currentlySelected().xcrun(args, workingDirectory: workingDirectory, redirectStderr: redirectStderr)
    default:
        return try await runProcess(args, workingDirectory: workingDirectory, environment: .current, interruptible: interruptible, redirectStderr: redirectStderr)
    }
}

/// Attempts to get and return the group name of the currently active user.
package func GetCurrentUserGroupName() -> String? {
    // Take a shortcut and assume that the group of the home directory is appropriate.
    return (try? FileManager.default.attributesOfItem(atPath: Path.homeDirectory.str))?[.groupOwnerAccountName] as? String
}

/// Create an SDK on disk (i.e., in the real, local, filesystem) in `parentDir` named `name` with an `SDKSettings.plist` whose contents are the property list `settings`.
package func writeSDK(name: String, parentDir: Path, settings: [String: PropertyListItem]) async throws {
    let sdkPath = parentDir.join(name)
    guard sdkPath.fileSuffix == ".sdk" else {
        throw StubError.error("SDK name '\(name)' must end in '.sdk'.")
    }
    let itemPath = sdkPath.join("SDKSettings.plist")
    try localFS.createDirectory(itemPath.dirname, recursive: true)
    try await localFS.writePlist(itemPath, settings)
}

package let compilerParallelismLevel = ProcessInfo.processInfo.activeProcessorCount

package extension ConfiguredTarget {
    /// Return a string identifying the platform this target was configured for, for convenient testing.
    var platformDiscriminator: String? {
        // Converts the sdkroot/sdkvariant info into a set of normalized values.
        func normalize(platform: String, variant: String?) -> String {
            // The suffix is not important in the discriminator as that can be verified via other means if necessary.
            let platform = String(platform.split(separator: ".").first ?? "")

            if let variant, platform == "macosx" { return variant }
            if platform == variant { return platform }
            return "\(platform)\(variant.map{"-\($0)"} ?? "")"
        }

        // First look at the parameter overrides to understand if this target has been configured differently than the active run destination may otherwise suggest.
        if let sdkroot = self.parameters.overrides["SDKROOT"] {
            let sdkvariant = self.parameters.overrides["SDK_VARIANT"]
            return normalize(platform: sdkroot, variant: sdkvariant)
        }

        // Next use the active run destination for the appropriate settings.
        guard let destination = self.parameters.activeRunDestination else { return nil }
        return normalize(platform: destination.platform, variant: destination.sdkVariant)
    }
}

package extension FSProxy {
    /// Write the contents of a file using a closure to produce the content.
    ///
    /// - parameter path: The path to which the file contents should be written.
    /// - parameter waitForNewTimestamp: `true` to guarantee that the file's timestamp will change after the contents are written. This is useful when writing to filesystems with coarse timestamp precision.
    func writeFileContents(_ path: Path, waitForNewTimestamp: Bool = false, body: (OutputByteStream) throws -> Void) async throws {
        let contents = OutputByteStream()
        try body(contents)
        try self.createDirectory(path.dirname, recursive: true)
        try self.write(path, contents: contents.bytes)
        if waitForNewTimestamp {
            try await updateTimestamp(path)
        }
    }

    /// Write the contents of a file using a closure to produce the content.
    ///
    /// - parameter path: The path to which the file contents should be written.
    /// - parameter waitForNewTimestamp: `true` to guarantee that the file's timestamp will change after the contents are written. This is useful when writing to filesystems with coarse timestamp precision.
    func writeFileContents(_ path: Path, waitForNewTimestamp: Bool = false, body: (OutputByteStream) async throws -> Void) async throws {
        let contents = OutputByteStream()
        try await body(contents)
        try self.createDirectory(path.dirname, recursive: true)
        try self.write(path, contents: contents.bytes)
        if waitForNewTimestamp {
            try await updateTimestamp(path)
        }
    }

    /// Updates the timestamp of the file to the current time, possibly sleeping until the current time is > minimumTime. If minimumTime is nil, updateTimestamp will use the file's current timestamp as a reference instead.
    func updateTimestamp(_ path: Path, minimumTime: Int? = nil) async throws {
        let oldTime = try minimumTime ?? getFileTimestamp(path)
        var newTime = time(nil)
        while newTime <= oldTime {
            try await Task.sleep(for: .seconds(1))
            newTime = time(nil)
        }
        try setFileTimestamp(path, timestamp: Int(newTime))
    }
}

package func XCTAssertEqualPropertyListItems(_ expression1: @autoclosure () throws -> PropertyListItem?, _ expression2: @autoclosure () throws -> PropertyListItem?, sourceLocation: SourceLocation = #_sourceLocation) rethrows {
    if case let .plDict(left)? = try expression1(), case let .plDict(right)? = try expression2() {
        for key in Set(Array(left.keys) + Array(right.keys)).sorted() {
            if let leftArray = left[key]?.stringArrayValue, let rightArray = right[key]?.stringArrayValue {
                XCTAssertEqualSequences(leftArray, rightArray, "for key \"\(key)\"", sourceLocation: sourceLocation)
            } else {
                #expect(left[key] == right[key], "for key \"\(key)\"", sourceLocation: sourceLocation)
            }
        }
    }
    #expect(try expression1() == expression2(), sourceLocation: sourceLocation)
}

extension ProcessInfo {
    package var isRunningInVirtualMachine: Bool {
        #if canImport(Darwin)
        let machdep_cpu_features = "machdep.cpu.features"
        var len: Int = 0
        if sysctlbyname(machdep_cpu_features, nil, &len, nil, 0) == 0 {
            var p = [CChar](repeating: 0, count: len)
            if sysctlbyname(machdep_cpu_features, &p, &len, nil, 0) == 0 {
                if let features = p.withUnsafeBufferPointer({ $0.baseAddress.map({ String(cString: $0) }) })?.split(separator: " ") {
                    return features.contains("VMM")
                }
            }
        }
        #endif
        return false
    }

    // Get memory usage of current process in bytes
    package var memoryUsage: UInt64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return info.phys_footprint // memory in bytes
        }
        return 0
        #else
        return 0 // for non-macOS platforms
        #endif
    }
}

extension SDKRegistryLookup {
    package func lookup(_ name: String) -> SDK? {
        try? lookup(name, activeRunDestination: nil)
    }

    package func lookup(nameOrPath: String, basePath: Path) -> SDK? {
        try? lookup(nameOrPath: nameOrPath, basePath: basePath, activeRunDestination: nil)
    }
}

package enum SWBTestInfrastructureError: Error {
    /// Indicates that an XCTestCase class-level or instance variable has not yet been initialized by the test infrastructure at the time of access.
    case uninitialized
}

extension Tag {
    @Tag package static var smokeTest: Self
}

package enum SWBTestTag: String, Comparable, Encodable, Sendable {
    case smokeTest = "Smoke Test"
}

extension ArenaInfo {
    package static func buildArena(derivedDataRoot path: Path, enableIndexDataStore: Bool = false) -> ArenaInfo {
        let buildRoot = path.join("Build")
        return ArenaInfo(
            derivedDataPath: path,
            buildProductsPath: buildRoot.join("Products"),
            buildIntermediatesPath: buildRoot.join("Intermediates.noindex"),
            pchPath: buildRoot.join("Intermediates.noindex/PrecompiledHeaders"),
            indexRegularBuildProductsPath: nil,
            indexRegularBuildIntermediatesPath: nil,
            indexPCHPath: path.join("Index.noindex/PrecompiledHeaders"),
            indexDataStoreFolderPath: enableIndexDataStore ? path.join("Index.noindex/DataStore") : nil,
            indexEnableDataStore: enableIndexDataStore
        )
    }

    package static func indexBuildArena(derivedDataRoot path: Path) -> ArenaInfo {
        let buildRoot = path.join("Build")
        let indexBuildRoot =  path.join("Index.noindex/Build")
        return ArenaInfo(
            derivedDataPath: path,
            buildProductsPath: indexBuildRoot.join("Products"),
            buildIntermediatesPath: indexBuildRoot.join("Intermediates.noindex"),
            pchPath: indexBuildRoot.join("Intermediates.noindex/PrecompiledHeaders"),
            indexRegularBuildProductsPath: buildRoot.join("Products"),
            indexRegularBuildIntermediatesPath: buildRoot.join("Intermediates.noindex"),
            indexPCHPath: path.join("Index.noindex/PrecompiledHeaders"),
            indexDataStoreFolderPath: nil,
            indexEnableDataStore: false
        )
    }
}

extension ProcessExecutionCache {
    package static let sharedForTesting = ProcessExecutionCache()
}
