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

public import struct Foundation.Date

public import SWBUtil
public import SWBCore
import SWBCAS
public import SWBMacro
package import typealias SWBLLBuild.llbuild_pid_t
package import protocol SWBLLBuild.ProcessDelegate

public import struct SWBProtocol.BuildOperationMetrics

// Vend CommandExtendedResult as our own type to prevent higher level clients
// from requiring LLBuild
@_exported public import struct SWBLLBuild.CommandExtendedResult

/// A task is a concrete unit of work which can be run.
package final class Task: ExecutableTask, Serializable, Encodable {
    /// The type description of the task.
    package let type: any TaskTypeDescription

    /// Information emitted by the execution of this task, which will allow additional dependency information be discovered.
    package let dependencyData: DependencyDataStyle?

    package let payload: (any TaskPayload)?

    /// The target this task is running on behalf of, if any.
    package let forTarget: ConfiguredTarget?

    package enum Storage {
        package struct InternedStorage {
            var byteStringArena: FrozenByteStringArena
            var stringArena: FrozenStringArena

            struct Handles {
                var ruleInfo: [StringArena.Handle]
                enum InternedCommandLineArgument {
                    case literal(ByteStringArena.Handle)
                    case path(StringArena.Handle)
                    case parentPath(StringArena.Handle)
                }
                var commandLine: [InternedCommandLineArgument]
                var additionalSignatureData: StringArena.Handle
                var inputPathStrings: [StringArena.Handle]
                var outputPathStrings: [StringArena.Handle]
                var environmentBindings: [(StringArena.Handle, StringArena.Handle)]
            }

            var handles: Handles
        }

        package struct DirectStorage {
            var ruleInfo: [String]
            var commandLine: [CommandLineArgument]
            var additionalSignatureData: String
            var inputPaths: [Path]
            var outputPaths: [Path]
            var environmentBindings: [(String, String)]
        }

        case direct(DirectStorage)
        case interned(InternedStorage)
    }

    private let storage: Storage

    /// The rule info description.
    package var ruleInfo: [String] {
        switch storage {
        case .direct(let directStorage):
            return directStorage.ruleInfo
        case .interned(let internedStorage):
            return internedStorage.handles.ruleInfo.map { internedStorage.stringArena.lookup(handle: $0) }
        }
    }

    /// The command line of the task, starting with the executable to run in the subprocess.
    package var commandLine: [CommandLineArgument] {
        switch storage {
        case .direct(let directStorage):
            return directStorage.commandLine
        case .interned(let internedStorage):
            return internedStorage.handles.commandLine.map {
                switch $0 {
                case .literal(let handle):
                    return .literal(internedStorage.byteStringArena.lookup(handle: handle))
                case .path(let handle):
                    return .path(Path(internedStorage.stringArena.lookup(handle: handle)))
                case .parentPath(let handle):
                    return .parentPath(Path(internedStorage.stringArena.lookup(handle: handle)))
                }
            }
        }
    }

    /// Additional arbitrary data used to contribute to the task's change-tracking signature.
    package var additionalSignatureData: String {
        switch storage {
        case .direct(let directStorage):
            return directStorage.additionalSignatureData
        case .interned(let internedStorage):
            return internedStorage.stringArena.lookup(handle: internedStorage.handles.additionalSignatureData)
        }
    }

    /// List of target dependencies related to this task. This is used by target gate tasks.
    package let targetDependencies: [ResolvedTargetDependency]

    /// Additional output that should be displayed for the task. Each element will be emitted on a separate line.
    package let additionalOutput: [String]

    /// The environment variables to pass to the task.
    package var environment: EnvironmentBindings {
        switch storage {
        case .direct(let directStorage):
            return EnvironmentBindings(directStorage.environmentBindings)
        case .interned(let internedStorage):
            return EnvironmentBindings(internedStorage.handles.environmentBindings.map {
                (internedStorage.stringArena.lookup(handle: $0), internedStorage.stringArena.lookup(handle: $1))
            })
        }
    }

    /// The directory in which the task should run.
    package let workingDirectory: Path

    /// The display description of a single invocation of the task.  If none, the task isn’t shown in the log that’s shown for the build.
    package let execDescription: String?

    /// The task action for the task, if any.
    package let action: TaskAction?

    package var inputPaths: [Path] {
        switch storage {
        case .direct(let storage):
            return storage.inputPaths
        case .interned(let storage):
            return storage.handles.inputPathStrings.map { Path(storage.stringArena.lookup(handle: $0)) }
        }
    }

    package var outputPaths: [Path] {
        switch storage {
        case .direct(let storage):
            return storage.outputPaths
        case .interned(let storage):
            return storage.handles.outputPathStrings.map { Path(storage.stringArena.lookup(handle: $0)) }
        }
    }

    package let priority: TaskPriority

    package let executionInputs: [ExecutionNode]?

    /// Whether the task should show its environment in logs.
    package let showEnvironment: Bool

    /// Do we need to run this task before the indexer can parse sources?
    package let preparesForIndexing: Bool

    /// Whether the llbuild control file descriptor is disabled for this task
    package let llbuildControlDisabled: Bool

    /// Whether or not this is a gate task.
    package let isGate: Bool

    /// Whether or not this task should show up in the build log.
    package let showInLog: Bool

    /// Whether or not the command line of this task should show up in the build log.
    package let showCommandLineInLog: Bool

    package let isDynamic: Bool

    // Whether or not this task should always execute.
    package let alwaysExecuteTask: Bool

    private enum CodingKeys: CodingKey {
        case dependencyData
        case forTarget
        case targetDependencies
        case additionalOutput
        case workingDirectory
        case showEnvironment
        case execDescription
        case preparesForIndexing
        case executionInputs
        case isGate
        case showInLog
        case showCommandLineInLog
        case priority
        case isDynamic
    }

    /// Construct a new task from a task builder.
    ///
    /// NOTE: This initializer does not mutate the builder, but we take it as inout nevertheless to avoid unnecessary copying.
    package convenience init(_ builder: inout PlannedTaskBuilder) {
        func paths(nodes: [any PlannedNode]) -> [Path] {
            return nodes.compactMap {
                switch $0 {
                case is PlannedPathNode:
                    return $0.path.withoutTrailingSlash()
                case is PlannedDirectoryTreeNode:
                    return Path($0.path.withoutTrailingSlash().str + "/")
                default:
                    return nil
                }
            }
        }
        self.init(
            type: builder.type,
            dependencyData: builder.dependencyData,
            payload: builder.payload,
            forTarget: builder.forTarget,
            additionalSignatureData: builder.additionalSignatureData,
            ruleInfo: builder.ruleInfo,
            commandLine: builder.commandLine,
            additionalOutput: builder.additionalOutput,
            environment: builder.environment,
            workingDirectory: builder.workingDirectory,
            showEnvironment: builder.showEnvironment,
            execDescription: builder.execDescription,
            // FIXME: This cast is unfortunate.
            action: builder.action.map{ $0 as! TaskAction },
            preparesForIndexing: builder.preparesForIndexing,
            llbuildControlDisabled: builder.llbuildControlDisabled,
            targetDependencies: builder.targetDependencies,
            isGate: builder.isGate,
            inputPaths: paths(nodes: builder.inputs),
            outputPaths: paths(nodes: builder.outputs),
            executionInputs: builder.usesExecutionInputs ? builder.inputs.map { ExecutionNode(identifier: $0.identifier) } : nil,
            showInLog: builder.showInLog,
            showCommandLineInLog: builder.showCommandLineInLog,
            priority: builder.priority,
            isDynamic: false,
            alwaysExecuteTask: builder.alwaysExecuteTask
        )
    }

    package init(type: any TaskTypeDescription, dependencyData: DependencyDataStyle? = nil, payload: (any TaskPayload)? = nil, forTarget: ConfiguredTarget? = nil, additionalSignatureData: String = "", ruleInfo: [String], commandLine: [CommandLineArgument], additionalOutput: [String] = [], environment: EnvironmentBindings = EnvironmentBindings(), workingDirectory: Path, showEnvironment: Bool = false, execDescription: String? = nil, action: TaskAction? = nil, preparesForIndexing: Bool = false, llbuildControlDisabled: Bool = false, targetDependencies: [ResolvedTargetDependency] = [], isGate: Bool = false, inputPaths: [Path] = [], outputPaths: [Path] = [], executionInputs: [ExecutionNode]? = nil, showInLog: Bool = true, showCommandLineInLog: Bool = true, priority: TaskPriority = .unspecified, isDynamic: Bool = false, alwaysExecuteTask: Bool = false) {
        assert(payload == nil || (type.payloadType != nil && Swift.type(of: payload!) == type.payloadType!))
        self.type = type
        self.dependencyData = dependencyData
        self.payload = payload
        self.forTarget = forTarget
        let additionalSignatureData = additionalSignatureData
        let ruleInfo = ruleInfo
        self.additionalOutput = additionalOutput
        self.workingDirectory = workingDirectory
        self.showEnvironment = showEnvironment
        self.action = action
        self.execDescription = execDescription
        self.preparesForIndexing = preparesForIndexing
        self.llbuildControlDisabled = llbuildControlDisabled
        self.targetDependencies = targetDependencies
        self.isGate = isGate
        self.executionInputs = executionInputs
        self.showInLog = showInLog
        self.showCommandLineInLog = showCommandLineInLog
        self.priority = priority
        self.isDynamic = isDynamic
        self.alwaysExecuteTask = alwaysExecuteTask
        self.storage = .direct(.init(ruleInfo: ruleInfo, commandLine: commandLine, additionalSignatureData: additionalSignatureData, inputPaths: inputPaths, outputPaths: outputPaths, environmentBindings: environment.bindings))
    }

    // MARK: Serialization

    package func serialize<T: Serializer>(to serializer: T) {
        guard let delegate = serializer.delegate as? (any ConfiguredTargetSerializerDelegate) else { fatalError("delegate must be a ConfiguredTargetSerializerDelegate") }

        serializer.beginAggregate(25)

        // For now we know that TaskTypeDescriptions are always a gate or a CommandLineToolSpecs, so we treat them as such for serialization and deserialization.
        //
        // FIXME: This is a hack, we should support anything here.
        if type === GateTask.type {
            serializer.serializeNil()
        } else if type === CustomTaskTypeDescription.only {
            serializer.beginAggregate(2)
            serializer.serialize("custom")
            serializer.serialize("")
            serializer.endAggregate()
        } else {
            let spec = type as! CommandLineToolSpec
            serializer.beginAggregate(2)
            serializer.serialize(spec.domain)
            serializer.serialize(spec.identifier)
            serializer.endAggregate()
        }

        serializer.serialize(dependencyData)

        if let p = payload {
            p.serialize(to: serializer)
        } else {
            serializer.serializeNil()
        }

        if let configuredTarget = forTarget {
            serializer.beginAggregate(2)
            // Make sure each configured target object is serialized only once.
            if let index = delegate.configuredTargetIndexes[configuredTarget] {
                // We already have an index into the configured target list, so serialize it.
                serializer.serialize(1)         // Placeholder indicating the next element is an index
                serializer.serialize(index)
            } else {
                // This configured target has not been serialized before, so serialize it and add it to our delegate's index map.
                serializer.serialize(0)         // Placeholder indicating the next element is a serialized ConfiguredTarget
                serializer.serialize(configuredTarget)
                delegate.configuredTargetIndexes[configuredTarget] = delegate.currentConfiguredTargetIndex
                delegate.currentConfiguredTargetIndex += 1
            }
            serializer.endAggregate()
        }
        else {
            serializer.serializeNil()
        }
        serializer.serialize(ruleInfo)
        serializer.serialize(additionalSignatureData)
        serializer.serialize(commandLine)
        serializer.serialize(additionalOutput)
        serializer.beginAggregate(2)
        serializer.serialize(environment.bindings.map(\.0))
        serializer.serialize(environment.bindings.map(\.1))
        serializer.endAggregate()
        serializer.serialize(workingDirectory)
        serializer.serialize(showEnvironment)
        serializer.serialize(execDescription)
        serializer.serialize(action)
        serializer.serialize(preparesForIndexing)
        serializer.serialize(llbuildControlDisabled)
        serializer.serialize(targetDependencies)
        serializer.serialize(isGate)
        serializer.serialize(inputPaths)
        serializer.serialize(outputPaths)
        serializer.serialize(executionInputs)
        serializer.serialize(showInLog)
        serializer.serialize(showCommandLineInLog)
        serializer.serialize(priority)
        serializer.serialize(isDynamic)
        serializer.serialize(alwaysExecuteTask)
        serializer.endAggregate()
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(25)
        guard let delegate = deserializer.delegate as? (any TaskDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a TaskDeserializerDelegate") }

        if deserializer.deserializeNil() {
            self.type = GateTask.type
        } else {
            try deserializer.beginAggregate(2)
            let domain: String = try deserializer.deserialize()
            let identifier: String = try deserializer.deserialize()
            if domain == "custom" && identifier.isEmpty {
                self.type = CustomTaskTypeDescription.only
            } else {
                guard let spec = delegate.specRegistry.getSpec(identifier, domain: domain) as? CommandLineToolSpec else { throw DeserializerError.deserializationFailed("Could not find CommandLineToolSpec with identifier '\(identifier)' in domain '\(domain)' to use as task type") }
                self.type = spec
            }
        }

        self.dependencyData = try deserializer.deserialize()

        // Deserialize the payload.
        if deserializer.deserializeNil() {
            self.payload = nil
        } else {
            guard let payloadType = type.payloadType else { throw DeserializerError.deserializationFailed("Expected a `payloadType` from \(type)") }
            self.payload = try payloadType.init(from: deserializer)
        }

        if deserializer.deserializeNil() {
            self.forTarget = nil
        }
        else {
            guard let delegate = deserializer.delegate as? (any ConfiguredTargetDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a ConfiguredTargetDeserializerDelegate") }

            // Deserialize the configured target by deserializing it if we haven't seen it before, or by looking it up via the delegate if we have.
            try deserializer.beginAggregate(2)
            let placeholder: Int = try deserializer.deserialize()
            switch placeholder {
            case 0:
                // Deserialize the configured target and add them to the delegate.
                let target: ConfiguredTarget = try deserializer.deserialize()
                delegate.configuredTargets.append(target)
                self.forTarget = target
            case 1:
                // Look up the configured target from our delegate.
                let index: Int = try deserializer.deserialize()
                guard index >= 0 && index < delegate.configuredTargets.count else { throw DeserializerError.deserializationFailed("ConfiguredTarget index \(index) is out of range (\(delegate.configuredTargets.count) configured targets)") }
                self.forTarget = delegate.configuredTargets[index]
            default:
                throw DeserializerError.deserializationFailed("BuildParameters placeholder was unexpected value '\(placeholder)'")
            }
        }
        let ruleInfo: [String] = try deserializer.deserialize()
        let additionalSignatureData: String = try deserializer.deserialize()
        let commandLine: [CommandLineArgument] = try deserializer.deserialize()
        self.additionalOutput = try deserializer.deserialize()
        try deserializer.beginAggregate(2)
        let environmentKeys: [String] = try deserializer.deserialize()
        let environmentValues: [String] = try deserializer.deserialize()
        guard environmentKeys.count == environmentValues.count else {
            throw DeserializerError.deserializationFailed("Deserialized environment contains unbalanced keys and values")
        }
        self.workingDirectory = try deserializer.deserialize()
        self.showEnvironment = try deserializer.deserialize()
        self.execDescription = try deserializer.deserialize()
        self.action = try deserializer.deserialize()
        self.preparesForIndexing = try deserializer.deserialize()
        self.llbuildControlDisabled = try deserializer.deserialize()
        self.targetDependencies = try deserializer.deserialize()
        self.isGate = try deserializer.deserialize()
        let inputPaths: [Path] = try deserializer.deserialize()
        let outputPaths: [Path] = try deserializer.deserialize()
        self.executionInputs = try deserializer.deserialize()
        self.showInLog = try deserializer.deserialize()
        self.showCommandLineInLog = try deserializer.deserialize()
        self.priority = try deserializer.deserialize()
        self.isDynamic = try deserializer.deserialize()
        self.alwaysExecuteTask = try deserializer.deserialize()
        self.storage = .direct(.init(ruleInfo: ruleInfo, commandLine: commandLine, additionalSignatureData: additionalSignatureData, inputPaths: inputPaths, outputPaths: outputPaths, environmentBindings: Array(zip(environmentKeys, environmentValues))))
    }

    internal func internedStorage(byteStringArena: ByteStringArena, stringArena: StringArena) -> Task.Storage.InternedStorage.Handles {
        let internedCommandLine: [Storage.InternedStorage.Handles.InternedCommandLineArgument] = commandLine.map {
            switch $0 {
            case .literal(let byteString):
                return .literal(byteStringArena.intern(byteString))
            case .path(let path):
                return .path(stringArena.intern(path.str))
            case .parentPath(let path):
                return .parentPath(stringArena.intern(path.str))
            }
        }
        return .init(ruleInfo: ruleInfo.map { stringArena.intern($0) },
                     commandLine: internedCommandLine,
                     additionalSignatureData: stringArena.intern(additionalSignatureData),
                     inputPathStrings: inputPaths.map { stringArena.intern($0.str) },
                     outputPathStrings: outputPaths.map { stringArena.intern($0.str) },
                     environmentBindings: environment.bindings.map { (stringArena.intern($0.0), stringArena.intern($0.1)) })
    }

    internal init(task: Task, internedStorageHandles: Task.Storage.InternedStorage.Handles, frozenByteStringArena: FrozenByteStringArena, frozenStringArena: FrozenStringArena) {
        self.type = task.type
        self.dependencyData = task.dependencyData
        self.payload = task.payload
        self.forTarget = task.forTarget

        self.storage = .interned(.init(byteStringArena: frozenByteStringArena, stringArena: frozenStringArena, handles: internedStorageHandles))

        self.targetDependencies = task.targetDependencies
        self.additionalOutput = task.additionalOutput
        self.workingDirectory = task.workingDirectory
        self.execDescription = task.execDescription
        self.action = task.action
        self.priority = task.priority
        self.executionInputs = task.executionInputs
        self.showEnvironment = task.showEnvironment
        self.preparesForIndexing = task.preparesForIndexing
        self.llbuildControlDisabled = task.llbuildControlDisabled
        self.isGate = task.isGate
        self.showInLog = task.showInLog
        self.showCommandLineInLog = task.showCommandLineInLog
        self.isDynamic = task.isDynamic
        self.alwaysExecuteTask = task.alwaysExecuteTask
    }
}

/// Tasks use reference semantics.
extension Task: Hashable {
    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    package static func ==(lhs: Task, rhs: Task) -> Bool {
        return lhs === rhs
    }
}


/// A delegate which must be used to deserialize a `Task`.
package protocol TaskDeserializerDelegate: DeserializerDelegate {
    /// The specification registry to use to look up `CommandLineToolSpec`s for deserializing Task.type properties.
    var specRegistry: SpecRegistry { get }
}

extension GateTask {
    /// Add the task to the given build description builder.
    func addToDescription(_ builder: BuildDescriptionBuilder) throws {
        try builder.addPhonyCommand(self, inputs: inputs, outputs: outputs)
    }
}

extension ConstructedTask {
    /// Add the task to the given build description builder.
    func addToDescription(_ builder: BuildDescriptionBuilder) throws {
        let allowMissingInputs = (ruleInfo.first == "PhaseScriptExecution" ? !SWBFeatureFlag.disableShellScriptAllowsMissingInputs.value : false)
            || ruleInfo.first == "ValidateDevelopmentAssets"

        // Handle custom tasks.
        //
        // FIXME: This cast is unfortunate.
        if let action = (execTask as! Task).action {
            try builder.addCustomCommand(self, tool: Swift.type(of: action).toolIdentifier, inputs: inputs, outputs: outputs, deps: execTask.dependencyData, allowMissingInputs: allowMissingInputs, alwaysOutOfDate: alwaysExecuteTask, description: ruleInfo)
            return
        }

        // Otherwise, delegate based on the task type.
        //
        // FIXME: Move to custom tasks for these behaviors.
        switch ruleInfo[0] {
        case "MkDir":
            try builder.addMkdirCommand(self, inputs: inputs, outputs: outputs, description: ruleInfo)

        case "SymLink":
            try builder.addSymlinkCommand(self, contents: ruleInfo[2], inputs: inputs, outputs: outputs, description: ruleInfo)

        default:
            try builder.addSubprocessCommand(self, inputs: inputs, outputs: outputs, description: ruleInfo, commandLine: commandLine, environment: environment, workingDirectory: execTask.workingDirectory, allowMissingInputs: allowMissingInputs, alwaysOutOfDate: alwaysExecuteTask, deps: execTask.dependencyData, isUnsafeToInterrupt: type.isUnsafeToInterrupt, llbuildControlDisabled: execTask.llbuildControlDisabled)
        }
    }
}

public enum RequiredTargetDependencyReason: CustomStringConvertible {
    case clangModuleDependency(translationUnit: Path, dependencyModuleName: String)
    case swiftModuleDependency(dependentModuleName: String, dependencyModuleName: String)

    public var description: String {
        switch self {
        case .clangModuleDependency(translationUnit: let translationUnit, dependencyModuleName: let dependencyModuleName):
            return "dependency scan of '\(translationUnit.basename)' discovered a dependency on '\(dependencyModuleName)'"
        case .swiftModuleDependency(dependentModuleName: let dependentModuleName, dependencyModuleName: let dependencyModuleName):
            return "dependency scan of Swift module '\(dependentModuleName)' discovered a dependency on '\(dependencyModuleName)'"
        }
    }
}

/// The interface used for interactions between running tasks and the controlling execution environment.
/// A `TaskExecutionDelegate` performs operations commonly needed by a task, such as file I/O.
/// This protocol enables task behavior to be more easily tested.
public protocol TaskExecutionDelegate
{
    /// The proxy to use for file system access.
    var fs: any FSProxy { get }

    /// The build command indicating what the build is being performed for.
    var buildCommand: BuildCommand? { get }

    /// The scheme command indicating what the build is being performed for.
    var schemeCommand: SchemeCommand? { get }

    /// Parent environment
    var environment: [String: String]? { get }

    /// User preferences
    var userPreferences: UserPreferences { get }

    var emitFrontendCommandLines: Bool { get }

    var infoLookup: any PlatformInfoLookup { get }

    var sdkRegistry: SDKRegistry { get }

    var specRegistry: SpecRegistry { get }

    var platformRegistry: PlatformRegistry { get }

    var requestContext: BuildRequestContext { get }

    var namespace: MacroNamespace { get }

    /// Notifies the delegate that this task has discovered a target dependency which must exist to ensure deterministic builds.
    func taskDiscoveredRequiredTargetDependency(target: ConfiguredTarget, antecedent: ConfiguredTarget, reason: RequiredTargetDependencyReason, warningLevel: BooleanWarningLevel)
}

/// A `BuildOutputDelegate` handles output emitted by the overall build, potentially within the context of a specific target.
package protocol BuildOutputDelegate: TargetDiagnosticProducingDelegate {
}

/// A `TaskOutputDelegate` handles output emitted by a task.
public protocol TaskOutputDelegate: DiagnosticProducingDelegate
{
    var startTime: Date { get }

    /// Emit output log data.
    func emitOutput(_ data: ByteString)

    /// Gives the delegate an opportunity to update its result.
    func updateResult(_ result: TaskResult)

    /// Report a subtask to be up to date, only for tasks that are not part of the build engine
    func subtaskUpToDate(_ subtask: any ExecutableTask)

    /// Report a task which was previously batched as up-to-date.
    func previouslyBatchedSubtaskUpToDate(signature: ByteString, target: ConfiguredTarget)

    func incrementClangCacheHit()

    func incrementClangCacheMiss()

    func incrementSwiftCacheHit()

    func incrementSwiftCacheMiss()

    func incrementTaskCounter(_ counter: BuildOperationMetrics.TaskCounter)

    var counters: [BuildOperationMetrics.Counter: Int] { get }
    var taskCounters: [BuildOperationMetrics.TaskCounter: Int] { get }

    /// The result of the task
    var result: TaskResult? { get }
}

package extension TaskOutputDelegate
{
    /// Emit an error message.
    func emitError(_ message: String) {
        error(message)
    }

    /// Emit a warning message.
    func emitWarning(_ message: String) {
        warning(message)
    }

    /// Emit a note.
    func emitNote(_ message: String) {
        note(message)
    }
}

/// Convenience function for writing inline text output.
extension TaskOutputDelegate
{
    func emitOutput(_ body: (OutputByteStream) -> Void) {
        let stream = OutputByteStream()
        body(stream)
        emitOutput(stream.bytes)
    }
}

package class TaskProcessDelegate: ProcessDelegate {
    let outputDelegate: any TaskOutputDelegate
    private(set) var executionError: String?
    private var _commandResult: CommandResult?
    private(set) var processStarted = false

    var commandResult: CommandResult? {
        guard processStarted else {
            return .cancelled
        }
        return _commandResult
    }

    init(outputDelegate: any TaskOutputDelegate) {
        self.outputDelegate = outputDelegate
    }

    package func processStarted(pid: llbuild_pid_t?) {
        processStarted = true
    }

    package func processHadError(error: String) {
        executionError = error
    }

    package func processHadOutput(output: [UInt8]) {
        outputDelegate.emitOutput(ByteString(output))
    }

    // Kept for compatibility with older versions of llbuild. Remove once rdar://97019909 is widely available.
    package func processHadOutput(output: String) {
        outputDelegate.emitOutput(ByteString(encodingAsUTF8: output))
    }

    package func processFinished(result: CommandExtendedResult) {
        // This may be updated by commandStarted in the case of certain failures,
        // so only update the exit status in output delegate if it is nil.
        if outputDelegate.result == nil {
            outputDelegate.updateResult(TaskResult(result))
        }
        self._commandResult = result.result
    }
}
