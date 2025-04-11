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

public import SWBCore
import SWBLibc
import SWBUtil
import Foundation
import struct SWBProtocol.BuildOperationMetrics
import Synchronization

fileprivate func executableFileNameMatchesSwiftRuntimeLibPattern(_ fileName: String) -> Bool {
    return fileName.hasPrefix("libswift") && fileName.hasSuffix(".dylib")
}

fileprivate extension MachO {
    func allSwiftLibNames() throws -> Set<String> {
        return try Set(self.slices()
            .flatMap { try $0.linkedLibraryPaths() }
            .compactMap { (lib: String) -> String? in
                let pcs = Path(lib)
                if (pcs.dirname.str == "@rpath" || pcs.dirname == Path("/usr/lib/swift")) && executableFileNameMatchesSwiftRuntimeLibPattern(pcs.basename) {
                    return pcs.basename
                }
                else {
                    return nil
                }
        })
    }
}

fileprivate struct Executable: Hashable {
    let path: Path
    let swiftABIVersion: SwiftABIVersion?
    let linkedSwiftLibNames: Set<String>
    let uuids: [Foundation.UUID]

    var usesSwift: Bool {
        return swiftABIVersion != nil
    }

    init(path: Path, object: MachO) throws {
        self.path = path

        let swiftABIVersions = try object.slices().compactMap{ try $0.swiftABIVersion() }
        if swiftABIVersions.isEmpty {
            self.swiftABIVersion = nil
        }
        else {
            let uniqueVersions = Set(swiftABIVersions)
            if uniqueVersions.count > 1 {
                throw StubError.error("Expected a single Swift ABI version in \(path.str) but found \(swiftABIVersions)")
            }
            else {
                self.swiftABIVersion = swiftABIVersions.first!
            }
        }

        self.linkedSwiftLibNames = try object.allSwiftLibNames()
        self.uuids = try object.slices().compactMap{ try $0.uuid() }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

/// Embeds Swift stdlibs into a bundle. Formerly known as swift-stdlib-tool, SwiftStdLibTool, CopySwiftLibs.
public final class EmbedSwiftStdLibTaskAction: TaskAction {

    // This struct contains the parsed input configuration and makes it available to its member funcs (who are non-mutating and cannot modify it)
    fileprivate struct RunningTask {
        let task: any ExecutableTask
        unowned let taskAction: TaskAction
        let dynamicExecutionDelegate: any DynamicTaskExecutionDelegate
        let executionDelegate: any TaskExecutionDelegate
        let clientDelegate: any TaskExecutionClientDelegate
        let outputDelegate: any TaskOutputDelegate

        /// Combined parent + task environment
        let effectiveEnvironment: [String: String]

        var fs : any FSProxy { return executionDelegate.fs }

        var verbose: Int = 0

        private final class OutputController: Sendable {
            /// Lock to synchronize emit output operations.
            let emitOutputLock = SWBMutex(())
        }

        private let outputController = OutputController()

        // Code signing inputs
        var codeSignIdentity: String? = nil
        var keychain: String? = nil
        var otherCodeSignFlags = [String]()

        // Executables to scan for Swift usage
        var scanExecutables = Set<Executable>()

        // Directories to scan for more executables.
        // --scan-folder
        var scanDirs = Set<Path>()

        // Platform name.
        // --platform
        // or the last path component of --source-libraries
        var platform: String? = nil

        // --toolchain
        var toolchainsDirs = OrderedSet<Path>()

        // Copy source.
        // --source-libraries
        // or /path/to/swift-stdlib-tool/../../lib/swift/<--platform>
        var srcDir: Path? = nil

        // Copy destinations, signed and unsigned.
        // --destination and --unsigned-destination
        var dstDir: Path?
        var unsignedDstDir: Path? = nil

        // Resource copy destination.
        // --resource-destination
        var resourceDstDir: Path? = nil

        // Resource libraries.
        // --resource-library
        var resourceLibraries = Set<String>()

        var shouldPrint = false
        var shouldCopy = false

        // Bitcode is no longer supported, but some old libraries may contain bitcode, so we continue to strip it when directed.
        var shouldStripBitcode = false
        var bitcodeStripPath: Path? = nil

        // Effective search path for Swift libraries.
        var srcDirs = OrderedSet<Path>()

        // Path of file to which discovered dependencies should be written.
        var discoveredDepsOutputFile: Path? = nil

        /// If this is set, we should:
        /// - Ignore Swift ABI versions when we look for dependencies
        /// - Emit warnings instead of errors when we detect an ABI mismatch in embedded binaries
        let ignoreABIVersion: Bool

        // If true, then the only swift libs that should be processed are those known to not exist in the SwiftOS install.
        var filterForSwiftOS = false

        // If true, then the Swift concurrency dylibs should be copied into the app/framework's bundles.
        var backDeploySwiftConcurrency = false

        // The allowed list of libraries that should *not* be filtered when `filterForSwiftOS=true`.
        let allowedLibsForSwiftOS = ["libswiftXCTest" ]

        // The allowed list of libraries that should *not* be filtered when `backDeploySwiftConcurrency=true`.
        let allowedLibsForSwiftConcurrency = ["libswift_Concurrency"]

        func absolutePath(_ path: Path) -> Path {
            return path.isAbsolute ? path : task.workingDirectory.join(path)
        }

        func logV(_ msg : @autoclosure () -> String) {
            if verbose > 0 {
                outputController.emitOutputLock.withLock {
                    outputDelegate.emitOutput { $0 <<< msg() <<< "\n" }
                }
            }
        }

        func logVV(_ msg : @autoclosure () -> String) {
            if verbose > 1 {
                outputController.emitOutputLock.withLock {
                    outputDelegate.emitOutput { $0 <<< msg() <<< "\n" }
                }
            }
        }

        /// - returns: `nil` if the file doesn't exist or isn't an executable.
        /// - throws if the file exists but can't be read
        func executableIfValid(path: Path) throws -> Executable? {
            guard try fs.exists(path) && !fs.isDirectory(path) && fs.isExecutable(path) else { return nil }

            do {
                let object = try MachO(data: fs.read(path))
                return try Executable(path: path, object: object)
            } catch BinaryReaderError.unrecognizedFileType {
                // Don't log any warnings if the file isn't a Mach-O, because that isn't an error case.
                return nil
            } catch let error as BinaryReaderError {
                // Log warnings if we *did* start parsing a Mach-O, and then it turned out to be corrupted.
                logV("warning: \(path.str): Failed to parse executable: \(error)")
                return nil
            }
        }

        func effectiveSourceDirectories(_ toolchainsDirs: OrderedSet<Path>, platform: String) -> [Path] {
            // FIXME: Maybe these should be defined within the toolchains or we could simply scan the toolchain directory as well.
            let swiftBackdeploymentDirs = ["usr/lib/swift-5.0", "usr/lib/swift-5.5"]

            var dirs = [Path]()
            for dir in toolchainsDirs {
                for path in swiftBackdeploymentDirs {
                    dirs.append(dir.join(path).join(platform))
                }
            }

            return dirs
        }

        init(task: any ExecutableTask, taskAction: TaskAction, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async throws {
            self.task = task
            self.taskAction = taskAction
            self.dynamicExecutionDelegate = dynamicExecutionDelegate
            self.executionDelegate = executionDelegate
            self.clientDelegate = clientDelegate
            self.outputDelegate = outputDelegate
            self.effectiveEnvironment = {
                var env = executionDelegate.environment ?? [:]
                env.addContents(of: task.environment.bindingsDictionary)
                return env
            }()

            // Read arguments
            let argsIter = task.commandLineAsStrings.makeIterator()
            precondition(argsIter.next() == "builtin-swiftStdLibTool")

            // The linker checks for the existence of this env var; its value doesn't matter
            self.ignoreABIVersion = self.effectiveEnvironment["LD_WARN_ON_SWIFT_ABI_VERSION_MISMATCHES"] != nil

            while true {
                guard let arg = argsIter.next() else { break }

                func argParam() throws -> String {
                    guard let p = argsIter.next() else { throw StubError.error("Failed to parse arguments: \(arg) requires an argument") }
                    return p
                }

                func setSingleOccurrence<T>(_ result: inout T?, _ getValue : @autoclosure () throws -> T) throws {
                    guard result == nil else { throw StubError.error("Failed to parse arguments: expected a single \(arg) argument") }
                    result = try getValue()
                }

                switch arg {
                case "--print":
                    shouldPrint = true

                case "--copy":
                    shouldCopy = true

                case "--verbose":
                    verbose += 1

                case "--scan-executable":
                    // --scan-executable <path>
                    // Scan the executable at <path> for references to Swift libraries.
                    // This option may be set multiple times.
                    let path = absolutePath(Path(try argParam()))
                    if let exe = try executableIfValid(path: path) {
                        scanExecutables.insert(exe)
                    }
                    else {
                        logV("Failed to scan executable: \(path.str)")
                    }

                case "--scan-folder":
                    // --scan-folder <path>
                    // Scan any executables inside <path> for references to Swift libraries.
                    // This option may be set multiple times.
                    scanDirs.insert(absolutePath(Path(try argParam())))

                case "--source-libraries":
                    // --source-libraries <path>
                    // Search <path> for Swift libraries.
                    // The default is /path/to/swift-stdlib-tool/../../lib/swift/<platform>/
                    var srcDir = self.srcDir
                    try setSingleOccurrence(&srcDir, absolutePath(Path(argParam())))
                    self.srcDir = srcDir

                case "--platform":
                    // --platform <macosx|iphoneos|iphonesimulator>
                    // Use the Swift libraries for <platform>.
                    try setSingleOccurrence(&platform, argParam())

                case "--toolchain":
                    // --toolchain <path> ...
                    // Find matching Swift libraries in any of the above toolchains.
                    toolchainsDirs.append(absolutePath(Path(try argParam())))

                case "--destination":
                    // --destination <path>
                    // Copy Swift libraries into <path>.
                    var dstDir = self.dstDir
                    try setSingleOccurrence(&dstDir, absolutePath(Path(argParam())))
                    self.dstDir = dstDir

                case "--unsigned-destination":
                    // --unsigned-destination <path>
                    // Copy Swift libraries into <path> without signing them.
                    var unsignedDstDir = self.unsignedDstDir
                    try setSingleOccurrence(&unsignedDstDir, absolutePath(Path(argParam())))
                    self.unsignedDstDir = unsignedDstDir

                case "--sign":
                    // --sign <identity>
                    // Sign copied Swift libraries using <identity>.
                    try setSingleOccurrence(&codeSignIdentity, argParam())

                case "--keychain":
                    // --keychain <keychain>
                    // Search <keychain> for the code signing identity.
                    try setSingleOccurrence(&keychain, argParam())

                case "--Xcodesign":
                    // --Xcodesign <option>
                    // Pass <option> to the codesign tool.
                    otherCodeSignFlags.append(try argParam())

                case "--strip-bitcode":
                    // --strip-bitcode
                    // Remove embedded bitcode from libraries copied to --destination.
                    // Libraries copied to --unsigned-destination are unmodified.
                    shouldStripBitcode = true

                case "--strip-bitcode-tool":
                    var bitcodeStripPath = self.bitcodeStripPath
                    try setSingleOccurrence(&bitcodeStripPath, absolutePath(Path(argParam())))
                    self.bitcodeStripPath = bitcodeStripPath

                case "--resource-library":
                    // --resource-library <library>
                    // Copy <library> and its dependencies as resources without signing
                    // them. These copies are in addition to any libraries copied as a result
                    // of the --scan-executable option.
                    // Any library in the Swift library search path can be specified for
                    // <library>.
                    // This option may be set multiple times.
                    resourceLibraries.insert(try argParam())

                case "--resource-destination":
                    // --resource-destination <path>
                    // The <path> to copy Swift resource libraries to.
                    var resourceDstDir = self.resourceDstDir
                    try setSingleOccurrence(&resourceDstDir, absolutePath(Path(argParam())))
                    self.resourceDstDir = resourceDstDir

                case "--emit-dependency-info":
                    // --emit-dependency-info <path>
                    // Writes a file to <path> containing paths of any discovered dependencies.
                    var discoveredDepsOutputFile = self.discoveredDepsOutputFile
                    try setSingleOccurrence(&discoveredDepsOutputFile, absolutePath(Path(argParam())))
                    self.discoveredDepsOutputFile = discoveredDepsOutputFile

                case "--filter-for-swift-os":
                    // Remove all libraries found except for those that are not present in swift in the os.
                    self.filterForSwiftOS = true

                case "--back-deploy-swift-concurrency":
                    self.backDeploySwiftConcurrency = true

                default:
                    throw StubError.error("unrecognized argument: \(arg)")
                }
            }

            if shouldStripBitcode && bitcodeStripPath == nil {
                throw StubError.error("Passed --strip-bitcode without --strip-bitcode-tool.")
            }

            if srcDir != nil && toolchainsDirs.count > 0 {
                logV("Ignoring --toolchain paths because --source-libraries was set.")
                toolchainsDirs.removeAll(keepingCapacity: false)
            }

            // Fix up srcDir and platform values.
            if srcDir == nil && platform == nil {
                throw StubError.error("at least one of --source-libraries and --platform must be set")
            }
            else if let srcDir = srcDir, platform == nil {
                // src_dir is set but platform is not.
                // Pick platform from src_dir's name.
                platform = srcDir.basename
            }

            srcDirs = srcDir != nil
                ? OrderedSet([srcDir!])
                : OrderedSet(effectiveSourceDirectories(toolchainsDirs, platform: platform!))
            logVV("Effective srcDirs:\n\(srcDirs.elements.map{$0.str}.joined(separator: "\n"))")

            // Add the platform to unsigned_dst_dir if it is not already present.
            if let unsignedDstDir, platform != unsignedDstDir.basename {
                self.unsignedDstDir = unsignedDstDir.join(platform!)
            }

            // If the user specifies --strip-bitcode but not --sign, this
            // will cause the dylibs to get copied, stripped, but not resigned.
            // This will cause apps to fail to launch because the code signature
            // is invalid.  In this case, ignore --strip-bitcode.
            if shouldStripBitcode && codeSignIdentity == nil {
                logV("Ignoring --strip-bitcode because --sign was not passed")
                shouldStripBitcode = false
            }

            let testLibrarySuffixes = await executionDelegate.requestContext.getKnownTestingLibraryPathSuffixes()

            // Collect executables from the --scan-folder locations.
            for embedDir in scanDirs {
                guard fs.exists(embedDir) else { continue }

                try fs.traverse(embedDir) { path throws -> Void in
                    // Skip embedded XCTest bundles when scanning folders.
                    if path.str.contains(".xctest/") {
                        logVV("Skipping \(path.str) because it is part of an XCTest bundle")
                        return
                    }

                    // Skip test support libraries (e.g. Testing, XCTest, and supporting libraries/frameworks) when scanning folders, since they are copied by test targets which depend on this target, and scanning them (beyond being unnecessary) will lead to dependency cycles.
                    guard !testLibrarySuffixes.contains(where: path.ends(with:)) else {
                        logVV("Skipping \(path.str) because it is an XCTest support library")
                        return
                    }

                    // Skip the Swift libraries which this tool itself copies.
                    guard !executableFileNameMatchesSwiftRuntimeLibPattern(path.basename) else {
                        logVV("Skipping \(path.str) because it is a Swift standard library copied by this tool")
                        return
                    }

                    // Skip temporaries created by `codesign`. These may have disappeared by the time we try to read them, and will never be executables.
                    guard path.fileExtension != "cstemp" else {
                        return
                    }

                    guard let exe = try executableIfValid(path: path) else {
                        logVV("Skipping \(path.str) because it is not an executable file")
                        return
                    }

                    // Skip this binary if it doesn't use Swift.
                    guard exe.usesSwift else {
                        logVV("Skipping \(path.str) because it is not a Swift executable file")
                        return
                    }

                    // If we get here then we can inset the executable in the list of those to scan.
                    scanExecutables.insert(exe)
                }
            }
        }

        func runProcess(_ args: [String]) async throws -> ByteString {
            logV(args.joined(separator: " "))

            final class CapturingOutputDelegate: TaskOutputDelegate {
                func incrementClangCacheHit() {
                    // TBD
                }

                func incrementClangCacheMiss() {
                    // TBD
                }
                func incrementSwiftCacheHit() {}
                func incrementSwiftCacheMiss() {}
                func incrementTaskCounter(_ counter: BuildOperationMetrics.TaskCounter) {}

                var counters: [BuildOperationMetrics.Counter : Int] = [:]
                var taskCounters: [BuildOperationMetrics.TaskCounter : Int] = [:]

                let underlyingDelegate: any TaskOutputDelegate
                var output = ByteString()

                init(outputDelegate underlyingDelegate: any TaskOutputDelegate) {
                    self.underlyingDelegate = underlyingDelegate
                }

                var startTime: Date {
                    underlyingDelegate.startTime
                }

                func emitOutput(_ data: SWBUtil.ByteString) {
                    output += data
                }

                func updateResult(_ result: SWBCore.TaskResult) {
                    underlyingDelegate.updateResult(result)
                }

                func subtaskUpToDate(_ subtask: any SWBCore.ExecutableTask) {
                    underlyingDelegate.subtaskUpToDate(subtask)
                }

                func previouslyBatchedSubtaskUpToDate(signature: SWBUtil.ByteString, target: SWBCore.ConfiguredTarget) {
                    underlyingDelegate.previouslyBatchedSubtaskUpToDate(signature: signature, target: target)
                }

                var result: SWBCore.TaskResult? {
                    underlyingDelegate.result
                }

                var diagnosticsEngine: SWBCore.DiagnosticProducingDelegateProtocolPrivate<SWBUtil.DiagnosticsEngine> {
                    underlyingDelegate.diagnosticsEngine
                }
            }

            let capturingDelegate = CapturingOutputDelegate(outputDelegate: outputDelegate)
            let processDelegate = TaskProcessDelegate(outputDelegate: capturingDelegate)
            try await taskAction.spawn(commandLine: args, environment: effectiveEnvironment, workingDirectory: task.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: processDelegate)
            if let error = processDelegate.executionError {
                throw StubError.error(error)
            }
            let output = capturingDelegate.output
            let failed = (processDelegate.commandResult ?? .failed) != .succeeded
            if failed || verbose > 1 {
                logV(output.asString)
            }

            guard !failed else {
                throw RunProcessNonZeroExitError(args: args, workingDirectory: task.workingDirectory.str, environment: .init(effectiveEnvironment), status: {
                    if case let .exit(exitStatus, _) = processDelegate.outputDelegate.result {
                        return exitStatus
                    }
                    return .uncaughtSignal(0)
                }(), mergedOutput: output)
            }

            return output
        }

        func copyAndStripBitcode(src: Path, dst: Path) async throws {
            let _ = try await runProcess([bitcodeStripPath!.str] + [src.str, "-r", "-o", dst.str])
        }

        func copyFile(src: Path, dst: Path, stripBitcode: Bool) async throws {
            if stripBitcode {
                try await copyAndStripBitcode(src: src, dst: dst)
            }
            else {
                try fs.copy(src, to: dst)
            }
        }

        func copyLibraries(dstDir: Path, libs: Set<Executable>, stripBitcode: Bool, discoveredDependencyInfo: inout DependencyInfo) async throws {
            // If we are asked to copy a set of libs that are empty, then do nothing here. This is important due to: <rdar://problem/48292950>.
            guard !libs.isEmpty else { return }

            try fs.createDirectory(dstDir, recursive: true)

            for srcExe in libs {
                let srcPath = srcExe.path
                let dstPath = dstDir.join(srcPath.basename)

                // Compare UUIDs of src and dst and don't copy if they're the same.
                // Do not use mod times for this task: the dst copy gets code-signed
                // and bitcode-stripped so it can look newer than it really is.
                let dstExe = try executableIfValid(path: dstPath)

                logVV("Source UUIDs \(srcPath.str): \(srcExe.uuids)")
                logVV("Destination UUIDs \(dstPath.str): \(String(describing: dstExe?.uuids))")

                if let dstUUIDs = dstExe?.uuids {
                    if !dstUUIDs.isEmpty && srcExe.uuids == dstUUIDs {
                        logV("\(srcExe.path.basename) is up to date at \(dstPath.str)")
                        continue
                    }
                }

                // Perform the copy.

                logV("Copying \(srcPath.str) to \(dstPath.str)")

                if fs.exists(dstPath) {
                    try fs.remove(dstPath)
                }

                discoveredDependencyInfo.inputs.append(srcPath.str)
                discoveredDependencyInfo.outputs.append(dstPath.str)
                try await copyFile(src: srcPath, dst: dstPath, stripBitcode: stripBitcode)
            }
        }


        func queryCodeSignature(codesign: Path, _ file: Path) async throws -> ByteString {
            logV("Probing signature of \(file.str)")
            return try await runProcess([codesign.str, "-r-", "--display", file.str])
        }

        func codeSignLibrary(codesign: Path, dst: Path) async throws {
            let tmpFilePath = Path(dst.str + ".original")
            defer {
                if fs.exists(tmpFilePath) {
                    do {
                        try fs.remove(tmpFilePath)
                    }
                    catch {
                        logV("Failed to remove: '\(tmpFilePath.str)': \(error)")
                    }
                }
            }

            // Get the code signature, and copy the dylib to the side
            // to preserve it in case it does not change.  We can use
            // this to avoid unnecessary copies during delta installs
            // to devices.
            // FIXME: The build system should handle this.
            let oldSignatureData = try? await queryCodeSignature(codesign: codesign, dst)

            if oldSignatureData != nil {
                // Make a copy of the existing file, with permissions and mtime preserved.
                if fs.exists(tmpFilePath) { try fs.remove(tmpFilePath) }
                try fs.copy(dst, to: tmpFilePath)
            }

            // Proceed with (re-)codesigning.
            logV("Codesigning \(dst.str)")

            // Build the codesign invocation.
            var arguments = ["--force", "--sign", codeSignIdentity!, "--verbose"]

            if let k = keychain {
                arguments.append(contentsOf: ["--keychain", k])
            }

            // Other codesign flags come later so they can override the default flags.
            arguments.append(contentsOf: otherCodeSignFlags)

            arguments.append(dst.str)

            let _ = try await runProcess([codesign.str] + arguments)

            // If we have an existing code signature data, query the new one and compare
            // it with the code signature of the file before we re-signed it.
            // If they are the same, use the original file instead.  This preserves
            // the contents of the file and mtime for use with delta installs.
            if let oldSignatureData {
                let newSignatureData = try await queryCodeSignature(codesign: codesign, dst)

                if oldSignatureData == newSignatureData {
                    logV("Code signature of \(dst.str) is unchanged; keeping original")

                    // The two signatures match.  Unlink the new file, and re-link the old file.
                    if fs.exists(dst) {
                        try fs.remove(dst)
                    }

                    try fs.move(tmpFilePath, to: dst)
                }
            }
        }

        func findSwiftLib(srcDirs: OrderedSet<Path>, name: String, swiftVersion: SwiftABIVersion, isOptional: Bool) throws -> Executable? {
            var foundNameMatches: [Executable] = []

            for srcDir in srcDirs {
                let src = srcDir.join(name)
                if let exe = try executableIfValid(path: src) {
                    if ignoreABIVersion {
                        return exe
                    }

                    // Some of the Swift runtime libs don't use Swift, so we allow either an empty swiftVersion or a swiftVersion which satisfies the requested swiftVersion.
                    if !exe.usesSwift || exe.swiftABIVersion == swiftVersion {
                        return exe
                    }
                    else {
                        foundNameMatches.append(exe)
                    }
                }
            }

            if foundNameMatches.count > 0 {
                for match in foundNameMatches {
                    logV("Found library with mismatched Swift ABI version: \(match.path.str) \(String(describing: match.swiftABIVersion)) (requested \(swiftVersion))")
                }
            }

            if !isOptional {
                let versionStr = ignoreABIVersion ? "" : " for Swift ABI version \(swiftVersion)"
                throw StubError.error("Could not find \(name)\(versionStr)")
            }
            else {
                return nil
            }
        }

        func collectTransitiveDependencies(srcDirs: OrderedSet<Path>, executables: Set<Executable>, swiftVersion: SwiftABIVersion, requireAllDependencies: Bool, discoveredDependencyInfo: inout DependencyInfo) throws -> Set <Executable>
        {
            var worklist = Array(executables)
            var result = Set<Executable>()
            var consideredLibNames = Set<String>()

            while worklist.count > 0 {
                let exe = worklist.popLast()!
                consideredLibNames.insert(exe.path.basename)

                if !executableFileNameMatchesSwiftRuntimeLibPattern(exe.path.basename) {
                    discoveredDependencyInfo.inputs.append(exe.path.str)
                }

                for libName in exe.linkedSwiftLibNames {
                    if consideredLibNames.contains(libName) {
                        continue
                    }

                    consideredLibNames.insert(libName)

                    if let dep = try findSwiftLib(srcDirs: srcDirs, name: libName, swiftVersion: swiftVersion, isOptional: !requireAllDependencies) {
                        result.insert(dep)
                        worklist.append(dep)
                    }
                }
            }

            return result
        }

        func main() async throws -> DependencyInfo {

            // Pick a Swift version that all executables have to agree on.
            let swiftVersionOpt = try scanExecutables.reduce(nil) { (memo: (SwiftABIVersion, Executable)?, newExe: Executable) throws -> (SwiftABIVersion, Executable)? in
                switch  (memo?.0,                   newExe.swiftABIVersion) {
                case    (_,                         nil):
                    return memo

                case    (nil,                       .some(let newVersion)):
                    return (newVersion, newExe)

                case    (.some(let prevVersion),    .some(let newVersion)):
                    guard prevVersion != newVersion else { return memo }

                    let mismatch = scanExecutables.first { object -> Bool in
                        return object.swiftABIVersion != nil && object.swiftABIVersion! != newVersion
                        }!

                    let paths = [mismatch.path.str, newExe.path.str].sorted()
                    let message = "The following binaries use incompatible versions of Swift:\n\(paths.joined(separator: "\n"))"
                    if ignoreABIVersion {
                        self.outputDelegate.emitWarning(message)
                        return memo
                    }
                    else {
                        throw StubError.error(message)
                    }
                }
                }?.0

            // Discovered dependency paths, collected during processing, emitted at the end.
            var discoveredDependencyInfo = DependencyInfo(version: "swift-stdlib-tool")
            discoveredDependencyInfo.inputs.append(contentsOf: scanExecutables.map { $0.path.str })

            guard let swiftVersion = swiftVersionOpt else {
                logV("Exiting early, found no Swift version in executables.")
                return discoveredDependencyInfo
            }
            if !ignoreABIVersion {
                // Let's only show the ABI version when this is an unstable ABI being used.
                if case .unstable(_) = swiftVersion {
                    logV("Requested Swift ABI version based on scanned binaries: \(swiftVersion)")
                }
            }

            // Collect Swift library names from the input files and follow dependencies recursively.
            let dependencies = try collectTransitiveDependencies(srcDirs: srcDirs,
                                                                 executables: scanExecutables,
                                                                 swiftVersion: swiftVersion,
                                                                 requireAllDependencies: false, // If the library does not exist in srcDirs then assume the user wrote their own library named libswift* and is handling it elsewhere.
                                                                 discoveredDependencyInfo: &discoveredDependencyInfo)

            // The list of dependencies needs to be pruned based on the filtering mechanism. Under normal circumstances, no libraries are expected to be allowed.
            let swiftLibs = dependencies
                .filter {
                    let item = $0.path.basenameWithoutSuffix

                    var shouldInclude = true
                    if filterForSwiftOS && !allowedLibsForSwiftOS.contains(item) {
                        shouldInclude = false
                    }
                    if backDeploySwiftConcurrency && allowedLibsForSwiftConcurrency.contains(item) {
                        shouldInclude = true
                    }

                    return shouldInclude
                }

            // Collect all the Swift libraries that the user requested with --resource-library.

            let resourceLibrariesExecutables = try Set(resourceLibraries.map{ obj throws -> Executable in
                return try findSwiftLib(srcDirs: srcDirs, name: obj, swiftVersion: swiftVersion, isOptional: false)!
            })

            let swiftLibsForResources: Set<Executable> = try collectTransitiveDependencies(
                srcDirs: srcDirs,
                executables: resourceLibrariesExecutables,
                swiftVersion: swiftVersion,
                requireAllDependencies: true, // These are system libraries and they should be complete.
                discoveredDependencyInfo: &discoveredDependencyInfo
            ).union(resourceLibrariesExecutables)

            // Print the Swift libraries (full path to toolchain's copy)
            if shouldPrint {
                for lib in swiftLibs {
                    outputDelegate.emitNote(lib.path.str)
                }
            }

            // Copy the Swift libraries to $build_dir/$frameworks
            // and $build_dir/$unsigned_frameworks
            if shouldCopy {
                try await copyLibraries(dstDir: dstDir!, libs: swiftLibs, stripBitcode: shouldStripBitcode, discoveredDependencyInfo: &discoveredDependencyInfo)

                if unsignedDstDir != nil {
                    // Never strip bitcode from the unsigned libraries.
                    // Their existing signatures must be preserved.
                    try await copyLibraries(dstDir: unsignedDstDir!, libs: swiftLibs, stripBitcode: false, discoveredDependencyInfo: &discoveredDependencyInfo)
                }

                if let resourceDstDir = resourceDstDir {
                    // Never strip bitcode from resources libraries, for
                    // the same reason as the libraries copied to
                    // unsigned_dst_dir.
                    try await copyLibraries(dstDir: resourceDstDir, libs: swiftLibsForResources, stripBitcode: false, discoveredDependencyInfo: &discoveredDependencyInfo)
                }
            }

            // Codesign the Swift libraries in $build_dir/$frameworks
            // but not the libraries in $build_dir/$unsigned_frameworks.
            if codeSignIdentity != nil && !swiftLibs.isEmpty {
                let codesign = Path(self.effectiveEnvironment["CODESIGN"] ?? "/usr/bin/codesign")

                // Swift libraries that are up-to-date get codesigned anyway
                // (in case options changed or a previous build was incomplete).

                // Work around authentication UI problems (rdar://23019128)
                // by signing one synchronously and then signing the rest.
                let swiftLibsArray = Array(swiftLibs)
                if let lib = swiftLibsArray.first {
                    try await codeSignLibrary(codesign: codesign, dst: dstDir!.join(lib.path.basename))
                }

                let swiftLibsRest = swiftLibsArray.dropFirst()

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for lib in swiftLibsRest {
                        group.addTask {
                            try await self.codeSignLibrary(codesign: codesign, dst: self.dstDir!.join(lib.path.basename))
                        }
                    }
                    try await group.waitForAll()
                }
            }

            return discoveredDependencyInfo
        }
    }

    override public class var toolIdentifier: String {
        return "embed-swift-stdlib"
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        do {
            let rt = try await RunningTask(task: task, taskAction: self, dynamicExecutionDelegate: dynamicExecutionDelegate, executionDelegate: executionDelegate, clientDelegate: clientDelegate, outputDelegate: outputDelegate)
            let discoveredDependencyInfo = try await rt.main()

            // Write out the discovered dependencies, if we've been asked to.
            if let discoveredDepsOutputFile = rt.discoveredDepsOutputFile {
                try rt.fs.write(discoveredDepsOutputFile, contents: ByteString(discoveredDependencyInfo.normalized().asBytes()))
            }

            return .succeeded
        }
        catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }
}
