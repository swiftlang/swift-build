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
public import SWBUtil
public import enum SWBLLBuild.BuildValueKind
public import protocol SWBLLBuild.ProcessDelegate
public import SWBProtocol

@_exported public import class SWBLLBuild.BuildValue
@_exported public import enum SWBLLBuild.CommandResult

public protocol BuildValueValidatingTaskAction: TaskAction {
    func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool
    func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool
}

extension BuildValueValidatingTaskAction {
    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool {
        // This should default to the fallback, but instead we defer to BuildValueValidatingTaskAction.isResultValid(_:_:buildValue:) for backward compatibility.
        return isResultValid(task, operationContext, buildValue: buildValue)
    }
}

/// A task action encapsulates concrete work to be done for a task during a build.
///
/// Task actions are primarily used to capture state and execution logic for in-process tasks.
open class TaskAction: PlannedTaskAction, PolymorphicSerializable
{
    /// A unique identifier for the tool, used for binding in llbuild.
    open class var toolIdentifier: String {
        fatalError("This method is a subclass responsibility")
    }

    /// The signature of the task action's serialized representation.
    /// By default, this is integrated as part of the task's signature.
    private var serializedRepresentationSignature: ByteString?

    /// Compute the initial signature for an action.
    ///
    /// Subclasses which implement custom signature computations should override this.
    open func computeInitialSignature() -> ByteString {
        // FIXME: This is quite inefficient as practically used by the build system, because we end up serializing every task action twice, effectively. We could do a lot better if we were willing to lift this signature out somewhere else, but this is simply and ensures that by default we tend to capture every interesting piece of information in the signature.
        let sz = MsgPackSerializer()
        serialize(to: sz)
        let md5 = InsecureHashContext()
        md5.add(bytes: sz.byteString)
        return md5.signature
    }

    public init()
    {
        self.serializedRepresentationSignature = computeInitialSignature()
    }

    /// Get a signature used to identify the internal state of the command.
    ///
    /// This is checked to determine if the command needs to rebuild versus the last time it was run.
    open func getSignature(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate) -> ByteString
    {
        let md5 = InsecureHashContext()
        md5.add(bytes: serializedRepresentationSignature!)
        for arg in task.commandLine {
            md5.add(bytes: arg.asByteString)
            md5.add(number: 0)
        }
        task.environment.computeSignature(into: md5)
        md5.add(string: task.additionalSignatureData)
        return md5.signature
    }

    /// Hook for task actions to configure itself in the build system, if they need to.
    /// - parameter task: The `Task` the action is acting on behalf of.
    /// - parameter dynamicExecutionDelegate: The dynamic execution context to request dynamic dependencies from.
    open func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {}

    /// Hook for task actions that signals that a dynamic dependency has been resolved and is available.
    /// - parameter task: The `Task` the action is acting on behalf of.
    /// - parameter dependencyID: The unique ID for the requested dependency.
    /// - parameter buildValue: Produced by the requested dependency.
    /// - parameter dynamicExecutionDelegate: The dynamic execution context to request further dynamic dependencies from.
    open func taskDependencyReady(
        _ task: any ExecutableTask,
        _ dependencyID: UInt,
        _ buildValueKind: BuildValueKind?,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate
    ) {}

    /// Perform the functionality of the task.
    /// - parameter task: The `Task` the action is acting on behalf of.
    /// - parameter dynamicExecutionDelegate: The dynamic execution context in case dependencies were discovered at
    ///   runtime.
    /// - parameter taskDelegate: The delegate for the tool to perform commonly-used operations.
    /// - parameter outputDelegate: The delegate for the tool to emit output during its execution.
    /// - returns: A command result to indicate if the task failed, succeeded, got cancelled or skipped its work.
    open func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult
    {
        fatalError("This method is a subclass responsibility")
    }

    open var shouldExecuteDetached: Bool {
        return false
    }

    open func cancelDetached() {}

    // Serialization


    open func serialize<T: Serializer>(to serializer: T)
    {
        // TaskAction has no content itself to serialize, but it serializes an aggregate count of 0 so that child classes which also have no content don't have to do anything.
        serializer.serializeAggregate(1) {
            serializer.serialize(self.serializedRepresentationSignature)
        }
    }

    public required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(1)
        self.serializedRepresentationSignature = try deserializer.deserialize()
    }

    @TaskLocal internal static var taskActionImplementations: [SerializableTypeCode: any PolymorphicSerializable.Type] = [:]

    public static var implementations: [SerializableTypeCode: any PolymorphicSerializable.Type] {
        let implementations = TaskAction.taskActionImplementations
        if implementations.isEmpty {
            fatalError("Task action implementations task local is not set (did you forget to wrap the call stack in TaskActionRegistry.withSerializationContext?)")
        }
        return implementations
    }
}

public enum DynamicTaskRequestReason: CustomStringConvertible {
    case wasScannedClangModuleDependency(of: String)
    case wasScheduledBySwiftDriver
    case wasCompilationCachingQuery

    public var description: String {
        switch self {
        case .wasScannedClangModuleDependency(of: let dependent):
            return "task was discovered as a Clang module dependency of '\(dependent)' during scanning"
        case .wasScheduledBySwiftDriver:
            return "task was scheduled by the Swift driver"
        case .wasCompilationCachingQuery:
            return "task is a compilation caching query"
        }
    }

    public var backtraceFrameKind: BuildOperationBacktraceFrameEmitted.Kind {
        switch self {
        case .wasScannedClangModuleDependency:
            return .genericTask
        case .wasScheduledBySwiftDriver:
            return .swiftDriverJob
        case .wasCompilationCachingQuery:
            return .genericTask
        }
    }
}

/// Protocol for delegation to the client during task execution.
public protocol TaskExecutionClientDelegate: CoreClientDelegate {
}

/// Protocol for manipulation of dynamic tasks in TaskActions.
public protocol DynamicTaskExecutionDelegate: ActivityReporter {
    /// Requests a new node to be added as a dependency to the TaskAction, before being executed.
    ///
    /// node: The node describing the required input to the action.
    /// nodeID: Identifier for the node. Should be unique across nodes and tasks.
    func requestInputNode(node: ExecutionNode, nodeID: UInt)

    /// Requests a dynamic task to be added as a dependency to the TaskAction, before being executed.
    ///
    /// - toolIdentifier: The identifier for the tool that is being requested.
    /// - taskKey: Enum containing tool specific arguments.
    /// - taskID: Identifier for the task. Should be unique across nodes and tasks.
    /// - singleUse: Whether this dependency should not be considered for incremental builds.
    /// - workingDirectory: The working directory for the task.
    /// - environment: Environment variables to set during task execution.
    /// - taskInputs: A list of node inputs to the task action.
    /// - forTarget: The ConfiguredTarget this task belongs to.
    /// - showEnvironment: Whether to show the environment in the logs. TODO: should this be here?
    /// - reason: The human-readable reason the task is being requested.
    func requestDynamicTask(
        toolIdentifier: String,
        taskKey: DynamicTaskKey,
        taskID: UInt,
        singleUse: Bool,
        workingDirectory: Path,
        environment: EnvironmentBindings,
        forTarget: ConfiguredTarget?,
        priority: TaskPriority,
        showEnvironment: Bool,
        reason: DynamicTaskRequestReason?
    )

    /// Signals that a node was discovered to be a dependency, after the TaskAction was executed.
    ///
    /// - node: The node describing the found dependency to the action.
    func discoveredDependencyNode(_ node: ExecutionNode)

    /// Signals that a directory tree was discovered to be a dependency, after the TaskAction was executed.
    func discoveredDependencyDirectoryTree(_ path: Path)

    /// Spawns a sub-process and waits for it to finish.
    ///
    /// - commandLine: Arguments for launching the process
    /// - environment: Environment of the new process, it will not inherit from the parent
    /// - workingDirectory: Absolute path to the working directory
    /// - processDelegate: Instance to handle callbacks while execution
    ///
    /// - returns: `true` if process ran successfully and exited with `0`. Check `result` in `processFinished`
    /// callback of the delegate for the extended command result.
    @discardableResult
    func spawn(
        commandLine: [String],
        environment: [String: String],
        workingDirectory: String,
        processDelegate: any ProcessDelegate
    ) async throws -> Bool

    var allowsExternalToolExecution: Bool { get }

    var operationContext: DynamicTaskOperationContext { get }

    var continueBuildingAfterErrors: Bool { get }
}

/// Class for collecting and caching messages to emit for a task action.
class TaskActionMessageCollection
{
    var messages = [TaskActionMessage]()

    func addMessage(_ message: TaskActionMessage)
    {
        messages.append(message)
    }

    func emitMessages(_ outputDelegate: any TaskOutputDelegate)
    {
        for message in messages
        {
            switch message
            {
            case .error(let value):
                outputDelegate.emitError(value)

            case .warning(let value):
                outputDelegate.emitWarning(value)

            case .note(let value):
                outputDelegate.emitNote(value)
            }
        }
    }
}

/// Enum describing the kinds of messages that an `TaskActionMessageCollection` can emit.
enum TaskActionMessage
{
    case error(String)
    case warning(String)
    case note(String)
}
