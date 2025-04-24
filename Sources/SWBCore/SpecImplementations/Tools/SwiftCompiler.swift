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

import class Foundation.ProcessInfo
import class Foundation.JSONEncoder
import struct Foundation.Data
import SWBLibc
public import SWBProtocol
public import SWBUtil
public import struct SWBProtocol.TargetDescription
public import enum SWBProtocol.BuildAction
import Foundation
public import SWBMacro

/// The minimal data we need to serialize to reconstruct `SwiftSourceFileIndexingInfo` from `generateIndexingInfoForTask`
public struct SwiftIndexingPayload: Serializable, Sendable {
    // If `USE_SWIFT_RESPONSE_FILE` is enabled, we use `filePaths`, otherwise `range`.
    // This is very unfortunate and will be removed in rdar://53000820
    public enum Inputs: Encodable, Sendable {
        case filePaths(Path, [Path])
        case range(Range<Int>)
    }

    private enum InputsCode: Int, Serializable {
        case filePaths = 0
        case range = 1
    }

    public let inputs: Inputs
    public let inputReplacements: [Path: Path]
    public let builtProductsDir: Path
    public let assetSymbolIndexPath: Path
    public let objectFileDir: Path
    public let toolchains: [String]

    init(inputs: Inputs, inputReplacements: [Path: Path], builtProductsDir: Path, assetSymbolIndexPath: Path, objectFileDir: Path, toolchains: [String]) {
        self.inputs = inputs
        self.inputReplacements = inputReplacements
        self.builtProductsDir = builtProductsDir
        self.assetSymbolIndexPath = assetSymbolIndexPath
        self.objectFileDir = objectFileDir
        self.toolchains = toolchains
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(7) {
            switch inputs {
            case let .filePaths(responseFilePath, inputFiles):
                serializer.serialize(InputsCode.filePaths)
                serializer.serializeAggregate(2) {
                    serializer.serialize(responseFilePath)
                    serializer.serialize(inputFiles)
                }
            case let .range(range):
                serializer.serialize(InputsCode.range)
                serializer.serialize(range)
            }
            serializer.serialize(inputReplacements)
            serializer.serialize(builtProductsDir)
            serializer.serialize(assetSymbolIndexPath)
            serializer.serialize(objectFileDir)
            serializer.serialize(toolchains)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        switch try deserializer.deserialize() as InputsCode {
        case .filePaths:
            try deserializer.beginAggregate(2)
            self.inputs = try .filePaths(deserializer.deserialize(), deserializer.deserialize())
        case .range:
            self.inputs = .range(try deserializer.deserialize())
        }
        self.inputReplacements = try deserializer.deserialize()
        self.builtProductsDir = try deserializer.deserialize()
        self.assetSymbolIndexPath = try deserializer.deserialize()
        self.objectFileDir = try deserializer.deserialize()
        self.toolchains = try deserializer.deserialize()
    }
}

/// The indexing info for a file being compiled by swiftc.  This will be sent to the client in a property list format described below.
public struct SwiftSourceFileIndexingInfo: SourceFileIndexingInfo {
    @_spi(Testing) public let commandLine: [ByteString]
    let builtProductsDir: Path
    let assetSymbolIndexPath: Path
    let toolchains: [String]
    let outputFile: Path

    public init(task: any ExecutableTask, payload: SwiftIndexingPayload, outputFile: Path, enableIndexBuildArena: Bool, integratedDriver: Bool) {
        self.commandLine = Self.indexingCommandLine(commandLine: task.commandLine.map(\.asByteString), payload: payload, enableIndexBuildArena: enableIndexBuildArena, integratedDriver: integratedDriver)
        self.builtProductsDir = payload.builtProductsDir
        self.assetSymbolIndexPath = payload.assetSymbolIndexPath
        self.toolchains = payload.toolchains
        self.outputFile = outputFile
    }

    // Arguments to skip for background indexing/AST building. This could be
    // to save computing them when it's not necessary, to avoid additional
    // outputs, or just because they don't make sense in the context of
    // indexing (eg. skipping all function bodies).
    //
    // TODO: It's pretty brittle relying on this to exclude supplementary
    // outputs, the driver ought to provide an easier way of doing that, either
    // through a dedicated indexing mode (which it sort of already has, as it
    // recognizes '-index-file' as a primary output), or a more generic
    // "only give me the primary output and nothing else" mode.
    private static let removeFlags: Set<ByteString> = [
        "-emit-dependencies",
        "-serialize-diagnostics",
        "-incremental",
        "-parseable-output",
        "-use-frontend-parseable-output",
        "-whole-module-optimization",
        "-save-temps",
        "-no-color-diagnostics",
        "-disable-cmo",
        "-validate-clang-modules-once",
        "-emit-module",
        "-emit-module-interface",
        "-emit-objc-header",
        "-lto=llvm-thin",
        "-lto=llvm-full"
    ]
    private static let removeArgs: Set<ByteString> = [
        "-o",
        "-output-file-map",
        "-clang-build-session-file",
        "-num-threads",
        "-emit-module-path",
        "-emit-module-interface-path",
        "-emit-private-module-interface-path",
        "-emit-package-module-interface-path",
        "-emit-objc-header-path"
    ]
    private static let removeFrontendArgs: Set<ByteString> = [
        "-experimental-skip-non-inlinable-function-bodies",
        "-experimental-skip-all-function-bodies"]

    // SourceKit uses the old driver to determine the frontend args. Remove all
    // new driver flags as a workaround for cases were corresponding no-op
    // flags weren't added to the old driver. This shouldn't be required and
    // can be removed after we use the new driver instead (rdar://75851402).
    private static let newDriverFlags: Set<ByteString> = [
        "-driver-print-graphviz",
        "-explicit-module-build",
        "-experimental-explicit-module-build",
        "-nonlib-dependency-scanner",
        "-driver-warn-unused-options",
        "-experimental-emit-module-separately",
        "-emit-module-separately-wmo",
        "-no-emit-module-separately-wmo",
        "-use-frontend-parseable-output",
        "-emit-digester-baseline"]
    private static let newDriverArgs: Set<ByteString> = [
        "-emit-module-serialize-diagnostics-path",
        "-emit-module-dependencies-path",
        "-emit-digester-baseline-path",
        "-compare-to-baseline-path",
        "-serialize-breaking-changes-path",
        "-digester-breakage-allowlist-path",
        "-digester-mode"]

    private static func indexingCommandLine(commandLine: [ByteString], payload: SwiftIndexingPayload, enableIndexBuildArena: Bool, integratedDriver: Bool) -> [ByteString] {
        precondition(!commandLine.isEmpty)

        var result: [ByteString] = []
        var index = 0

        if integratedDriver {
            index = commandLine.firstIndex(of: "--") ?? commandLine.endIndex
            index += 1
        }

        // Skip the compiler path
        index += 1

        while index < commandLine.count {
            let arg = commandLine[index]
            index += 1

            // Skip unwanted single flags
            guard !removeFlags.contains(arg), !newDriverFlags.contains(arg) else {
                continue
            }

            // Skip unwanted flags and their argument
            guard !removeArgs.contains(arg), !newDriverArgs.contains(arg) else {
                index += 1
                continue
            }

            if let nextArg = commandLine[safe: index] {
                // Remove frontend args (including the -Xfrontend)
                if removeFrontendArgs.contains(nextArg) {
                    index += 1
                    continue
                }

                // <rdar://problem/23297285> Swift tests are not being discovered, XCTest framework from the project fails to import correctly
                if !enableIndexBuildArena, UserDefaults.enableFixFor23297285,
                   arg == "-I" || arg == "-F" {
                    result.append(contentsOf: ["-Xcc", arg, "-Xcc", nextArg])
                }
            }

            switch payload.inputs {
            case let .filePaths(responseFilePath, paths):
                // Replace file lists with all files
                if arg == ByteString(encodingAsUTF8: "@" + responseFilePath.str) {
                    for input in paths {
                        let pathToAdd = payload.inputReplacements[input] ?? input
                        result.append(ByteString(encodingAsUTF8: pathToAdd.str))
                    }
                    continue
                }
            case .range(_):
                if let pathToAdd = payload.inputReplacements[Path(arg.asString)] {
                    result.append(ByteString(encodingAsUTF8: pathToAdd.str))
                    continue
                }
            }

            result.append(arg)
        }

        if !enableIndexBuildArena {
            // Add the supplemental C compiler options in the legacy case.
            let clangArgs = ClangCompilerSpec.supplementalIndexingArgs(allowCompilerErrors: false)
            result += clangArgs.flatMap { ["-Xcc", ByteString(encodingAsUTF8: $0)] }
        }

        return result
    }

    /// The indexing info is packaged and sent to the client in the property list format defined here.
    public var propertyListItem: PropertyListItem {
        var dict = [String: PropertyListItem]()

        // FIXME: Convert to bytes.
        dict["LanguageDialect"] = PropertyListItem("swift")
        // FIXME: Convert to bytes.
        dict["swiftASTCommandArguments"] = PropertyListItem(commandLine.map{ $0.asString })
        dict["swiftASTBuiltProductsDir"] = PropertyListItem(builtProductsDir.str)
        dict["assetSymbolIndexPath"] = PropertyListItem(assetSymbolIndexPath.str)
        dict["toolchains"] = PropertyListItem(toolchains)

        func getopt(_ key: ByteString) -> ByteString? {
            guard let argIndex = commandLine.firstIndex(of: key) else { return nil }
            let valueIndex = commandLine.index(after: argIndex)
            guard valueIndex < commandLine.endIndex else { return nil }
            return commandLine[valueIndex]
        }

        guard let moduleName = getopt("-module-name")?.asString else { preconditionFailure("Expected to have -module-name in: \(commandLine.map{$0.asString})") }
        dict["swiftASTModuleName"] = PropertyListItem(moduleName)

        dict["outputFilePath"] = PropertyListItem(outputFile.str)

        return .plDict(dict)
    }
}

/// The minimal data we need to serialize to reconstruct `generatePreviewInfo`
public struct SwiftPreviewPayload: Serializable, Encodable, Sendable {
    public let architecture: String
    public let buildVariant: String
    public let objectFileDir: Path
    public let moduleCacheDir: Path

    init(architecture: String, buildVariant: String, objectFileDir: Path, moduleCacheDir: Path) {
        self.architecture = architecture
        self.buildVariant = buildVariant
        self.objectFileDir = objectFileDir
        self.moduleCacheDir = moduleCacheDir
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(architecture)
            serializer.serialize(buildVariant)
            serializer.serialize(objectFileDir)
            serializer.serialize(moduleCacheDir)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.architecture = try deserializer.deserialize()
        self.buildVariant = try deserializer.deserialize()
        self.objectFileDir = try deserializer.deserialize()
        self.moduleCacheDir = try deserializer.deserialize()
    }
}

/// The minimal data we need to serialize to reconstruct `generateLocalizationInfo`
public struct SwiftLocalizationPayload: Serializable, Sendable {
    public let effectivePlatformName: String
    public let buildVariant: String
    public let architecture: String

    init(effectivePlatformName: String, buildVariant: String, architecture: String) {
        self.effectivePlatformName = effectivePlatformName
        self.buildVariant = buildVariant
        self.architecture = architecture
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(3) {
            serializer.serialize(effectivePlatformName)
            serializer.serialize(buildVariant)
            serializer.serialize(architecture)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.effectivePlatformName = try deserializer.deserialize()
        self.buildVariant = try deserializer.deserialize()
        self.architecture = try deserializer.deserialize()
    }
}

public struct SwiftDriverPayload: Serializable, TaskPayload, Encodable {
    public let uniqueID: String
    public let compilerLocation: LibSwiftDriver.CompilerLocation
    public let moduleName: String
    public let tempDirPath: Path
    public let explicitModulesTempDirPath: Path
    public let variant: String
    public let architecture: String
    public let eagerCompilationEnabled: Bool
    public let explicitModulesEnabled: Bool
    public let commandLine: [String]
    public let ruleInfo: [String]
    public let isUsingWholeModuleOptimization: Bool
    public let casOptions: CASOptions?
    public let reportRequiredTargetDependencies: BooleanWarningLevel
    public let linkerResponseFilePath: Path?
    public let dependencyFilteringRootPath: Path?
    public let verifyScannerDependencies: Bool

    internal init(uniqueID: String, compilerLocation: LibSwiftDriver.CompilerLocation, moduleName: String, tempDirPath: Path, explicitModulesTempDirPath: Path, variant: String, architecture: String, eagerCompilationEnabled: Bool, explicitModulesEnabled: Bool, commandLine: [String], ruleInfo: [String], isUsingWholeModuleOptimization: Bool, casOptions: CASOptions?, reportRequiredTargetDependencies: BooleanWarningLevel, linkerResponseFilePath: Path?, dependencyFilteringRootPath: Path?, verifyScannerDependencies: Bool) {
        self.uniqueID = uniqueID
        self.compilerLocation = compilerLocation
        self.moduleName = moduleName
        self.tempDirPath = tempDirPath
        self.explicitModulesTempDirPath = explicitModulesTempDirPath
        self.variant = variant
        self.architecture = architecture
        self.eagerCompilationEnabled = eagerCompilationEnabled
        self.explicitModulesEnabled = explicitModulesEnabled
        self.commandLine = commandLine
        self.ruleInfo = ruleInfo
        self.isUsingWholeModuleOptimization = isUsingWholeModuleOptimization
        self.casOptions = casOptions
        self.reportRequiredTargetDependencies = reportRequiredTargetDependencies
        self.linkerResponseFilePath = linkerResponseFilePath
        self.dependencyFilteringRootPath = dependencyFilteringRootPath
        self.verifyScannerDependencies = verifyScannerDependencies
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(17)
        self.uniqueID = try deserializer.deserialize()
        self.compilerLocation = try deserializer.deserialize()
        self.moduleName = try deserializer.deserialize()
        self.tempDirPath = try deserializer.deserialize()
        self.explicitModulesTempDirPath = try deserializer.deserialize()
        self.variant = try deserializer.deserialize()
        self.architecture = try deserializer.deserialize()
        self.eagerCompilationEnabled = try deserializer.deserialize()
        self.explicitModulesEnabled = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
        self.ruleInfo = try deserializer.deserialize()
        self.isUsingWholeModuleOptimization = try deserializer.deserialize()
        self.casOptions = try deserializer.deserialize()
        self.reportRequiredTargetDependencies = try deserializer.deserialize()
        self.linkerResponseFilePath = try deserializer.deserialize()
        self.dependencyFilteringRootPath = try deserializer.deserialize()
        self.verifyScannerDependencies = try deserializer.deserialize()
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(17) {
            serializer.serialize(self.uniqueID)
            serializer.serialize(self.compilerLocation)
            serializer.serialize(self.moduleName)
            serializer.serialize(self.tempDirPath)
            serializer.serialize(self.explicitModulesTempDirPath)
            serializer.serialize(self.variant)
            serializer.serialize(self.architecture)
            serializer.serialize(self.eagerCompilationEnabled)
            serializer.serialize(self.explicitModulesEnabled)
            serializer.serialize(self.commandLine)
            serializer.serialize(self.ruleInfo)
            serializer.serialize(self.isUsingWholeModuleOptimization)
            serializer.serialize(self.casOptions)
            serializer.serialize(self.reportRequiredTargetDependencies)
            serializer.serialize(self.linkerResponseFilePath)
            serializer.serialize(self.dependencyFilteringRootPath)
            serializer.serialize(self.verifyScannerDependencies)
        }
    }
}

public protocol ParentTaskPayload: TaskPayload {
    var numExpectedCompileSubtasks: Int { get }
}

/// Payload information for Swift tasks.
public struct SwiftTaskPayload: ParentTaskPayload {
    public let moduleName: String

    /// The indexing specific information.
    public let indexingPayload: SwiftIndexingPayload

    /// The preview specific information.
    public let previewPayload: SwiftPreviewPayload?

    /// Localization-specific information (about extracted .stringsdata).
    public let localizationPayload: SwiftLocalizationPayload?

    /// The expected number of compile subtasks that will be spawned by the Swift compiler.
    public let numExpectedCompileSubtasks: Int

    /// Extra payload for the swift driver invocation
    public let driverPayload: SwiftDriverPayload?

    /// The preview build style in effect (dynamic replacement or XOJIT), if any.
    public let previewStyle: PreviewStyleMessagePayload?

    init(moduleName: String, indexingPayload: SwiftIndexingPayload, previewPayload: SwiftPreviewPayload?, localizationPayload: SwiftLocalizationPayload?, numExpectedCompileSubtasks: Int, driverPayload: SwiftDriverPayload?, previewStyle: PreviewStyle?) {
        self.moduleName = moduleName
        self.indexingPayload = indexingPayload
        self.previewPayload = previewPayload
        self.localizationPayload = localizationPayload
        self.numExpectedCompileSubtasks = numExpectedCompileSubtasks
        self.driverPayload = driverPayload
        switch previewStyle {
        case .dynamicReplacement:
            self.previewStyle = .dynamicReplacement
        case .xojit:
            self.previewStyle = .xojit
        case nil:
            self.previewStyle = nil
        }
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(7) {
            serializer.serialize(moduleName)
            serializer.serialize(indexingPayload)
            serializer.serialize(previewPayload)
            serializer.serialize(localizationPayload)
            serializer.serialize(numExpectedCompileSubtasks)
            serializer.serialize(driverPayload)
            serializer.serialize(previewStyle)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        self.moduleName = try deserializer.deserialize()
        self.indexingPayload = try deserializer.deserialize()
        self.previewPayload = try deserializer.deserialize()
        self.localizationPayload = try deserializer.deserialize()
        self.numExpectedCompileSubtasks = try deserializer.deserialize()
        self.driverPayload = try deserializer.deserialize()
        self.previewStyle = try deserializer.deserialize()
    }
}

/// A parser for Swift's parseable output.
///
/// See: https://github.com/apple/swift/blob/main/docs/DriverParseableOutput.rst
public final class SwiftCommandOutputParser: TaskOutputParser {
    // no such module 'Foo'
    private static let noSuchModuleRegEx = (RegEx(patternLiteral: "^no such module '(.+)'$"), false)

    /// The known message kinds.
    enum MessageKind: String {
        case began
        case finished
        case abnormal = "abnormal-exit" // Windows exceptions
        case signalled // POSIX signals
        case skipped
    }

    /// The subtask names reported by the Swift's parsable output.
    enum SubtaskName: String {
        case compile
        case backend
        case mergeModule = "merge-module"
        case emitModule = "emit-module"
        case verifyEmittedModuleInterface = "verify-module-interface"
        case legacyVerifyEmittedModuleInterface = "verify-emitted-module-interface"
        case link
        case generatePCH = "generate-pch"
        case generatePCM = "generate-pcm"
        case compileModuleFromInterface = "compile-module-from-interface"
        case generateDSYM = "generate-dsym"
    }

    /// An executing subtask.
    struct Subtask {
        let pid: Int

        let serializedDiagnosticsPaths: [Path]

        let delegate: any TaskOutputParserDelegate

        func nonEmptyDiagnosticsPaths(fs: any FSProxy) -> [Path] {
            serializedDiagnosticsPaths.filter { path in
                // rdar://91295617 (Swift produces empty serialized diagnostics if there are none which is not parseable by clang_loadDiagnostics)
                do {
                    return try fs.exists(path) && fs.getFileInfo(path).statBuf.st_size > 0
                } catch {
                    return false
                }
            }
        }
    }

    public let delegate: any TaskOutputParserDelegate

    var task: (any ExecutableTask)?

    public let workspaceContext: WorkspaceContext

    public let buildRequestContext: BuildRequestContext

    /// The name of the target that this parser is working on.
    let targetName: String?

    /// The task working directory.
    let workingDirectory: Path

    /// The variant information, from the task.
    let variant: String

    /// The arch information, from the task.
    let arch: String

    /// The current buffered contents.
    var buffer: [UInt8] = []

    /// Whether or not there was a stream error, which cancels parsing.
    var hasStreamError = false

    /// The map of open subtasks.
    var subtasks: [Int: Subtask] = [:]

    /// The subtask progress reporter.
    let progressReporter: (any SubtaskProgressReporter)?

    let commandDecoder = LLVMStyleCommandCodec()

    /// `true` if this task is using the Swift integrated driver.
    let usingSwiftIntegratedDriver: Bool

    /// Simplified initializer, for testing convenience.
    @_spi(Testing) public init(targetName: String? = nil, workingDirectory: Path, variant: String, arch: String, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?, usingSwiftIntegratedDriver: Bool = false) {
        self.targetName = targetName
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
        self.workingDirectory = workingDirectory
        self.variant = variant
        self.arch = arch
        self.progressReporter = progressReporter
        self.usingSwiftIntegratedDriver = usingSwiftIntegratedDriver
    }

    convenience public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        // Extract the variant and arch from the task.
        precondition(task.ruleInfo.count >= 3, "unexpected rule info: \(task.ruleInfo)")

        // Get a Settings object, and compute state which we know will be needed multiple times when processing output from this task.
        // Due to rdar://53726633, the actual target instance needs to be re-fetched instead of used directly, when retrieving the settings.
        var usingSwiftIntegratedDriver = false
        if let configuredTarget = task.forTarget, let target = workspaceContext.workspace.target(for: configuredTarget.target.guid) {
            let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: target)
            usingSwiftIntegratedDriver = settings.globalScope.evaluate(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER)
        }

        self.init(targetName: task.forTarget?.target.name, workingDirectory: task.workingDirectory, variant: task.ruleInfo[1], arch: task.ruleInfo[2], workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, delegate: delegate, progressReporter: progressReporter, usingSwiftIntegratedDriver: usingSwiftIntegratedDriver)
        self.task = task

        // Report the number of compile subtasks as the scanning count.
        // This is only done for tasks with a ParentTaskPayload type, for example SwiftTaskPayload for the original one-per-target Swift driver task.  The dynamic frontend tasks issued when using the integrated driver have a SwiftDriverJobDynamicTaskPayload, which is not of that type, and so the progress reported here for those tasks will be zero.
        progressReporter?.subtasksScanning(count: (task.payload as? (any ParentTaskPayload))?.numExpectedCompileSubtasks ?? 0, forTargetName: targetName)
    }

    public func write(bytes: ByteString) {
        guard !hasStreamError else {
            return
        }

        // Append to the buffer.
        buffer.append(contentsOf: bytes.bytes)

        // Parse off each complete individual message.
        //
        // The encoding is an ASCII one:
        // <length>\n
        // <contents>\n
        var slice = buffer[buffer.startIndex ..< buffer.endIndex]
        while !slice.isEmpty {
            // Get the end of the length.
            guard let lengthTerminator = slice.firstIndex(of: UInt8(ascii: "\n")) else {
                break
            }

            // We expect the slice to be a single integer length followed by a newline.
            guard let lengthString = String(bytes: slice[slice.startIndex ..< lengthTerminator], encoding: .utf8),
                  let length = Int(lengthString) else {
                // Non-parseable chunks are *assumed* to be output, currently.
                //
                // This actually happens in practice in at least one case when the swiftc subprocess crashes.
                let eol = slice.index(after: lengthTerminator)
                delegate.emitOutput(ByteString(slice[slice.startIndex ..< eol]))
                slice = slice[eol ..< slice.endIndex]
                continue
            }

            // If the bytes are available, we have a message. The length does not including the trailing newline.
            let dataStart = slice.index(after: lengthTerminator)
            let dataEnd = slice.index(dataStart, offsetBy: length + 1)
            guard dataEnd <= slice.endIndex else {
                break
            }

            // We found a message.
            handleMessage(Array(slice[dataStart ..< dataEnd]))

            // Update the slice.
            slice = slice[dataEnd ..< slice.endIndex]
        }

        // Update the buffer.
        self.buffer = Array(slice)
    }

    public func close(result: TaskResult?) {
        // If we have any open subtasks, then we report them as completed.  It's likely that the top-level Swift compiler task was cancelled and therefore its subtasks were never able to emit a 'finished' message for us to handle to report them as having completed.  We want to report them here so the client can clean up any state it has for the subtasks.
        for subtask in subtasks.values {
            // Reporting that the task was 'signalled' will indicate to the client that it should not read any diagnostics file for the incomplete subtask.  This is an awkward way to do this, but we don't want the client to try to read such a file, and I don't think we should rely at this level on the client silently ignoring the absence of a file, given that we're reporting an exit status of 0 (which is also a bit squirrelly).  I think we need a more robust API here to handle this case cleanly.
            let exitStatus: Processes.ExitStatus
            switch result {
            case .exit(let status, _)?:
                if status.isSuccess {
                    exitStatus = status
                } else {
                    exitStatus = subtask.nonEmptyDiagnosticsPaths(fs: workspaceContext.fs).isEmpty ? .buildSystemCanceledTask : status
                }
            case .failedSetup?:
                exitStatus = .buildSystemCanceledTask
            case .skipped?:
                exitStatus = .exit(0)
            case nil:
                exitStatus = .buildSystemCanceledTask
            }
            subtask.delegate.taskCompleted(exitStatus: exitStatus)
            subtask.delegate.close()
        }
        subtasks.removeAll()
        delegate.close()
    }

    /// Compute the title to use for this subtask.
    private func computeSubtaskTitle(_ name: String, _ onlyInput: Path?, _ inputCount: Int) -> String {
        if let name = SubtaskName(rawValue: name) {
            let title: String
            switch name {
            case .compile:
                title = onlyInput.map{ "Compile \($0.basename)" } ?? "Compile \(inputCount) Swift source files"
            case .backend:
                title = onlyInput.map{ "Code Generation \($0.basename)" } ?? "Code Generation for Swift source files"
            case .mergeModule:
                title = onlyInput.map{ "Merge \($0.basename)" } ?? "Merge swiftmodule"
            case .emitModule:
                title = "Emit Swift module"
            case .compileModuleFromInterface:
                title = "Compile Swift module interface"
            case .verifyEmittedModuleInterface, .legacyVerifyEmittedModuleInterface:
                title = onlyInput.map{ "Verify \($0.basename)" } ?? "Verify swiftinterface"
            case .link:
                title = "Link"
            case .generatePCH:
                title = onlyInput.map{ "Precompile Bridging Header \($0.basename)" } ?? "Precompile bridging header"
            case .generatePCM:
                title = onlyInput.map{ "Compile Clang module \($0.basename)" } ?? "Compile Clang module"
            case .generateDSYM:
                title = "Generate dSYM"
            }
            // Add the architecture so it's easy for users to distinguish tasks which are otherwise identical across architectures by their build log title.
            return title + " (\(arch))"
        } else {
            delegate.diagnosticsEngine.emit(data: DiagnosticData("unknown Swift parseable message name: `\(name)`"), behavior: .warning)
            return name
        }
    }

    /// Compute the rule info signature to use for this subtask.
    private func computeSubtaskSignatureName(_ name: String) -> String {
       if let name = SubtaskName(rawValue: name) {
            switch name {
            case .compile:
                return "CompileSwift"
            case .backend:
                return "SwiftCodeGeneration"
            case .mergeModule:
                return "MergeSwiftModule"
            case .emitModule:
                return "EmitSwiftModule"
            case .compileModuleFromInterface:
                return "CompileSwiftModuleInterface"
            case .verifyEmittedModuleInterface, .legacyVerifyEmittedModuleInterface:
                return "VerifyEmittedModuleInterface"
            case .link:
                return "Swift-Link"
            case .generatePCH:
                return "PrecompileSwiftBridgingHeader"
            case .generatePCM:
                return "CompileClangModule"
            case .generateDSYM:
                return "Swift-GenerateDSYM"
            }
        } else {
            delegate.diagnosticsEngine.emit(data: DiagnosticData("unknown Swift parseable message name: `\(name)`"), behavior: .warning)
            return "Swift-\(name)"
        }
    }

    /// Finds all outputs in a message of the given type.
    ///
    /// - Returns: The output paths, or nil if the message could not be understood.
    private func findOutputs(in contents: [String: PropertyListItem], ofType type: String) -> [Path]? {
        guard case let .plArray(outputContents)? = contents["outputs"] else { return nil }

        var result = [Path]()
        for item in outputContents {
            guard case let .plDict(contents) = item,
                  case let .plString(itemType)? = contents["type"] else {
                delegate.diagnosticsEngine.emit(data: DiagnosticData("invalid item in Swift parseable output message (\(item))"), behavior: .error)
                return nil
            }
            if itemType == type {
                guard case let .plString(path)? = contents["path"] else {
                    delegate.diagnosticsEngine.emit(data: DiagnosticData("invalid item in Swift parseable output message (\(item))"), behavior: .error)
                    return nil
                }
                result.append(Path(path))
            }
        }
        return result
    }

    private func handleMessage(_ data: [UInt8]) {
        func error(_ message: String) {
            delegate.diagnosticsEngine.emit(data: DiagnosticData("invalid Swift parseable output message (\(message)): `\(data.asReadableString())`"), behavior: .error)
        }

        // Convert from JSON.
        guard let json = try? PropertyList.fromJSONData(data), case let .plDict(contents) = json else {
            return error("malformed JSON")
        }

        // Decode the message.
        guard case let .plString(kindName)? = contents["kind"], let kind = MessageKind(rawValue: kindName) else {
            return error("missing kind")
        }
        guard case let .plString(name)? = contents["name"] else {
            return error("missing name")
        }

        // Extract the singleton input, if present.
        var onlyInput: Path? = nil
        var inputCount = 0
        if case let .plArray(inputContents)? = contents["inputs"] {
            var hadInput = false
            for case let .plString(value) in inputContents {
                if value.hasSuffix(".swift") ||
                   value.hasSuffix(".swiftinterface") ||
                   value.hasSuffix(".modulemap") {
                    inputCount += 1
                    if !hadInput {
                        hadInput = true
                        onlyInput = Path(value)
                    } else {
                        onlyInput = nil
                    }
                }
            }
        }

        let subtaskName = SubtaskName(rawValue: name)

        // Process the message.
        switch kind {
        case .began:
            // Start a new subtask.
            guard case let .plInt(pid)? = contents["pid"] else {
                return error("missing pid")
            }
            if subtasks[pid] != nil {
                    return error("invalid pid \(pid) (already in use)")
            }

            // Compute the title.
            let title = computeSubtaskTitle(name, onlyInput, inputCount)

            // Find the serialized diagnostics, if expected.
            let serializedDiagnosticsPaths: [Path]
            if let outputs = findOutputs(in: contents, ofType: "diagnostics") {
                serializedDiagnosticsPaths = outputs
            } else {
                serializedDiagnosticsPaths = []
            }

            let (ruleInfo, signature) = computeRuleInfo(name: name, onlyInput: onlyInput)

            // Start the subtask.
            let subtaskDelegate = delegate.startSubtask(
                // FIXME: This should really come from the spec definition, but we don't have enough information to get that here.
                buildOperationIdentifier: self.delegate.buildOperationIdentifier,
                taskName: "Swift Compiler",
                id: ByteString(encodingAsUTF8: String(pid)),
                signature: signature,
                ruleInfo: ruleInfo,
                executionDescription: title,
                commandLine: [],
                additionalOutput: [],
                interestingPath: onlyInput,
                workingDirectory: workingDirectory,
                serializedDiagnosticsPaths: serializedDiagnosticsPaths)
            subtasks[pid] = Subtask(pid: pid, serializedDiagnosticsPaths: serializedDiagnosticsPaths, delegate: subtaskDelegate)

            if subtaskName == .compile, !usingSwiftIntegratedDriver {
                progressReporter?.subtasksStarted(count: 1, forTargetName: self.targetName)
            }

        case .finished, .abnormal, .signalled:
            // Find the subtask record.
            guard case let .plInt(pid)? = contents["pid"] else {
                return error("missing pid")
            }
            guard let subtask = subtasks.removeValue(forKey: pid) else {
                return error("invalid pid (no subtask record)")
            }

            // Get the output, if present.
            if case let .plString(output)? = contents["output"] {
                subtask.delegate.emitOutput(ByteString(encodingAsUTF8: output))
            }

            // Report the completion.
            let exitStatus: Processes.ExitStatus
            if kind == .finished {
                // Get the exit status.
                if case let .plInt(exitStatusValue)? = contents["exit-status"] {
                    exitStatus = .exit(Int32(exitStatusValue))
                } else {
                    error("missing exit-status")
                    exitStatus = .exit(2)
                }
            } else {
                let numericFailureCodeKey: String
                let errorMessageKey: String?
                let fallbackExitStatus: Int32
                switch kind {
                case .abnormal:
                    numericFailureCodeKey = "exception"
                    errorMessageKey = nil
                    fallbackExitStatus = 0
                case .signalled:
                    numericFailureCodeKey = "signal"
                    errorMessageKey = "error-message"
                    fallbackExitStatus = SIGABRT
                default:
                    preconditionFailure("unreachable")
                }

                if case let .plInt(signalValue)? = contents[numericFailureCodeKey] {
                    exitStatus = .uncaughtSignal(Int32(signalValue))
                } else {
                    exitStatus = .uncaughtSignal(fallbackExitStatus)
                }

                // Get the error message.
                if let errorMessageKey, case let .plString(message)? = contents[errorMessageKey] {
                    if exitStatus.wasCanceled {
                        // Special case: some signals generated by users (SIGINT, SIGKILL) will be interpreted by the
                        // delegate as "cancellation"; we honor that here by suppressing the diagnostic we'd otherwise
                        // print. This also handles the case where a pseudo-task exits with SIGINT when running in batch
                        // mode, which happens when it was cancelled due to being batched together with another
                        // pseudo-task that emitted an error.
                    } else {
                        subtask.delegate.diagnosticsEngine.emit(data: DiagnosticData(message), behavior: .error)
                    }
                } else if let errorMessageKey {
                    error("missing \(errorMessageKey)")
                } else {
                    subtask.delegate.diagnosticsEngine.emit(data: DiagnosticData("The Swift compiler exited abnormally."), behavior: .error)
                }
            }
            if subtaskName == .compile, !usingSwiftIntegratedDriver {
                progressReporter?.subtasksFinished(count: 1, forTargetName: self.targetName)
            }

            // Don't try to read diagnostics if the process exited with an uncaught signal as they were almost certainly not written in this case.
            let serializedDiagnosticsPaths = subtask.nonEmptyDiagnosticsPaths(fs: workspaceContext.fs)
            if !serializedDiagnosticsPaths.isEmpty {
                for path in serializedDiagnosticsPaths {
                    subtask.delegate.processSerializedDiagnostics(at: path, workingDirectory: workingDirectory, workspaceContext: workspaceContext)
                }
            }

            subtask.delegate.taskCompleted(exitStatus: exitStatus.isSuccess ? exitStatus : (serializedDiagnosticsPaths.isEmpty ? .buildSystemCanceledTask : exitStatus))
            subtask.delegate.close()

        case .skipped:
            if subtaskName == .compile, !usingSwiftIntegratedDriver {
                progressReporter?.subtasksSkipped(count: 1, forTargetName: self.targetName)
            }
            delegate.skippedSubtask(signature: computeRuleInfo(name: name, onlyInput: onlyInput).signature)
        }
    }

    /// Compute the `ruleInfo` and signature for a subtask.
    func computeRuleInfo(name: String, onlyInput: Path?) -> (ruleInfo: String, signature: ByteString) {
        if usingSwiftIntegratedDriver, let onlyInput {
            // If using the Swift integrated driver, we must be parsing the output of a batch compile task. As a result, we should only receive messages about per-file compilation.
            let (ruleInfo, signature) = SwiftCompilerSpec.computeRuleInfoAndSignatureForPerFileVirtualBatchSubtask(variant: self.variant, arch: self.arch, path: onlyInput)
            return (ruleInfo.joined(separator: " "), signature)
        } else {
            let signatureName = computeSubtaskSignatureName(name)
            var ruleInfo = "\(signatureName) \(self.variant) \(self.arch)"
            if let path = onlyInput {
                ruleInfo = "\(ruleInfo) \(path.str.quotedDescription)"
            }
            let signature: ByteString = {
                let md5 = InsecureHashContext()
                md5.add(string: ruleInfo)
                return md5.signature
            }()
            return (ruleInfo, signature)
        }
    }
}

public struct SwiftBlocklists: Sendable {

    public struct ExplicitModulesInfo : ProjectFailuresBlockList, Codable, Sendable {
        let KnownFailures: [String]

        enum CodingKeys: String, CodingKey {
            case KnownFailures
        }
    }

    var explicitModules: ExplicitModulesInfo? = nil

    public struct InstallAPILazyTypecheckInfo : Codable, Sendable {
        /// A blocklist of module names that do not support the `SWIFT_INSTALLAPI_LAZY_TYPECHECK` build setting.
        let Modules: [String]
    }

    var installAPILazyTypecheck: InstallAPILazyTypecheckInfo? = nil

    public struct CachingBlockList : ProjectFailuresBlockList, Codable, Sendable {
        let KnownFailures: [String]

        /// A blocklist of module names that do not support the `SWIFT_ENABLE_COMPILE_CACHE` build setting.
        let Modules: [String]
    }

    var caching: CachingBlockList? = nil

    public struct LanguageFeatureEnablementInfo : Codable, Sendable {
        public struct Feature: Codable, Sendable {
            public enum DiagnosticLevel: String, Codable, Sendable {
                case ignore
                case warn
                case error
            }

            /// The level of the diagnostic to emit when the feature is disabled.
            let level: DiagnosticLevel

            /// The names of build settings to check. If any of these build settings are enabled, then the feature is considered enabled.
            let buildSettings: [String]?

            /// A URL that developers can go to to learn more about why the feature should be enabled.
            let learnMoreURL: URL?

            /// Whether or not the feature is experimental (as opposed to an upcoming, official language feature).
            let experimental: Bool?

            /// A list of module names that should not receive the diagnostic.
            let moduleExceptions: [String]?
        }

        let features: [String: Feature]
    }

    var languageFeatureEnablement: LanguageFeatureEnablementInfo? = nil

    public init() {}
}

public struct DiscoveredSwiftCompilerToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    /// The path to the tool from which we captured this info.
    public let toolPath: Path
    /// The version of the Swift language in the tool.
    public let swiftVersion: Version
    /// The version of swiftlang in the tool.
    public let swiftlangVersion: Version
    /// The version of the stable ABI for the Swift language in the tool.
    public let swiftABIVersion: String?
    /// The version of clang in the tool.
    public let clangVersion: Version?
    /// `compilerClientsConfig` blocklists for Swift
    public let blocklists: SwiftBlocklists

    public var toolVersion: Version? { return self.swiftlangVersion }

    public var hostLibraryDirectory: Path {
        toolPath.dirname.dirname.join("lib/swift/host")
    }

    public enum FeatureFlag: String, CaseIterable, Sendable {
        case experimentalSkipAllFunctionBodies = "experimental-skip-all-function-bodies"
        case experimentalAllowModuleWithCompilerErrors = "experimental-allow-module-with-compiler-errors"
        case emitLocalizedStrings = "emit-localized-strings"
        case libraryLevel = "library-level"
        case packageName = "package-name-if-supported"
        case vfsDirectoryRemap = "vfs-directory-remap"
        case indexUnitOutputPath = "index-unit-output-path"
        case indexUnitOutputPathWithoutWarning = "no-warn-superfluous-index-unit-path"
        case emitABIDescriptor = "emit-abi-descriptor"
        case emptyABIDescriptor = "empty-abi-descriptor"
        case clangVfsRedirectingWith = "clang-vfs-redirecting-with"
        case emitContValuesSidecar = "emit-const-value-sidecar"
        case vfsstatcache = "clang-vfsstatcache"
        case emitExtensionBlockSymbols = "emit-extension-block-symbols"
        case constExtractCompleteMetadata = "const-extract-complete-metadata"
        case emitPackageModuleInterfacePath = "emit-package-module-interface-path"
        case compilationCaching = "compilation-caching"
    }
    public var toolFeatures: ToolFeatures<FeatureFlag>
    public func hasFeature(_ flag: String) -> Bool {
        return toolFeatures.has(flag)
    }

    public init(toolPath: Path, swiftVersion: Version, swiftlangVersion: Version, swiftABIVersion: String?, clangVersion: Version?, blocklists: SwiftBlocklists, toolFeatures: ToolFeatures<DiscoveredSwiftCompilerToolSpecInfo.FeatureFlag>) {
        self.toolPath = toolPath
        self.swiftVersion = swiftVersion
        self.swiftlangVersion = swiftlangVersion
        self.swiftABIVersion = swiftABIVersion
        self.clangVersion = clangVersion
        self.blocklists = blocklists
        self.toolFeatures = toolFeatures
    }
}

public struct SwiftMacroImplementationDescriptor: Hashable, Comparable, Sendable {
    private let value: String
    public let path: Path

    // The flag passed to the compiler to load the macro implementation.
    public var compilerFlags: [String] {
        ["-Xfrontend", "-load-plugin-executable", "-Xfrontend", value]
    }

    public init(declaringModuleNames: [String], path: Path) {
        self.value = "\(path.str)#\(declaringModuleNames.joined(separator: ","))"
        self.path = path
    }

    public init?(value: String) {
        self.value = value
        guard let endOfPath = value.lastIndex(of: "#") else {
            return nil
        }
        self.path = Path(value[..<endOfPath])
    }

    public static func < (lhs: SwiftMacroImplementationDescriptor, rhs: SwiftMacroImplementationDescriptor) -> Bool {
        return lhs.value < rhs.value
    }
}

public final class SwiftCompilerSpec : CompilerSpec, SpecIdentifierType, SwiftDiscoveredCommandLineToolSpecInfo, @unchecked Sendable {
    @_spi(Testing) public static let parallelismLevel = ProcessInfo.processInfo.activeProcessorCount

    public static let identifier = "com.apple.xcode.tools.swift.compiler"

    /// The name of a source file which the Swift compiler will recognize in order implicitly lift its content into an automatically-generated `main()` function.
    static let mainFileName = "main.swift"

    public override var supportsInstallAPI: Bool {
        return true
    }

    fileprivate func getABIBaselinePath(_ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate,
                                        _ mode: SwiftCompilationMode) -> Path? {
        switch mode {
        case .api, .prepareForIndex:
            return nil
        case .generateModule, .compile:
            guard scope.evaluate(BuiltinMacros.RUN_SWIFT_ABI_CHECKER_TOOL_DRIVER) else {
                return nil
            }
            let baselineDir = scope.evaluate(BuiltinMacros.SWIFT_ABI_CHECKER_BASELINE_DIR)
            let fileName = mode.destinationModuleFileName(scope)
            if !baselineDir.isEmpty {
                let path1 = Path(baselineDir).join(Path("\(fileName).abi.json"))
                if delegate.fileExists(at: path1) {
                    return path1
                }
                let path2 = Path(baselineDir).join("ABI").join(Path("\(fileName).json"))
                if delegate.fileExists(at: path2) {
                    return path2
                }
                delegate.warning("cannot find Swift ABI baseline file at: `\(path1.str)` or `\(path2.str)`")
            }
            return nil
        }
    }

    /// Indicates whether a Swift version is considered invalid by the spec, valid-as-is, or if only the major version component is valid.
    public enum SwiftVersionState {
        /// The Swift version is valid exactly as it is.
        case valid
        /// Only the Swift major version is valid.
        case validMajor
        /// The Swift version is invalid.
        case invalid
    }

    static let outputAgnosticCompilerArgumentsWithValues = Set<ByteString>([
        "-index-store-path",
        "-index-unit-output-path",
    ])

    func isOutputAgnosticCommandLineArgument(_ argument: ByteString, prevArgument: ByteString?) -> Bool {
        if SwiftCompilerSpec.outputAgnosticCompilerArgumentsWithValues.contains(argument) {
            return true
        }

        if let prevArgument, SwiftCompilerSpec.outputAgnosticCompilerArgumentsWithValues.contains(prevArgument) {
            return true
        }

        return false
    }

    public override func commandLineForSignature(for task: any ExecutableTask) -> [ByteString] {
        // TODO: We should probably allow the specs themselves to mark options
        // as output agnostic, rather than always postprocessing the command
        // line. In some cases we will have to postprocess, because of settings
        // like OTHER_SWIFT_FLAGS where the user can't possibly add this
        // metadata to the values, but those settings be handled on a
        // case-by-case basis.
        return task.commandLine.indices.compactMap { index in
            let arg = task.commandLine[index].asByteString
            let prevArg = index > task.commandLine.startIndex ? task.commandLine[index - 1].asByteString : nil
            if isOutputAgnosticCommandLineArgument(arg, prevArgument: prevArg) {
                return nil
            }
            return arg
        }
    }

    // remove in rdar://53000820
    /// Describes how input files are passed to the compiler invocation
    private enum SwiftCompilerInputMode {
        case responseFile(Path)
        case individualFiles
    }

    /// Enum to determine the mode in which to run the compiler.
    enum SwiftCompilationMode {
        case compile
        case api
        case generateModule(triplePlatform: String, tripleSuffix: String, moduleOnly: Bool)
        case prepareForIndex

        /// Returns the rule info name to use for this mode.
        var compileSources: Bool {
            switch self {
            case .compile:
                return true
            default:
                return false
            }
        }

        /// Returns the string to use as the first item in the ruleInfo when using the binary driver flow
        var ruleName: String {
            switch self {
            case .generateModule, .prepareForIndex:
                return "GenerateSwiftModule"
            default:
                return "CompileSwiftSources"
            }
        }

        /// Returns the string to use as the first item in the ruleInfo when using the integrated driver flow
        var ruleNameIntegratedDriver: String {
            switch self {
            case .generateModule, .prepareForIndex:
                return "SwiftDriver GenerateModule"
            default:
                return "SwiftDriver"
            }
        }

        /// The suffix to apply to the module basename for this mode.
        var moduleBaseNameSuffix: String {
            switch self {
            case .generateModule(let triplePlatform, let tripleSuffix, _):
                return "-\(triplePlatform)\(tripleSuffix)"
            default:
                return ""
            }
        }

        /// Returns true if this mode will generate the ObjC bridging header.
        var emitObjCHeader: Bool {
            switch self {
            case .generateModule(_, _, let moduleOnly):
                return moduleOnly
            default:
                return true
            }
        }

        /// Returns true if we must avoid passing `-index-store-path` to the task.
        var omitIndexStorePath: Bool {
            switch self {
            case .generateModule, .prepareForIndex:
                return true
            default:
                return false
            }
        }

        /// Returns true if this mode will generate the .swiftdoc file.
        var generateDocumentation: Bool {
            switch self {
            case .api:
                return false
            default:
                return true
            }
        }

        var canEmitABIDescriptor: Bool {
            switch self {
            case .compile, .generateModule:
                return true
            case .prepareForIndex, .api:
                return false
            }
        }

        /// Returns the destination module file basename for the mode.
        func destinationModuleFileName(_ scope: MacroEvaluationScope) -> String {
            let mode = self
            let lookup: ((MacroDeclaration) -> MacroExpression?) = { macro in
                switch (macro, mode) {
                case (BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, .generateModule(let triplePlatform, _, _)):
                    return scope.namespace.parseLiteralString(triplePlatform)
                case (BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX, .generateModule(_, let tripleSuffix, _)):
                    return scope.namespace.parseLiteralString(tripleSuffix)
                case (BuiltinMacros.SWIFT_DEPLOYMENT_TARGET, _):
                    return Static { scope.namespace.parseString("") } as MacroStringExpression
                default:
                    return nil
                }
            }

            return scope.evaluate(BuiltinMacros.SWIFT_TARGET_TRIPLE, lookup: lookup)
        }

        /// Returns true if the compilation mode supports emitting modules early to unblock downstream targets
        func supportsEagerCompilation(isUsingWholeModuleOptimization: Bool) -> Bool {
            switch self {
            case .compile:
                return true
            case .generateModule:
                return !isUsingWholeModuleOptimization
            default:
                return false
            }
        }

        var installAPI: Bool {
            guard case .api = self else { return false }
            return true
        }
    }

    /// Validates the given `swiftVersion` against the Swift spec, indicating whether it is invalid, valid-as-is, or if only the major version is valid.
    public func validateSwiftVersion(_ swiftVersion: Version) -> SwiftVersionState {
        if supportedLanguageVersions.contains(swiftVersion) {
            return .valid
        } else {
            let majorSwiftVersion = Version(swiftVersion[0], 0, 0)
            if supportedLanguageVersions.contains(majorSwiftVersion) {
                return .validMajor
            } else {
                return .invalid
            }
        }
    }

    private func supportConstSupplementaryMetadata(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, compilationMode: SwiftCompilationMode) async -> Bool {
        guard compilationMode.compileSources else {
            return false
        }
        return cbc.scope.evaluate(BuiltinMacros.SWIFT_ENABLE_EMIT_CONST_VALUES)
    }

    static func getSwiftModuleFilePathInternal(_ scope: MacroEvaluationScope, _ mode: SwiftCompilationMode) -> Path {
        let moduleFileDir = scope.evaluate(BuiltinMacros.PER_ARCH_MODULE_FILE_DIR)
        let moduleName = scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
        return moduleFileDir.join(moduleName + ".swiftmodule").appendingFileNameSuffix(mode.moduleBaseNameSuffix)
    }

    static public func getSwiftModuleFilePath(_ scope: MacroEvaluationScope) -> Path {
        return SwiftCompilerSpec.getSwiftModuleFilePathInternal(scope, .compile)
    }

    static public func collectInputSearchPaths(_ cbc: CommandBuildContext, toolInfo: DiscoveredSwiftCompilerToolSpecInfo) -> [String] {
        var results: [String] = []

        // For SWIFT_INCLUDE_PATHS.
        results.append(contentsOf: cbc.producer.expandedSearchPaths(for: BuiltinMacros.SWIFT_INCLUDE_PATHS, scope: cbc.scope))

        // For PRODUCT_TYPE_SWIFT_INCLUDE_PATHS.
        results.append(contentsOf: cbc.producer.expandedSearchPaths(for: BuiltinMacros.PRODUCT_TYPE_SWIFT_INCLUDE_PATHS, scope: cbc.scope))

        if cbc.scope.evaluate(BuiltinMacros.SWIFT_ADD_TOOLCHAIN_SWIFTSYNTAX_SEARCH_PATHS) {
            results.append(toolInfo.hostLibraryDirectory.str)
        }
        return results
    }

    private func compilerWorkingDirectory(_ cbc: CommandBuildContext) -> Path {
        cbc.scope.evaluate(BuiltinMacros.COMPILER_WORKING_DIRECTORY).nilIfEmpty.map { Path($0) } ?? cbc.producer.defaultWorkingDirectory
    }

    private func getExplicitModuleBlocklist(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async ->  SwiftBlocklists.ExplicitModulesInfo? {
        let specInfo = await (discoveredCommandLineToolSpecInfo(producer, scope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo)
        return specInfo?.blocklists.explicitModules
    }

    func swiftExplicitModuleBuildEnabled(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async -> Bool {
        let buildSettingEnabled = scope.evaluate(BuiltinMacros.SWIFT_ENABLE_EXPLICIT_MODULES) == .enabled ||
                                  scope.evaluate(BuiltinMacros._EXPERIMENTAL_SWIFT_EXPLICIT_MODULES) == .enabled

        // rdar://122829880 (Turn off Swift explicit modules when c++ interop is enabled)
        guard scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTEROP_MODE) != "objcxx" && !scope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-cxx-interoperability-mode=default") else {
            return scope.evaluate(BuiltinMacros._SWIFT_EXPLICIT_MODULES_ALLOW_CXX_INTEROP)
        }

        // Disable explicit modules in the pre-Swift-5 language modes to avoid versioned API notes confusion.
        guard let swiftVersion = try? Version(scope.evaluate(BuiltinMacros.SWIFT_VERSION)), swiftVersion >= Version(5) else {
            return scope.evaluate(BuiltinMacros._SWIFT_EXPLICIT_MODULES_ALLOW_BEFORE_SWIFT_5)
        }

        // If a blocklist is provided in the toolchain, use it to determine the default for the current project
        guard let explicitModuleBlocklist = await getExplicitModuleBlocklist(producer, scope, delegate) else {
            return buildSettingEnabled
        }

        // If this project is on the blocklist, override the blocklist default enable for it
        if explicitModuleBlocklist.isProjectListed(scope) {
            return false
        }
        return buildSettingEnabled
    }

    func shouldEmitMakeStyleDependencies(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, delegate: any TaskGenerationDelegate) async -> Bool {
        guard await swiftExplicitModuleBuildEnabled(producer, scope, delegate) else {
            return true
        }
        switch scope.evaluate(BuiltinMacros.SWIFT_DEPENDENCY_REGISTRATION_MODE) {
        case .makeStyleDependenciesSupplementedByScanner:
            return true
        case .swiftDependencyScannerOnly:
            return false
        case .verifySwiftDependencyScanner:
            return true
        }
    }

    private func swiftCachingEnabled(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ moduleName: String, _ useIntegratedDriver: Bool, _ explicitModuleBuildEnabled: Bool, _ disabledPCHCompile: Bool) async -> Bool {
        guard cbc.producer.supportsCompilationCaching else { return false }

        guard cbc.scope.evaluate(BuiltinMacros.SWIFT_ENABLE_COMPILE_CACHE) else {
            return false
        }
        if cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA) {
            return false
        }
        guard useIntegratedDriver else {
            delegate.warning("swift compiler caching requires integrated driver")
            return false
        }
        guard explicitModuleBuildEnabled else {
            delegate.warning("swift compiler caching requires explicit module build (SWIFT_ENABLE_EXPLICIT_MODULES=YES)")
            return false
        }
        if disabledPCHCompile, !cbc.scope.evaluate(BuiltinMacros.SWIFT_OBJC_BRIDGING_HEADER).isEmpty {
            delegate.warning("swift compiler caching requires precompile bridging header if caching is enabled (SWIFT_PRECOMPILE_BRIDGING_HEADER=YES)")
            return false
        }
        if let specInfo = await (discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo) {
            if !specInfo.hasFeature(DiscoveredSwiftCompilerToolSpecInfo.FeatureFlag.compilationCaching.rawValue) {
                delegate.warning("swift compiler caching is not supported by toolchain")
                return false
            }
            if let blocklist = specInfo.blocklists.caching {
                if blocklist.Modules.contains(moduleName) {
                    return false
                }
                if blocklist.isProjectListed(cbc.scope) {
                    return false
                }
            }
        }
        return true
    }

    private func diagnoseFeatureEnablement(_ cbc: CommandBuildContext, _ languageFeatureEnablementInfo: SwiftBlocklists.LanguageFeatureEnablementInfo, _ delegate: any TaskGenerationDelegate) {
        let moduleName = cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
        let otherFlags = cbc.scope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS)
        var otherFlagsFeatures: [String] = []
        for (index, flag) in otherFlags.enumerated().dropLast() {
            if flag == "-enable-experimental-feature" || flag == "-enable-upcoming-feature" {
                if index < otherFlags.count - 1 {
                    otherFlagsFeatures.append(otherFlags[index + 1])
                }
            }
        }

        for (identifier, feature) in languageFeatureEnablementInfo.features {
            if feature.moduleExceptions?.contains(moduleName) == true {
                continue
            }

            // Check whether any associated build setting is enabled.
            let matchingBuildSetting = feature.buildSettings?.first(where: {
                if let macro = try? cbc.scope.namespace.declareBooleanMacro($0) {
                    return cbc.scope.evaluate(macro)
                }
                return false
            })
            if matchingBuildSetting != nil {
                continue
            }

            // Check whether the language feature is enabled via OTHER_SWIFT_FLAGS.
            if otherFlagsFeatures.contains(identifier) {
                continue
            }

            let supplementaryMessage: String
            if let firstBuildSetting = feature.buildSettings?.first {
                supplementaryMessage = "set '\(firstBuildSetting) = YES'"
            } else {
                let experimental = feature.experimental ?? false
                supplementaryMessage = "add '\(experimental ? "-enable-experimental-feature" : "-enable-upcoming-feature") \(identifier)' to 'OTHER_SWIFT_FLAGS'"
            }

            switch feature.level {
            case .warn:
                delegate.warning("Enabling the Swift language feature '\(identifier)' will become a requirement in the future; \(supplementaryMessage)")
            case .error:
                delegate.error("Enabling the Swift language feature '\(identifier)' is required; \(supplementaryMessage)")
            case .ignore:
                continue
            }

            if let learnMoreURL = feature.learnMoreURL {
                delegate.note("Learn more about '\(identifier)' by visiting \(learnMoreURL.absoluteString)")
            }
        }
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Our command build context should not contain any outputs, since we construct the output path ourselves.
        precondition(cbc.outputs.isEmpty, "Unexpected output paths \(cbc.outputs.map { "'\($0.str)'" }) passed to \(type(of: self)).")

        // Compute general parameters about this Swift invocation.
        let targetName = cbc.scope.evaluate(BuiltinMacros.TARGET_NAME)
        let arch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)
        let variant = cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT)
        let isNormalVariant = variant == "normal"
        let objectFileDir = cbc.scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR)
        let moduleName = cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)

        let toolSpecInfo: DiscoveredSwiftCompilerToolSpecInfo
        do {
            toolSpecInfo = try await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
        } catch {
            delegate.error("Unable to discover `swiftc` command line tool info: \(error)")
            return
        }

        if let languageFeatureEnablementInfo = toolSpecInfo.blocklists.languageFeatureEnablement {
            diagnoseFeatureEnablement(cbc, languageFeatureEnablementInfo, delegate)
        }

        let swiftc = toolSpecInfo.toolPath

        /// Utility function to construct the task, since we may construct multiple tasks for slightly different purposes.
        /// - parameter compilationMode: Whether the sources should be compiled to object files by this command.
        /// - parameter lookup: Lookup function to override looking up certain build settings to conditionalize creating the task.
        func constructSwiftCompilationTasks(compilationMode: SwiftCompilationMode, inputMode: SwiftCompilerInputMode, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) async {

            // The extra inputs required by the compiler.
            var extraInputPaths = [Path]()
            // Paths to outputs generated by the compiler's module emission job.
            var moduleOutputPaths = [Path]()
            // The extra outputs generated by the compiler's compile jobs.
            var extraOutputPaths = [Path]()

            // Build the command line, starting with the executable.
            var args: [String] = [swiftc.str]

            // Add the build fallback VFS overlay before all other arguments so that any user-defined overlays can also be found from the regular build folder (if not found in the index arena).
            if case .prepareForIndex = compilationMode, !cbc.scope.evaluate(BuiltinMacros.INDEX_REGULAR_BUILD_PRODUCTS_DIR).isEmpty, !cbc.scope.evaluate(BuiltinMacros.INDEX_DISABLE_VFS_DIRECTORY_REMAP) {
                let overlayPath = cbc.scope.evaluate(BuiltinMacros.INDEX_DIRECTORY_REMAP_VFS_FILE)
                args += ["-vfsoverlay", overlayPath]
                extraInputPaths.append(Path(overlayPath))
            }

            func overrideLookup(_ declaration: MacroDeclaration) -> MacroExpression? {
                switch declaration {
                case BuiltinMacros.SWIFT_INDEX_STORE_ENABLE where compilationMode.omitIndexStorePath:
                    return cbc.scope.namespace.parseLiteralString("NO")
                default:
                    return nil
                }
            }

            await args.append(contentsOf: self.commandLineFromOptions(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: chainLookupFuncs(overrideLookup, lookup ?? { _ in nil })).map(\.asString))

            // Add `-swift-version` compiler flag
            let swiftVersion = cbc.scope.evaluate(BuiltinMacros.EFFECTIVE_SWIFT_VERSION)
            if swiftVersion.isEmpty {
                delegate.error("SWIFT_VERSION '\(cbc.scope.evaluate(BuiltinMacros.SWIFT_VERSION))' is unsupported, supported versions are: \(supportedLanguageVersions.map({ "\($0)" }).joined(separator: ", ")).")
            } else {
                args.append(contentsOf: ["-swift-version", swiftVersion])
            }

            for searchPath in SwiftCompilerSpec.collectInputSearchPaths(cbc, toolInfo: toolSpecInfo) {
                args.append(contentsOf: ["-I", searchPath])
            }

            for searchPath in cbc.producer.expandedSearchPaths(for: BuiltinMacros.SWIFT_SYSTEM_INCLUDE_PATHS, scope: cbc.scope) {
                args.append(contentsOf: ["-Isystem", searchPath])
            }

            // Add -F for the effective framework search paths.
            let frameworkSearchPaths = GCCCompatibleCompilerSpecSupport.frameworkSearchPathArguments(cbc.producer, cbc.scope, asSeparateArguments: true)
            args += frameworkSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

            // Add -F for the sparse SDK framework search paths.
            let sparseSDKSearchPaths = GCCCompatibleCompilerSpecSupport.sparseSDKFrameworkSearchPathArguments(cbc.producer.sparseSDKs, frameworkSearchPaths.frameworkSearchPaths, asSeparateArguments: true)
            args += sparseSDKSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

            // Add args to load macro plugins.
            if let macroDescriptors = cbc.producer.swiftMacroImplementationDescriptors {
                args.append(contentsOf: macroDescriptors.sorted().flatMap(\.compilerFlags))
                extraInputPaths.append(contentsOf: macroDescriptors.map(\.path))
            }

            // Note that we currently do not support per-file compiler flags for Swift.  <rdar://problem/19527999>

            // If there is only a single input, ensure we pass -parse-as-library as appropriate.
            if cbc.inputs.count == 1 {
                let filename = cbc.inputs[0].absolutePath.basename
                if filename != SwiftCompilerSpec.mainFileName && !cbc.scope.evaluate(BuiltinMacros.SWIFT_LIBRARIES_ONLY) {
                    // Add -parse-as-library if the only input's file name isn't main.swift and if we didn't already add it due to SWIFT_LIBRARIES_ONLY.
                    args.append("-parse-as-library")
                }
            }

            func shouldEmitTBD() -> Bool {
                // We should only run TBD generation if it's a dylib or relocatable object file -- not for other types of Mach-Os like bundles
                return cbc.scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_dylib" || cbc.scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_object"
            }

            func addEmitLocStringsIfRequired() -> SwiftLocalizationPayload? {
                // Nothing to be done if the not directed to emit localized strings
                guard cbc.scope.evaluate(BuiltinMacros.SWIFT_EMIT_LOC_STRINGS) else {
                    return nil
                }

                // Check if the emit-localized-strings is enabled in features.json
                guard toolSpecInfo.toolFeatures.has(.emitLocalizedStrings) && LibSwiftDriver.supportsDriverFlag(spelled: "-emit-localized-strings") else {
                    return nil
                }

                args.append("-emit-localized-strings")

                // The path for outputting the .stringsdata file created during compilation would be coming from the STRINGSDATA_DIR build setting and passed as the -emit-localized-strings-path argument
                let localizedStringsPath = cbc.scope.evaluate(BuiltinMacros.STRINGSDATA_DIR)
                args += ["-emit-localized-strings-path", "\(localizedStringsPath.str)"]

                for inp in cbc.inputs {
                    if inp.fileType.conformsTo(cbc.producer.lookupFileType(identifier: "sourcecode.swift")!) {
                        let stringsDataFilePath = Path(localizedStringsPath.join(inp.absolutePath.basenameWithoutSuffix).str + ".stringsdata")
                        extraOutputPaths.append(stringsDataFilePath)
                    }
                }

                // Currently this compiler invocation corresponds to a single platform/variant/arch grouping.
                let effectivePlatformName = LocalizationBuildPortion.effectivePlatformName(scope: cbc.scope, sdkVariant: cbc.producer.sdkVariant)
                return SwiftLocalizationPayload(effectivePlatformName: effectivePlatformName, buildVariant: variant, architecture: arch)
            }

            func addTBDEmissionIfRequired() {
                let typeStr = cbc.scope.evaluate(BuiltinMacros.PRODUCT_TYPE)
                let productType = ProductTypeIdentifier(typeStr)

                // For some targets, a tbd can be emitted to allow downstream targets to begin linking earlier.
                let supportsTBDEmissionForEagerLinking = cbc.producer.supportsEagerLinking(scope: cbc.scope)

                // InstallAPI support requires explicit opt-in and a compatible product type.
                let supportsInstallAPI = productType.supportsInstallAPI && cbc.scope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API)

                guard supportsInstallAPI || supportsTBDEmissionForEagerLinking else {
                    return
                }
                if shouldEmitTBD() {
                    // Compute the destination TBD file path.
                    let tapiOutputNode = delegate.createNode(objectFileDir.join("Swift-API.tbd"))

                    args.append("-emit-tbd")
                    args += ["-emit-tbd-path", tapiOutputNode.path.str]

                    // Add to the output list, but we can't do this until we have eliminated the TAPI step.
                    moduleOutputPaths.append(tapiOutputNode.path)
                    delegate.declareGeneratedTBDFile(tapiOutputNode.path, forVariant: variant)

                    // Add additional `installapi` specific arguments.
                    let installName = cbc.scope.evaluate(BuiltinMacros.TAPI_DYLIB_INSTALL_NAME)
                    args += ["-Xfrontend", "-tbd-install_name", "-Xfrontend", installName]

                    let currentVersion = cbc.scope.evaluate(BuiltinMacros.DYLIB_CURRENT_VERSION)
                    if !currentVersion.isEmpty {
                        args += ["-Xfrontend", "-tbd-current-version", "-Xfrontend", currentVersion]
                    }
                    let compatibilityVersion = cbc.scope.evaluate(BuiltinMacros.DYLIB_COMPATIBILITY_VERSION)
                    if !compatibilityVersion.isEmpty {
                        args += ["-Xfrontend", "-tbd-compatibility-version", "-Xfrontend", compatibilityVersion]
                    }
                }
                // When running installAPI, skip non-inlinable function bodies. We still skip function bodies with nested types here, because installAPI swiftmodules are not needed by lldb.
                if compilationMode.installAPI {
                    args += ["-Xfrontend", "-experimental-skip-non-inlinable-function-bodies"]

                    // When lazy typechecking is enabled, pass the -experimental-lazy-typecheck and -experimental-skip-non-exportable-decls frontend flags.
                    let enableLazyTypechecking = cbc.scope.evaluate(BuiltinMacros.SWIFT_INSTALLAPI_LAZY_TYPECHECK)

                    // Lazy typechecking requires library evolution.
                    let enableLibraryEvolution = cbc.scope.evaluate(BuiltinMacros.SWIFT_ENABLE_LIBRARY_EVOLUTION)

                    if enableLazyTypechecking && enableLibraryEvolution {
                        if let blocklist = toolSpecInfo.blocklists.installAPILazyTypecheck, blocklist.Modules.contains(moduleName) {
                            delegate.warning("SWIFT_INSTALLAPI_LAZY_TYPECHECK is disabled because \(moduleName) is blocked")
                        } else {
                            args += ["-Xfrontend", "-experimental-lazy-typecheck"]
                            args += ["-Xfrontend", "-experimental-skip-non-exportable-decls"]
                        }
                    }
                }
            }

            var localizationPayload: SwiftLocalizationPayload? = nil
            switch compilationMode {
            case .api:
                addTBDEmissionIfRequired()
            case .compile:
                addTBDEmissionIfRequired()
                localizationPayload = addEmitLocStringsIfRequired()
                args.append(self.sourceFileOption ?? "-c")
            case .prepareForIndex:
                let skipFlag = toolSpecInfo.toolFeatures.has(.experimentalSkipAllFunctionBodies) ? "-experimental-skip-all-function-bodies" : "-experimental-skip-non-inlinable-function-bodies"
                args += ["-Xfrontend", skipFlag]

                let allowErrors = toolSpecInfo.toolFeatures.has(.experimentalAllowModuleWithCompilerErrors)
                if allowErrors {
                    args += ["-Xfrontend", "-experimental-allow-module-with-compiler-errors"]
                }

                // Avoid emitting the ABI descriptor, we don't need it
                if toolSpecInfo.toolFeatures.has(.emptyABIDescriptor) {
                    args += ["-Xfrontend", "-empty-abi-descriptor"]
                }

                let clangArgs = ClangCompilerSpec.supplementalIndexingArgs(allowCompilerErrors: allowErrors)
                args += clangArgs.flatMap { ["-Xcc", $0] }
            default:
                break
            }

            // Set the parallelism level for the compile.
            let (isUsingWholeModuleOptimization, isWMOSettingExplicitlyEnabled) = Self.shouldUseWholeModuleOptimization(for: cbc.scope)
            let useParallelWholeModuleOptimization = cbc.scope.evaluate(BuiltinMacros.SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION)
            if isUsingWholeModuleOptimization && useParallelWholeModuleOptimization {
                args.append(contentsOf: ["-num-threads", "\(SwiftCompilerSpec.parallelismLevel)"])
            } else {
                args.append(contentsOf: ["-j\(SwiftCompilerSpec.parallelismLevel)"])
            }

            // If we need to force WMO mode (for InstallAPI), do so now.
            if isUsingWholeModuleOptimization && !isWMOSettingExplicitlyEnabled {
                args.append("-whole-module-optimization")
            }

            // If we're not using WMO, enable or disable batch mode based on the value of SWIFT_ENABLE_BATCH_MODE
            if !isUsingWholeModuleOptimization {
                args.append(cbc.scope.evaluate(BuiltinMacros.SWIFT_ENABLE_BATCH_MODE) ? "-enable-batch-mode" : "-disable-batch-mode")

                if cbc.scope.evaluate(BuiltinMacros.SWIFT_ENABLE_INCREMENTAL_COMPILATION) {
                    args.append("-incremental")
                }
            }

            let useIntegratedDriver = integratedDriverEnabled(scope: cbc.scope)
            let explicitModuleBuildEnabled = await swiftExplicitModuleBuildEnabled(cbc.producer, cbc.scope, delegate)
            let isCachingEnabled = await swiftCachingEnabled(cbc, delegate, moduleName, useIntegratedDriver, explicitModuleBuildEnabled, args.contains("-disable-bridging-pch"))
            if await cbc.producer.shouldUseSDKStatCache() && toolSpecInfo.toolFeatures.has(.vfsstatcache) && !isCachingEnabled {
                let cachePath = Path(cbc.scope.evaluate(BuiltinMacros.SDK_STAT_CACHE_PATH))
                args.append(contentsOf: ["-Xcc", "-ivfsstatcache", "-Xcc", cachePath.str])
            }

            // FIXME: The native build system disables running other commands while the Swift compiler is running.  Not sure if we want to do the same thing here, or let llbuild take care of it.

            // Add the input files.
            if case let .responseFile(path) = inputMode {
                extraInputPaths.append(path)
            }

            var indexObjectFileDir: Path? = nil
            if toolSpecInfo.toolFeatures.has(.indexUnitOutputPathWithoutWarning) ||
                (toolSpecInfo.toolFeatures.has(.indexUnitOutputPath) && (args.contains("-index-store-path") || cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA))) {
                // Unlike CCompiler, the index unit path remapping is actually added to the output file map. So even though both *arguments* are ignored when determining tasks to re-run, the file itself is hashed and that will cause rebuilds. Thus, always add the output path if Swift is new enough to not generate a warning if it isn't used.
                let basePath = cbc.scope.evaluate(BuiltinMacros.OBJROOT)
                if let newPath = generateIndexOutputPath(from: objectFileDir, basePath: basePath) {
                    indexObjectFileDir = newPath
                } else if delegate.userPreferences.enableDebugActivityLogs {
                    delegate.note("Output path '\(objectFileDir.str)' could not be mapped to a relocatable index path using base path '\(basePath.str)'")
                }
            }

            // Construct the output file map, and pass the path to it to swiftc.
            let outputFileMapPath = objectFileDir.join(targetName + ".json").appendingFileNameSuffix(compilationMode.moduleBaseNameSuffix + "-OutputFileMap")
            let outputFileMapContents: ByteString
            do {
                outputFileMapContents = try await computeOutputFileMapContents(cbc, delegate, compilationMode, objectFileDir: objectFileDir, isUsingWholeModuleOptimization: isUsingWholeModuleOptimization, indexObjectFileDir: indexObjectFileDir)
            } catch {
                delegate.error(error)
                return
            }
            cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: outputFileMapPath), delegate, contents: outputFileMapContents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
            args += ["-output-file-map", outputFileMapPath.str]
            extraInputPaths.append(outputFileMapPath)

            if useIntegratedDriver {
                // Instruct the frontend to provide parseable output so we can construct the log of the individual file commands.
                args.append("-use-frontend-parseable-output")

                // -save-temps will give Swift Build the opportunity to hold temporary files over the life time of a Driver run.
                // Temporary files will be stored in an intermediate dir.
                args.append("-save-temps")
                args.append("-no-color-diagnostics")

                // Instructs the driver to perform build planning with explicit module builds
                if explicitModuleBuildEnabled {
                    args.append("-explicit-module-build")
                    let explicitDependencyOutputPath = Path(cbc.scope.evaluate(BuiltinMacros.SWIFT_EXPLICIT_MODULES_OUTPUT_PATH))
                    args.append(contentsOf: ["-module-cache-path", explicitDependencyOutputPath.str])
                    let moduleCacheDir = cbc.scope.evaluate(BuiltinMacros.MODULE_CACHE_DIR)
                    if LibSwiftDriver.supportsDriverFlag(spelled: "-clang-scanner-module-cache-path"),
                       !moduleCacheDir.isEmpty {
                        // Specify the Clang scanner cache separately as a shared cache among different projects
                        args.append(contentsOf: ["-clang-scanner-module-cache-path", moduleCacheDir.str])
                    }
                    if LibSwiftDriver.supportsDriverFlag(spelled: "-sdk-module-cache-path"),
                       !moduleCacheDir.isEmpty {
                        args.append(contentsOf: ["-sdk-module-cache-path", moduleCacheDir.str])
                    }
                }
            } else {
                // Instruct the compiler to provide parseable output so we can construct the log of the individual file commands.
                args.append("-parseable-output")

                if explicitModuleBuildEnabled {
                    delegate.error("Enabling Swift explicit modules also requires: \(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER.name)")
                }
            }

            // Add caching related configurations.
            let casOptions: CASOptions?
            do {
                casOptions = isCachingEnabled ? (try CASOptions.create(cbc.scope, .compiler(.other(dialectName: "swift")))) : nil
                if let casOpts = casOptions {
                    args.append("-cache-compile-job")
                    args += ["-cas-path", casOpts.casPath.str]
                    if let pluginPath = casOpts.pluginPath {
                        args += ["-cas-plugin-path", pluginPath.str]
                    }
                    // If the integrated cache queries is enabled, the remote service is handled by build system and no need to pass to compiler
                    if !casOpts.enableIntegratedCacheQueries && casOpts.hasRemoteCache,
                       let remoteService = casOpts.remoteServicePath {
                        args += ["-cas-plugin-option", "remote-service-path=" + remoteService.str]
                    }
                }
            } catch {
                delegate.error(error.localizedDescription)
                casOptions = nil
            }

            // Instruct the compiler to serialize diagnostics.
            args.append("-serialize-diagnostics")

            if await shouldEmitMakeStyleDependencies(cbc.producer, cbc.scope, delegate: delegate) {
                // Instruct the compiler to emit dependencies information.
                args.append("-emit-dependencies")
            }

            // Generate the .swiftmodule from this compilation to a known location.
            //
            // (We don't care about the intermediate partial swiftmodules, so leave those out of the output file map.)
            let moduleName = cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
            let moduleFilePath = SwiftCompilerSpec.getSwiftModuleFilePathInternal(cbc.scope, compilationMode)
            args += ["-emit-module", "-emit-module-path", moduleFilePath.str]
            moduleOutputPaths.append(moduleFilePath)
            let moduleLinkerArgsPath: Path?
            if cbc.scope.evaluate(BuiltinMacros.SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS) {
                let path = Path(moduleFilePath.appendingFileNameSuffix("-linker-args").withoutSuffix + ".resp")
                moduleOutputPaths.append(path)
                moduleLinkerArgsPath = path
            } else {
                moduleLinkerArgsPath = nil
            }

            if let baselinePath = getABIBaselinePath(cbc.scope, delegate, compilationMode) {
                args += ["-digester-mode", "abi", "-compare-to-baseline-path", baselinePath.str]
            }

            if DocumentationCompilerSpec.shouldConstructSymbolGenerationTask(cbc) {
                let symbolGraphOutputPath = Self.getSymbolGraphDirectory(cbc.scope, compilationMode)
                let mainSymbolGraphPath = Self.getMainSymbolGraphFile(cbc.scope, compilationMode)

                args += ["-emit-symbol-graph", "-emit-symbol-graph-dir", symbolGraphOutputPath.str]
                moduleOutputPaths.append(mainSymbolGraphPath)

                args += DocumentationCompilerSpec.additionalSymbolGraphGenerationArgs(cbc, swiftCompilerInfo: toolSpecInfo)

                // When building using the integrated driver, dynamic tasks will rely on the directory to exist.
                // llbuild creates it before executing the constructed task at which point the dynamic task already failed.
                // Specifying it as the output of a task that runs before unblocks documentation compilation too early.
                // As a workaround we create the directory here. Proper fix in rdar://70881411.
                if integratedDriverEnabled(scope: cbc.scope) {
                    cbc.producer.createBuildDirectorySpec.constructTasks(cbc, delegate, buildDirectoryNode: delegate.createNode(symbolGraphOutputPath))
                    extraInputPaths.append(symbolGraphOutputPath)
                }
            }

            // Copy .swiftsourceinfo generated from this compilation to the build dir.
            let sourceInfoPath = Path(moduleFilePath.withoutSuffix + ".swiftsourceinfo")
            moduleOutputPaths.append(sourceInfoPath)
            let usingLegacyDriver = cbc.scope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-disallow-use-new-driver")
            let abiDescriptorPath: Path? = !usingLegacyDriver &&
                cbc.producer.isApplePlatform &&
                toolSpecInfo.toolFeatures.has(.emitABIDescriptor) &&
                compilationMode.canEmitABIDescriptor &&
                cbc.scope.evaluate(BuiltinMacros.SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR) ?
                  Path(moduleFilePath.withoutSuffix + ".abi.json") : nil
            if let abiDescriptorPath {
                moduleOutputPaths.append(abiDescriptorPath)
            }

            // Generate the .swiftinterface, .private.swiftinterface, and .package.swiftinterface file if appropriate.
            let moduleInterfaceFilePath: Path?
            let privateModuleInterfaceFilePath: Path?
            let packageModuleInterfaceFilePath: Path?
            if cbc.scope.evaluate(BuiltinMacros.SWIFT_EMIT_MODULE_INTERFACE) {
                do {
                    let path = Path(moduleFilePath.withoutSuffix + ".swiftinterface")
                    moduleInterfaceFilePath = path
                    args += ["-emit-module-interface-path", path.str]
                    moduleOutputPaths.append(path)
                }
                do {
                    let path = Path(moduleFilePath.withoutSuffix + ".private.swiftinterface")
                    privateModuleInterfaceFilePath = path
                    args += ["-emit-private-module-interface-path", path.str]
                    moduleOutputPaths.append(path)
                }
                do {
                    let packageName = cbc.scope.evaluate(BuiltinMacros.SWIFT_PACKAGE_NAME)
                    let emitPackageInterfacePath = "-emit-package-module-interface-path"
                    if !packageName.isEmpty,
                       toolSpecInfo.toolFeatures.has(.emitPackageModuleInterfacePath),
                       LibSwiftDriver.supportsDriverFlag(spelled: emitPackageInterfacePath) {
                        let path = Path(moduleFilePath.withoutSuffix + ".package.swiftinterface")
                        packageModuleInterfaceFilePath = path
                        args += [emitPackageInterfacePath, path.str]
                        moduleOutputPaths.append(path)
                    } else {
                        packageModuleInterfaceFilePath = nil
                    }
                }
            }
            else {
                moduleInterfaceFilePath = nil
                privateModuleInterfaceFilePath = nil
                packageModuleInterfaceFilePath = nil
            }

            let userModuleVersion = cbc.scope.evaluate(BuiltinMacros.SWIFT_USER_MODULE_VERSION)
            if !userModuleVersion.isEmpty {
                args += ["-user-module-version", userModuleVersion]
            }

            let buildSessionFile = cbc.scope.evaluate(BuiltinMacros.CLANG_MODULES_BUILD_SESSION_FILE)
            if !buildSessionFile.isEmpty,
               integratedDriverEnabled(scope: cbc.scope),
               LibSwiftDriver.supportsDriverFlag(spelled: "-validate-clang-modules-once") && LibSwiftDriver.supportsDriverFlag(spelled: "-clang-build-session-file"),
               cbc.scope.evaluate(BuiltinMacros.SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION) {
                args += ["-validate-clang-modules-once", "-clang-build-session-file", buildSessionFile]
            }

            if toolSpecInfo.toolFeatures.has(.libraryLevel),
               let libraryLevel = cbc.scope.evaluateAsString(BuiltinMacros.SWIFT_LIBRARY_LEVEL).nilIfEmpty {
                args += ["-library-level", libraryLevel]
            }

            if toolSpecInfo.toolFeatures.has(.packageName),
               let packageName = cbc.scope.evaluate(BuiltinMacros.SWIFT_PACKAGE_NAME).nilIfEmpty {
                args += ["-package-name", packageName]
            }

            // Hide the Swift interface generated by this specific command from any Clang importer includes. We do this by adding a fake headermap mapping the include to a bogus path.
            // Note that this must come before we add the regular header search options.
            // This is a total hack, but it is important because without it, users might easily begin including the Swift interface in other headers, and it will work for some part of the time (because it has already been generated), but then will fail on a clean build, or will fail once they start hitting cyclic dependency detection. See <rdar://problem/17363873>, <rdar://problem/17245239>, and <rdar://problem/17204900>. Finding a less hacky way to do this is tracked by: <rdar://problem/17365003> Improve mechanism for hiding Swift generated header during compilation
            let objcHeaderFilePath: Path?
            if compilationMode.emitObjCHeader {
                let objcHeaderFileName = cbc.scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME)
                objcHeaderFilePath = objcHeaderFileName.isEmpty ? nil : objectFileDir.join(objcHeaderFileName)
                if !objcHeaderFileName.isEmpty {
                    // FIXME: Create the overrides headermap.
                    //
                    // FIXME: This should probably be in the object file dir, not the temp dir.
                    let overridesHeadermapPath = cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("swift-overrides.hmap")
                    // FIXME: Separate -I and its argument.
                    args += ["-Xcc", "-I" + overridesHeadermapPath.str]
                }
            }
            else {
                objcHeaderFilePath = nil
            }

            // The compiler is to emit the auxiliary compile-time known values output for a collection
            // of protocol conformances. Add the required inputs to swiftc.
            let constValueConformanceProtocolList = cbc.scope.evaluate(BuiltinMacros.SWIFT_EMIT_CONST_VALUE_PROTOCOLS)
            let supportsConstSupplementaryMetadata = await supportConstSupplementaryMetadata(cbc, delegate, compilationMode: compilationMode)
            if !constValueConformanceProtocolList.isEmpty && supportsConstSupplementaryMetadata {
                // This flag is added here instead of in Swift.xcspec in order to allow only
                // using it when the tool has the appropriate feature flag.
                args += ["-emit-const-values"]
                let protocolListPath = objectFileDir.join(targetName + "_const_extract_protocols" + ".json").appendingFileNameSuffix(compilationMode.moduleBaseNameSuffix)
                let protocolListContents: ByteString
                do {
                    protocolListContents = try PropertyListItem.init(constValueConformanceProtocolList).asJSONFragment()
                } catch {
                    delegate.error(error)
                    return
                }
                cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: protocolListPath),
                                                              delegate, contents: protocolListContents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                args += ["-Xfrontend", "-const-gather-protocols-file",
                         "-Xfrontend", protocolListPath.str]
                extraInputPaths.append(protocolListPath)
            }

            // Add the common header search options.  The swift driver expects that we prefix each option with '-Xcc' to pass it to clang.
            let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(cbc.producer, cbc.scope, usesModules: true)
            let commonHeaderSearchArgs = headerSearchPaths.searchPathArguments(for: self, scope: cbc.scope)
            for option in commonHeaderSearchArgs {
                args.append(contentsOf: ["-Xcc", option])
            }

            // NOTE: We intentionally chose not to depend on the headermaps here, see the comments for the CCompiler: <rdar://problem/31843906> Move to stronger dependencies on headermaps and VFS

            // Add a handful of Clang compiler settings that could impact imported modules.
            //
            // Note that we can explicitly ignore GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS here because those are automatically ignored by modules.
            //
            // For now, we don't try and pass OTHER_CFLAGS because we don't know which flags are safe:
            //   <rdar://problem/16906483> OTHER_CFLAGS confuse Swift compiler
            for cppDefinition in cbc.scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS) {
                // FIXME: Separate -D and its argument.
                args.append(contentsOf: ["-Xcc", "-D" + cppDefinition])
            }

            // Instruct the compiler to emit the ObjC header file.
            if let objcHeaderFilePath {
                args += ["-emit-objc-header", "-emit-objc-header-path", objcHeaderFilePath.str]
                moduleOutputPaths.append(objcHeaderFilePath)

                if SwiftCompilerSpec.shouldInstallGeneratedObjectiveCHeader(cbc.scope) {
                    // Disable swiftinterface verification when installing a compatibility header.
                    // This is a workaround until we can ensure that the verification phase
                    // runs after the merge of the compatibility headers. rdar://99159525
                    if moduleInterfaceFilePath != nil || privateModuleInterfaceFilePath != nil {
                        args.append("-no-verify-emitted-module-interface")
                    }

                    if !cbc.scope.evaluate(BuiltinMacros.SWIFT_ALLOW_INSTALL_OBJC_HEADER) {
                        let message: String
                        if let customized = cbc.scope.evaluate(BuiltinMacros.__SWIFT_ALLOW_INSTALL_OBJC_HEADER_MESSAGE).nilIfEmpty {
                            message = customized
                        } else {
                            message = "SWIFT_ALLOW_INSTALL_OBJC_HEADER is not allowed in the current context"
                        }
                        if cbc.scope.evaluateAsString(BuiltinMacros.SWIFT_ALLOW_INSTALL_OBJC_HEADER).isEmpty {
                            delegate.warning(message, location: .unknown)
                        } else {
                            delegate.error(message, location: .unknown)
                        }
                    }
                }
            }

            // Pass an Obj-C bridging header, if one is defined.
            let objcBridgingHeaderPath = Path(cbc.scope.evaluate(BuiltinMacros.SWIFT_OBJC_BRIDGING_HEADER))
            if !objcBridgingHeaderPath.isEmpty {
                let objcBridgingHeaderNode = delegate.createNode(objcBridgingHeaderPath)
                args += ["-import-objc-header", objcBridgingHeaderNode.path.normalize().str]
                extraInputPaths.append(objcBridgingHeaderPath)
                let precompsPath = cbc.scope.evaluate(BuiltinMacros.SHARED_PRECOMPS_DIR)
                if !precompsPath.isEmpty,
                   !explicitModuleBuildEnabled {
                    args += ["-pch-output-dir", precompsPath.str]
                }
            }

            // If this target defines additional (not Swift only) module content, then tell Swift to implicitly import it.
            if let moduleInfo = cbc.producer.moduleInfo, !moduleInfo.forSwiftOnly {
                args.append("-import-underlying-module")

                // If the target isn't Swift only, but does export API, then we need to also use the extra VFS overlay that is used to "hide" the generated API file when doing the Swift compile.
                //
                // This is tightly coupled to the implementation in the ModuleMap task producer.
                if moduleInfo.exportsSwiftObjCAPI {
                    let unextendedModuleMapNode = delegate.createNode(Path(cbc.scope.evaluate(BuiltinMacros.SWIFT_UNEXTENDED_MODULE_MAP_PATH)))
                    extraInputPaths.append(unextendedModuleMapNode.path)

                    let vfsNode = delegate.createNode(Path(cbc.scope.evaluate(BuiltinMacros.SWIFT_UNEXTENDED_VFS_OVERLAY_PATH)))
                    args += ["-Xcc", "-ivfsoverlay", "-Xcc", vfsNode.path.str]
                    extraInputPaths.append(vfsNode.path)
                }

            }

            // Add the working directory.
            args.append(contentsOf: ["-working-directory", compilerWorkingDirectory(cbc).str])

            // Add product type specific options.
            // Currently only the test product types use this.
            args.append(contentsOf: cbc.producer.productType?.additionalArgs(for: self) ?? [])

            // Add preview args for dynamic replacement previews
            let previewStyle = cbc.scope.previewStyle
            if previewStyle == .dynamicReplacement {
                args.append(contentsOf: [
                    "-Xfrontend", "-enable-implicit-dynamic",
                    "-Xfrontend", "-enable-private-imports",
                    "-Xfrontend", "-enable-dynamic-replacement-chaining",
                    "-Xfrontend", "-disable-previous-implementation-calls-in-dynamic-replacements"
                ])
            }

            // The overall preview payload applies for both preview styles
            let previewPayload: SwiftPreviewPayload?
            if case .compile = compilationMode, previewStyle != nil {
                previewPayload = SwiftPreviewPayload(
                    architecture: arch,
                    buildVariant: variant,
                    objectFileDir: objectFileDir,
                    moduleCacheDir: cbc.scope.evaluate(BuiltinMacros.MODULE_CACHE_DIR)
                )
            } else {
                previewPayload = nil
            }

            // Pass in access notes if present.
            // "Access notes" are YAML files to override attributes on Swift declarations in this module.
            // We want to be able to add an access note for a particular target without changing anything in the project itself, including the project file. So instead of setting SWIFT_ACCESS_NOTES_PATH only in targets that have an access note, SWIFT_ACCESS_NOTES_PATH can be set by default in SDKs that contain access notes.
            // But that means SWIFT_ACCESS_NOTES_PATH is often set in targets which don't actually have a corresponding access note. A nonexistent access note is not an error--in fact, it's the most common case. Swift Build must therefore check not only whether SWIFT_ACCESS_NOTES_PATH is non-empty, but also whether there is a file at the path it specifies, before it knows whether to pass the path to the compiler.
            // This special case only covers nonexistent files. Other errors (e.g. bad permissions, directory instead of file, parse errors) will be diagnosed by the compiler, so Swift Build doesn't check for them.
            let accessNotesPath = Path(cbc.scope.evaluate(BuiltinMacros.SWIFT_ACCESS_NOTES_PATH))
            if !accessNotesPath.isEmpty && delegate.fileExists(at: accessNotesPath) {
                args += ["-access-notes-path", accessNotesPath.str]
                extraInputPaths.append(accessNotesPath)
            }

            // FIXME: Emit a warning if there is no -target in the options.

            // Compute the inputs and object output dependency paths.
            // Note that we compute the object file output paths here even if the compilation mode won't produce any, because these paths are used to compute the paths to other generated files.
            // FIXME: If we want to match what Xcode did, then when using non-parallel WMO, we should include $(TARGET_NAME)-master.o as an output file, but not include the per-input-file object files as output files.
            let outputObjectExtension: String
            switch cbc.scope.evaluate(BuiltinMacros.SWIFT_LTO) {
            case .yes, .yesThin:
                outputObjectExtension = "bc"
            case .no:
                outputObjectExtension = "o"
            }
            let (inputPaths, objectOutputPaths): ([Path], [Path]) = {
                var inputs = [Path]()
                var outputs = [Path]()
                for input in cbc.inputs {
                    // Add the input path.
                    inputs.append(input.absolutePath)

                    // Compute and add the output object file path.
                    outputs.append(SwiftCompilerSpec.objectFileDirOutput(input: input, moduleBaseNameSuffix: compilationMode.moduleBaseNameSuffix,
                                                                         objectFileDir: objectFileDir, fileExtension: ".\(outputObjectExtension)"))
                }
                return (inputs, outputs)
            }()

            if cbc.scope.evaluate(BuiltinMacros.PLATFORM_REQUIRES_SWIFT_MODULEWRAP) && cbc.scope.evaluate(BuiltinMacros.GCC_GENERATE_DEBUGGING_SYMBOLS) {
                let moduleWrapOutput = Path(moduleFilePath.withoutSuffix + ".o")
                moduleOutputPaths.append(moduleWrapOutput)
            }

            // Add const metadata outputs to extra compilation outputs
            if await supportConstSupplementaryMetadata(cbc, delegate, compilationMode: compilationMode) {
                // If using whole module optimization then we use the -master.swiftconstvalues file from the sole compilation task.
                if isUsingWholeModuleOptimization {
                    if let outputPath = objectOutputPaths.first {
                        let masterSwiftBaseName = cbc.scope.evaluate(BuiltinMacros.TARGET_NAME) + compilationMode.moduleBaseNameSuffix + "-master"
                        let supplementaryConstMetadataOutputPath = outputPath.dirname.join(masterSwiftBaseName + ".swiftconstvalues")
                        extraOutputPaths.append(supplementaryConstMetadataOutputPath)
                        delegate.declareGeneratedSwiftConstMetadataFile(supplementaryConstMetadataOutputPath, architecture: arch)
                    }
                } else {
                    // Otherwise, there will be a const metadata file per-input (per-object-file-output)
                    for input in cbc.inputs {
                        // Compute and add the output supplementary const metadata file path.
                        let supplementaryConstMetadataOutputPath = SwiftCompilerSpec.objectFileDirOutput(input: input, moduleBaseNameSuffix: compilationMode.moduleBaseNameSuffix,
                                                                                                         objectFileDir: objectFileDir, fileExtension: ".swiftconstvalues")
                        extraOutputPaths.append(supplementaryConstMetadataOutputPath)
                        delegate.declareGeneratedSwiftConstMetadataFile(supplementaryConstMetadataOutputPath, architecture: arch)
                    }
                }
            }

            // Add additional input paths.
            extraInputPaths.append(contentsOf: headerSearchPaths.inputPaths)

            // If we're generating module map files, then make the compile task depend on them.
            if let moduleInfo = cbc.producer.moduleInfo {
                extraInputPaths.append(moduleInfo.moduleMapPaths.builtPath)
                if let privateModuleMapPath = moduleInfo.privateModuleMapPaths?.builtPath {
                    extraInputPaths.append(privateModuleMapPath)
                }
            }

            // Add additional output paths.
            let docFilePath: Path?
            if compilationMode.generateDocumentation {
                docFilePath = Path(moduleFilePath.withoutSuffix + ".swiftdoc")
                moduleOutputPaths.append(docFilePath!)
            } else {
                docFilePath = nil
            }

            // Set up the environment.
            var environment: [(String, String)] = environmentFromSpec(cbc, delegate)
            environment.append(("DEVELOPER_DIR", cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR).str))
            let sdkroot = cbc.scope.evaluate(BuiltinMacros.SDKROOT)
            if !sdkroot.isEmpty {
                environment.append(("SDKROOT", sdkroot.str))
            }
            let toolchains = cbc.scope.evaluateAsString(BuiltinMacros.TOOLCHAINS)
            if !toolchains.isEmpty {
                environment.append(("TOOLCHAINS", toolchains))
            }
            let additionalSignatureData = "SWIFTC: \(toolSpecInfo.swiftlangVersion.description)"
            let environmentBindings = EnvironmentBindings(environment)

            let indexingInputReplacements = Dictionary(uniqueKeysWithValues: cbc.inputs.compactMap { ftb -> (Path, Path)? in
                if let repl = ftb.indexingInputReplacement {
                    return (ftb.absolutePath, repl)
                }
                else {
                    return nil
                }
            })

            let dependencyInfoPath: Path? = await {
                guard await shouldEmitMakeStyleDependencies(cbc.producer, cbc.scope, delegate: delegate) else {
                    return nil
                }
                // FIXME: Duplication with `SwiftCompilerSpec.computeOutputFileMapContents`
                //
                // FIXME: Can we simplify this to not require the full macro scope?
                //
                // If using whole module optimization then we use the -master.d file as the dependency file.
                if let outputPath = objectOutputPaths.first {
                    if Self.shouldUseWholeModuleOptimization(for: cbc.scope).result {
                        let masterSwiftBaseName = cbc.scope.evaluate(BuiltinMacros.TARGET_NAME) + compilationMode.moduleBaseNameSuffix + "-master"
                        let dependenciesFilePath = outputPath.dirname.join(masterSwiftBaseName + ".d")
                        return dependenciesFilePath
                    } else {
                        // if not using WMO, we use the first .d file as all are the same
                        return outputPath.dirname.join(outputPath.basenameWithoutSuffix + ".d")
                    }
                }
                return nil
            }()

            if eagerCompilationEnabled(args: args, scope: cbc.scope, compilationMode: compilationMode, isUsingWholeModuleOptimization: isUsingWholeModuleOptimization) {
                if isUsingWholeModuleOptimization {
                    args += ["-emit-module-separately-wmo"]
                } else {
                    args += ["-experimental-emit-module-separately"]
                }
                // Cross-module optimization is not supported when emitting the swiftmodule separately.
                args += ["-disable-cmo"]
            } else if isUsingWholeModuleOptimization && !usingLegacyDriver {
                args += ["-no-emit-module-separately-wmo"]
            }

            // The rule info.
            //
            // NOTE: If this changes, be sure to update the log parser to extract the variant and arch properly.
            func ruleInfo(_ rule: String...) -> [String] {
                rule + [
                    variant,
                    arch + compilationMode.moduleBaseNameSuffix,
                    self.identifier
                ]
            }


            // BUILT_PRODUCTS_DIR here is guaranteed to be absolute by `getCommonTargetTaskOverrides`.
            let payload = SwiftTaskPayload(
                moduleName: moduleName,
                indexingPayload: SwiftIndexingPayload(
                    inputs: indexingInputs(&args),
                    inputReplacements: indexingInputReplacements,
                    builtProductsDir: cbc.scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR),
                    assetSymbolIndexPath: cbc.makeAbsolute(
                        cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_INDEX_PATH)
                    ),
                    objectFileDir: indexObjectFileDir ?? objectFileDir,
                    toolchains: cbc.producer.toolchains.map{ $0.identifier }
                ),
                previewPayload: previewPayload,
                localizationPayload: localizationPayload,
                numExpectedCompileSubtasks: isUsingWholeModuleOptimization ? 1 : cbc.inputs.count,
                driverPayload: await driverPayload(uniqueID: String(args.hashValue), scope: cbc.scope, delegate: delegate, compilationMode: compilationMode, isUsingWholeModuleOptimization: isUsingWholeModuleOptimization, args: args, tempDirPath: objectFileDir, explicitModulesTempDirPath: Path(cbc.scope.evaluate(BuiltinMacros.SWIFT_EXPLICIT_MODULES_OUTPUT_PATH)), variant: variant, arch: arch + compilationMode.moduleBaseNameSuffix, commandLine: ["builtin-SwiftDriver", "--"] + args, ruleInfo: ruleInfo(compilationMode.ruleNameIntegratedDriver, targetName), casOptions: casOptions, linkerResponseFilePath: moduleLinkerArgsPath), previewStyle: cbc.scope.previewStyle
            )

            // Finally, assemble the input and output paths and create the Swift compiler command.
            let allInputs = inputPaths + extraInputPaths

            // Validate inputs for path conformance
            for input in inputPaths where !input.isConformant {
                delegate.error("Input '\(input.str.asSwiftStringLiteralContent)' is non-conformant to path conventions on this platform")
            }

            var allNonModuleOutputs = [Path]()
            if compilationMode.compileSources {
                allNonModuleOutputs += objectOutputPaths
            }
            allNonModuleOutputs += extraOutputPaths
            var allInputsNodes: [any PlannedNode] = allInputs.map(delegate.createNode(_:))
            if await cbc.producer.shouldUseSDKStatCache() && toolSpecInfo.toolFeatures.has(.vfsstatcache) {
                allInputsNodes.append(delegate.createVirtualNode("ClangStatCache \(cbc.scope.evaluate(BuiltinMacros.SDK_STAT_CACHE_PATH))"))
            }
            let execDescription: String
            switch compilationMode {
            case .generateModule:
                // If we're processing module only archs and have a deployment target setting name but no deployment target,
                // it means the SWIFT_MODULE_ONLY_$(DEPLOYMENT_TARGET_SETTING_NAME) setting is not set.
                if cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS, lookup: lookup).contains(arch) && cbc.scope.evaluate(BuiltinMacros.SWIFT_DEPLOYMENT_TARGET, lookup: lookup).nilIfEmpty == nil, let deploymentTargetSettingName = cbc.scope.evaluate(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, lookup: lookup).nilIfEmpty {
                    delegate.error("Using SWIFT_MODULE_ONLY_ARCHS but no module-only deployment target has been specified via SWIFT_MODULE_ONLY_\(deploymentTargetSettingName).", location: .buildSetting(name: "SWIFT_MODULE_ONLY_\(deploymentTargetSettingName)"))
                }

                execDescription = "Generate Swift module"
            default:
                execDescription = resolveExecutionDescription(cbc, delegate)
            }

            if integratedDriverEnabled(scope: cbc.scope) {
                let targetName = cbc.scope.evaluate(BuiltinMacros.TARGET_NAME)

                // Swift Compilation is broken up in 4 phases
                //   - Swift Driver planning
                //   - Unblocking downstream targets by either
                //      - Emitting module (if eager compilation is supported) or
                //      - Compiling files + merging module
                //   - Compiling files (if eager compilation is not supported)
                let compilationRequirementsFinishedNode = delegate.createNode(objectFileDir.join("\(targetName) Swift Compilation Requirements Finished").appendingFileNameSuffix(compilationMode.moduleBaseNameSuffix))
                let compilationFinishedNode = delegate.createNode(objectFileDir.join("\(targetName) Swift Compilation Finished").appendingFileNameSuffix(compilationMode.moduleBaseNameSuffix))

                // Rest compilation (defined before for transparent dependency handling
                let eagerCompilationEnabled = eagerCompilationEnabled(args: args, scope: cbc.scope, compilationMode: compilationMode, isUsingWholeModuleOptimization: isUsingWholeModuleOptimization)
                let compilationRequirementOutputs: [any PlannedNode]
                let compilationOutputs: [any PlannedNode]
                if eagerCompilationEnabled {
                    let nonModuleOutputNodes = allNonModuleOutputs.map(delegate.createNode(_:))
                    compilationRequirementOutputs = [compilationRequirementsFinishedNode] + moduleOutputPaths.map(delegate.createNode(_:))
                    compilationOutputs = [compilationFinishedNode] + nonModuleOutputNodes
                } else {
                    compilationRequirementOutputs = (allNonModuleOutputs + moduleOutputPaths).map(delegate.createNode(_:))
                    compilationOutputs = [compilationFinishedNode]
                }

                let dependencyData: DependencyDataStyle?
                if await shouldEmitMakeStyleDependencies(cbc.producer, cbc.scope, delegate: delegate) {
                    // FIXME: Duplication with `SwiftCompilerSpec.computeOutputFileMapContents`
                    let masterSwiftBaseName = cbc.scope.evaluate(BuiltinMacros.TARGET_NAME) + compilationMode.moduleBaseNameSuffix + "-master"
                    let emitModuleDependenciesFilePath = objectFileDir.join(masterSwiftBaseName + "-emit-module.d")
                    dependencyData = eagerCompilationEnabled ? .makefileIgnoringSubsequentOutputs(emitModuleDependenciesFilePath) : dependencyInfoPath.map(DependencyDataStyle.makefileIgnoringSubsequentOutputs)
                } else {
                    dependencyData = nil
                }

                // Compilation Requirements
                delegate.createTask(type: self, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo("SwiftDriver Compilation Requirements", targetName), additionalSignatureData: additionalSignatureData, commandLine: ["builtin-Swift-Compilation-Requirements", "--"] + args, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: allInputsNodes, outputs: compilationRequirementOutputs, action: delegate.taskActionCreationDelegate.createSwiftCompilationRequirementTaskAction(), execDescription: archSpecificExecutionDescription(cbc.scope.namespace.parseString("Unblock downstream dependents of $PRODUCT_NAME"), cbc, delegate), preparesForIndexing: true, enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilation, .compilationRequirement, .linkingRequirement, .blockedByTargetHeaders, .compilationForIndexableSourceFile], usesExecutionInputs: true, showInLog: true)

                if case .compile = compilationMode {
                    // Unblocking compilation
                    delegate.createTask(type: self, dependencyData: eagerCompilationEnabled ? dependencyInfoPath.map(DependencyDataStyle.makefileIgnoringSubsequentOutputs) : nil, payload: payload, ruleInfo: ruleInfo("SwiftDriver Compilation", targetName), additionalSignatureData: additionalSignatureData, commandLine: ["builtin-Swift-Compilation", "--"] + args, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: allInputsNodes, outputs: compilationOutputs, action: delegate.taskActionCreationDelegate.createSwiftCompilationTaskAction(), execDescription: archSpecificExecutionDescription(cbc.scope.namespace.parseString("Compile $PRODUCT_NAME"), cbc, delegate), preparesForIndexing: true, enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.blockedByTargetHeaders, .compilation], usesExecutionInputs: true, showInLog: true)
                }

            } else {
                // Swift is creating its compilation invocation using the .compilationRequirement task ordering option because it generates a module which needs to block downstream compile tasks.
                // With InstallAPI, only the module generation will be the requirement, compilation can be done in parallel.
                delegate.createTask(type: self, dependencyData: dependencyInfoPath.map(DependencyDataStyle.makefileIgnoringSubsequentOutputs), payload: payload, ruleInfo: ruleInfo(compilationMode.ruleName), additionalSignatureData: additionalSignatureData, commandLine: args, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: allInputsNodes, outputs: (allNonModuleOutputs + moduleOutputPaths).map { delegate.createNode($0) }, action: nil, execDescription: execDescription, preparesForIndexing: true, enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilation, .compilationRequirement, .blockedByTargetHeaders, .compilationForIndexableSourceFile], usesExecutionInputs: false)
            }

            if cbc.scope.evaluate(BuiltinMacros.PLATFORM_REQUIRES_SWIFT_AUTOLINK_EXTRACT) {
                let toolName = cbc.producer.hostOperatingSystem.imageFormat.executableName(basename: "swift-autolink-extract")
                let toolPath = resolveExecutablePath(cbc, toolSpecInfo.toolPath.dirname.join(toolName))

                delegate.createTask(
                    type: self,
                    ruleInfo: ["SwiftAutolinkExtract", moduleName],
                    commandLine: [toolPath.str] + objectOutputPaths.map(\.str) + ["-o", cbc.scope.evaluate(BuiltinMacros.SWIFT_AUTOLINK_EXTRACT_OUTPUT_PATH).str],
                    environment: EnvironmentBindings(),
                    workingDirectory: compilerWorkingDirectory(cbc),
                    inputs: objectOutputPaths,
                    outputs: [cbc.scope.evaluate(BuiltinMacros.SWIFT_AUTOLINK_EXTRACT_OUTPUT_PATH)],
                    execDescription: "Extract autolink entries for '\(moduleName)'",
                    enableSandboxing: false
                )
            }

            // Add copy tasks to move the module-related files into place.  We only do this for the normal variant.
            // FIXME: What should we do here if there is no normal variant?
            if isNormalVariant && cbc.scope.evaluate(BuiltinMacros.SWIFT_INSTALL_MODULE) {
                /// Utility function to copy a module-related file into the final destination.
                func copyModuleContent(_ input: Path, isProject: Bool = false, additionalTaskOrderingOptions: TaskOrderingOptions = []) async {
                    if isProject {
                        if cbc.scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING) {
                            return
                        }
                    }

                    var inputFileSuffix = input.fileSuffix

                    // Check for the longer suffix of private module interfaces.
                    // `fileSuffix` would only return .swiftinterface in this case.
                    let privateModuleInterfaceSuffix = ".private.swiftinterface"
                    if input.matchesFilenamePattern("*" + privateModuleInterfaceSuffix) {
                      inputFileSuffix = privateModuleInterfaceSuffix
                    }

                    // Check for .package.swiftinterface suffix of package module interfaces.
                    let packageModuleInterfaceSuffix = ".package.swiftinterface"
                    if input.matchesFilenamePattern("*" + packageModuleInterfaceSuffix) {
                      inputFileSuffix = packageModuleInterfaceSuffix
                    }

                    // Check for the longer suffix of abi descriptor.
                    let abiDescriptorSuffix = ".abi.json"
                    if input.matchesFilenamePattern("*" + abiDescriptorSuffix) {
                        inputFileSuffix = abiDescriptorSuffix
                    }

                    let outputFileName = compilationMode.destinationModuleFileName(cbc.scope) + inputFileSuffix
                    let outputPath = swiftModuleContentPath(cbc, moduleName: moduleName, fileName: outputFileName, isProject: isProject)
                    await cbc.producer.copySpec.constructCopyTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [FileToBuild(absolutePath: input, inferringTypeUsing: cbc.producer)], output: outputPath, preparesForIndexing: true), delegate, additionalTaskOrderingOptions: additionalTaskOrderingOptions)
                }

                let orderingOptions: TaskOrderingOptions = [.compilationRequirement, .blockedByTargetHeaders]

                // Copy the main .swiftmodule file.
                await copyModuleContent(moduleFilePath, additionalTaskOrderingOptions: orderingOptions)

                if let abiDescriptorPath = abiDescriptorPath {
                    // Copy the ABI descriptor to the module dir.
                    await copyModuleContent(abiDescriptorPath, additionalTaskOrderingOptions: orderingOptions)
                }

                // Copy the main .swiftsourceinfo file to the Project dir.
                await copyModuleContent(sourceInfoPath, isProject: true, additionalTaskOrderingOptions: orderingOptions)

                // Copy the generated .swiftinterface file.
                if let moduleInterfaceFilePath = moduleInterfaceFilePath {
                    await copyModuleContent(moduleInterfaceFilePath, additionalTaskOrderingOptions: orderingOptions)
                }

                // Copy the generated .private.swiftinterface file.
                if let privateModuleInterfaceFilePath = privateModuleInterfaceFilePath {
                    await copyModuleContent(privateModuleInterfaceFilePath, additionalTaskOrderingOptions: orderingOptions)
                }

                // Copy the generated .package.swiftinterface file.
                if let packageModuleInterfaceFilePath = packageModuleInterfaceFilePath {
                    await copyModuleContent(packageModuleInterfaceFilePath, additionalTaskOrderingOptions: orderingOptions)
                }

                // Copy the generated .swiftdoc file.
                if let docFilePath = docFilePath {
                    await copyModuleContent(docFilePath, additionalTaskOrderingOptions: orderingOptions)
                }

                // Copy the generated API header for Objective-C.
                if let objcHeaderFilePath = objcHeaderFilePath {
                    delegate.declareGeneratedSwiftObjectiveCHeaderFile(objcHeaderFilePath, architecture: arch)
                }
            }
        }

        func integratedDriverEnabled(scope: MacroEvaluationScope) -> Bool {
            scope.evaluate(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER)
        }

        func eagerCompilationEnabled(args: [String], scope: MacroEvaluationScope, compilationMode: SwiftCompilationMode, isUsingWholeModuleOptimization: Bool) -> Bool {
            let supported = scope.evaluate(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER) && compilationMode.supportsEagerCompilation(isUsingWholeModuleOptimization: isUsingWholeModuleOptimization)
            if isUsingWholeModuleOptimization {
                // As of rdar://89223981 eager compilation with WMO is opt-in
                return supported && scope.evaluate(BuiltinMacros.SWIFT_EAGER_MODULE_EMISSION_IN_WMO) && scope.evaluate(BuiltinMacros.SWIFT_ENABLE_LIBRARY_EVOLUTION)
            } else {
                return supported
            }
        }

        func driverPayload(uniqueID: String, scope: MacroEvaluationScope, delegate: any TaskGenerationDelegate, compilationMode: SwiftCompilationMode, isUsingWholeModuleOptimization: Bool, args: [String], tempDirPath: Path, explicitModulesTempDirPath: Path, variant: String, arch: String, commandLine: [String], ruleInfo: [String], casOptions: CASOptions?, linkerResponseFilePath: Path?) async -> SwiftDriverPayload? {
            guard integratedDriverEnabled(scope: scope) else {
                return nil
            }

            let compilerLocation: LibSwiftDriver.CompilerLocation

            #if os(macOS) || !canImport(Darwin)
            compilerLocation = .path(swiftc)
            #else
            guard let libSwiftScanPath = cbc.producer.toolchains.map({ $0.path.join("usr/lib/swift/host/lib_InternalSwiftScan.dylib") }).first(where: { localFS.exists($0) }) else {
                delegate.error("Could not find lib_InternalSwiftScan.dylib in toolchain")
                return nil
            }
            compilerLocation = .library(libSwiftScanPath: libSwiftScanPath)
            #endif
            let explicitModuleBuildEnabled = await swiftExplicitModuleBuildEnabled(cbc.producer, cbc.scope, delegate)
            let verifyScannerDependencies = explicitModuleBuildEnabled && cbc.scope.evaluate(BuiltinMacros.SWIFT_DEPENDENCY_REGISTRATION_MODE) == .verifySwiftDependencyScanner

            return SwiftDriverPayload(uniqueID: uniqueID, compilerLocation: compilerLocation, moduleName: scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME), tempDirPath: tempDirPath, explicitModulesTempDirPath: explicitModulesTempDirPath, variant: variant, architecture: arch, eagerCompilationEnabled: eagerCompilationEnabled(args: args, scope: scope, compilationMode: compilationMode, isUsingWholeModuleOptimization: isUsingWholeModuleOptimization), explicitModulesEnabled: explicitModuleBuildEnabled, commandLine: commandLine, ruleInfo: ruleInfo, isUsingWholeModuleOptimization: isUsingWholeModuleOptimization, casOptions: casOptions, reportRequiredTargetDependencies: scope.evaluate(BuiltinMacros.DIAGNOSE_MISSING_TARGET_DEPENDENCIES), linkerResponseFilePath: linkerResponseFilePath, dependencyFilteringRootPath: cbc.producer.sdk?.path, verifyScannerDependencies: verifyScannerDependencies)
        }

        func constructSwiftResponseFileTask(path: Path) {
            let fileListContents = OutputByteStream()
            for inputFile in cbc.inputs {
                guard let quotedPath = inputFile.absolutePath.commandQuoted else {
                    delegate.error("Response file input '\(inputFile.absolutePath.str.asSwiftStringLiteralContent)' is non-conformant to path conventions on this platform")
                    continue
                }
                fileListContents <<< quotedPath <<< "\n"
            }

            cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: path), delegate, contents: fileListContents.bytes, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        func validSwiftResponseFilePath() -> Path? {
            let fileListPath = cbc.scope.evaluate(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH)
            guard !fileListPath.isEmpty else {
                return nil
            }
            return fileListPath
        }

        /// Returns the inputs that should be passed for indexing.
        /// For response files, this contains all file paths of the inputs.
        /// For legacy this contains the range of all inputs in the arguments array which gets the inputs appended at the end.
        func indexingInputs(_ cliArgs: inout [String]) -> SwiftIndexingPayload.Inputs {
            let responseFilePath = cbc.scope.evaluate(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH)
            // remove in rdar://53000820
            if cbc.scope.evaluate(BuiltinMacros.USE_SWIFT_RESPONSE_FILE) {
                return .filePaths(responseFilePath, cbc.inputs.map { $0.absolutePath })
            } else {
                // The file list parameter will be added by default from the spec, so if the feature is off, we need to remove it manually
                if let fileListIndex = cliArgs.firstIndex(of: "@" + responseFilePath.str) {
                    cliArgs.remove(at: fileListIndex)
                }

                for inputFile in cbc.inputs {
                    // Add the absolute path.
                    cliArgs.append(inputFile.absolutePath.str)
                }
                return .range(Range(uncheckedBounds: (cliArgs.count - cbc.inputs.count, cliArgs.count)))
            }
        }

        // Create the Swift response file creation task if needed
        let inputMode: SwiftCompilerInputMode
        // remove in rdar://53000820
        if cbc.scope.evaluate(BuiltinMacros.USE_SWIFT_RESPONSE_FILE) {
            guard let filePath = validSwiftResponseFilePath() else {
                delegate.error("The path for Swift input file list cannot be empty.", location: .buildSetting(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH), component: .default)
                return
            }
            constructSwiftResponseFileTask(path: filePath)
            inputMode = .responseFile(filePath)
        } else {
            inputMode = .individualFiles
        }

        typealias LookupFunc = (MacroDeclaration) -> MacroExpression?
        func chainLookupFuncs(_ lookupFuncs: LookupFunc...) -> LookupFunc {
            return { macro in
                for lookupFunc in lookupFuncs {
                    if let expression = lookupFunc(macro) {
                        return expression
                    }
                }

                return nil
            }
        }

        func constructZipperedSwiftModuleTasks(moduleOnly: Bool, lookup: LookupFunc? = nil) async {
            guard let (alternatePlatform, triplePlatform, tripleSuffix) = Self.zipperedSwiftModuleInfo(cbc.producer, arch: arch) else {
                return
            }

            // We use the same command line we used for the main compile, but with a few changes controlled by the
            // lookup function.
            let zipperedLookup: ((MacroDeclaration) -> MacroExpression?) = { macro in
                switch macro {
                case BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME:
                    return Static { cbc.scope.namespace.parseLiteralString("") } as MacroStringExpression
                case BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX:
                    return cbc.scope.namespace.parseLiteralString(triplePlatform)
                case BuiltinMacros.SWIFT_DEPLOYMENT_TARGET:
                    // SDKSettings for macCatalyst variant sets this to $(IPHONEOS_DEPLOYMENT_TARGET);
                    // it should probably set DEPLOYMENT_TARGET_SETTING_NAME=IPHONEOS_DEPLOYMENT_TARGET
                    // instead, and we get rid of SWIFT_DEPLOYMENT_TARGET.
                    return Static {
                        cbc.scope.namespace.parseString("$($(DEPLOYMENT_TARGET_SETTING_NAME))")
                    } as MacroStringExpression
                case BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME:
                    return cbc.scope.namespace.parseString(alternatePlatform.deploymentTargetSettingName(infoLookup: cbc.producer))
                case BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX:
                    return cbc.scope.namespace.parseLiteralString(tripleSuffix)
                case BuiltinMacros.SWIFT_TARGET_TRIPLE_VARIANTS:
                    return Static { cbc.scope.namespace.parseLiteralStringList([]) } as MacroStringListExpression
                case BuiltinMacros.SWIFT_INDEX_STORE_ENABLE:
                    // Doesn't contribute to the module store per rdar://48211996.
                    return Static { cbc.scope.namespace.parseLiteralString("NO") } as MacroStringExpression
                default:
                    return nil
                }
            }

            let lookup = lookup ?? { _ in return nil }
            let chainLookup = chainLookupFuncs(lookup, zipperedLookup)

            await constructSwiftCompilationTasks(
                compilationMode: .generateModule(triplePlatform: triplePlatform, tripleSuffix: tripleSuffix, moduleOnly: moduleOnly),
                inputMode: inputMode,
                lookup: chainLookup)
        }

        let hasEnabledIndexBuildArena = cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        if hasEnabledIndexBuildArena && !cbc.producer.targetRequiredToBuildForIndexing {
            await constructSwiftCompilationTasks(compilationMode: .prepareForIndex, inputMode: inputMode)
            return
        }

        // Build .swiftmodules for module-only architectures.
        let moduleOnlyArchs = cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS)
        if moduleOnlyArchs.contains(arch) {
            let triplePlatform = cbc.scope.evaluate(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX)
            let tripleSuffix = cbc.scope.evaluate(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX)

            // We use the same command line we used for the main compile, but with a few changes controlled by the lookup function.
            let lookup: LookupFunc = { macro in
                switch macro {
                case BuiltinMacros.SWIFT_DEPLOYMENT_TARGET:
                    return Static {
                        cbc.scope.namespace.parseString("$(SWIFT_MODULE_ONLY_$(DEPLOYMENT_TARGET_SETTING_NAME):default=$($(DEPLOYMENT_TARGET_SETTING_NAME)))")
                    } as MacroStringExpression
                default:
                    return nil
                }
            }

            let deploymentTargetNameLookup: LookupFunc = { macro in
                switch macro {
                case BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME:
                    if cbc.producer.sdkVariant?.isMacCatalyst == true {
                        return cbc.scope.namespace.parseString(
                            BuildVersion.Platform.macCatalyst.deploymentTargetSettingName(infoLookup: cbc.producer))
                    }
                    return nil
                default:
                    return nil
                }
            }

            let is32BitMacCatalyst = cbc.producer.sdkVariant?.isMacCatalyst == true && arch == "i386"
            let chainLookup = chainLookupFuncs(deploymentTargetNameLookup, lookup)

            // Skip generation of i386 swiftmodules when building for Mac Catalyst - 32 bit never existed there.
            // Note that we still enter the zippered case below, since we may be building zippered with Mac Catalyst
            // as the primary variant and with i386 in SWIFT_MODULE_ONLY_ARCHS, in which case the secondary variant
            // (normal macOS) should still generate the i386 swiftmodule.
            if !is32BitMacCatalyst {
                await constructSwiftCompilationTasks(
                    compilationMode: .generateModule(triplePlatform: triplePlatform, tripleSuffix: tripleSuffix, moduleOnly: true),
                    inputMode: inputMode,
                    lookup: chainLookup)
            }

            // Don't pass the module-only flag to the zippered variant if we passed it to the main variant above, because we don't want to create generated Objective-C headers from that task. It's unnecessary because zippering can't be distinguished at the API level, and would result in duplicate tasks creating the header file anyways.
            if cbc.producer.platform?.familyName == "macOS", cbc.scope.evaluate(BuiltinMacros.IS_ZIPPERED) {
                await constructZipperedSwiftModuleTasks(moduleOnly: is32BitMacCatalyst, lookup: lookup)
            }

            // Construct the tasks and then exit early to avoid constructing actual compilation tasks.
            return
        }

        // Create the main compilation task using the appropriate mode.
        let compilationMode: SwiftCompilationMode
        if cbc.scope.evaluate(BuiltinMacros.INSTALLAPI_MODE_ENABLED) {
            guard cbc.producer.targetShouldBuildModuleForInstallAPI else {
                delegate.warning("Skipping installAPI swiftmodule emission for target '\(cbc.producer.configuredTarget?.target.name ?? "<unknown>")'")
                return
            }
            compilationMode = .api
        }
        else {
            compilationMode = .compile
        }
        await constructSwiftCompilationTasks(compilationMode: compilationMode, inputMode: inputMode)

        // If we're building a zippered framework (for macOS+macCatalyst), then we need to invoke the compiler again to generate the macCatalyst .swiftmodule, .swiftdoc and .swiftinterface files and copy them into the framework to the appropriate location.
        // This command has the following characteristics:
        //  - Passes a different -target option ("<arch>-<vendor>-ios<ios-depl-tgt>-macabi").
        //  - Does not pass -c.
        //  - Still passes -index-store-path, as that's how symbols for the zippered framework end up in the index. (Currently this is disabled per <rdar://problem/48211996> but we hope to restore it in the future.)
        //  - Emits the .swiftmodule file to a different filename and then copies it alongside the main .swiftmodule.
        // Note that we *do* invoke swiftc in this mode even when doing installapi since we want the .swiftmodule (etc.) to be emitted for installapi, but we don't want to emit another .tbd file.
        if cbc.producer.platform?.familyName == "macOS", cbc.scope.evaluate(BuiltinMacros.IS_ZIPPERED) {
            await constructZipperedSwiftModuleTasks(moduleOnly: false)
        }
    }

    private static func zipperedSwiftModuleInfo(_ producer: any CommandProducer, arch: String) -> (alternatePlatform: BuildVersion.Platform, triplePlatform: String, tripleSuffix: String)? {
        // This is a hard-coded hack for zippering. But many things around zippering are similarly hacky.
        let alternatePlatform: BuildVersion.Platform
        let triplePlatform: String
        let tripleSuffix: String
        switch producer.sdkVariant?.isMacCatalyst ?? false {
        case true:
            alternatePlatform = .macOS
            triplePlatform = "macos"
            tripleSuffix = ""
        case false:
            alternatePlatform = .macCatalyst
            triplePlatform = "ios"
            tripleSuffix = "-macabi"
        }

        // Skip generation of i386 swiftmodules when building zippered and the secondary variant is Mac Catalyst
        // - 32 bit never existed there.
        if alternatePlatform == .macCatalyst && arch == "i386" {
            return nil
        }

        return (alternatePlatform, triplePlatform, tripleSuffix)
    }

    public static func shouldInstallGeneratedObjectiveCHeader(_ scope: MacroEvaluationScope) -> Bool {
        let objcHeaderFileName = scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME)
        return !objcHeaderFileName.isEmpty && scope.isFramework && scope.evaluate(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER)
    }

    public static func generatedObjectiveCHeaderOutputPath(_ scope: MacroEvaluationScope) -> Path {
        // Figure out whether we're installing the ObjC header file.
        // FIXME: We need to be able to ask the product type here for the module map path, and whether to install the header.  This is placeholder code for now.
        let installObjCHeader = shouldInstallGeneratedObjectiveCHeader(scope)
        let headerOutputPathDir = scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_DIR).nilIfEmpty

        let headerOutputPath: Path
        if installObjCHeader {
            headerOutputPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH)).join(scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME))
        } else if let headerOutputPathDir = headerOutputPathDir {
            headerOutputPath = Path(headerOutputPathDir).join(scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME))
        } else {
            headerOutputPath = scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME))
        }

        return headerOutputPath
    }

    public static func swiftModuleContentDir(_ scope: MacroEvaluationScope, moduleName: String, isProject: Bool) -> Path {
        let moduleDirPath: Path
        if scope.evaluate(BuiltinMacros.SWIFT_INSTALL_MODULE_FOR_DEPLOYMENT) {
            let modulesFolderPath = scope.evaluate(BuiltinMacros.MODULES_FOLDER_PATH)
            moduleDirPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(modulesFolderPath).join(moduleName + ".swiftmodule")
        } else {
            moduleDirPath = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(moduleName + ".swiftmodule")
        }
        if isProject {
            // Copy this content to the Project subdir so we could master them out when installing.
            return moduleDirPath.join("Project")
        }
        return moduleDirPath
    }

    /// Utility method to compute the path to the final destination for a module-related file.
    private func swiftModuleContentPath(_ cbc: CommandBuildContext, moduleName: String, fileName: String, isProject: Bool) -> Path {
        return SwiftCompilerSpec.swiftModuleContentDir(cbc.scope, moduleName: moduleName, isProject: isProject).join(fileName)
    }

    /// Gets the paths to the symbol graph files for the Swift module for all architectures and variants.
    static func mainSymbolGraphFiles(_ cbc: CommandBuildContext) -> [Path] {
        let archSpecificSubScopes = cbc.scope.evaluate(BuiltinMacros.ARCHS).map { arch in
            return cbc.scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
        }

        return archSpecificSubScopes.flatMap { subScope in
            mainSymbolGraphFilesForCurrentArch(cbc: CommandBuildContext(producer: cbc.producer, scope: subScope, inputs: cbc.inputs))
        }
    }

    /// Gets the paths to the symbol graph files for the Swift module for all variants.
    static func mainSymbolGraphFilesForCurrentArch(cbc: CommandBuildContext) -> [Path] {
        var paths = [getMainSymbolGraphFile(cbc.scope, .compile)]

        // Check if there should be an additional main symbol graph file for the zippered variant in this sub scope.
        if cbc.producer.platform?.familyName == "macOS", cbc.scope.evaluate(BuiltinMacros.IS_ZIPPERED),
           let (_, triplePlatform, tripleSuffix) = zipperedSwiftModuleInfo(cbc.producer, arch: cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH))
        {
            paths.append(getMainSymbolGraphFile(cbc.scope, .generateModule(triplePlatform: triplePlatform, tripleSuffix: tripleSuffix, moduleOnly: false)))
        }

        return paths
    }

    /// Gets the path to the symbol graph file for the Swift module in a given scope for a given compiler mode.
    ///
    /// - Important: Only use this as an argument to the command line tool that produces the symbol graph files.
    ///              Use `getMainSymbolGraphFile` when specifying the inputs and outputs of constructed tasks.
    static func getSymbolGraphDirectory(_ scope: MacroEvaluationScope, _ mode: SwiftCompilerSpec.SwiftCompilationMode) -> Path {
        // This method exists so that other tasks can compute the symbol graph file path to depend on it.
        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.SWIFT_TARGET_TRIPLE:
                return scope.namespace.parseLiteralString(mode.destinationModuleFileName(scope))
            default:
                return nil
            }
        }

        return Path(scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_OUTPUT_DIR, lookup: lookup))
    }

    /// Gets the path to the symbol graph file for the Swift module in a given scope for a given compiler mode.
    ///
    /// - Important: Use this value when specifying the inputs and outputs of constructed tasks.
    static func getMainSymbolGraphFile(_ scope: MacroEvaluationScope, _ mode: SwiftCompilerSpec.SwiftCompilationMode) -> Path {
        // Changes to a file in a directory doesn't mark the directory as "changed" when the directory is specified as a tasks output.
        //
        // Since one tasks outputs the directories of symbol graph files and another uses it as input, we need to specify
        // a file as input so that incremental builds work as expected.
        //
        // At the point where the tasks are constructed we don't know all the symbol graph files that it will output but it's
        // enough that we know the main symbol graph file (the one for the current module) since this is only control dependencies between tasks.
        return getSymbolGraphDirectory(scope, mode).join("\(scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME)).symbols.json")
    }

    /// Find the path for a library.
    private func findSearchPathForLibrary(executablePath: Path, possibleNames libraryNames: [String], toolchains: [Toolchain]) -> Path? {
        func findLibrary(inDirectory path: Path) -> Path? {
            for name in libraryNames {
                let candidate = path.join(name)
                if localFS.exists(candidate) {
                    return candidate.dirname
                }
            }
            return nil
        }
        func findSearchPath(inToolchain toolchain: Toolchain) -> Path? {
            // When examining the toolchains, the list of possible names is not considered. This is due to the migration to Swift-in-the-OS and the removal of the stdlib from the toolchain path. However, there are still libraries being emitted into this folder, and thus the toolchain path needs to be added if it exists on disk. (rdar://52062097)

            for path in toolchain.librarySearchPaths.paths {
                for name in libraryNames {
                    let candidate = path.join(name).dirname
                    if localFS.exists(candidate) {
                        return candidate
                    }
                }
            }
            return nil
        }

        // First, look next to the compiler.
        let executableParentFilePath = executablePath.dirname
        let possibleLibSearchPath = executableParentFilePath.dirname.join("lib")
        if localFS.isDirectory(possibleLibSearchPath) {
            if let result = findLibrary(inDirectory: possibleLibSearchPath) {
                return result
            }
        }

        // We couldn't find the standard library next to the compiler; look in the toolchains specified by TOOLCHAINS.
        for toolchain in toolchains {
            if let result = findSearchPath(inToolchain: toolchain) {
                return result
            }
        }

        return nil
    }

    /// Compute whether the task should use whole module optimization.
    ///
    /// The `result` component will be true if the WMO is explicitly enabled or if we're building for API. The 'isExplicitlyEnabled' component will be true if the 'result' is true *because* WMO is explicitly enabled.
    public static func shouldUseWholeModuleOptimization(for scope: MacroEvaluationScope) -> (result: Bool, isExplicitlyEnabled: Bool) {
        let isForAPI = scope.evaluate(BuiltinMacros.INSTALLAPI_MODE_ENABLED)
        let isExplicitlyEnabled =
            scope.evaluate(BuiltinMacros.SWIFT_WHOLE_MODULE_OPTIMIZATION) ||
            (scope.evaluate(BuiltinMacros.SWIFT_COMPILATION_MODE) == "wholemodule") ||
            (scope.evaluate(BuiltinMacros.SWIFT_OPTIMIZATION_LEVEL) == "-Owholemodule")
        let isEnabled = isExplicitlyEnabled || isForAPI
        return (isEnabled, isExplicitlyEnabled)
    }

    private func staticallyLinkSwiftStdlib(_ producer: any CommandProducer, scope: MacroEvaluationScope) -> Bool {
        // Determine whether we should statically link the Swift stdlib, and determined
        // by the following logic in the following order:
        //
        // (1) Static linking is used if SWIFT_FORCE_STATIC_LINK_STDLIB is set.
        // (2) Otherwise, dynamic linking is used.
        //
        // NOTE: If SWIFT_FORCE_SYSTEM_LINK_STDLIB has been set then the system
        //       libraries will be used first, regardless of static linking being
        //       used.  This is controlled by the linker search path logic below.
        //
        // NOTE: With Swift in the OS, static libs aren't being supplied by the toolchains
        //       so users of this flag will need to provide their own.
        if scope.evaluate(BuiltinMacros.SWIFT_FORCE_STATIC_LINK_STDLIB) {
            return true
        }
        return false
    }

    public override func computeAdditionalLinkerArgs(_ producer: any CommandProducer, scope: MacroEvaluationScope, inputFileTypes: [FileTypeSpec], optionContext: (any BuildOptionGenerationContext)?, delegate: any TaskGenerationDelegate) async -> (args: [[String]], inputPaths: [Path]) {
        return await computeAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: inputFileTypes, optionContext: optionContext, forTAPI: false, delegate: delegate)
    }

    func computeAdditionalLinkerArgs(_ producer: any CommandProducer, scope: MacroEvaluationScope, inputFileTypes: [FileTypeSpec], optionContext: (any BuildOptionGenerationContext)?, forTAPI: Bool = false, delegate: any TaskGenerationDelegate) async -> (args: [[String]], inputPaths: [Path]) {
        guard let swiftToolSpec = optionContext as? DiscoveredSwiftCompilerToolSpecInfo else {
            // An error message would have already been emitted by this point
            return (args: [[]], inputPaths: [])
        }

        // Compute the executable path.
        let swiftc = swiftToolSpec.toolPath

        var args:  [[String]] = []
        var inputPaths: [Path] = []
        if !forTAPI {
            // TAPI can't use all of the additional linker options, and its spec has all of the build setting/option arguments that it can use.
            args = self.flattenedOrderedBuildOptions.map { $0.getAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: inputFileTypes) }.filter { !$0.isEmpty }
        }

        // Determine if we are forced to use the standard system location; this is currently only for OS adopters of Swift, not any client.
        let useSystemSwift = scope.evaluate(BuiltinMacros.SWIFT_FORCE_SYSTEM_LINK_STDLIB)

        // Determine whether we should statically link the Swift stdlib.
        let shouldStaticLinkStdlib = staticallyLinkSwiftStdlib(producer, scope: scope)

        let swiftStdlibName = scope.evaluate(BuiltinMacros.SWIFT_STDLIB)
        var swiftLibraryPath = scope.evaluate(BuiltinMacros.SWIFT_LIBRARY_PATH)
        let dynamicLibraryExtension = scope.evaluate(BuiltinMacros.DYNAMIC_LIBRARY_EXTENSION)

        // If we weren't given an explicit library path, compute one
        let platformName = scope.evaluate(BuiltinMacros.PLATFORM_NAME)
        if swiftLibraryPath.isEmpty {
            // Look next to the compiler and in the toolchains for one.
            if shouldStaticLinkStdlib {
                swiftLibraryPath = findSearchPathForLibrary(executablePath: swiftc, possibleNames: [
                        "swift_static/\(platformName)/lib\(swiftStdlibName).a",
                        "swift_static/lib\(swiftStdlibName).a",
                        "lib\(swiftStdlibName).a",
                    ], toolchains: producer.toolchains) ?? Path("")
            } else {
                swiftLibraryPath = findSearchPathForLibrary(executablePath: swiftc, possibleNames: [
                        "swift/\(platformName)/lib\(swiftStdlibName).\(dynamicLibraryExtension)",
                        "swift/lib\(swiftStdlibName).\(dynamicLibraryExtension)",
                        "lib\(swiftStdlibName).\(dynamicLibraryExtension)",
                    ], toolchains: producer.toolchains) ?? Path("")
            }
        }

        let isMacCatalystUnzippered = producer.sdkVariant?.isMacCatalyst == true && !scope.evaluate(BuiltinMacros.IS_ZIPPERED)

        var sdkPathArgument: [String] = []
        var unzipperedSDKPathArgument: [String] = []
        if forTAPI {
            // TAPI requires absolute paths.
            let sdkroot = scope.evaluate(BuiltinMacros.SDKROOT)
            if !sdkroot.isEmpty {
                sdkPathArgument = ["-L" + sdkroot.join("usr/lib/swift").str]
                unzipperedSDKPathArgument = ["-L" + sdkroot.join("System/iOSSupport/usr/lib/swift").str]
            }
        } else {
            // ld prefers SDK relative paths.
            sdkPathArgument = ["-L/usr/lib/swift"]
            unzipperedSDKPathArgument = ["-L/System/iOSSupport/usr/lib/swift"]
        }

        // If we are forced to use the system's copy of the runtime dylibs, always prepend a -L path to find those FIRST before the ones in the toolchain.
        if useSystemSwift {
            if isMacCatalystUnzippered {
                args += [unzipperedSDKPathArgument]
            }

            args += [sdkPathArgument]
        }

        // Add the -L to the standard library path. This is used primarily for the OSS toolchain now as each of the libs have been moved into the Swift SDK.
        //
        // Even if useSystemSwift is true, still append the library path.  It will be later in the search path, and will allow libraries not in the system location (such as XCTest) to be found.
        if !swiftLibraryPath.isEmpty {
            // Tell the linker where it can find SWIFT_STDLIB. (We don't need to quote this, since the driver accepts -L.)
            args += [["-L\(swiftLibraryPath.str)"]]
        } else {
            // FIXME: We don't have a way to report diagnostics from here, currently.
            // warning("Unable to find \(swiftStdlibName); please set SWIFT_LIBRARY_PATH (currently '\(swiftLibraryPath)') to the folder containing \(swiftStdlibName).")
        }

        if isMacCatalystUnzippered {
            args += [unzipperedSDKPathArgument]
        }

        // Add in the linker flags for the Swift SDK.
        args += [sdkPathArgument]

        if !forTAPI {
            if shouldStaticLinkStdlib {
                args += [["-Xlinker", "-force_load_swift_libs"]]
                // The Swift runtime requires libc++ & Foundation.
                args += [["-lc++", "-framework", "Foundation"]]
            }

            // Add the AST, if debugging.
            //
            // We also check if there are any sources in this target because this could
            // be a source-less target which just contains object files in it's framework phase.
            let currentPlatformFilter = PlatformFilter(scope)
            let containsSources = (producer.configuredTarget?.target as? StandardTarget)?.sourcesBuildPhase?.buildFiles.filter { currentPlatformFilter.matches($0.platformFilters) }.isEmpty == false
            if containsSources && inputFileTypes.contains(where: { $0.conformsTo(identifier: "sourcecode.swift") }) && scope.evaluate(BuiltinMacros.GCC_GENERATE_DEBUGGING_SYMBOLS) && !scope.evaluate(BuiltinMacros.PLATFORM_REQUIRES_SWIFT_MODULEWRAP) {
                let moduleName = scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
                let moduleFileDir = scope.evaluate(BuiltinMacros.PER_ARCH_MODULE_FILE_DIR)
                let moduleFilePath = moduleFileDir.join(moduleName + ".swiftmodule")
                args += [["-Xlinker", "-add_ast_path", "-Xlinker", moduleFilePath.str]]
                if scope.evaluate(BuiltinMacros.SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS) {
                    args += [["@\(Path(moduleFilePath.appendingFileNameSuffix("-linker-args").withoutSuffix + ".resp").str)"]]
                }
            }
        }

        if scope.evaluate(BuiltinMacros.SWIFT_ADD_TOOLCHAIN_SWIFTSYNTAX_SEARCH_PATHS) {
            args += [["-L\(swiftToolSpec.hostLibraryDirectory.str)"]]
        }

        let containsSwiftSources = (producer.configuredTarget?.target as? StandardTarget)?.sourcesBuildPhase?.containsSwiftSources(producer, producer, scope, producer.filePathResolver) == true
        if scope.evaluate(BuiltinMacros.PLATFORM_REQUIRES_SWIFT_AUTOLINK_EXTRACT) && containsSwiftSources {
            let inputPath = scope.evaluate(BuiltinMacros.SWIFT_AUTOLINK_EXTRACT_OUTPUT_PATH)
            args += [["@\(inputPath.str)"]]
            inputPaths.append(inputPath)
        }

        return (args: args, inputPaths: inputPaths)
    }

    private static func objectFileDirOutput(inputPath: Path, moduleBaseNameSuffix: String, uniquingSuffix: String, objectFileDir: Path, fileExtension: String) -> Path {
        assert(inputPath.isAbsolute)
        return objectFileDir.join(inputPath.basenameWithoutSuffix + fileExtension).appendingFileNameSuffix(moduleBaseNameSuffix + uniquingSuffix)
    }

    private static func objectFileDirOutput(input: FileToBuild, moduleBaseNameSuffix: String, objectFileDir: Path, fileExtension: String) -> Path {
        return objectFileDirOutput(inputPath: input.absolutePath, moduleBaseNameSuffix: moduleBaseNameSuffix,
                                   uniquingSuffix: input.uniquingSuffix, objectFileDir: objectFileDir, fileExtension: fileExtension)
    }

    /// Generate the Swift output file map.
    private func computeOutputFileMapContents(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ compilationMode: SwiftCompilationMode, objectFileDir: Path, isUsingWholeModuleOptimization: Bool, indexObjectFileDir: Path?) async throws -> ByteString {
        // We construct the map as a property list for easy serialization to JSON.
        var mapDict = [String: SwiftOutputFileMap.Entry]()

        // Compute strings that will be used at various points when building the map.
        let moduleBaseNameSuffix = compilationMode.moduleBaseNameSuffix
        let masterSwiftBaseName = cbc.scope.evaluate(BuiltinMacros.TARGET_NAME) + moduleBaseNameSuffix + "-master"
        let emitConstSideCarValues = await supportConstSupplementaryMetadata(cbc, delegate, compilationMode: compilationMode)

        func createCommonFileEntry(input: FileToBuild) -> (objectFilePath: Path, fileMapEntry: SwiftOutputFileMap.Entry) {
            var fileMapEntry = SwiftOutputFileMap.Entry()
            // The object file.
            let objectFilePath = SwiftCompilerSpec.objectFileDirOutput(input: input, moduleBaseNameSuffix: moduleBaseNameSuffix, objectFileDir: objectFileDir, fileExtension: ".o")
            if compilationMode.compileSources {
                fileMapEntry.object = objectFilePath.str
                if let indexObjectFileDir = indexObjectFileDir {
                    let indexObjectPath = SwiftCompilerSpec.objectFileDirOutput(input: input, moduleBaseNameSuffix: moduleBaseNameSuffix, objectFileDir: indexObjectFileDir, fileExtension: ".o")
                    fileMapEntry.indexUnitOutputPath = indexObjectPath.str
                }
            }
            return (objectFilePath, fileMapEntry)
        }

           // Add entries to the map indicating where to find the files the compiler generates.
        if !isUsingWholeModuleOptimization {
            // If we're not using WMO at all, then we produce an entry in the output file map for each file.
            for input in cbc.inputs {
                var (objectFilePath, fileMapEntry) = createCommonFileEntry(input: input)

                let objectFilePrefix = objectFilePath.basenameWithoutSuffix

                // The diagnostics file.
                let diagnosticsFilePath = objectFileDir.join(objectFilePrefix + ".dia")
                fileMapEntry.diagnostics = diagnosticsFilePath.str

                if await shouldEmitMakeStyleDependencies(cbc.producer, cbc.scope, delegate: delegate) {
                    // The dependencies file, used to discover implicit dependencies.  This file will be in Makefile format.
                    let dependenciesFilePath = objectFileDir.join(objectFilePrefix + ".d")
                    fileMapEntry.dependencies = dependenciesFilePath.str
                }

                // The file used by Swift to manage intermodule dependencies.
                let swiftDependenciesFilePath = objectFileDir.join(objectFilePrefix + ".swiftdeps")
                fileMapEntry.swiftDependencies = swiftDependenciesFilePath.str

                // The Swift partial module file.
                let swiftmoduleFilePath = objectFileDir.join(objectFilePrefix + "~partial.swiftmodule")
                fileMapEntry.swiftmodule = swiftmoduleFilePath.str

                // The requested compile-time values
                if emitConstSideCarValues {
                    fileMapEntry.constValues = objectFileDir.join(objectFilePrefix + ".swiftconstvalues").str
                }

                // Finally add an entry for this file to the map.
                mapDict[input.absolutePath.str] = fileMapEntry
            }

            // Add global entries to the output file map, keyed under a pseudo-filename of "".
            do {
                var fileMapEntry = SwiftOutputFileMap.Entry()

                // The file used by Swift to manage intermodule dependencies.
                let globalSwiftDependenciesFilePath = objectFileDir.join(masterSwiftBaseName + ".swiftdeps")
                fileMapEntry.swiftDependencies = globalSwiftDependenciesFilePath.str

                // The diagnostics file.
                let diagnosticsFilePath = objectFileDir.join(masterSwiftBaseName + ".dia")
                fileMapEntry.diagnostics = diagnosticsFilePath.str

                // The diagnostics file for emit-module jobs.
                let emitModuleDiagnosticsFilePath = objectFileDir.join(masterSwiftBaseName + "-emit-module.dia")
                fileMapEntry.emitModuleDiagnostics = emitModuleDiagnosticsFilePath.str

                if await shouldEmitMakeStyleDependencies(cbc.producer, cbc.scope, delegate: delegate) {
                    // The dependency file for emit-module jobs.
                    let emitModuleDependenciesFilePath = objectFileDir.join(masterSwiftBaseName + "-emit-module.d")
                    fileMapEntry.emitModuleDependencies = emitModuleDependenciesFilePath.str
                }

                // The PCH file path for generatePCH job.
                let bridgingHeaderPCHPath = objectFileDir.join(masterSwiftBaseName + "-Bridging-header.pch")
                fileMapEntry.pch = bridgingHeaderPCHPath.str

                // Add the global entry to the map.
                mapDict[""] = fileMapEntry
            }
        }
        else {
            // If we are using WMO, then we still generate entries for each file, but several files move to the global map since the source files aren't processed individually.
            for input in cbc.inputs {
                mapDict[input.absolutePath.str] = createCommonFileEntry(input: input).fileMapEntry
            }

            // Add global entries to the output file map, keyed under a pseudo-filename of "".
            do {
                var fileMapEntry = SwiftOutputFileMap.Entry()

                // The diagnostics file.
                let diagnosticsFilePath = objectFileDir.join(masterSwiftBaseName + ".dia")
                fileMapEntry.diagnostics = diagnosticsFilePath.str

                // The diagnostics file for emit-module jobs.
                let emitModuleDiagnosticsFilePath = objectFileDir.join(masterSwiftBaseName + "-emit-module.dia")
                fileMapEntry.emitModuleDiagnostics = emitModuleDiagnosticsFilePath.str

                if await shouldEmitMakeStyleDependencies(cbc.producer, cbc.scope, delegate: delegate) {
                    // The dependency file for emit-module jobs.
                    let emitModuleDependenciesFilePath = objectFileDir.join(masterSwiftBaseName + "-emit-module.d")
                    fileMapEntry.emitModuleDependencies = emitModuleDependenciesFilePath.str


                    // The dependencies file, used to discover implicit dependencies.  This file will be in Makefile format.
                    let dependenciesFilePath = objectFileDir.join(masterSwiftBaseName + ".d")
                    fileMapEntry.dependencies = dependenciesFilePath.str
                }

                // The file used by Swift to manage intermodule dependencies.
                let swiftDependenciesFilePath = objectFileDir.join(masterSwiftBaseName + ".swiftdeps")
                fileMapEntry.swiftDependencies = swiftDependenciesFilePath.str

                // The requested compile-time values
                if emitConstSideCarValues && compilationMode.compileSources {
                    fileMapEntry.constValues = objectFileDir.join(masterSwiftBaseName + ".swiftconstvalues").str
                }

                // The PCH file path for generatePCH job.
                let bridgingHeaderPCHPath = objectFileDir.join(masterSwiftBaseName + "-Bridging-header.pch")
                fileMapEntry.pch = bridgingHeaderPCHPath.str

                // Add the global entry to the map.
                mapDict[""] = fileMapEntry
            }
        }

        // Finalize the property list object.
        let map = SwiftOutputFileMap(files: mapDict)

        // Encode the map into a JSON string and return it.
        return try ByteString(encodingAsUTF8: String(decoding: JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).encode(map), as: UTF8.self))
    }

    /// Examines the task and returns the indexing information for the source file it compiles.
    public override func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        guard let payload = task.payload as? SwiftTaskPayload else { return [] }

        if payload.driverPayload != nil {
            // With integrated driver, Swift spawns many tasks with the same inputs, only one should produce indexing information
            guard task.ruleInfo.first == "SwiftDriver Compilation Requirements" else {
                return []
            }
        }

        let filePaths: [Path]
        switch payload.indexingPayload.inputs {
        case let .filePaths(_, paths):
            filePaths = paths
        case let .range(range):
            filePaths = task.commandLine[range].map { Path($0.asByteString) }
        }

        // FIXME: We're sending an identical indexingInfo for each file, but we'll fix that when we can send a serialized strong type and either change the API to ([Path], Info) or (Path, Ref<Info>).
        return filePaths.compactMap { inputPath in
            let inputReplacementPath = payload.indexingPayload.inputReplacements[inputPath] ?? inputPath
            guard input.requestedSourceFiles.contains(inputReplacementPath) else { return nil }
            // FIXME: <rdar://problem/41060621> Getting the right uniquingSuffix requires having a FileToBuild, which we don't have here.  I'm not sure whether ExecutableTask has enough information to be able to get the correct path to the output file when there are multiple input files with the same base name.
            let outputFile = SwiftCompilerSpec.objectFileDirOutput(inputPath: inputPath, moduleBaseNameSuffix: "", uniquingSuffix: "",
                                                                   objectFileDir: payload.indexingPayload.objectFileDir, fileExtension: ".o")
            let indexingInfo: any SourceFileIndexingInfo
            if input.outputPathOnly {
                indexingInfo = OutputPathIndexingInfo(outputFile: outputFile)
            } else {
                indexingInfo = SwiftSourceFileIndexingInfo(task: task, payload: payload.indexingPayload, outputFile: outputFile, enableIndexBuildArena: input.enableIndexBuildArena, integratedDriver: payload.driverPayload != nil)
            }
            return .init(path: inputReplacementPath, indexingInfo: indexingInfo)
        }
    }

    static func previewThunkPathWithoutSuffix(sourceFile: Path, thunkVariantSuffix: String, objectFileDir: Path) -> Path {
        return Path(SwiftCompilerSpec.objectFileDirOutput(inputPath: sourceFile, moduleBaseNameSuffix: "", uniquingSuffix: ".\(thunkVariantSuffix).preview-thunk", objectFileDir: objectFileDir, fileExtension: ".o").withoutSuffix)
    }

    public override func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] {
        guard let payload = task.payload as? SwiftTaskPayload else { return [] }
        guard let previewPayload = payload.previewPayload else { return [] }

        var commandLine = [String](task.commandLineAsStrings)

        if input == .targetDependencyInfo {
            let inputs = task.inputPaths.filter({ $0.fileSuffix == ".swift" })
            let outputs = task.outputPaths.filter({ $0.fileSuffix == ".o" })
            guard inputs.count == outputs.count else { return [] }
            return zip(inputs, outputs).map { input, output in
                TaskGeneratePreviewInfoOutput(
                    architecture: previewPayload.architecture,
                    buildVariant: previewPayload.buildVariant,
                    commandLine: commandLine,
                    workingDirectory: task.workingDirectory,
                    input: input,
                    output: output,
                    type: .Swift
                )
            }
        }

        guard case .thunkInfo(let sourceFile, let thunkVariantSuffix) = input else { return [] }

        if payload.driverPayload != nil {
            // With integrated driver, multiple tasks get created, but preview info exists only once
            guard task.ruleInfo.first == "SwiftDriver Compilation Requirements" else { return [] }

            // Drop the prefix that gets added for invoking the integrated driver task action
            commandLine = Array(commandLine.drop(while: { $0 != "--" }))
            commandLine.remove(at: 0)
        }

        let basePath = SwiftCompilerSpec.previewThunkPathWithoutSuffix(sourceFile: sourceFile, thunkVariantSuffix: thunkVariantSuffix, objectFileDir: previewPayload.objectFileDir)

        let inputPath = Path(basePath.str + ".swift")
        let outputPath = Path(basePath.str + ".o")

        // Remove all file lists
        let originalInputs: [Path]
        switch payload.indexingPayload.inputs {
        case let .filePaths(responseFilePath, paths):
            originalInputs = paths
            if let indexOfFileList = commandLine.firstIndex(of: "@" + responseFilePath.str) {
                commandLine.remove(at: indexOfFileList)
            }
        case let .range(range):
            originalInputs = Array(commandLine[range].map(Path.init))
            commandLine.removeSubrange(range)
        }

        // Args without parameters
        for arg in [
            // Should strip this because it saves some work and avoids writing a useless incremental build record
            "-incremental",

            // Stripped because we want to end up in single file mode
            "-enable-batch-mode",
            "-disable-batch-mode",

            // Should be stripped in case the user enabled it in their config
            "-whole-module-optimization",

            // Avoids emitting the `.d`` file
            "-emit-dependencies",

            // Avoids overwriting localized strings for the transformed source file.
            "-emit-localized-strings",

            // Previews doesn't need a `.swiftmodule` for the thunk
            "-emit-module",

            // Preview thunks does not need this
            "-emit-objc-header",

            // Previews only work on unoptimized build products.
            "-O",
            "-Osize",

            // Previews does not use compiler output
            "-parseable-output",
            "-use-frontend-parseable-output",

            // Writes more intermediates that Previews does not need
            "-emit-const-values",
            "-save-temps",
        ] {
            while let index = commandLine.firstIndex(of: arg) {
                commandLine.remove(at: index)
            }
        }
        if payload.previewStyle == .dynamicReplacement {
            for arg in [
                // Debug symbols aren't needed in dynamic replacement preview info.
                "-g",

                // We add back `-Onone` below in dynamic replacement.
                "-Onone",

                // Dynamic replacement thunks don't need this.
                "-import-underlying-module",

                // This property was always stripped in dynamic replacement.
                "-explicit-module-build",

                // Strip until builder SDKs include a swift-driver with this flag. Do not remove without also removing -clang-build-session-file.
                "-validate-clang-modules-once"
            ] {
                while let index = commandLine.firstIndex(of: arg) {
                    commandLine.remove(at: index)
                }
            }
        }

        // Args without parameters (-Xfrontend-prefixed, e.g. -Xfrontend arg)
        func removeWithPrefix(_ arg: String) {
            let argPrefix = "-Xfrontend"
            while let index = commandLine.firstIndex(of: arg) {
                guard index > 0, commandLine[index - 1] == argPrefix else { break }
                commandLine.removeSubrange(index - 1 ... index)
            }
        }

        if payload.previewStyle == .dynamicReplacement {
            // Only strip these in dynamic replacement. These affect the object files and we
            // want XOJIT mode to invoke builds as close as possible to the original.
            for arg in [
                // All of these args are stripped out for thunks in dynamic replacement mode.
                "-enable-implicit-dynamic",
                "-enable-dynamic-replacement-chaining",
                "-enable-private-imports",
                "-disable-previous-implementation-calls-in-dynamic-replacements"
            ] {
                removeWithPrefix(arg)
            }
        }

        // Args with a parameter
        func removeWithParameter(_ arg: String) {
            while let index = commandLine.firstIndex(of: arg) {
                guard index + 1 < commandLine.count else { break }
                commandLine.removeSubrange(index ... index + 1)
            }
        }
        for arg in [
            // Stripped because they emit sidecar data that Previews does not need.
            "-output-file-map",
            "-index-store-path",
            "-emit-module-path",
            "-emit-objc-header-path",
            "-emit-module-interface-path",
            "-emit-private-module-interface-path",
            "-emit-package-module-interface-path",
            "-emit-localized-strings-path",
            "-pch-output-dir",
        ] {
            removeWithParameter(arg)
        }

        // We need to ignore precompiled headers due to:
        // rdar://126212044 ([JIT] iOS test Failures: Thunk build failure, unable to read PCH file)
        removeWithPrefix("-cache-compile-job")
        commandLine.append("-disable-bridging-pch")

        if payload.previewStyle == .dynamicReplacement {
            for (arg, newValue) in [
                // Previews needs a path to _a_ module cache so it has a place to store built modules.
                ("-module-cache-path", previewPayload.moduleCacheDir.str)
            ] {
                removeWithParameter(arg)
                if !newValue.isEmpty {
                    commandLine += [arg, newValue]
                }
            }

            for arg in [
                // We want the objc header in XOJIT mode so ignore in dynamic replacement mode
                "-import-objc-header",

                // Old setting only stripped in dynamic replacement mode for backward compatibility
                "-clang-build-session-file",
            ] {
                removeWithParameter(arg)
            }
        }

        // Args with a parameter (-Xfrontend-prefixed, e.g. -Xfrontend arg)
        func removeWithPrefixAndParameter(_ arg: String) {
            let argPrefix = "-Xfrontend"
            while let index = commandLine.firstIndex(of: arg) {
                guard index > 0, commandLine[index - 1] == argPrefix else { break }
                commandLine.removeSubrange(index - 1 ... index + 2)
            }
        }
        for arg in [
            // Stripped because they emit sidecar data that Previews does not need.
            "-const-gather-protocols-file",
        ] {
            removeWithPrefixAndParameter(arg)
        }

        let selectedInputPath: Path
        if payload.previewStyle == .xojit {
            // Also pass the auxiliary Swift files.
            commandLine.append(contentsOf: originalInputs.map(\.str))
            selectedInputPath = sourceFile

            if let driverPayload = payload.driverPayload {
                do {
                    // Inject the thunk source into the output file map
                    let map = SwiftOutputFileMap(files: [sourceFile.str: .init(object: outputPath.str)])
                    let newOutputFileMap = driverPayload.tempDirPath.join(UUID().uuidString)
                    try fs.createDirectory(newOutputFileMap.dirname, recursive: true)
                    try fs.write(newOutputFileMap, contents: ByteString(JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).encode(map)))
                    commandLine.append(contentsOf: ["-output-file-map", newOutputFileMap.str])

                    // rdar://127735418 ([JIT] Emit a vfsoverlay for JIT preview thunk compiler arguments so clients can specify the original file path when substituting contents)
                    let vfs = VFS()
                    vfs.addMapping(sourceFile, externalContents: inputPath)
                    let newVFSOverlayPath = driverPayload.tempDirPath.join("vfsoverlay-\(inputPath.basename).json")
                    try fs.createDirectory(newOutputFileMap.dirname, recursive: true)
                    let overlay = try vfs.toVFSOverlay().propertyListItem.asJSONFragment().asString
                    try fs.write(newVFSOverlayPath, contents: ByteString(encodingAsUTF8: overlay))

                    commandLine.append(contentsOf: ["-vfsoverlay", newVFSOverlayPath.str])
                } catch {
                    return []
                }
            }
        }
        else {
            selectedInputPath = inputPath
            commandLine.append(contentsOf: [inputPath.str])
        }

        if payload.previewStyle == .dynamicReplacement {
            commandLine.append(contentsOf: ["-o", outputPath.str])

            removeWithParameter("-module-name")
            commandLine.append(contentsOf: [
                "-module-name",
                "\(payload.moduleName)_PreviewReplacement_\(sourceFile.basenameWithoutSuffix)_\(thunkVariantSuffix)".mangledToC99ExtendedIdentifier(),
            ])
            commandLine.append("-parse-as-library")

            // Faster thunk builds
            commandLine.append("-Onone")

            // Faster thunk builds
            commandLine.append(contentsOf: [
                "-Xfrontend",
                "-disable-modules-validate-system-headers",
                ])
        }

        // For XOJIT previews, we want the frontend (`swift-frontend`) invocation rather than the driver (`swiftc`) invocation, so ask libSwiftDriver for it and replace the command line with the result for propagation back to the request.
        if let driverPayload = payload.driverPayload, payload.previewStyle == .xojit {
            final class Delegate: DiagnosticProducingDelegate {
                let engine = DiagnosticsEngine()
                let diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine>
                init() {
                    diagnosticsEngine = .init(engine)
                }
            }
            let outputDelegate = Delegate()
            if let newCommandLine = LibSwiftDriver.frontendCommandLine(
                outputDelegate: outputDelegate,
                compilerLocation: driverPayload.compilerLocation,
                inputPath: selectedInputPath,
                workingDirectory: task.workingDirectory,
                tempDirPath: driverPayload.tempDirPath,
                explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                commandLine: commandLine,
                environment: task.environment.bindingsDictionary,
                eagerCompilationEnabled: driverPayload.eagerCompilationEnabled,
                casOptions: driverPayload.casOptions
            ) {
                commandLine = newCommandLine
            } else {
                commandLine = []
            }

            // The driver may have emitted an error even if it returned us a command line. In this case, don't return the command line since it likely won't work.
            if commandLine.isEmpty || outputDelegate.engine.hasErrors {
                #if canImport(os)
                for diagnostic in outputDelegate.engine.diagnostics.filter({ $0.behavior == .error }) {
                    OSLog.log("Swift driver preview info error: \(diagnostic.data.description)")
                }
                #endif
                return []
            }
        }

        let output = TaskGeneratePreviewInfoOutput(
            architecture: previewPayload.architecture,
            buildVariant: previewPayload.buildVariant,
            commandLine: commandLine,
            workingDirectory: task.workingDirectory,
            input: inputPath,
            output: outputPath,
            type: .Swift
        )

        return [output]
    }

    public override func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
        guard let payload = task.payload as? SwiftTaskPayload else { return [] }
        guard let localizationPayload = payload.localizationPayload else { return [] }

        // Do not gate to "SwiftDriver Compilation Requirements" task here because we are checking output paths and whether the stringsdata are included in the Compilation Requirements output paths depends on if Eager Compilation is enabled.
        // It's fine to generate localization info for every task, because deduping will occur downstream anyway.

        let stringsdataPaths = task.outputPaths.filter { $0.fileExtension == "stringsdata" }
        guard !stringsdataPaths.isEmpty else {
            return []
        }

        return [TaskGenerateLocalizationInfoOutput(producedStringsdataPaths: [
            LocalizationBuildPortion(effectivePlatformName: localizationPayload.effectivePlatformName, variant: localizationPayload.buildVariant, architecture: localizationPayload.architecture): stringsdataPaths
        ])]
    }

    /// Define the custom output parser.
    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        switch task.ruleInfo.first {
        case "CompileSwiftSources",
             "GenerateSwiftModule":
                return SwiftCommandOutputParser.self
        default:
                return nil
        }
    }

    public override var payloadType: (any TaskPayload.Type)? { return SwiftTaskPayload.self }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await (self as (any SwiftDiscoveredCommandLineToolSpecInfo)).discoveredCommandLineToolSpecInfo(producer, scope, delegate)
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

extension SwiftCompilerSpec {
    static public func computeRuleInfoAndSignatureForPerFileVirtualBatchSubtask(variant: String, arch: String, path: Path) -> ([String], ByteString) {
        let ruleInfo = ["SwiftCompile", variant, arch, path.str.quotedDescription]
        let signature: ByteString = {
            let md5 = InsecureHashContext()
            md5.add(string: ruleInfo.joined(separator: " "))
            return md5.signature
        }()
        return (ruleInfo, signature)
    }
}

/// Consults the global cache of discovered info for the Swift compiler at `toolPath` and returns it, creating it if necessary.
///
/// This is global and public because it is used by `SWBTaskExecution` and `CoreBasedTests`, which is the basis of many of our tests (so caching this info across tests is desirable), and which is used in some performance tests.  If we discover that the info for a compiler at a given path can change during an instance of Swift Build (e.g., if a downloadable toolchain can replace an existing compiler) then this may need to be revisited.
public func discoveredSwiftCompilerInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, at toolPath: Path, blocklistsPathOverride: Path?) async throws -> DiscoveredSwiftCompilerToolSpecInfo {
    try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, [toolPath.str, "--version"], { executionResult in
        let outputString = String(decoding: executionResult.stdout, as: UTF8.self)

        // Values we will parse.  If we end up not parsing any values, then we return an empty info struct.
        var swiftVersion: Version? = nil
        var swiftlangVersion: Version? = nil
        var clangVersion: Version? = nil
        var swiftABIVersion: String? = nil

        // Note that Swift toolchains downloaded from swift.org have a swiftc with a different version format than those built by Apple; the 'releaseVersionRegex' reflects that format.  c.f. <rdar://problem/34956869>
        let versionRegex = #/Apple Swift version (?<swiftVersion>[\d.]+) \(swiftlang-(?<swiftlangVersion>[\d.]+) clang-(?<clangVersion>[\d.]+)\)/#
        let releaseVersionRegex = #/(?:Apple )?Swift version (?<swiftVersion>[\d.]+) \(swift-(?<swiftlangVersion>[\d.]+)-RELEASE\)/#
        let developmentVersionRegex = #/Swift version (?<swiftVersion>[\d.]+)-dev \(LLVM (?:\b[0-9a-f]+), Swift (?:\b[0-9a-f]+)\)/#
        let abiVersionRegex = #/ABI version: (?<abiVersion>[\d.]+)/#

        // Iterate over each line and add any discovered info to the info object.
        for line in outputString.components(separatedBy: "\n") {
            if swiftlangVersion == nil {
                if let groups = try versionRegex.firstMatch(in: line) {
                    swiftVersion = try? Version(String(groups.output.swiftVersion))
                    swiftlangVersion = try? Version(String(groups.output.swiftlangVersion))
                    clangVersion = try? Version(String(groups.output.clangVersion))
                }
                else if let groups = try releaseVersionRegex.firstMatch(in: line) {
                    swiftVersion = try? Version(String(groups.output.swiftVersion))
                    swiftlangVersion = try? Version(String(groups.output.swiftlangVersion))
                    // This form has no clang version.
                } else if let groups = try developmentVersionRegex.firstMatch(in: line) {
                    swiftVersion = try? Version(String(groups.output.swiftVersion))
                    guard let swiftVersion else {
                        throw StubError.error("Could not parse Swift version from: \(outputString)")
                    }
                    clangVersion = try? Version(swiftVersion.description + ".999.999")
                    swiftlangVersion = try? Version(swiftVersion.description + ".999.999")
                }
            }
            if swiftABIVersion == nil {
                if let groups = try abiVersionRegex.firstMatch(in: line) {
                    swiftABIVersion = groups.output.abiVersion.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        guard let swiftVersion, let swiftlangVersion else {
            throw StubError.error("Could not parse Swift versions from: \(outputString)")
        }

        func getFeatures(at toolPath: Path) -> ToolFeatures<DiscoveredSwiftCompilerToolSpecInfo.FeatureFlag> {
            let featuresPath = toolPath.dirname.dirname.join("share").join("swift").join("features.json")
            do {
                let features: ToolFeatures<DiscoveredSwiftCompilerToolSpecInfo.FeatureFlag> = try .init(path: featuresPath, fs: localFS)
                if features.has(.experimentalAllowModuleWithCompilerErrors) {
                    // FIXME: Need to add this flag into Swift's features.json
                    return .init(features.flags.union([.vfsDirectoryRemap]))
                }
                return features
            } catch {
                // FIXME: Consider about reporting this as error, lest users silently get surprising behavior if we fail to read the features file for any reason.
                return ToolFeatures.none
            }
        }

        let blocklistPaths = CompilerSpec.findToolchainBlocklists(producer, directoryOverride: blocklistsPathOverride)

        func getBlocklist<T: Codable>(type: T.Type, toolchainFilename: String, delegate: any TargetDiagnosticProducingDelegate) -> T? {
            return CompilerSpec.getBlocklist(
                type: type,
                toolchainFilename: toolchainFilename,
                blocklistPaths: blocklistPaths,
                fs: localFS,
                delegate: delegate
            )
        }

        var blocklists = SwiftBlocklists()
        blocklists.explicitModules = getBlocklist(type: SwiftBlocklists.ExplicitModulesInfo.self, toolchainFilename: "swift-explicit-modules.json", delegate: delegate)
        blocklists.installAPILazyTypecheck = getBlocklist(type: SwiftBlocklists.InstallAPILazyTypecheckInfo.self, toolchainFilename: "swift-lazy-installapi.json", delegate: delegate)
        blocklists.caching = getBlocklist(type: SwiftBlocklists.CachingBlockList.self, toolchainFilename: "swift-caching.json", delegate: delegate)
        blocklists.languageFeatureEnablement = getBlocklist(type: SwiftBlocklists.LanguageFeatureEnablementInfo.self, toolchainFilename: "swift-language-feature-enablement.json", delegate: delegate)
        return DiscoveredSwiftCompilerToolSpecInfo(toolPath: toolPath, swiftVersion: swiftVersion, swiftlangVersion: swiftlangVersion, swiftABIVersion: swiftABIVersion, clangVersion: clangVersion, blocklists: blocklists, toolFeatures: getFeatures(at: toolPath))
    })
}

extension SwiftCompilerSpec: GCCCompatibleCompilerCommandLineBuilder {
    package func searchPathArguments(_ entry: SearchPathEntry, _ scope: MacroEvaluationScope) -> [String]
    {
        var args = [String]()
        switch entry
        {
        case .userHeaderSearchPath(let path):
            args.append(contentsOf: ["-iquote", path.str])

        case .headerSearchPath(let path, let separateArgs):
            args.append(contentsOf: separateArgs ? ["-I", path.str] : ["-I" + path.str])

        case .systemHeaderSearchPath(let path):
            args.append(contentsOf: ["-isystem", path.str])

        case .headerSearchPathSplitter:
            args.append(contentsOf: ["-I-"])              // <rdar://problem/24312805> states that clang has never supported this option.

        case .frameworkSearchPath(let path, let separateArgs):
            args.append(contentsOf: separateArgs ? ["-F", path.str] : ["-F" + path.str])

        case .systemFrameworkSearchPath(let path):
            // FIXME: <rdar://problem/30939744> Swift: Utilize '-Fsystem' flag for system framework search paths
            // We need to use -Fsystem for the public iOSSupport directories (Frameworks, SubFrameworks), so we special-case doing so.  c.f. <rdar://problem/50117414>  We *don't* pass -Fsystem to the equivalent PrivateFrameworks directory, for reasons described in <rdar://problem/50309541>.
            if path.ends(with: "System/iOSSupport/System/Library/Frameworks") || path.ends(with: "System/iOSSupport/System/Library/SubFrameworks") || scope.evaluate(BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS_USE_FSYSTEM) {
                args.append(contentsOf: ["-Fsystem", path.str])
            }
            else {
                args.append(contentsOf: ["-F", path.str])
            }

        case .literalArguments(let literalArgs):
            args.append(contentsOf: literalArgs)
        }
        return args
    }
}

public extension BuildPhaseWithBuildFiles {
    /// Checks if the build phase contains files of a given type.
    ///
    /// - Parameters:
    ///   - type: The file type to look for in the build phase build files.
    ///   - referenceLookupContext: The context used to look up references in.
    ///   - specLookupContext: The context used to look up specifications and file types.
    ///   - scope: The scope in which to lookup platform filters and patterns for excluding or including source files.
    ///   - predicate: An additional predicate to filter the file references.
    /// - Returns: If the build phase contains any files of the given type that are not filtered out via the platform filter, exclude patterns, or predicate.
    func containsFiles(
        ofType type: FileTypeSpec,
        _ referenceLookupContext: any ReferenceLookupContext,
        _ specLookupContext: any SpecLookupContext,
        _ scope: MacroEvaluationScope,
        _ filePathResolver: FilePathResolver,
        _ predicate: (FileReference) -> Bool = { _ in true }
    ) -> Bool {
        struct FilteringContext: BuildFileFilteringContext {
            let excludedSourceFileNames: [String]
            let includedSourceFileNames: [String]
            let currentPlatformFilter: PlatformFilter?
        }
        let filteringContext = FilteringContext(
            excludedSourceFileNames: scope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES),
            includedSourceFileNames: scope.evaluate(BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES),
            currentPlatformFilter: PlatformFilter(scope)
        )

        return buildFiles.contains { buildFile -> Bool in
            // We only need to consider file references.
            guard case let .reference(guid) = buildFile.buildableItem,
                  let reference = referenceLookupContext.lookupReference(for: guid),
                  let fileRef = reference as? FileReference else { return false }

            let path = filePathResolver.resolveAbsolutePath(fileRef)
            guard !filteringContext.isExcluded(path, filters: buildFile.platformFilters) else { return false }

            // FIXME: We should bind file type identifiers at project load time, and reject unknown ones.
            guard specLookupContext.lookupFileType(identifier: fileRef.fileTypeIdentifier)?.conformsTo(type) == true else {
                return false
            }

            return predicate(fileRef)
        }
    }

    /// Checks if the build phase contains any Swift source files.
    ///
    /// - Note:This filters the build files by both platform filter and excluded source file names.
    ///
    /// - Parameters:
    ///   - type: The file type to look for in the build phase build files.
    ///   - referenceLookupContext: The context used to look up references in.
    ///   - specLookupContext: The context used to look up specifications and file types.
    ///   - scope: The scope in which to lookup platform filters and patterns for excluding or including source files.
    /// - Returns: If the build phase contains any Swift source files that are not filtered out via the platform filter or excluded source file name patterns.
    func containsSwiftSources(_ referenceLookupContext: any ReferenceLookupContext, _ specLookupContext: any SpecLookupContext, _ scope: MacroEvaluationScope, _ filePathResolver: FilePathResolver) -> Bool {
        guard let swiftFileType = specLookupContext.lookupFileType(identifier: "sourcecode.swift") else { return false }
        return containsFiles(ofType: swiftFileType, referenceLookupContext, specLookupContext, scope, filePathResolver)
    }
}

struct SwiftOutputFileMap: Codable {
    struct Entry: Codable {
        var object: String?
        var indexUnitOutputPath: String?
        var remap: String?
        var diagnostics: String?
        var emitModuleDiagnostics: String?
        var dependencies: String?
        var emitModuleDependencies: String?
        var swiftDependencies: String?
        var swiftmodule: String?
        var constValues: String?
        var pch: String?

        enum CodingKeys: String, CodingKey {
            case object
            case indexUnitOutputPath = "index-unit-output-path"
            case remap
            case diagnostics
            case emitModuleDiagnostics = "emit-module-diagnostics"
            case dependencies
            case emitModuleDependencies = "emit-module-dependencies"
            case swiftDependencies = "swift-dependencies"
            case swiftmodule
            case constValues = "const-values"
            case pch
        }
    }

    var files: [String: Entry]

    init(files: [String: Entry]) {
        self.files = files
    }

    init(from decoder: any Decoder) throws {
        try self.files = .init(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try files.encode(to: encoder)
    }
}

protocol SwiftDiscoveredCommandLineToolSpecInfo {
    func resolveExecutablePath(_ producer: any CommandProducer, _ path: Path) -> Path

    func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async throws -> DiscoveredSwiftCompilerToolSpecInfo
}

extension SwiftDiscoveredCommandLineToolSpecInfo {
    func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async throws -> DiscoveredSwiftCompilerToolSpecInfo {
        let compilerFileName = producer.hostOperatingSystem.imageFormat.executableName(basename: "swiftc")

        // Get the path to the compiler.
        let path = scope.evaluate(BuiltinMacros.SWIFT_TOOLS_DIR).nilIfEmpty.map(Path.init)?.join(compilerFileName)
            ?? scope.evaluate(BuiltinMacros.SWIFT_EXEC).nilIfEmpty.map({ $0.isAbsolute
                ? $0
                : Path(producer.hostOperatingSystem.imageFormat.executableName(basename: $0.str)) })
            ?? Path(compilerFileName)
        let userSpecifiedBlocklists = scope.evaluate(BuiltinMacros.BLOCKLISTS_PATH).nilIfEmpty.map { Path($0) }
        let toolPath = self.resolveExecutablePath(producer, path)

        // Get the info from the global cache.
        return try await discoveredSwiftCompilerInfo(producer, delegate, at: toolPath, blocklistsPathOverride: userSpecifiedBlocklists)
    }
}
