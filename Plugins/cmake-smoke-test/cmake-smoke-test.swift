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

import PackagePlugin
import Foundation

@main
struct CMakeSmokeTest: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var args = ArgumentExtractor(arguments)
        let hostOS = try OS.host()

        guard args.extractFlag(named: "disable-sandbox") > 0 else {
            throw Errors.missingRequiredOption("--disable-sandbox")
        }

        guard let cmakePath = args.extractOption(named: "cmake-path").last else { throw Errors.missingRequiredOption("--cmake-path") }
        Diagnostics.progress("using cmake at \(cmakePath)")
        let cmakeURL = URL(filePath: cmakePath)
        guard let ninjaPath = args.extractOption(named: "ninja-path").last else { throw Errors.missingRequiredOption("--ninja-path") }
        Diagnostics.progress("using ninja at \(ninjaPath)")
        let ninjaURL = URL(filePath: ninjaPath)
        let sysrootPath = args.extractOption(named: "sysroot-path").last
        if let sysrootPath {
            Diagnostics.progress("using sysroot at \(sysrootPath)")
        }

        let extraCMakeArgs = args.extractOption(named: "extra-cmake-arg")
        Diagnostics.progress("Extra cmake args: \(extraCMakeArgs.joined(separator: " "))")

        let moduleCachePath = try context.pluginWorkDirectoryURL.appending(component: "module-cache").filePath

        let swiftBuildURL = context.package.directoryURL
        let swiftBuildBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-build")
        try Diagnostics.progress("swift-build: \(swiftBuildURL.filePath)")

        let swiftToolsSupportCoreURL = try findDependency("swift-tools-support-core", pluginContext: context)
        let swiftToolsSupportCoreBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-tools-support-core")

        let swiftSystemURL = try findDependency("swift-system", pluginContext: context)
        let swiftSystemBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-system")

        let llbuildURL = try findDependency("swift-llbuild", pluginContext: context)
        let llbuildBuildURL = context.pluginWorkDirectoryURL.appending(component: "llbuild")

        let swiftArgumentParserURL = try findDependency("swift-argument-parser", pluginContext: context)
        let swiftArgumentParserBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-argument-parser")

        let swiftDriverURL = try findDependency("swift-driver", pluginContext: context)
        let swiftDriverBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-driver")

        for url in [swiftToolsSupportCoreBuildURL, swiftSystemBuildURL, llbuildBuildURL, swiftArgumentParserBuildURL, swiftDriverBuildURL, swiftBuildBuildURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        var sharedSwiftFlags = [
            "-module-cache-path", moduleCachePath,
        ]

        if let sysrootPath {
            sharedSwiftFlags += ["-sdk", sysrootPath]
        }

        let cMakeProjectArgs = try [
            "-DArgumentParser_DIR=\(swiftArgumentParserBuildURL.appending(components: "cmake", "modules").filePath)",
            "-DLLBuild_DIR=\(llbuildBuildURL.appending(components: "cmake", "modules").filePath)",
            "-DTSC_DIR=\(swiftToolsSupportCoreBuildURL.appending(components: "cmake", "modules").filePath)",
            "-DSwiftDriver_DIR=\(swiftDriverBuildURL.appending(components: "cmake", "modules").filePath)",
            "-DSwiftSystem_DIR=\(swiftSystemBuildURL.appending(components: "cmake", "modules").filePath)",
        ]

        let sharedCMakeArgs =
            [
                "-G", "Ninja",
                "-DCMAKE_MAKE_PROGRAM=\(ninjaPath)",
                "-DCMAKE_BUILD_TYPE:=Debug",
                "-DCMAKE_Swift_FLAGS='\(sharedSwiftFlags.joined(separator: " "))'",
            ] + cMakeProjectArgs + extraCMakeArgs

        Diagnostics.progress("Building swift-tools-support-core")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftToolsSupportCoreURL.filePath], workingDirectory: swiftToolsSupportCoreBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftToolsSupportCoreBuildURL)
        Diagnostics.progress("Built swift-tools-support-core")

        if hostOS != .macOS {
            Diagnostics.progress("Building swift-system")
            try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftSystemURL.filePath], workingDirectory: swiftSystemBuildURL)
            try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftSystemBuildURL)
            Diagnostics.progress("Built swift-system")
        }

        Diagnostics.progress("Building llbuild")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + ["-DLLBUILD_SUPPORT_BINDINGS:=Swift", llbuildURL.filePath], workingDirectory: llbuildBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: llbuildBuildURL)
        Diagnostics.progress("Built llbuild")

        Diagnostics.progress("Building swift-argument-parser")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + ["-DBUILD_TESTING=NO", "-DBUILD_EXAMPLES=NO", swiftArgumentParserURL.filePath], workingDirectory: swiftArgumentParserBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftArgumentParserBuildURL)
        Diagnostics.progress("Built swift-argument-parser")

        Diagnostics.progress("Building swift-driver")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftDriverURL.filePath], workingDirectory: swiftDriverBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftDriverBuildURL)
        Diagnostics.progress("Built swift-driver")

        Diagnostics.progress("Building swift-build in \(swiftBuildBuildURL)")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftBuildURL.filePath], workingDirectory: swiftBuildBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftBuildBuildURL)
        Diagnostics.progress("Built swift-build")
    }

    func findDependency(_ name: String, pluginContext: PluginContext) throws -> URL {
        var stack: [Package] = pluginContext.package.dependencies.map { $0.package }
        var visited = Set(stack.map { $0.id })
        var transitiveDependencies = pluginContext.package.dependencies.map { $0.package }
        while let current = stack.popLast() {
            for dependency in current.dependencies {
                guard visited.insert(dependency.package.id).inserted else {
                    continue
                }
                transitiveDependencies.append(dependency.package)
                stack.append(dependency.package)
            }
        }
        guard let dependency = transitiveDependencies.first(where: { $0.id == name }) else {
            throw Errors.missingRepository(name)
        }
        let dependencyURL = dependency.directoryURL
        let dependencyFilePath = try dependencyURL.filePath
        Diagnostics.progress("\(name): \(dependencyFilePath)")
        guard FileManager.default.fileExists(atPath: dependencyFilePath) else {
            throw Errors.missingRepository(dependencyFilePath)
        }
        return dependencyURL
    }
}

enum Errors: Error {
    case processError(terminationReason: Process.TerminationReason, terminationStatus: Int32)
    case missingRequiredOption(String)
    case missingRepository(String)
    case unimplementedForHostOS
    case miscError(String)
}

enum OS {
    case macOS
    case linux
    case windows

    static func host() throws -> Self {
        #if os(macOS)
            return .macOS
        #elseif os(Linux)
            return .linux
        #elseif os(Windows)
            return .windows
        #else
            throw Errors.unimplementedForHostOS
        #endif
    }
}

extension URL {
    var filePath: String {
        get throws {
            try withUnsafeFileSystemRepresentation { path in
                guard let path else {
                    throw Errors.miscError("cannot get file path for URL: \(self)")
                }
                return String(cString: path)
            }
        }
    }
}

extension Process {
    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            terminationHandler = { _ in
                continuation.resume()
            }

            do {
                try run()
            } catch {
                terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    static func checkNonZeroExit(url: URL, arguments: [String], workingDirectory: URL, environment: [String: String]? = nil) async throws {
        try Diagnostics.progress("\(url.filePath) \(arguments.joined(separator: " "))")
        #if USE_PROCESS_SPAWNING_WORKAROUND && !os(Windows)
            Diagnostics.progress("Using process spawning workaround")
            // Linux workaround for https://github.com/swiftlang/swift-corelibs-foundation/issues/4772
            // Foundation.Process on Linux seems to inherit the Process.run()-calling thread's signal mask, creating processes that even have SIGTERM blocked
            // This manifests as CMake getting stuck when invoking 'uname' with incorrectly configured signal handlers.
            var fileActions = posix_spawn_file_actions_t()
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            var attrs: posix_spawnattr_t = posix_spawnattr_t()
            defer { posix_spawnattr_destroy(&attrs) }
            posix_spawn_file_actions_init(&fileActions)
            try posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.filePath)

            posix_spawnattr_init(&attrs)
            posix_spawnattr_setpgroup(&attrs, 0)
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            posix_spawnattr_setsigmask(&attrs, &noSignals)

            var mostSignals = sigset_t()
            sigemptyset(&mostSignals)
            for i in 1..<SIGSYS {
                if i == SIGKILL || i == SIGSTOP {
                    continue
                }
                sigaddset(&mostSignals, i)
            }
            posix_spawnattr_setsigdefault(&attrs, &mostSignals)
            posix_spawnattr_setflags(&attrs, numericCast(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
            var pid: pid_t = -1
            try withArrayOfCStrings([url.filePath] + arguments) { arguments in
                try withArrayOfCStrings((environment ?? [:]).map { key, value in "\(key)=\(value)" }) { environment in
                    let spawnResult = try posix_spawn(&pid, url.filePath, /*file_actions=*/ &fileActions, /*attrp=*/ &attrs, arguments, nil);
                    var exitCode: Int32 = -1
                    var result = wait4(pid, &exitCode, 0, nil);
                    while (result == -1 && errno == EINTR) {
                        result = wait4(pid, &exitCode, 0, nil)
                    }
                    guard result != -1 else {
                        throw Errors.miscError("wait failed")
                    }
                    guard exitCode == 0 else {
                        throw Errors.miscError("exit code nonzero")
                    }
                }
            }
        #else
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = environment
            try await process.run()
            if process.terminationStatus != 0 {
                throw Errors.processError(terminationReason: process.terminationReason, terminationStatus: process.terminationStatus)
            }
        #endif
    }
}

#if USE_PROCESS_SPAWNING_WORKAROUND && !os(Windows)
    func scan<S: Sequence, U>(_ seq: S, _ initial: U, _ combine: (U, S.Element) -> U) -> [U] {
        var result: [U] = []
        result.reserveCapacity(seq.underestimatedCount)
        var runningResult = initial
        for element in seq {
            runningResult = combine(runningResult, element)
            result.append(runningResult)
        }
        return result
    }

    func withArrayOfCStrings<T>(
        _ args: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<Int8>?>) throws -> T
    ) throws -> T {
        let argsCounts = Array(args.map { $0.utf8.count + 1 })
        let argsOffsets = [0] + scan(argsCounts, 0, +)
        let argsBufferSize = argsOffsets.last!
        var argsBuffer: [UInt8] = []
        argsBuffer.reserveCapacity(argsBufferSize)
        for arg in args {
            argsBuffer.append(contentsOf: arg.utf8)
            argsBuffer.append(0)
        }
        return try argsBuffer.withUnsafeMutableBufferPointer {
            (argsBuffer) in
            let ptr = UnsafeRawPointer(argsBuffer.baseAddress!).bindMemory(
                to: Int8.self,
                capacity: argsBuffer.count
            )
            var cStrings: [UnsafePointer<Int8>?] = argsOffsets.map { ptr + $0 }
            cStrings[cStrings.count - 1] = nil
            return try cStrings.withUnsafeMutableBufferPointer {
                let unsafeString = UnsafeMutableRawPointer($0.baseAddress!).bindMemory(
                    to: UnsafeMutablePointer<Int8>?.self,
                    capacity: $0.count
                )
                return try body(unsafeString)
            }
        }
    }
#endif
