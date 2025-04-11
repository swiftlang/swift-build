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

public import SWBUtil

/// A unique, stable identifier for a task.
///
/// These identifiers are used to associate tasks across multiple invocations of a build, so it is important that they be stable (otherwise the command will rerun). They also need to be constructed in such a way as to be unique across all possible tasks which could appear in a single build description.
public struct TaskIdentifier: Comparable, Hashable, Serializable, CustomStringConvertible, RawRepresentable, Encodable, Sendable {
    public typealias RawValue = String
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        return rawValue.description
    }

    public var sandboxProfileSentinel: String {
        let taskIdentifierChecksumContext = InsecureHashContext()
        taskIdentifierChecksumContext.add(string: self.rawValue)
        return taskIdentifierChecksumContext.signature.asString
    }
}

extension TaskIdentifier {
    /// Form a stable identifier for the task, which needs to be unique across the entire command namespace.
    ///
    /// These identifiers also need to be stable from one plan to the next, they are the basic mechanism by which llbuild associates information across builds for the purpose of incremental rebuilding.
    ///
    /// FIXME: These need to be are currently very verbose in an effort to ensure uniqueness (which could still technically be violated if two projects shared a name and a target name). In the long run, we would like llbuild to surface additional features to scope the command namespace differently so that we do can use simpler identifiers.
    public init(forTarget: ConfiguredTarget?, ruleInfo: [String], priority: TaskPriority) {
        self.rawValue = "P\(priority.rawValue):\(forTarget?.guid.stringValue ?? ""):\(forTarget?.parameters.configuration ?? ""):\(ruleInfo.joined(separator: " "))"
    }

    public init(forTarget: ConfiguredTarget?, dynamicTaskPayload: ByteString, priority: TaskPriority) {
        let ctx = InsecureHashContext()
        ctx.add(bytes: dynamicTaskPayload)
        self.rawValue = "P\(priority.rawValue):\(forTarget?.guid.stringValue ?? ""):\(forTarget?.parameters.configuration ?? ""):\(ctx.signature.asString)"
    }
}

public protocol PlannedTaskInputsOutputs {
    var inputs: [any PlannedNode] { get }
    var outputs: [any PlannedNode] { get }
}

/// A task is a concrete unit of work to be performed by the build system as a result of task construction.  For example the compilation of an individual file or the copying of a single resource. In many cases, each task will directly correspond to an external command line to be executed.  Every task also has inputs and outputs which will be honored by the build system.
///
/// A *planned* task contains information used only during task construction or which is added to the `BuildDescription` and not otherwise used during execution; information used during execution is stored in a corresponding *executable* task.  A planned task also contains a strong reference to its executable task (since during task construction the planned task is the only object which is keeping the executable task alive).
public protocol PlannedTask: AnyObject, CustomStringConvertible, Sendable, PlannedTaskInputsOutputs {
    /// The type description of the task.
    var type: any TaskTypeDescription { get }

    /// The target this task is running on behalf of, if any.
    var forTarget: ConfiguredTarget? { get }

    /// The task identifier.
    var identifier: TaskIdentifier { get }

    /// Additional arbitrary data used to contribute to the task's change-tracking signature.
    var additionalSignatureData: String { get }

    /// The rule info description.
    var ruleInfo: [String] { get }

    /// The inputs to the task.
    var inputs: [any PlannedNode] { get }

    /// The outputs of the task.
    var outputs: [any PlannedNode] { get }

    /// The other tasks which this task must be executed before.
    var mustPrecede: [UnownedPlannedTask] { get }

    /// The executable task for this planned task.
    var execTask: any ExecutableTask { get }

    /// The provisional task corresponding to this task, if any.
    ///
    /// This is mainly important for resolution of provisional tasks for directory creation: We don't want to consider a provisional task for directory creation valid just because other provisional tasks (and *only* provisional tasks) are placing content there; we want to be able to easily determine that non-provisional tasks are placing content there.
    var provisionalTask: ProvisionalTask? { get set }

    /// Allows a task to always be executed.
    var alwaysExecuteTask: Bool { get }

    var priority: TaskPriority { get }

    var repairViaOwnershipAnalysis: Bool { get }
}

/// Represents the priority of a task in relation to other tasks which may be ready to run at the same time.
public enum TaskPriority: Int, Comparable, Serializable, Encodable, Sendable {
    /// The default, lowest priority.
    case unspecified
    /// Tasks which are preferred to run earlier than those of unspecified priority. This can be used to tune scheduling behavior of specific tasks.
    case preferred
    /// The priority of a task which unblocks tasks in downstream targets. We consider these tasks higher priority because unblocking more work sooner allows for a more parallel build.
    case unblocksDownstreamTasks
    /// Network I/O that is performed outside the execution lanes (doesn't block them or is constrained by them).
    /// It's beneficial to start it as soon as possible to maximize use of network bandwidth.
    case network
    /// Gate tasks do no work and should always be the very highest priority to unblock ready work.
    case gate
}

/// An unowned planned task reference.
///
/// We need a custom type here rather than using `UnownedWrapper` because of the limitation on supplying a class only-protocol for an AnyObject constraint.
public struct UnownedPlannedTask: Sendable {
    public unowned let instance: any PlannedTask

    public init(_ instance: any PlannedTask) {
        self.instance = instance
    }
}

extension PlannedTask {
    public var description: String {
        return "\(Swift.type(of: self))(forTarget: \(forTarget?.target.name ?? "<none>"), \(inputs.count) inputs, \(outputs.count) outputs, ruleInfo: \(ruleInfo))"
    }
}

/// A constructed task is a concrete instance of `PlannedTask` which captures information about a task which is used during task construction and creation of the `BuildDescription`.  It has a reference to the executable task which will be used during task execution.
public final class ConstructedTask: PlannedTask {
    /// The task identifier.
    public let identifier: TaskIdentifier

    /// Additional arbitrary data used to contribute to the task's change-tracking signature.
    public let additionalSignatureData: String

    /// The inputs to the task.
    public let inputs: [any PlannedNode]

    /// The outputs of the task.
    public let outputs: [any PlannedNode]

    /// The commands which this task must precede.
    public let mustPrecede: [UnownedPlannedTask]

    /// The executable task for this planned task.
    public let execTask: any ExecutableTask

    /// Allows a task to always be executed.
    public let alwaysExecuteTask: Bool

    public let priority: TaskPriority

    public let repairViaOwnershipAnalysis: Bool

    /// The provisional task corresponding to this task, if any.
    ///
    /// This is mainly important for resolution of provisional tasks for directory creation: We don't want to consider a provisional task for directory creation valid just because other provisional tasks (and *only* provisional tasks) are placing content there; we want to be able to easily determine that non-provisional tasks are placing content there.
    public weak var provisionalTask: ProvisionalTask? = nil {
        willSet(newProvisionalTask) {
            precondition(provisionalTask == nil, "A provisional task has already been assigned to planned task \(self)")
        }
    }

    /// Construct a new task from a task builder.
    ///
    /// NOTE: This initializer does not mutate the builder, but we take it as inout nevertheless to avoid unnecessary copying.
    public init(_ builder: inout PlannedTaskBuilder, execTask: any ExecutableTask) {
        self.identifier = TaskIdentifier(forTarget: execTask.forTarget, ruleInfo: execTask.ruleInfo, priority: builder.priority)
        self.additionalSignatureData = builder.additionalSignatureData
        self.inputs = builder.inputs
        self.outputs = builder.outputs
        self.mustPrecede = builder.mustPrecede.map{ UnownedPlannedTask($0) }
        self.execTask = execTask
        self.alwaysExecuteTask = builder.alwaysExecuteTask
        self.priority = builder.priority
        self.repairViaOwnershipAnalysis = builder.repairViaOwnershipAnalysis
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case additionalSignatureData
        case inputs
        case outputs
        case mustPrecede
        case execTask
        case alwaysExecuteTask
        case repairViaOwnershipAnalysis
    }

    // MARK: Forwarding methods

    public var type: any TaskTypeDescription { return execTask.type}
    public var forTarget: ConfiguredTarget? { return execTask.forTarget }
    public var ruleInfo: [String] { return execTask.ruleInfo }
    public var commandLine: [ByteString] { return execTask.commandLine.map(\.asByteString) }
    public var environment: EnvironmentBindings { return execTask.environment }
    public var execDescription: String? { return execTask.execDescription }
    public var llbuildControlDisabled: Bool { return execTask.llbuildControlDisabled }
}


public final class GateTask: PlannedTask {
    /// A static task type description for gate tasks.
    private final class GateTaskTypeDescription: TaskTypeDescription {
        let payloadType: (any TaskPayload.Type)? = nil
        let isUnsafeToInterrupt: Bool = false
        var toolBasenameAliases: [String] { return [] }
        func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]? { return nil }
        func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] { return [] }
        func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] { return [] }
        func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] { return [] }
        func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] { return [] }
        func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? { return nil }
        func interestingPath(for task: any ExecutableTask) -> Path? { return nil }

        func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
            // XCStringsCompiler generates a gate task for .xcstrings files that don't actually need to be built.
            // We should report them.
            let xcstringsInputs = task.inputPaths.filter { $0.fileExtension == "xcstrings" }
            if !xcstringsInputs.isEmpty {
                return [TaskGenerateLocalizationInfoOutput(compilableXCStringsPaths: xcstringsInputs)]
            } else {
                return []
            }
        }
    }
    public static let type: any TaskTypeDescription = GateTaskTypeDescription()

    /// The task identifier.
    public let identifier: TaskIdentifier

    /// Additional arbitrary data used to contribute to the task's change-tracking signature.
    public let additionalSignatureData: String

    public var type: any TaskTypeDescription { return execTask.type }

    public var forTarget: ConfiguredTarget? { return execTask.forTarget }

    public var ruleInfo: [String] { return execTask.ruleInfo }

    /// The inputs to the task.
    public let inputs: [any PlannedNode]

    /// The outputs of the task.
    public let outputs: [any PlannedNode]

    /// The commands which this task must precede.
    public let mustPrecede: [UnownedPlannedTask]

    /// The executable task for this planned task.
    public let execTask: any ExecutableTask

    /// Gate tasks do not support always execute mode.
    public let alwaysExecuteTask = false

    public var priority: TaskPriority { .gate }

    public let repairViaOwnershipAnalysis: Bool = false

    private enum CodingKeys: String, CodingKey {
        case type
        case identifier
        case additionalSignatureData
        case payload
        case inputs
        case outputs
        case mustPrecede
        case execTask
        case alwaysExecuteTask
        case repairViaOwnershipAnalysis
    }

    /// The provisional task corresponding to this task, if any.
    ///
    /// This is mainly important for resolution of provisional tasks for directory creation: We don't want to consider a provisional task for directory creation valid just because other provisional tasks (and *only* provisional tasks) are placing content there; we want to be able to easily determine that non-provisional tasks are placing content there.
    /// The provisional task corresponding to this task, if any.
    public weak var provisionalTask: ProvisionalTask? = nil {
        willSet(newProvisionalTask) {
            preconditionFailure("Tried to assign a provisional task to gate task \(self)")
        }
    }

    /// Construct a new task from a task builder.
    ///
    /// NOTE: This initializer does not mutate the builder, but we take it as inout nevertheless to avoid unnecessary copying.
    public init(_ builder: inout PlannedTaskBuilder, execTask: any ExecutableTask) {
        assert(builder.action == nil)
        self.identifier = TaskIdentifier(forTarget: builder.forTarget, ruleInfo: execTask.ruleInfo, priority: .gate)
        self.additionalSignatureData = builder.additionalSignatureData
        self.inputs = builder.inputs
        self.outputs = builder.outputs
        self.mustPrecede = builder.mustPrecede.map{ UnownedPlannedTask($0) }
        // FIXME: It seems unfortunate that GateTask has to take an ExecutableTask, but I think that the BuildDescription expects that every PlannedTask will have an ExecutableTask.
        self.execTask = execTask
    }
}
