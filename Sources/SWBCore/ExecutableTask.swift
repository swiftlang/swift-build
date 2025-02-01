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

/// An executable task contains that information needed by Swift Build's task execution engine.  This protocol allows task
/// construction to capture that information, but the backing object is in the task execution layer.  This separation
/// allows the execution layer to cache its concrete executable task objects and restore them without having to go
/// through task construction again.
public protocol ExecutableTask: AnyObject, CustomStringConvertible, Sendable {
    /// The type description of the task.
    var type: any TaskTypeDescription { get }

    /// The payload of the task, if present, which can be used by the task type to associate additional information
    /// with the task.
    var payload: (any TaskPayload)? { get }

    /// Information emitted by the execution of this task, which will allow additional dependency information be
    /// discovered.
    var dependencyData: DependencyDataStyle? { get }

    /// The target this task is running on behalf of, if any.
    var forTarget: ConfiguredTarget? { get }

    /// The rule info description.
    var ruleInfo: [String] { get }

    /// The command line of the task, starting with the executable to run in the subprocess.
    var commandLine: [CommandLineArgument] { get }

    /// Additional output that should be displayed for the task. Each element will be emitted on a separate line.
    var additionalOutput: [String] { get }

    /// The environment variables to pass to the task.
    var environment: EnvironmentBindings { get }

    /// The directory in which the task should run.
    var workingDirectory: Path { get }

    /// The display description of a single invocation of the task.  If none, the task isn’t shown in the log that’s
    /// shown for the build.
    var execDescription: String? { get }

    /// List of target dependencies related to this task. This is used by target gate tasks.
    ///
    /// FIXME: This should be specific to gate tasks, but we don't have their information in the build description.
    ///     The build description only knows about executable tasks.
    var targetDependencies: [ResolvedTargetDependency] { get }

    /// List of paths of non-virtual input nodes to the task. Used for graph validation purposes during the execution phase.
    var inputPaths: [Path] { get }

    var outputPaths: [Path] { get }

    /// List of node dependencies known to the executable task. Used mostly for tasks that require dynamic dependencies
    /// not known during the planning phase, so in most cases will be nil.
    var executionInputs: [ExecutionNode]? { get }

    var additionalSignatureData: String { get }

    var priority: TaskPriority { get }

    // Note: all the booleans are collocated here for alignment reasons (see rdar://119266783), implementations of `ExecutableTask` should follow that

    /// Whether or not this is a gate task.
    var isGate: Bool { get }

    /// Whether or not this task should show up in the build log.
    var showInLog: Bool { get }

    /// Whether or not this task's command line should be printed in the log.
    var showCommandLineInLog: Bool { get }

    /// Whether or not this task is scheduled outside the build description
    var isDynamic: Bool { get }

    /// Whether the task is configured to always execute.
    var alwaysExecuteTask: Bool { get }

    /// Whether the task should show its environment in logs.
    var showEnvironment: Bool { get }

    /// Whether the task should be executed when preparing for indexing.
    var preparesForIndexing: Bool { get }

    /// Whether llbuild control file descriptor is disabled for this task.
    var llbuildControlDisabled: Bool { get }
}

extension ExecutableTask {
    public var identifier: TaskIdentifier {
        return .init(forTarget: forTarget, ruleInfo: ruleInfo, priority: priority)
    }

    /// The command line, as a sequence of strings.
    ///
    /// Clients should expect this is cheap to compute, but not necessarily O(1).
    public var commandLineAsStrings: AnySequence<String> {
        return AnySequence(commandLine.lazy.map{ $0.asString })
    }

    public func generateIndexingInfo(input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        return type.generateIndexingInfo(for: self, input: input)
    }

    public func generatePreviewInfo(input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] {
        return type.generatePreviewInfo(for: self, input: input, fs: fs)
    }

    public func generateDocumentationInfo(input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] {
        return type.generateDocumentationInfo(for: self, input: input)
    }

    /// Generates localization info (such as produced stringsdata paths) for this task.
    public func generateLocalizationInfo(input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
        // Are we supposed to filter by target?
        if let targetFilter = input.targetIdentifiers, let target = forTarget?.target, !targetFilter.contains(target.guid) {
            // We were asked to filter by target and this target is not in the filter.
            return []
        }

        // Ask the task type to help us get this info.
        // XCStringsCompiler will tell us about compiled .xcstrings files.
        // Other types (e.g. SwiftCompiler) will tell us about .stringsdata grouped by build attributes.
        let infoFromTaskType = type.generateLocalizationInfo(for: self, input: input)

        // Ensure we return at least one output object so that each target (in the filter) has at least one representative, even if there are no paths.
        return infoFromTaskType.isEmpty ? [TaskGenerateLocalizationInfoOutput()] : infoFromTaskType
    }

    /// Method to facilitate sorting a list of ExecutableTasks.  The tasks are ordered by target name first (with tasks
    /// without targets ordered last), and then by ruleInfo within each target.
    public func shouldPrecede(_ other: any ExecutableTask) -> Bool {
        // If the tasks' targets have different names, then we order them by those names.
        guard self.forTarget?.target.name == other.forTarget?.target.name else {
            if let selfName = self.forTarget?.target.name, let otherName = other.forTarget?.target.name {
                // If both tasks' targets have names, then we order them by those names
                return selfName < otherName
            }
            else {
                // Otherwise only one has a name, so we order the one without a name last.  So all tasks without a
                // target will get ordered to the end (usually these are all gate tasks).
                return self.forTarget?.target.name != nil
            }
        }
        // Order these tasks by ruleInfo.
        return self.ruleInfo.lexicographicallyPrecedes(other.ruleInfo)
    }

    // CustomStringConvertible conformance
    public var description: String {
        return "\(Swift.type(of: self))(forTarget: \(forTarget?.target.name ?? "<none>"), ruleInfo: \(ruleInfo))"
    }
}

/// An ExecutionNode are the interfaces between the build system and the ExecutableTasks inputs and outputs. They are
/// mostly used to to track filesystem dependencies for llbuild in dynamic actions, for inputs that are not known during
/// task planning.
public struct ExecutionNode: Serializable, Encodable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public func serialize<T: Serializer>(to serializer: T) {
        // Serialize the target's GUID.
        serializer.serialize(identifier)
    }

    public init(from deserializer: any Deserializer) throws {
        identifier = try deserializer.deserialize()
    }
}
