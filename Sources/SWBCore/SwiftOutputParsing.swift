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

import SWBMacro
public import SWBUtil
import Foundation

public final class SwiftCompilerOutputParser: TaskOutputParser {
    public let workspaceContext: WorkspaceContext
    public let buildRequestContext: BuildRequestContext
    public let delegate: any TaskOutputParserDelegate
    private let task: any ExecutableTask

    public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
        self.task = task
    }

    public func write(bytes: SWBUtil.ByteString) {
        delegate.emitOutput(bytes)
    }

    public func close(result: TaskResult?) {
        for entry in task.type.serializedDiagnosticsInfo(task, workspaceContext.fs) {
            if let sourceFilePath = entry.sourceFilePath {
                // FIXME: find a better way to get at these
                let variant = task.ruleInfo[1]
                let arch = task.ruleInfo[2]
                let (ruleInfo, signature) = SwiftCompilerSpec.computeRuleInfoAndSignatureForPerFileVirtualBatchSubtask(variant: variant, arch: arch, path: sourceFilePath)
                let subtaskDelegate = delegate.startSubtask(
                    buildOperationIdentifier: self.delegate.buildOperationIdentifier,
                    taskName: "Swift Compiler",
                    signature: signature,
                    ruleInfo: ruleInfo.joined(separator: " "),
                    executionDescription: "Compile \(sourceFilePath.basename)",
                    commandLine: ["builtin-SwiftPerFileCompile", ByteString(encodingAsUTF8: sourceFilePath.basename)],
                    additionalOutput: [],
                    interestingPath: sourceFilePath,
                    workingDirectory: task.workingDirectory,
                    serializedDiagnosticsPaths: [entry.serializedDiagnosticsPath]
                )
                let diagnostics = subtaskDelegate.processSerializedDiagnostics(at: entry.serializedDiagnosticsPath, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext)
                let exitStatus: Processes.ExitStatus
                switch result {
                case .exit(let status, _)?:
                    switch status {
                    case .exit(let exitCode):
                        if exitCode == 0 {
                            // The batch compile succeeded, mark the individual files as succeeded.
                            exitStatus = status
                        } else {
                            // The batch compile failed. Mark files which reported errors as failed, and files which did not as cancelled.
                            if diagnostics.contains(where: { $0.behavior == .error }) {
                                exitStatus = status
                            } else {
                                exitStatus = .buildSystemCanceledTask
                            }
                        }
                    case .uncaughtSignal(_):
                        // If the batch compile failed due to a signal, there is likely not enough information to attribute the failure
                        // to a particular file.
                        exitStatus = status
                    }
                case .failedSetup?:
                    exitStatus = .buildSystemCanceledTask
                case .skipped?:
                    exitStatus = .exit(0)
                case nil:
                    exitStatus = .buildSystemCanceledTask
                }
                subtaskDelegate.taskCompleted(exitStatus: exitStatus)
                subtaskDelegate.close()
            } else {
                delegate.processSerializedDiagnostics(at: entry.serializedDiagnosticsPath, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext)
            }
        }
        delegate.close()
    }
}


// MARK: - Legacy Swift output parsing

/// A parser for Swift's parseable output. This implementation remains as a fallback when the integrated Swift driver is disabled.
///
/// See: https://github.com/apple/swift/blob/main/docs/DriverParseableOutput.rst
public final class LegacySwiftCommandOutputParser: TaskOutputParser {
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
                    return try fs.exists(path) && fs.getFileInfo(path).size > 0
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
