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

import struct Foundation.Date
import class Foundation.ProcessInfo

package import Testing

package import SWBBuildSystem
@_spi(Testing) package import SWBCore
package import SWBTaskConstruction
package import SWBTaskExecution
@_spi(Testing) package import SWBUtil

private import class SWBLLBuild.BuildDB
private import class SWBLLBuild.BuildKey

package import struct SWBProtocol.ArenaInfo
package import struct SWBProtocol.RunDestinationInfo
package import struct SWBProtocol.PreparedForIndexResultInfo
package import enum SWBProtocol.ExternalToolResult
package import struct SWBProtocol.BuildOperationTaskEnded
package import struct SWBProtocol.BuildOperationEnded
package import struct SWBProtocol.BuildOperationBacktraceFrameEmitted
package import enum SWBProtocol.BuildOperationTaskSignature
package import struct SWBProtocol.BuildOperationMetrics

// FIXME: Workaround: <rdar://problem/26249252> Unable to prefer my own type over NS renamed types
package import class SWBTaskExecution.Task
import SWBMacro

extension BuildRequest {
    func with(parameters: BuildParameters, buildTargets: [BuildTargetInfo]) -> BuildRequest {
        return Self(
            parameters: parameters,
            buildTargets: buildTargets,
            dependencyScope: dependencyScope,
            continueBuildingAfterErrors: continueBuildingAfterErrors,
            hideShellScriptEnvironment: hideShellScriptEnvironment,
            useParallelTargets: useParallelTargets,
            useImplicitDependencies: useImplicitDependencies,
            useDryRun: useDryRun,
            enableStaleFileRemoval: enableStaleFileRemoval,
            showNonLoggedProgress: showNonLoggedProgress,
            recordBuildBacktraces: recordBuildBacktraces,
            generatePrecompiledModulesReport: generatePrecompiledModulesReport,
            buildDescriptionID: buildDescriptionID,
            qos: qos,
            buildPlanDiagnosticsDirPath: buildPlanDiagnosticsDirPath,
            buildCommand: buildCommand,
            schemeCommand: schemeCommand,
            containerPath: containerPath,
            jsonRepresentation: jsonRepresentation)
    }
}

package protocol BuildRequestCheckingResult {
    var buildRequest: BuildRequest { get }
    var core: Core { get }
}

extension BuildRequestCheckingResult {
    /// The target architecture of the run destination in the build request.  Returns `undefined_arch` if the build request has no run destination, or the run destination has no target architecture.
    package var runDestinationTargetArchitecture: String {
        return buildRequest.parameters.activeRunDestination?.targetArchitecture ?? "undefined_arch"
    }

    package var runDestinationSDK: TestSDKInfo {
        guard let runDestination = buildRequest.parameters.activeRunDestination else {
            return TestSDKInfo.undefined()
        }
        return core.loadSDK(runDestination)
    }
}

package protocol PlanRequestCheckingResult {
    var buildPlanRequest: BuildPlanRequest { get }
    var buildRequest: BuildRequest { get }
}

extension PlanRequestCheckingResult {
    // The builtProductsDirSuffix, which is the EFFECTIVE_PLATFORM_NAME for a given target
    package func builtProductsDirSuffix(_ target: ConfiguredTarget) -> String {
        let settings: Settings = buildPlanRequest.buildRequestContext.getCachedSettings(target.parameters, target: target.target)
        let scope = settings.globalScope
        return scope.evaluateAsString(BuiltinMacros.EFFECTIVE_PLATFORM_NAME)
    }
}

package protocol FileContentsCheckingResult {
    var fs: any FSProxy { get }
}

/// Helper class for testing build operations.
package final class BuildOperationTester {
    package typealias DiagnosticKind = DiagnosticsCheckingResult.DiagnosticKind

    /// Describes a single event which occurred as a part of the build.
    package enum BuildEvent: Hashable, Equatable, CustomStringConvertible, Sendable {
        /// The build reported its copied path map.
        case buildReportedPathMap(copiedPathMap: [String: String], generatedFilesPathMap: [String: String]?)

        /// The build was started.
        case buildStarted

        /// The build was cancelled.
        case buildCancelled

        /// The build was completed.
        case buildCompleted

        /// The build produced a diagnostic.
        case buildHadDiagnostic(Diagnostic)

        /// An event specific to a particular target occurred.
        case targetHadEvent(ConfiguredTarget, event: BuildOperationTester.TargetEvent)

        /// Target prepared-for-index result.
        case targetPreparedForIndex(Target, PreparedForIndexResultInfo)

        /// An event specific to a particular task occurred.
        case taskHadEvent(Task, event: BuildOperationTester.TaskEvent)

        /// A previously batched subtask was marked up-to-date
        case previouslyBatchedSubtaskUpToDate(ByteString)

        /// A generic activity was started.
        case activityStarted(ruleInfo: String)

        /// A generic activity produced a diagnostic.
        case activityHadDiagnostic(ActivityID, Diagnostic)

        /// A generic activity produced output.
        case activityEmittedData(ruleInfo: String, [UInt8])

        /// A generic activity ended.
        case activityEnded(ruleInfo: String, status: BuildOperationTaskEnded.Status)

        /// The progress of the build was updated due to another event
        case totalProgressChanged(targetName: String?, startedCount: Int, maxCount: Int)

        /// The build progress was updated.
        case updatedBuildProgress(statusMessage: String, showInLog: Bool)

        /// A subtask reported its progress.
        case subtaskDidReportProgress(SubtaskProgressEvent, count: Int)

        /// The build emitted a backtrace frame.
        case emittedBuildBacktraceFrame(identifier: SWBProtocol.BuildOperationBacktraceFrameEmitted.Identifier, previousFrameIdentifier: SWBProtocol.BuildOperationBacktraceFrameEmitted.Identifier?, category: SWBProtocol.BuildOperationBacktraceFrameEmitted.Category, description: String)

        package var description: String {
            switch self {
            case .buildReportedPathMap(let copiedPathMap, let generatedFilesPathMap):
                return "buildReportedPathMap(copiedPathMap: \(String(describing: copiedPathMap)), generatedFilesPathMap: \(String(describing: generatedFilesPathMap)))"
            case .buildStarted:
                return "buildStarted"
            case .buildCancelled:
                return "buildCancelled"
            case .buildCompleted:
                return "buildCompleted"
            case .buildHadDiagnostic(let diagnostic):
                return "buildHadDiagnostic(\(diagnostic.formatLocalizedDescription(.debug)))"
            case .targetHadEvent(let target, let event):
                return "targetHadEvent(\(target), event: \(event))"
            case .targetPreparedForIndex(let target, let info):
                return "targetPreparedForIndex(\(target.name), info: \(String(describing: info)))"
            case .taskHadEvent(let task, let event):
                return "taskHadEvent(\(task), event: \(event))"
            case .totalProgressChanged(let targetName, let startedCount, let maxCount):
                return "totalProgressChanged(target: \(targetName ?? "<none>"), startedCount: \(startedCount), maxCount: \(maxCount))"
            case .updatedBuildProgress(let statusMessage, let showInLog):
                return "updatedBuildProgress(\(statusMessage), showInLog: \(showInLog))"
            case .subtaskDidReportProgress(let event, let count):
                return "subtaskDidReportProgress(\(event), count: \(count))"
            case .activityStarted(ruleInfo: let ruleInfo):
                return "activityStarted(\(ruleInfo))"
            case .activityHadDiagnostic(let activityID, let diagnostic):
                return "activityHadDiagnostic(\(activityID),\(diagnostic))"
            case .activityEmittedData(ruleInfo: let ruleInfo, let bytes):
                return "activityEmittedData(\(ruleInfo), bytes: \(ByteString(bytes).asString)"
            case .activityEnded(ruleInfo: let ruleInfo):
                return "activityEnded(\(ruleInfo))"
            case .emittedBuildBacktraceFrame(identifier: let id, previousFrameIdentifier: let previousID, category: let category, description: let description):
                return "emittedBuildBacktraceFrame(\(id), previous: \(String(describing: previousID)), category: \(category), description: \(description))"
            case .previouslyBatchedSubtaskUpToDate(let signature):
                return "previouslyBatchedSubtaskUpToDate(\(signature))"
            }
        }
    }

    /// Describes the progress event of a subtask.
    package enum SubtaskProgressEvent: String, Sendable {
        case started
        case finished
        case upToDate
        case scanning
    }

    package enum TargetEvent: Hashable, Equatable, CustomStringConvertible, Sendable {
        /// Preparation for the target was started.
        case preparationStarted

        /// The target was started.
        case started

        /// The target was completed.
        case completed

        /// The build produced a diagnostic specific to the target.
        case hadDiagnostic(Diagnostic)

        package var description: String {
            switch self {
            case .preparationStarted:
                return "preparationStarted"
            case .started:
                return "started"
            case .completed:
                return "completed"
            case .hadDiagnostic(let diagnostic):
                return ".hadDiagnostic(\(diagnostic.formatLocalizedDescription(.debug)))"
            }
        }
    }

    /// Describes a single event which occurred as a part of a task, during the build.
    package enum TaskEvent: Hashable, Equatable, CustomStringConvertible, Sendable {

        /// The task was started.
        case started

        /// The task was completed.
        case completed

        /// The task was up to date
        case upToDate

        /// The task exited with this status.
        case exit(TaskResult)

        /// The task's subprocess produced a diagnostic.
        case hadDiagnostic(Diagnostic)

        /// The task's subprocess produced output data.
        case hadOutput(contents: ByteString)

        package var description: String {
            switch self {
            case .started:
                return ".started"
            case .completed:
                return ".completed"
            case .upToDate:
                return ".upToDate"
            case .exit(let result):
                return "exit(\(result))"
            case .hadDiagnostic(let diagnostic):
                return ".hadDiagnostic(\(diagnostic.formatLocalizedDescription(.debug)))"
            case .hadOutput(let contents):
                return ".hadOutput(\(contents.bytes.asReadableString().debugDescription))"
            }
        }
    }

    package final class BuildDescriptionResults: TasksCheckingResult, DiagnosticsCheckingResult {
        /// The build description retrieval info.
        package let buildDescriptionInfo: BuildDescriptionRetrievalInfo

        /// The build description.
        package var buildDescription: BuildDescription { return buildDescriptionInfo.buildDescription }

        package var uncheckedDiagnostics: [ConfiguredTarget?: [Diagnostic]]
        package var uncheckedTasks: [Task]

        /// The build request.
        package let buildRequest: BuildRequest

        package let buildRequestContext: BuildRequestContext

        package let manifest: TestManifest?

        package let clientDelegate: any ClientDelegate

        package var checkedErrors = false
        package var checkedWarnings = false
        package var checkedNotes = false
        package var checkedRemarks = false

        private let workspace: Workspace

        init(workspace: Workspace, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, manifest: TestManifest?, clientDelegate: any ClientDelegate, buildDescriptionInfo: BuildDescriptionRetrievalInfo) {
            self.workspace = workspace
            self.buildRequest = buildRequest
            self.buildRequestContext = buildRequestContext
            self.manifest = manifest
            self.clientDelegate = clientDelegate
            self.buildDescriptionInfo = buildDescriptionInfo
            self.uncheckedDiagnostics = buildDescriptionInfo.buildDescription.diagnostics
            self.uncheckedTasks = buildDescriptionInfo.buildDescription.tasks
        }

        package func getDiagnostics(_ forKind: DiagnosticKind) -> [String] {
            return uncheckedDiagnostics.formatLocalizedDescription(.debugWithoutBehavior, workspace: workspace, filter: { $0.behavior == forKind })
        }

        package func getDiagnosticMessage(_ pattern: StringPattern, kind: DiagnosticKind, checkDiagnostic: (Diagnostic) -> Bool) -> String? {
            for (target, targetDiagnostics) in uncheckedDiagnostics {
                for (index, event) in targetDiagnostics.enumerated() {
                    guard event.behavior == kind else {
                        continue
                    }
                    let message = event.formatLocalizedDescription(.debugWithoutBehavior, targetAndWorkspace: target.map { ($0, workspace) } ?? nil)
                    guard pattern ~= message else {
                        continue
                    }
                    guard checkDiagnostic(event) else {
                        continue
                    }

                    var diags = targetDiagnostics
                    diags.remove(at: index)
                    uncheckedDiagnostics[target] = diags

                    return message
                }
            }
            return nil
        }

        package func check(_ pattern: StringPattern, kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation, checkDiagnostic: (Diagnostic) -> Bool) -> Bool {
            let found = (getDiagnosticMessage(pattern, kind: kind, checkDiagnostic: checkDiagnostic) != nil)

            if !found, failIfNotFound {
                Issue.record("Unable to find \(kind.name): '\(pattern)' (other \(kind.name)s: \(getDiagnostics(kind)))", sourceLocation: sourceLocation)
            }
            return found
        }

        package func check(_ patterns: [StringPattern], diagnostics: [String], kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation) -> Bool {
            Issue.record("\(type(of: self)).check() for multiple patterns is not yet implemented", sourceLocation: sourceLocation)
            return false
        }

        package func removeMatchedTask(_ task: Task) {
            for i in 0..<uncheckedTasks.count {
                if uncheckedTasks[i] === task {
                    uncheckedTasks.remove(at: i)
                    break
                }
            }
        }
    }

    /// Wrapper to encapsulate the results of pseudo-building and answer test queries.
    ///
    /// This helper will automatically validate some properties if not explicitly checked, for example that there are no errors or warnings.
    package final class BuildResults: BuildRequestCheckingResult, FileContentsCheckingResult, TasksCheckingResult, DiagnosticsCheckingResult {
        package typealias BuildEvent = BuildOperationTester.BuildEvent
        package typealias TaskEvent = BuildOperationTester.TaskEvent

        /// The build description retrieval info.
        package let buildDescriptionInfo: BuildDescriptionRetrievalInfo

        /// The build description.
        package var buildDescription: BuildDescription { return buildDescriptionInfo.buildDescription }

        /// The manifest info.
        package let manifest: TestManifest?

        /// The build request.
        package let buildRequest: BuildRequest

        package let buildRequestContext: BuildRequestContext

        /// Arena for the configured build request
        package var arena: ArenaInfo? {
            buildRequest.parameters.arena
        }

        package var checkedErrors = false
        package var checkedWarnings = false
        package var checkedNotes = false
        package var checkedRemarks = false

        /// The list of tasks in this build.
        package var tasks: [Task] {
            return buildDescription.tasks
        }

        package var uncheckedTasks: [Task] {
            return Array(startedTasks)
        }

        // ruleIdentifier -> [ruleIdentifier]
        private let allDynamicTaskDependencies: [String: [String]]

        private var uncheckedDynamicTaskDependencies: [String: [String]]

        /// The map of tasks by task identifier.
        fileprivate var tasksByTaskIdentifier: [TaskIdentifier: Task]

        /// The FS in use (either the pseudo FS, if in simulation, or the local FS).
        package let fs: any FSProxy

        fileprivate final class BuildEventList: CustomReflectable {
            private(set) var events: [BuildEvent]

            /// `events` structured as a dictionary for fast containment checks and counting checks of equivalent elements.
            private var eventsSet: [BuildEvent: [(index: Int, event: BuildEvent)]] = [:]

            init(events: [BuildEvent]) {
                self.events = events
                for (index, event) in events.enumerated() {
                    eventsSet[event, default: []].append((index: index, event: event))
                }
            }

            func remove(at index: Int) {
                eventsSet.removeValue(forKey: events.remove(at: index))
            }

            func contains(_ event: BuildEvent) -> Bool {
                eventsSet.contains(event)
            }

            func count(of event: BuildEvent) -> Int {
                eventsSet[event]?.count ?? 0
            }

            func firstIndex(of event: BuildEvent) -> Int? {
                eventsSet[event]?.first?.index
            }

            // Workaround: rdar://138208832 (Extremely bad performance when using a large instance of a type in an #expect)
            var customMirror: Mirror {
                Mirror(self, unlabeledChildren: [])
            }
        }

        private var _eventList: BuildEventList

        /// The list of all build events.
        ///
        /// This list is guaranteed to be in order only w.r.t. the causal ordering honored by the underlying build system for the underlying events. For example, the build completed message is guaranteed to appear after the build started message IFF the underlying system makes the same guarantee.
        ///
        /// Use `getEventLog()` to get a pretty-printed form of the events. See that method for how to use it from the `lldb` prompt.
        package var events: [BuildEvent] {
            _eventList.events
        }

        /// The list of all started tasks.
        let allStartedTasks: Set<Task>

        /// The list of tasks that reported upToDate
        let allSkippedTasks: Set<Task>

        /// The list of unmatched started tasks.
        var startedTasks: Set<Task>

        /// A sorted list of the unmatched, started tasks, for stability in issue reporting.
        var sortedStartedTasks: [Task] {
            return startedTasks.sorted(by: { $0.shouldPrecede($1) })
        }

        private let buildDatabasePath: Path?

        /// Don't use this property, use the throwing `taskDependencies()` lazy getter
        private var _taskDependencies: TaskDependencyResolver? = nil

        package let core: Core

        private let workspace: Workspace

        init(core: Core, workspace: Workspace, buildDescriptionResults: BuildDescriptionResults, tasksByTaskIdentifier: [TaskIdentifier: Task], fs: any FSProxy, events: [BuildEvent], dynamicTaskDependencies: [String: [String]], buildDatabasePath: Path?) throws {
            self.core = core
            self.workspace = workspace
            self.buildDescriptionInfo = buildDescriptionResults.buildDescriptionInfo
            self.buildRequest = buildDescriptionResults.buildRequest
            self.buildRequestContext = buildDescriptionResults.buildRequestContext
            self.manifest = buildDescriptionResults.manifest
            self.fs = fs
            self._eventList = .init(events: events)
            self.allDynamicTaskDependencies = dynamicTaskDependencies
            self.uncheckedDynamicTaskDependencies = dynamicTaskDependencies
            self.tasksByTaskIdentifier = tasksByTaskIdentifier
            let (allStartedTasks, allSkippedTasks) = events.reduce(into: ([SWBTaskExecution.Task](), [SWBTaskExecution.Task]())) { state, event in
                switch event {
                case let .taskHadEvent(task, event: .started):
                    state.0.append(task)
                case let .taskHadEvent(task, event: .upToDate):
                    state.1.append(task)
                default:
                    return
                }
            }
            self.allStartedTasks = Set(allStartedTasks)
            self.allSkippedTasks = Set(allSkippedTasks)
            self.startedTasks = self.allStartedTasks
            self.buildDatabasePath = buildDatabasePath
        }

        /// Return the contents of the manifest, for debugging.
        package func readLLBuildManifestContents() throws -> String {
            return try fs.read(buildDescription.manifestPath).bytes.asReadableString()
        }

        /// Return a human readable build log, for debugging.
        package var buildTranscript: String {
            // Harvest task information up front.
            var taskOutput = Dictionary<Ref<Task>, ByteString>()
            var taskDiagnostics = Dictionary<Ref<Task>, [Diagnostic]>()
            for case .taskHadEvent(let task, let taskEvent) in self.events {
                switch taskEvent {
                case .hadDiagnostic(let diagnostic):
                    taskDiagnostics[Ref(task)] = (taskDiagnostics[Ref(task)] ?? []) + [diagnostic]
                case .hadOutput(let output):
                    taskOutput[Ref(task)] = (taskOutput[Ref(task)] ?? ByteString()) + output
                default:
                    continue
                }
            }

            // Construct the log.
            let codec = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .fullCommandLine)
            let result = OutputByteStream()
            for event in self.events {
                switch event {
                case .buildHadDiagnostic(let diagnostic):
                    result <<< "\nbuild \(diagnostic.behavior.name): \(diagnostic.formatLocalizedDescription(.debugWithoutBehavior))\n\n"
                case .targetHadEvent(let target, .hadDiagnostic(let diagnostic)):
                    result <<< "\nbuild \(diagnostic.behavior.name): \(diagnostic.formatLocalizedDescription(.debugWithoutBehavior, target: target, workspace: workspace))\n\n"
                case .taskHadEvent(let task, let taskEvent):
                    switch taskEvent {
                    case .started:
                        result <<< "\(task.ruleInfo.quotedDescription)\n"
                        if !task.commandLine.isEmpty {
                            result <<< "    " <<< codec.encode(task.commandLine.map { $0.asString }) <<< "\n"
                        }
                        if let output = taskOutput[Ref(task)] {
                            result <<< output
                        }
                        if let diagnostics = taskDiagnostics[Ref(task)] {
                            for diagnostic in diagnostics {
                                result <<< "\ntask \(diagnostic.behavior.name): \(diagnostic.formatLocalizedDescription(.debugWithoutBehavior))\n\n"
                            }
                        }
                        result <<< "\n"
                    default:
                        continue
                    }
                case .activityHadDiagnostic(_, let diagnostic):
                    result <<< "\nbuild \(diagnostic.behavior.name): \(diagnostic.formatLocalizedDescription(.debugWithoutBehavior))\n\n"
                default:
                    result <<< "\nEVENT: \(event)\n"
                }
            }
            return result.bytes.asString
        }

        /// Get the list of all errors.
        package func getDiagnostics(_ forKind: DiagnosticKind) -> [String] {
            return self.events.compactMap { evt -> String? in
                switch evt {
                case .buildHadDiagnostic(let diagnostic) where diagnostic.behavior == forKind:
                    return diagnostic.formatLocalizedDescription(.debugWithoutBehavior)
                case .targetHadEvent(let target, .hadDiagnostic(let diagnostic)) where diagnostic.behavior == forKind:
                    return diagnostic.formatLocalizedDescription(.debugWithoutBehavior, target: target, workspace: workspace)
                case .taskHadEvent(let task, .hadDiagnostic(let diagnostic)) where diagnostic.behavior == forKind:
                    if filterDiagnostic(message: diagnostic.formatLocalizedDescription(.messageOnly)) == nil {
                        return nil
                    }

                    return diagnostic.formatLocalizedDescription(.debugWithoutBehavior, task: task)
                case .activityHadDiagnostic(_, let diagnostic) where diagnostic.behavior == forKind:
                    return diagnostic.formatLocalizedDescription(.debugWithoutBehavior)
                default:
                    return nil
                }
            }
        }

        package func getPreparedForIndexResultInfo() -> [(Target, PreparedForIndexResultInfo)] {
            return events.compactMap({ event -> (Target, PreparedForIndexResultInfo)? in
                if case let .targetPreparedForIndex(target, info) = event {
                    return (target, info)
                }
                return nil
            })
        }

        package func getDiagnosticMessage(_ pattern: StringPattern, kind: DiagnosticKind, checkDiagnostic: (Diagnostic) -> Bool) -> String? {
            for (index, event) in self.events.enumerated() {
                switch event {
                case .buildHadDiagnostic(let diagnostic) where diagnostic.behavior == kind:
                    let message = diagnostic.formatLocalizedDescription(.debugWithoutBehavior)
                    if pattern ~= message, checkDiagnostic(diagnostic) {
                        _eventList.remove(at: index)
                        return message
                    }
                case .targetHadEvent(let target, event: .hadDiagnostic(let diagnostic)) where diagnostic.behavior == kind:
                    let message = diagnostic.formatLocalizedDescription(.debugWithoutBehavior, target: target, workspace: workspace)
                    if pattern ~= message, checkDiagnostic(diagnostic) {
                        _eventList.remove(at: index)
                        return message
                    }
                case .taskHadEvent(let task, event: .hadDiagnostic(let diagnostic)) where diagnostic.behavior == kind:
                    let message = diagnostic.formatLocalizedDescription(.debugWithoutBehavior, task: task)
                    if pattern ~= message, checkDiagnostic(diagnostic) {
                        _eventList.remove(at: index)
                        return message
                    }
                case .activityHadDiagnostic(_, let diagnostic) where diagnostic.behavior == kind:
                    let message = diagnostic.formatLocalizedDescription(.debugWithoutBehavior)
                    if pattern ~= message, checkDiagnostic(diagnostic) {
                        _eventList.remove(at: index)
                        return message
                    }
                default:
                    continue
                }
            }
            return nil
        }

        package func getDiagnosticMessageForTask(_ pattern: StringPattern, kind: DiagnosticKind, task: Task) -> String? {
            for (index, event) in self.events.enumerated() {
                switch event {
                case .taskHadEvent(let eventTask, event: .hadDiagnostic(let diagnostic)) where diagnostic.behavior == kind:
                    guard eventTask == task else {
                        continue
                    }
                    let message = diagnostic.formatLocalizedDescription(.debugWithoutBehavior, task: eventTask)
                    if pattern ~= message {
                        _eventList.remove(at: index)
                        return message
                    }
                default:
                    continue
                }
            }
            return nil
        }

        package func check(_ pattern: StringPattern, kind: BuildOperationTester.DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation, checkDiagnostic: (Diagnostic) -> Bool) -> Bool {
            let found = (getDiagnosticMessage(pattern, kind: kind, checkDiagnostic: checkDiagnostic) != nil)
            if !found, failIfNotFound {
                Issue.record("Unable to find \(kind.name): '\(pattern)' (other \(kind.name)s: \(getDiagnostics(kind)))", sourceLocation: sourceLocation)
            }
            return found
        }

        package func check(_ patterns: [StringPattern], diagnostics: [String], kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation) -> Bool {
            var diagnostics = diagnostics
            var success = true
            for pattern in patterns {
                var found = false
                for (index, diagnostic) in diagnostics.enumerated() {
                    if case pattern = diagnostic {
                        found = true
                        diagnostics.remove(at: index)
                        break
                    }
                }
                if !found {
                    if failIfNotFound {
                        Issue.record("Unable to find \(kind.name): '\(pattern)'", sourceLocation: sourceLocation)
                    }
                    success = false
                }
            }
            if !diagnostics.isEmpty {
                if failIfNotFound {
                    Issue.record("Unexpected \(kind.name) diagnostics: \(diagnostics)", sourceLocation: sourceLocation)
                }
                success = false
            }
            return success
        }

        // Checking dependency cycle errors.

        /// Utility class to parse a dependency cycle and make it available to more easily check the elements of the formatted cycle.
        package final class CycleChecker: Sendable {

            package let header: String
            package let path: String
            package let usingManualOrder: Bool
            package let lines: [String]
            package let rawTrace: [String]

            package init(_ message: String) {
                var header = ""
                var path = ""
                var usingManualOrder = false
                var lines = [String]()
                var rawTrace = [String]()
                var isInRawTrace = false

                for line in message.split(separator: "\n") {
                    if isInRawTrace {
                        rawTrace.append(String(line))
                    }
                    else if line.hasPrefix("Cycle in dependencies between targets") {
                        header = String(line)
                    }
                    else if line.hasPrefix("Cycle path") {
                        path = String(line)
                    }
                    else if line == "Target build order preserved because “Build Order” is set to “Manual Order” in the scheme settings" {
                        usingManualOrder = true
                    }
                    else if line.count > 2, line.hasPrefix("→ ") || line.hasPrefix("○ ") {
                        lines.append(String(line))
                    }
                    else if line.hasPrefix("Raw dependency cycle trace") {
                        isInRawTrace = true
                    }
                }

                self.header = header
                self.path = path
                self.usingManualOrder = usingManualOrder
                self.lines = lines
                self.rawTrace = rawTrace
            }

        }

        package func checkNoTaskWithBacktraces(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
            for matchedTask in findMatchingTasks(conditions) {
                Issue.record("found unexpected task matching conditions '\(conditions)', found: \(matchedTask)", sourceLocation: sourceLocation)

                if let frameID = getBacktraceID(matchedTask, sourceLocation: sourceLocation) {
                    enumerateBacktraces(frameID) { _, category, description in
                        Issue.record("...<category='\(category)' description='\(description)'>", sourceLocation: sourceLocation)
                    }
                }
            }
        }

        /// Check whether the results contains a dependency cycle error. If so, then consume the error and create a `CycleChecking` object and pass it to the block. Otherwise fail.
        package func checkDependencyCycle(_ pattern: StringPattern, kind: DiagnosticKind = .error, failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation, body: (CycleChecker) async throws -> Void) async throws {
            guard let message = getDiagnosticMessage(pattern, kind: kind, checkDiagnostic: { _ in true }) else {
                Issue.record("Unable to find dependency cycle error: '\(pattern)' (other errors: \(getDiagnostics(.error)))", sourceLocation: sourceLocation)
                return
            }
            let checker = CycleChecker(message)
            try await body(checker)
        }

        /// Dump a log of all events.
        /// - parameter compact: If `true`, omits certain events such as updating progress which don't contribute to the actual build.
        ///
        /// To pretty-print the result of `getEventLog()` from lldb, use:
        ///
        ///     p print(results.getEventLog())
        package func getEventLog(compact: Bool = false) -> String {
            let stream = OutputByteStream() <<< "EVENT LOG:\n"
            for (idx, event) in events.enumerated() {
                let emitEvent: Bool = {
                    guard compact else { return true }
                    switch event {
                    case .buildReportedPathMap(_, _):
                        return false
                    case .totalProgressChanged(_, _, _):
                        return false
                    case .updatedBuildProgress(_, _):
                        return false
                    default:
                        return true
                    }
                }()
                if emitEvent {
                    stream <<< "  " <<< "\(idx): " <<< String(describing: event) <<< "\n"
                }
            }
            return stream.bytes.asString
        }

        /// Check that an event is present.
        package func check(contains event: BuildEvent, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(_eventList.contains(event), "event \(event) was not present", sourceLocation: sourceLocation)
        }

        /// Check that an event is not present.
        package func check(notContains event: BuildEvent, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(!_eventList.contains(event), "event \(event) was present", sourceLocation: sourceLocation)
        }

        /// Check that an event is present `count` times.
        package func check(contains event: BuildEvent, count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
            let foundCount = _eventList.count(of: event)
            #expect(foundCount == count, "event \(event) was not present \(count) times", sourceLocation: sourceLocation)
        }

        /// Check an ordering relationship exists in the events.
        package func check(event eventA: BuildEvent, precedes eventB: BuildEvent, sourceLocation: SourceLocation = #_sourceLocation) {
            // Get the index for each event.
            guard let aIndex = _eventList.firstIndex(of: eventA) else {
                Issue.record("unable to find expected event: \(eventA)", sourceLocation: sourceLocation)
                return
            }
            guard let bIndex = _eventList.firstIndex(of: eventB) else {
                Issue.record("unable to find expected event: \(eventB)", sourceLocation: sourceLocation)
                return
            }

            // Check that B follows A.
            #expect(aIndex < bIndex, "event \(eventA) does not appear before \(eventB)!", sourceLocation: sourceLocation)
        }

        /// Checks that the first and last events in the event stream are equal to the specified values.
        package func checkCapstoneEvents(first: BuildEvent = .buildStarted, last: BuildEvent = .buildCompleted, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(events.first == first, sourceLocation: sourceLocation)
            #expect(events.last == last, sourceLocation: sourceLocation)
        }

        /// Check the output of a given task.
        package func checkTaskOutput(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation, body: (ByteString) throws -> Void) rethrows {
            try body(events.compactMap{ (event: BuildOperationTester.BuildEvent) -> ByteString? in
                if case .taskHadEvent(task, event: .hadOutput(let output)) = event {
                    return output
                }
                return nil
            }.reduce(.init(), +))
        }

        /// Check the output of a given task.
        @_disfavoredOverload package func checkTaskOutput(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation, body: (ByteString) async throws -> Void) async rethrows {
            try await body(events.compactMap{ (event: BuildOperationTester.BuildEvent) -> ByteString? in
                if case .taskHadEvent(task, event: .hadOutput(let output)) = event {
                    return output
                }
                return nil
            }.reduce(.init(), +))
        }

        package func checkTaskResult(_ task: Task, expected result: TaskResult, sourceLocation: SourceLocation = #_sourceLocation) {
            var count = 0
            for event in events {
                switch event {
                case .taskHadEvent(task, event: .exit(let actualResult)):
                    count += 1
                    switch (result, actualResult) {
                    case (let .exit(exitStatusLhs, _), let .exit(exitStatusRhs, _)):
                        // Ignore metrics since we can't predict them
                        #expect(exitStatusLhs == exitStatusRhs, sourceLocation: sourceLocation)
                    default:
                        #expect(result == actualResult, sourceLocation: sourceLocation)
                    }
                default:
                    break
                }
            }
            switch count {
            case 0:
                Issue.record("Could not find exitStatus event for task \(task).", sourceLocation: sourceLocation)
            case 2...:
                Issue.record("Found multiple exitStatus events for task \(task).", sourceLocation: sourceLocation)
            default:
                break
            }
        }

        package func checkTaskUpToDate(_ taskConditions: TaskCondition..., expectedCount: UInt = 1, sourceLocation: SourceLocation = #_sourceLocation) {
            let matchingTasks = allSkippedTasks.filter({ skippedTask in
                taskConditions.allSatisfy({ _match(skippedTask, $0) })
            })

            if matchingTasks.isEmpty {
                if expectedCount == 0 {
                    return
                }
                Issue.record("No matching up to date task found for conditions \(taskConditions).", sourceLocation: sourceLocation)
                return
            }

            if matchingTasks.count == expectedCount {
                return
            }

            Issue.record("Unexpected matching task count \(matchingTasks.count), expected \(expectedCount). Matching tasks: \(matchingTasks)", sourceLocation: sourceLocation)
        }

        private func taskIdentifier(for task: any ExecutableTask, sourceLocation: SourceLocation = #_sourceLocation) throws -> TaskIdentifier {
            guard let taskIdentifier = tasksByTaskIdentifier.first(where: { $0.value.ruleIdentifier == task.ruleIdentifier })?.key else {
                throw StubError.error("Unable to get task identifier for task \(task).")
            }

            return taskIdentifier
        }

        private func matchingTasksWithIdentifier(_ conditions: [TaskCondition]) -> [(identifier: TaskIdentifier, task: Task)] {
            let matchedTasksWithIdentifier = tasksByTaskIdentifier.filter { identifier, task in
                conditions.allSatisfy { _match(task, $0) }
            }

            return matchedTasksWithIdentifier.map { (identifier: $0, task: $1) }
        }

        private func tasksThatRequested(other task: any ExecutableTask) -> [any ExecutableTask] {
            allDynamicTaskDependencies.compactMap { (key, value) -> Task? in
                guard
                    value.contains(task.ruleIdentifier),
                    let task = self.allStartedTasks.first(where: { $0.ruleIdentifier == key })
                else {
                    return nil
                }
                return task
            }
        }

        private func dependencyEdge(from task1: any ExecutableTask, to task2: any ExecutableTask, using taskDependencyResolver: TaskDependencyResolver, resolveDynamicTaskRequests: Bool = true) throws -> TaskDependencyResolver.TaskDependencyEdge {
            let givenTaskIdentifier1 = try taskIdentifier(for: task1)
            let givenTaskIdentifier2 = try taskIdentifier(for: task2)
            var edge = try taskDependencyResolver.taskDependencyEdge(givenTaskIdentifier1, other: givenTaskIdentifier2)
            // If no direct dependency edge found, we'll search from all tasks that requested `task1`
            if edge == .none, resolveDynamicTaskRequests {
                for requestingTask in tasksThatRequested(other: task1) {
                    let taskIdentifier = try taskIdentifier(for: requestingTask)
                    edge = try taskDependencyResolver.taskDependencyEdge(taskIdentifier, other: givenTaskIdentifier2)
                    if edge != .none {
                        break
                    }
                }
            }

            return edge
        }

        private func taskDependencies() throws -> TaskDependencyResolver? {
            if let _taskDependencies {
                return _taskDependencies
            }
            _taskDependencies = try buildDatabasePath.map {
                try TaskDependencyResolver(databasePath: $0)
            }
            return _taskDependencies
        }

        /// Verifies that `task` has a dependency edge on any of the tasks matching `conditions`.
        package func checkTaskFollows(_ task: any ExecutableTask, _ conditions: TaskCondition..., resolveDynamicTaskRequests: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws {
            guard let taskDependencies = try taskDependencies() else {
                Issue.record("\(#function) is only supported when persistent is set to true.", sourceLocation: sourceLocation)
                return
            }

            let matchings = matchingTasksWithIdentifier(conditions)
            guard try matchings.first(where: { identifier, matchingTask in
                let edge = try dependencyEdge(from: task, to: matchingTask, using: taskDependencies, resolveDynamicTaskRequests: resolveDynamicTaskRequests)
                return edge != .none
            }) != nil else {
                Issue.record("Unable to find a dependency edge from \(task) to any of matching tasks \(matchings.map(\.task)).", sourceLocation: sourceLocation)
                return
            }
        }

        package func checkTaskFollows(_ task1: any ExecutableTask, _ task2: any ExecutableTask, resolveDynamicTaskRequests: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws {
            guard let taskDependencies = try taskDependencies() else {
                Issue.record("\(#function) is only supported when persistent is set to true.", sourceLocation: sourceLocation)
                return
            }

            let edge = try dependencyEdge(from: task1, to: task2, using: taskDependencies, resolveDynamicTaskRequests: resolveDynamicTaskRequests)
            #expect(edge != .none, "Unable to find a dependency edge from \(task1) to \(task2).", sourceLocation: sourceLocation)
        }

        package func checkTaskDoesNotFollow(_ task: any ExecutableTask, _ conditions: TaskCondition..., resolveDynamicTaskRequests: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws {
            guard let taskDependencies = try taskDependencies() else {
                Issue.record("\(#function) is only supported when persistent is set to true.", sourceLocation: sourceLocation)
                return
            }

            let givenTaskIdentifier = try taskIdentifier(for: task)
            let matching = matchingTasksWithIdentifier(conditions)
            for (identifier, otherTask) in matching {
                let edge = try taskDependencies.taskDependencyEdge(givenTaskIdentifier, other: identifier)
                if edge != .none {
                    Issue.record("Unexpected dependency edge from \(task) to \(otherTask) via: \(edge)", sourceLocation: sourceLocation)
                }
            }
        }

        package func checkTaskDoesNotFollow(_ task1: any ExecutableTask, _ task2: any ExecutableTask, sourceLocation: SourceLocation = #_sourceLocation) throws {
            guard let taskDependencies = try taskDependencies() else {
                Issue.record("\(#function) is only supported when persistent is set to true.", sourceLocation: sourceLocation)
                return
            }

            let givenTaskIdentifier1 = try taskIdentifier(for: task1)
            let givenTaskIdentifier2 = try taskIdentifier(for: task2)
            let edge = try taskDependencies.taskDependencyEdge(givenTaskIdentifier1, other: givenTaskIdentifier2)
            #expect(edge == .none, "Unexpected dependency edge from \(task1) to \(task2) via: \(edge)", sourceLocation: sourceLocation)
        }

        package func checkTaskRequested(_ task: any ExecutableTask, _ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
            let matchedTasks = allStartedTasks.filter { startedTask in
                conditions.allSatisfy { _match(startedTask, $0) }
            }

            for dependencyIdentifier in allDynamicTaskDependencies[task.ruleIdentifier] ?? [] {
                if matchedTasks.contains(where: { $0.ruleIdentifier == dependencyIdentifier }) {
                    if let index = uncheckedDynamicTaskDependencies[task.ruleIdentifier]?.firstIndex(of: dependencyIdentifier) {
                        uncheckedDynamicTaskDependencies[task.ruleIdentifier]?.remove(at: index)
                    }
                    return
                }
            }
            Issue.record("Task \(task) does not follow any tasks matching \(conditions). Found: \(matchedTasks) in \(allStartedTasks)", sourceLocation: sourceLocation)
        }

        package func checkNoTaskRequested(_ task: any ExecutableTask, _ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
            let matchedTasks = allStartedTasks.filter { startedTask in
                conditions.allSatisfy { _match(startedTask, $0) }
            }

            for dependencyIdentifier in allDynamicTaskDependencies[task.ruleIdentifier] ?? [] {
                if matchedTasks.contains(where: { $0.ruleIdentifier == dependencyIdentifier }) {
                    Issue.record("Task \(task) did request child tasks matching \(conditions). Found: \(matchedTasks) in \(allStartedTasks)", sourceLocation: sourceLocation)
                }
            }
            return
        }

        package func checkNoUncheckedTasksRequested(_ task: any ExecutableTask, sourceLocation: SourceLocation = #_sourceLocation) {
            guard let uncheckedDependencies = uncheckedDynamicTaskDependencies[task.ruleIdentifier] else {
                return
            }

            for dependency in uncheckedDependencies {
                Issue.record("Unexpected dependency for \(task): found \(dependency)", sourceLocation: sourceLocation)
            }
        }

        package func removeMatchedTask(_ task: Task) {
            startedTasks.remove(task)
        }

        private func getBacktraceID(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) -> BuildOperationBacktraceFrameEmitted.Identifier? {
            guard let frameID: BuildOperationBacktraceFrameEmitted.Identifier = events.compactMap ({ (event) -> BuildOperationBacktraceFrameEmitted.Identifier? in
                guard case .emittedBuildBacktraceFrame(identifier: let identifier, previousFrameIdentifier: _, category: _, description: _) = event, case .task(let signature) = identifier, BuildOperationTaskSignature.taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue)) == signature else {
                    return nil
                }
                return identifier
                // Iff the task is a dynamic task, there may be more than one corresponding frame if it was requested multiple times, in which case we choose the first. Non-dynamic tasks always have a 1-1 relationship with frames.
            }).sorted().first else {
                Issue.record("Did not find a single build backtrace frame for task: \(task.identifier)", sourceLocation: sourceLocation)
                return nil
            }
            return frameID
        }

        private func enumerateBacktraces(_ identifier: BuildOperationBacktraceFrameEmitted.Identifier, _ handleFrameInfo: (_ identifier: BuildOperationBacktraceFrameEmitted.Identifier?, _ category: BuildOperationBacktraceFrameEmitted.Category, _ description: String) -> ()) {
            var currentFrameID: BuildOperationBacktraceFrameEmitted.Identifier? = identifier
            while let id = currentFrameID {
                if let frameInfo: (BuildOperationBacktraceFrameEmitted.Identifier?, BuildOperationBacktraceFrameEmitted.Category, String) = events.compactMap({ (event) -> (BuildOperationBacktraceFrameEmitted.Identifier?, BuildOperationBacktraceFrameEmitted.Category, String)? in
                    guard case .emittedBuildBacktraceFrame(identifier: id, previousFrameIdentifier: let previousFrameIdentifier, category: let category, description: let description) = event else {
                        return nil
                    }
                    return (previousFrameIdentifier, category, description)
                    // Iff the task is a dynamic task, there may be more than one corresponding frame if it was requested multiple times, in which case we choose the first. Non-dynamic tasks always have a 1-1 relationship with frames.
                }).sorted(by: { $0.0 }).first {
                    handleFrameInfo(frameInfo.0, frameInfo.1, frameInfo.2)
                    currentFrameID = frameInfo.0
                } else {
                    currentFrameID = nil
                }
            }
        }

        package func checkBacktrace(_ identifier: BuildOperationBacktraceFrameEmitted.Identifier, _ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
            var frameDescriptions: [String] = []
            enumerateBacktraces(identifier) { (_, category, description) in
                frameDescriptions.append("<category='\(category)' description='\(description)'>")
            }

            XCTAssertMatch(frameDescriptions, patterns, sourceLocation: sourceLocation)
        }

        package func checkBacktrace(_ task: Task, _ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
            if let frameID = getBacktraceID(task, sourceLocation: sourceLocation) {
                checkBacktrace(frameID, patterns, sourceLocation: sourceLocation)
            } else {
                // already recorded an issue
            }
        }

        private class TaskDependencyResolver {
            /// The database schema has to match what `BuildSystemImpl` defines in `getMergedSchemaVersion()`.
            /// Can be removed once rdar://85336712 is resolved.
            private static let databaseSchemaVersion: UInt32 = 9

            private let buildDB: BuildDB
            fileprivate let buildKeyByTaskIdentifier: [TaskIdentifier: BuildKey]

            init(databasePath: Path) throws {
                self.buildDB = try BuildDB(path: databasePath.str, clientSchemaVersion: Self.databaseSchemaVersion)

                let results = try self.buildDB.getKeysWithResult()
                var buildKeyByTaskIdentifier = [TaskIdentifier: BuildKey](minimumCapacity: results.count)
                for element in results {
                    guard let taskIdentifier = element.key.taskIdentifier else {
                        continue
                    }

                    buildKeyByTaskIdentifier[taskIdentifier] = element.key
                }
                self.buildKeyByTaskIdentifier = buildKeyByTaskIdentifier
            }

            enum TaskDependencyEdge: CustomStringConvertible, Equatable {
                case none
                case direct
                case transitive(keys: [BuildKey])

                fileprivate init(rawValue: [BuildKey]) {
                    if rawValue.isEmpty {
                        self = .none
                    } else if rawValue.count == 1 {
                        self = .direct
                    } else {
                        self = .transitive(keys: rawValue)
                    }
                }

                var description: String {
                    switch self {
                    case .none: return "No dependency"
                    case .direct: return "Direct dependency"
                    case .transitive(let keys):
                        return "Transitive edge via \(keys)"
                    }
                }
            }

            /// Breadth-first search to find a dependency edge between `task1` and `task2`.
            func taskDependencyEdge(_ task1: TaskIdentifier, other task2: TaskIdentifier) throws -> TaskDependencyEdge {
                guard let key1 = buildKeyByTaskIdentifier[task1] else {
                    return .none
                }

                struct QueueItem {
                    let key: BuildKey
                    let partialResult: [BuildKey]
                }

                var queue: Queue<QueueItem> = [QueueItem(key: key1, partialResult: [])]
                var visited: Set<BuildKey> = [key1]
                while let queueItem = queue.popFirst() {
                    let dependencies = try self.buildDB.lookupRuleResult(buildKey: queueItem.key)?.dependencies ?? []
                    if dependencies.isEmpty {
                        continue
                    }
                    for dep in dependencies {
                        if dep.taskIdentifier == task2 {
                            return TaskDependencyEdge(rawValue: queueItem.partialResult + [dep])
                        }
                        if !visited.contains(dep) {
                            queue.append(QueueItem(key: dep, partialResult: queueItem.partialResult + [dep]))
                            visited.insert(dep)
                        }
                    }
                }

                return TaskDependencyEdge(rawValue: [])
            }
        }
    }

    /// The core in use.
    package let core: Core

    package enum TestVariant: Sendable {
        /// Testing variant against a full workspace.
        case viaWorkspace(TestWorkspace, Workspace, BuildDescriptionManager)

        /// Testing variant against a simple list of manually defined tasks.
        case viaTaskSet(Workspace, [any PlannedTask])
    }

    /// The directory to use for persistent temporaries, if necessary.
    //
    // FIXME: In an ideal world, we wouldn't need this, but currently when the SWBLLBuild layer attaches a database it has to attach a file system based on.
    package let temporaryDirectory: NamedTemporaryDirectory

    /// The test variant.
    package let testVariant: TestVariant

    /// Whether the build is being simulated.
    package let simulated: Bool

    /// Whether or not to continue building after errors
    package let continueBuildingAfterErrors: Bool

    /// The file system in use, which will be a pseudo filesystem if simulating the build.
    ///
    /// Tests can mutate this filesystem before starting builds, if desired.
    ///
    /// In simulation, the tester itself will automatically populate it with an entry for each source file found in test projects.
    package let fs: any FSProxy

    /// The client delegate to use.  Defaults to a mock delegate if not specified.  Can be overridden by individual calls to checkBuild().
    package let clientDelegate: any ClientDelegate

    private let cachedBuildSystems: any BuildSystemCache = Registry<Path, SystemCacheEntry>()

    /// The user information to supply when testing.
    ///
    /// The environment is configured so that the inferior build processes launched by the tester can find the libraries and frameworks required to launch individual tools (e.g., `ibtool`, `momc`). The relevant environment variables are defined in the individual Swift Build tests.
    package var userInfo: UserInfo

    /// Convenience method for assigning the tester a `UserInfo` object configured for the current user.
    package class func userInfoForCurrentUser(sourceLocation: SourceLocation = #_sourceLocation) -> UserInfo? {
        let environment = ProcessInfo.processInfo.environment
        guard let user = environment["USER"] else {
            Issue.record("$(USER) not defined in environment", sourceLocation: sourceLocation)
            return nil
        }
        guard let home = environment["HOME"] else {
            Issue.record("$(HOME) not defined in environment", sourceLocation: sourceLocation)
            return nil
        }
        return UserInfo(user: user, group: "", uid: 0, gid: 0, home: Path(home), environment: [:])
    }

    package static var defaultUserInfo: UserInfo {
        get throws {
            try UserInfo(
                user: "exampleUser",
                group: "exampleGroup",
                uid: 1234,
                gid: 12345,
                home: Path("/Users/exampleUser"),
                environment: ["PATH": defaultPathEntries.joined(separator: String(Path.pathEnvironmentSeparator))].addingContents(of: ProcessInfo.processInfo.cleanEnvironment.filter(keys: ["__XCODE_BUILT_PRODUCTS_DIR_PATHS", "XCODE_DEVELOPER_DIR_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "TEMP", "VCToolsInstallDir"])))
        }
    }

    package static var defaultPathEntries: [String] {
        get throws {
            if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
                return []
            }
            return ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        }
    }

    package static let defaultSystemInfoForIntel = SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "x86_64")
    // FIXME: Make this the default
    package static let defaultSystemInfo = SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: Architecture.host.stringValue ?? "undefined_arch")
    /// The system information to supply when testing.
    package var systemInfo: SystemInfo

    /// The user preferences to supply when testing.
    package var userPreferences = UserPreferences.defaultForTesting

    private struct EnvironmentVariablesExtensionContext: EnvironmentExtensionAdditionalEnvironmentVariablesContext {
        var hostOperatingSystem: OperatingSystem
        var fs: any FSProxy
    }

    /// Create a build tester.
    ///
    /// - simulated: Whether or not the build is being done in simulation.
    package init(_ core: Core, _ testWorkspace: TestWorkspace, simulated: Bool, temporaryDirectory: NamedTemporaryDirectory? = nil, fileSystem: (any FSProxy)? = nil, clientDelegate: (any ClientDelegate)? = nil, buildDescriptionMaxCacheSize: (inMemory: Int, onDisk: Int) = (1, 1), continueBuildingAfterErrors: Bool = true, systemInfo: SystemInfo = BuildOperationTester.defaultSystemInfoForIntel) async throws {
        self.core = core
        self.simulated = simulated
        self.temporaryDirectory = try temporaryDirectory ?? NamedTemporaryDirectory()
        let fs = fileSystem ?? (simulated ? PseudoFS() : SWBUtil.localFS)
        let buildDescriptionManager = BuildDescriptionManager(fs: fs, buildDescriptionMemoryCacheEvictionPolicy: .never, maxCacheSize: buildDescriptionMaxCacheSize)
        self.testVariant = .viaWorkspace(testWorkspace, try testWorkspace.load(core), buildDescriptionManager)
        self.fs = fs
        self.clientDelegate = clientDelegate ?? MockTestClientDelegate()
        self.continueBuildingAfterErrors = continueBuildingAfterErrors
        self.systemInfo = systemInfo
        let env = try await EnvironmentExtensionPoint.additionalEnvironmentVariables(pluginManager: core.pluginManager, context: EnvironmentVariablesExtensionContext(hostOperatingSystem: core.hostOperatingSystem, fs: fs))
        self.userInfo = try await Self.defaultUserInfo.addingPlatformDefaults(from: env)
    }

    /// Convenience initializer for single project workspace tests.
    convenience package init(_ core: Core, _ testProject: TestProject, simulated: Bool, temporaryDirectory: NamedTemporaryDirectory? = nil, fileSystem: (any FSProxy)? = nil, clientDelegate: (any ClientDelegate)? = nil, buildDescriptionMaxCacheSize: (inMemory: Int, onDisk: Int) = (1, 1), continueBuildingAfterErrors: Bool = true) async throws {
        try await self.init(core, TestWorkspace("Test", sourceRoot: testProject.sourceRoot, projects: [testProject]), simulated: simulated, temporaryDirectory: temporaryDirectory, fileSystem: fileSystem, clientDelegate: clientDelegate, buildDescriptionMaxCacheSize: buildDescriptionMaxCacheSize, continueBuildingAfterErrors: continueBuildingAfterErrors)
    }

    package init(_ core: Core, _ tasks: [any PlannedTask], simulated: Bool, temporaryDirectory: NamedTemporaryDirectory? = nil, fileSystem: (any FSProxy)? = nil, clientDelegate: (any ClientDelegate)? = nil, continueBuildingAfterErrors: Bool = true, systemInfo: SystemInfo = BuildOperationTester.defaultSystemInfoForIntel) async throws {
        self.core = core
        self.testVariant = .viaTaskSet(try TestWorkspace("empty", projects: []).load(core), tasks)
        self.simulated = simulated
        self.temporaryDirectory = try temporaryDirectory ?? NamedTemporaryDirectory()
        self.fs = fileSystem ?? (simulated ? PseudoFS() : SWBUtil.localFS)
        self.clientDelegate = clientDelegate ?? MockTestClientDelegate()
        self.continueBuildingAfterErrors = continueBuildingAfterErrors
        self.systemInfo = systemInfo
        let env = try await EnvironmentExtensionPoint.additionalEnvironmentVariables(pluginManager: core.pluginManager, context: EnvironmentVariablesExtensionContext(hostOperatingSystem: core.hostOperatingSystem, fs: fs))
        self.userInfo = try await Self.defaultUserInfo.addingPlatformDefaults(from: env)
    }

    package var workspace: Workspace {
        switch testVariant {
        case let .viaWorkspace(_, workspace, _):
            return workspace
        case let .viaTaskSet(workspace, _):
            return workspace
        }
    }

    package lazy var workspaceContext: WorkspaceContext = {
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: self.fs, processExecutionCache: .sharedForTesting)

        // Configure fake user and system info.
        workspaceContext.updateUserInfo(self.userInfo)
        workspaceContext.updateSystemInfo(self.systemInfo)
        workspaceContext.updateUserPreferences(self.userPreferences)

        return workspaceContext
    }()

    package func findExecutable(basename: String, toolchain toolchainIdentifier: String = "default") -> Path? {
        guard let toolchain = core.toolchainRegistry.lookup(toolchainIdentifier) else { return nil }
        return workspaceContext.createExecutableSearchPaths(platform: nil, toolchains: [toolchain]).findExecutable(operatingSystem: core.hostOperatingSystem, basename: basename)
    }

    /// Returns the effective build parameters to use for the build.
    private func effectiveBuildParameters(_ parameters: BuildParameters?, runDestination: SWBProtocol.RunDestinationInfo?) -> BuildParameters {
        // Indexing tests pass exactly the parameters they want to use, so we don't mess with them.
        if let parameters, parameters.action == .indexBuild {
            return parameters
        }

        // Always start with some set of build parameters.
        let parameters = parameters ?? BuildParameters(configuration: "Debug")

        // If the build parameters don't specify a run destination, but we were passed one, then use the one we were passed. (checkBuild() defaults this to .macOS.)
        let runDestination = parameters.activeRunDestination ?? runDestination

        // Define a default set of overrides.
        var overrides = [
            // Always use separate headermaps by forcing ALWAYS_SEARCH_USER_PATHS off, unless the build parameters passed to checkBuild() explicitly enables it. (Since traditional headermaps are currently not supported by Swift Build, doing so is not presently useful.)  Doing this also suppresses the warning of traditional headermaps being unsupported.
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            // Temporarily force each tester to use its own stat cache dir. rdar://104356237 (Clang-stat-cache should write to a temporary file and rename into place to avoid races generating the cache)
            "SDK_STAT_CACHE_DIR": workspace.path.dirname.str,
        ]

        // If we have a run destination, then we default ONLY_ACTIVE_ARCH to YES. This means when they build with a non-generic run destination, that run destination's architecture will be used rather than building universal.
        // If we don't have a run destination, then defaulting ONLY_ACTIVE_ARCH is probably the wrong thing to do.
        if runDestination != nil {
            overrides["ONLY_ACTIVE_ARCH"] = "YES"
        }

        // Initial code to enable the proper setting overrides for when specialization is enabled. This is only a partial implementation for early testing.
        let specializationEnabled = SWBFeatureFlag.allowTargetPlatformSpecialization.value
        if let destination = runDestination, specializationEnabled {
            overrides["SDKROOT"] = destination.sdk
            if let variant = destination.sdkVariant {
                overrides["SDK_VARIANT"] = variant

                if variant == MacCatalystInfo.sdkVariantName {
                    overrides["SUPPORTS_MACCATALYST"] = "YES"
                }
            }

            // TODO: handle SUPPORTED_PLATFORMS and TOOLCHAINS when necessary. Would be better to factor out the code from DependencyResolution.imposed(on:).
        }

        if let ciWorkspace = ProcessInfo.processInfo.environment["CI_WORKSPACE_PATH"] {
            for platform in ["macosx", "iphoneos", "iphonesimulator", "appletvos", "appletvsimulator", "watchos", "watchsimulator", "xros", "xrsimulator"] {
                overrides["SWIFT_OVERLOAD_PREBUILT_MODULE_CACHE_PATH[sdk=\(platform)*]"] = "\(ciWorkspace)/prebuilt-modules/\(platform)"
            }
        }

        // Add overrides from the parameters we were passed, which will supersede the default overrides above.
        overrides.addContents(of: parameters.overrides)

        // Create and return the effective parameters.
        return BuildParameters(action: parameters.action, configuration: parameters.configuration, activeRunDestination: runDestination, activeArchitecture: parameters.activeArchitecture, overrides: overrides, commandLineOverrides: parameters.commandLineOverrides, commandLineConfigOverridesPath: parameters.commandLineConfigOverridesPath, commandLineConfigOverrides: parameters.commandLineConfigOverrides, environmentConfigOverridesPath: parameters.environmentConfigOverridesPath, environmentConfigOverrides: parameters.environmentConfigOverrides, arena: parameters.arena)
    }

    private func effectiveBuildRequest(_ buildRequest: BuildRequest, runDestination: SWBProtocol.RunDestinationInfo?) -> BuildRequest {
        // Create the effective build parameters.
        let parameters = effectiveBuildParameters(buildRequest.parameters, runDestination: runDestination)

        // Modify all the build targets to use modified parameters.
        let buildTargets = buildRequest.buildTargets.map({ BuildRequest.BuildTargetInfo(parameters: effectiveBuildParameters($0.parameters, runDestination: runDestination), target: $0.target) })

        // Create the return the build request.
        return buildRequest.with(parameters: parameters, buildTargets: buildTargets)
    }

    /// Construct the build description for the given build parameters, and check it.
    @discardableResult package func checkBuildDescription<T>(_ parameters: BuildParameters? = nil, runDestination: SWBProtocol.RunDestinationInfo?, buildRequest inputBuildRequest: BuildRequest? = nil, buildCommand: BuildCommand? = nil, schemeCommand: SchemeCommand? = .launch, persistent: Bool = false, serial: Bool = false, signableTargets: Set<String> = [], signableTargetInputs: [String: ProvisioningTaskInputs] = [:], clientDelegate: (any ClientDelegate)? = nil, workspaceContext: WorkspaceContext? = nil, sourceLocation: SourceLocation = #_sourceLocation, body: (BuildDescriptionResults) async throws -> T) async throws -> T {
        let parameters = effectiveBuildParameters(parameters, runDestination: runDestination)

        let clientDelegate = clientDelegate ?? self.clientDelegate
        let buildRequest: BuildRequest
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext ?? self.workspaceContext)
        let buildDescriptionInfo: BuildDescriptionRetrievalInfo
        let manifest: TestManifest?
        switch testVariant {
        case let .viaWorkspace(testWorkspace, workspace, buildDescriptionManager):
            // If using a simulated FS, then ensure all of the source files exist, in some form.
            if simulated {
                for path in testWorkspace.findSourceFiles() {
                    try fs.createDirectory(path.dirname, recursive: true)
                    try fs.write(path, contents: ByteString(encodingAsUTF8: "FAKE SOURCE FILE"))
                }
            }

            // Create the build request for the app target, if needed
            if let inputBuildRequest {
                precondition(buildCommand == nil, "unexpected explicit build request and build command")
                if inputBuildRequest.parameters.action == .indexBuild {
                    // Indexing tests pass exactly the build request they want to use, so we don't mess with it.
                    buildRequest = inputBuildRequest
                } else {
                    buildRequest = effectiveBuildRequest(inputBuildRequest, runDestination: runDestination)
                }
            } else {
                let project = workspace.projects[0]
                let target = project.targets[0]
                let buildTarget = BuildRequest.BuildTargetInfo(parameters: parameters, target: target)
                buildRequest = BuildRequest(parameters: parameters, buildTargets: [buildTarget], dependencyScope: .workspace, continueBuildingAfterErrors: continueBuildingAfterErrors, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: buildCommand ?? .build(style: .buildOnly, skipDependencies: false), schemeCommand: schemeCommand)
            }

            // Create the build description.
            let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext ?? self.workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)

            // Construct a dictionary of provisioning inputs for targets which are to be signed.  If inputs for a target were not provided to us, then we default to simple ad-hoc signing.
            var provisioningInputs = [ConfiguredTarget: ProvisioningTaskInputs]()
            for ct in buildGraph.allTargets {
                if signableTargets.contains(ct.target.name) {
                    provisioningInputs[ct] = signableTargetInputs[ct.target.name] ?? ProvisioningTaskInputs(identityHash: "-")
                }
            }
            let planRequest = BuildPlanRequest(workspaceContext: workspaceContext ?? self.workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: buildGraph, provisioningInputs: provisioningInputs)

            // FIXME: It is unfortunate that we need to do this here, but outside of tests the client will create this directory because of PIF transfer.
            if !simulated {
                let cacheDirectory = try BuildDescriptionManager.cacheDirectory(planRequest)
                _ = CreateBuildDirectoryTaskAction.createBuildDirectory(at: cacheDirectory, fs: fs)
            }

            let buildDescriptionDelegate = MockTestBuildDescriptionConstructionDelegate()
            guard let buildDescriptionRetrievalInfo = try await buildDescriptionManager.getNewOrCachedBuildDescription(planRequest, bypassActualTasks: simulated, clientDelegate: clientDelegate, constructionDelegate: buildDescriptionDelegate) else {
                throw StubError.error("Build plan construction was unexpectedly cancelled")
            }
            buildDescriptionInfo = buildDescriptionRetrievalInfo
            await buildDescriptionManager.waitForBuildDescriptionSerialization()
            manifest = buildDescriptionDelegate.manifest

        case let .viaTaskSet(workspace, tasks):
            precondition(inputBuildRequest == nil, "build requests unsupported in those mode")

            // Create the build request.
            buildRequest = BuildRequest(parameters: parameters, buildTargets: [], dependencyScope: .workspace, continueBuildingAfterErrors: continueBuildingAfterErrors, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: buildCommand ?? .build(style: .buildOnly, skipDependencies: false))

            // Create the build description.
            //
            // FIXME: We have to pass this a temporary directory path, in case the client is trying to use persistent builds, in which case the llbuild database path will be derived from this. We should clean this up and make it explicit.
            let buildDescriptionDelegate = MockTestBuildDescriptionConstructionDelegate()
            let buildDescription = try await BuildDescription.construct(workspace: workspace, tasks: tasks, path: temporaryDirectory.path, signature: "checkBuild_viaTaskSet", buildCommand: buildCommand ?? .build(style: .buildOnly, skipDependencies: false), fs: fs, delegate: buildDescriptionDelegate)!
            manifest = buildDescriptionDelegate.manifest

            buildDescriptionInfo = BuildDescriptionRetrievalInfo(buildDescription: buildDescription, source: BuildDescriptionRetrievalSource.new, inMemoryCacheSize: 0, onDiskCachePath: Path(""))
        }

        return try await body(BuildDescriptionResults(workspace: workspace, buildRequest: buildRequest, buildRequestContext: buildRequestContext, manifest: manifest, clientDelegate: clientDelegate, buildDescriptionInfo: buildDescriptionInfo))
    }

    /// Construct the tasks for the given build parameters, and test the result.
    @discardableResult package func checkBuild<T>(_ name: String? = nil, parameters: BuildParameters? = nil, runDestination: SWBProtocol.RunDestinationInfo?, buildRequest inputBuildRequest: BuildRequest? = nil, buildCommand: BuildCommand? = nil, schemeCommand: SchemeCommand? = .launch, persistent: Bool = false, serial: Bool = false, buildOutputMap: [String:String]? = nil, signableTargets: Set<String> = [], signableTargetInputs: [String: ProvisioningTaskInputs] = [:], clientDelegate: (any ClientDelegate)? = nil, sourceLocation: SourceLocation = #_sourceLocation, body: (BuildResults) async throws -> T) async throws -> T {
        try await checkBuild(name, parameters: parameters, runDestination: runDestination, buildRequest: inputBuildRequest, buildCommand: buildCommand, schemeCommand: schemeCommand, persistent: persistent, serial: serial, buildOutputMap: buildOutputMap, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs, clientDelegate: clientDelegate, sourceLocation: sourceLocation, body: body, performBuild: { await $0.buildWithTimeout() })
    }

    /// Construct the tasks for the given build parameters, and test the result.
    @discardableResult package func checkBuild<T>(_ name: String? = nil, parameters: BuildParameters? = nil, runDestination: RunDestinationInfo?, buildRequest inputBuildRequest: BuildRequest? = nil, operationBuildRequest: BuildRequest? = nil, buildCommand: BuildCommand? = nil, schemeCommand: SchemeCommand? = .launch, persistent: Bool = false, serial: Bool = false, buildOutputMap: [String:String]? = nil, signableTargets: Set<String> = [], signableTargetInputs: [String: ProvisioningTaskInputs] = [:], clientDelegate: (any ClientDelegate)? = nil, sourceLocation: SourceLocation = #_sourceLocation, body: (BuildResults) async throws -> T, performBuild: @escaping (any BuildSystemOperation) async throws -> Void) async throws -> T {
        try await checkBuildDescription(parameters, runDestination: runDestination, buildRequest: inputBuildRequest, buildCommand: buildCommand, schemeCommand: schemeCommand, persistent: persistent, serial: serial, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs, clientDelegate: clientDelegate) { results throws in
            // Check that there are no duplicate task identifiers - it is a fatal error if there are, unless `continueBuildingAfterErrors` is set.
            var tasksByTaskIdentifier: [TaskIdentifier: Task] = [:]
            results.buildDescription.taskStore.forEachTask { task in
                let identifier = task.identifier
                assert(tasksByTaskIdentifier[identifier] == nil || results.buildRequest.continueBuildingAfterErrors, "unexpected duplicate task identifier: \(task.ruleInfo)")
                tasksByTaskIdentifier[identifier] = task
            }

            // Create a build operation.
            //
            // NOTE: We explicitly don't pass an FS here when not simulating, so that llbuild will talk directly to the file system.
            let delegate = BuildOperationTesterDelegate(self, tasksByTaskIdentifier: tasksByTaskIdentifier, simulated ? fs : nil)

            let operationBuildRequest = operationBuildRequest ?? results.buildRequest
            let buildRequestContext = results.buildRequestContext

            let buildCommand = buildCommand ?? operationBuildRequest.buildCommand
            let operation: any BuildSystemOperation
            if case let .cleanBuildFolder(style) = buildCommand {
                operation = CleanOperation(buildRequest: operationBuildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext, style: style, delegate: delegate, cachedBuildSystems: cachedBuildSystems)
            } else {
                let nodesToBuild: [BuildDescription.BuildNodeToPrepareForIndex]?
                if case TestVariant.viaWorkspace = testVariant {
                    nodesToBuild = results.buildDescription.buildNodesToPrepareForIndex(buildRequest: operationBuildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext)
                } else {
                    nodesToBuild = nil
                }
                operation = BuildOperation(operationBuildRequest, buildRequestContext, results.buildDescription, environment: userInfo.processEnvironment, delegate, results.clientDelegate, cachedBuildSystems, persistent: persistent, serial: serial, buildOutputMap: buildOutputMap, nodesToBuild: nodesToBuild, workspace: workspace, core: core, userPreferences: userPreferences)
            }

            // Perform the build.
            try await performBuild(operation)

            // Check to make sure we don't have leftover tasks or targets,
            // unless we had a build error e.g a dependency cycle.
            if !delegate.buildHadError {
                for task in delegate.activeTasks {
                    Issue.record("Leftover task '\(task)'", sourceLocation: sourceLocation)
                }
                for target in delegate.activeTargets {
                    Issue.record("Leftover target '\(target)'", sourceLocation: sourceLocation)
                }
            }

            // Get event log.
            let events = delegate.getEvents()
            let dynamicDependencies = delegate.dynamicTaskDependencies.mapValues { taskIdentifiers in
                taskIdentifiers.compactMap {
                    delegate.dynamicTasksByTaskIdentifier[$0]?.ruleIdentifier
                }
            }

            // Check the results.
            let results = try BuildResults(core: core, workspace: workspace, buildDescriptionResults: results, tasksByTaskIdentifier: delegate.tasksByTaskIdentifier.merging(delegate.dynamicTasksByTaskIdentifier, uniquingKeysWith: { a, b in a }), fs: fs, events: events, dynamicTaskDependencies: dynamicDependencies, buildDatabasePath: persistent ? results.buildDescription.buildDatabasePath : nil)

            /*@MainActor func addAttachments() {
                // TODO: This `runActivity` call should be wider in scope, but this would significantly complicate the code flow due to threading requirements without having async/await.
                XCTContext.runActivity(named: "Execute Build Operation" + (name.map({ " \"\($0)\"" }) ?? "")) { activity in
                    // TODO: <rdar://59432231> Longer term, we should find a way to share code with CoreQualificationTester, which has a number of APIs for emitting build operation debug info.
                    activity.attach(name: "Build Transcript", string: results.buildTranscript)
                    if localFS.exists(results.buildDescription.packagePath) {
                        activity.attach(name: "Build Description", from: results.buildDescription.packagePath)
                    }
                }
            }

            await addAttachments()*/

            defer {
                let validationResults = results.validate(sourceLocation: sourceLocation)

                // Print the build transcript in the case of unchecked errors/warnings, which is useful on platforms where XCTAttachment doesn't exist
                if validationResults.hadUncheckedErrors || validationResults.hadUncheckedWarnings {
                    Issue.record("Build failed with unchecked errors and/or warnings; build transcript follows:\n\n\(results.buildTranscript)", sourceLocation: sourceLocation)
                }
            }

            return try await body(results)
        }
    }

    /// Ensure that the build is a null build.
    package func checkNullBuild(_ name: String? = nil, parameters: BuildParameters? = nil, runDestination: RunDestinationInfo?, buildRequest inputBuildRequest: BuildRequest? = nil, buildCommand: BuildCommand? = nil, schemeCommand: SchemeCommand? = .launch, persistent: Bool = false, serial: Bool = false, buildOutputMap: [String:String]? = nil, signableTargets: Set<String> = [], signableTargetInputs: [String: ProvisioningTaskInputs] = [:], clientDelegate: (any ClientDelegate)? = nil, excludedTasks: Set<String> = ["ClangStatCache", "LinkAssetCatalogSignature"], diagnosticsToValidate: Set<DiagnosticKind> = [.note, .error, .warning], sourceLocation: SourceLocation = #_sourceLocation) async throws {

        func body(results: BuildResults) throws -> Void {
            results.consumeTasksMatchingRuleTypes(excludedTasks)
            results.checkNoTaskWithBacktraces(sourceLocation: sourceLocation)

            results.checkNote(.equal("Building targets in dependency order"), failIfNotFound: false)
            results.checkNote(.prefix("Target dependency graph"), failIfNotFound: false)

            for kind in diagnosticsToValidate {
                switch kind {
                case .note:
                    results.checkNoNotes(sourceLocation: sourceLocation)

                case .warning:
                    results.checkNoWarnings(sourceLocation: sourceLocation)

                case .error:
                    results.checkNoErrors(sourceLocation: sourceLocation)

                case .remark:
                    results.checkNoRemarks(sourceLocation: sourceLocation)

                default:
                    // other kinds are ignored
                    break
                }
            }
        }

        try await UserDefaults.withEnvironment(["EnableBuildBacktraceRecording": "true"]) {
            try await checkBuild(name, parameters: parameters, runDestination: runDestination, buildRequest: inputBuildRequest, buildCommand: buildCommand, schemeCommand: schemeCommand, persistent: persistent, serial: serial, buildOutputMap: buildOutputMap, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs, clientDelegate: clientDelegate, sourceLocation: sourceLocation, body: body)
        }
    }

    package static func buildRequestForIndexOperation(
        workspace: Workspace,
        buildTargets: [any TestTarget]? = nil,
        prepareTargets: [String]? = nil,
        workspaceOperation: Bool? = nil,
        runDestination: RunDestinationInfo? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> BuildRequest {
        let workspaceOperation = workspaceOperation ?? (buildTargets == nil)

        // If this is an operation on the entire workspace (rather than for a specific target/package), then
        // we will end up configuring for all platforms - do not pass a run destination. Use the provided (or a
        // reasonable default) otherwise.
        let buildDestination: RunDestinationInfo?
        if workspaceOperation {
            buildDestination = nil
        } else {
            buildDestination = runDestination ?? RunDestinationInfo.macOS
        }

        let arena = ArenaInfo.indexBuildArena(derivedDataRoot: workspace.path.dirname)
        let overrides: [String: String] = ["ONLY_ACTIVE_ARCH": "YES", "ALWAYS_SEARCH_USER_PATHS": "NO"]
        let buildRequestParameters = BuildParameters(action: .indexBuild, configuration: "Debug", activeRunDestination: buildDestination, overrides: overrides, arena: arena)

        let buildRequestTargets: [BuildRequest.BuildTargetInfo]
        if let buildTargets {
            buildRequestTargets = try buildTargets.map { BuildRequest.BuildTargetInfo(parameters: buildRequestParameters, target: try #require(workspace.target(for: $0.guid), sourceLocation: sourceLocation)) }
        } else {
            buildRequestTargets = workspace.projects.flatMap { project in
                // The workspace description excludes packages so that we don't end up configuring every target for every
                // platform.
                if workspaceOperation && project.isPackage {
                    return [BuildRequest.BuildTargetInfo]()
                }
                return project.targets.compactMap { target in
                    if target.type == .aggregate {
                        return nil
                    }
                    return BuildRequest.BuildTargetInfo(parameters: buildRequestParameters, target: target)
                }
            }
        }

        let targetsToPrepare = try prepareTargets?.map { try #require(workspace.target(for: $0)) }
        return BuildRequest(parameters: buildRequestParameters, buildTargets: buildRequestTargets, dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false, buildCommand: .prepareForIndexing(buildOnlyTheseTargets: targetsToPrepare, enableIndexBuildArena: true))

    }

    /// Construct 'prepare' index build operation, and test the result.
    package func checkIndexBuild<T>(
        prepareTargets: [String],
        workspaceOperation: Bool = true,
        runDestination: RunDestinationInfo? = nil,
        persistent: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation,
        body: (BuildResults) throws -> T
    ) async throws -> T {
        let buildRequest = try Self.buildRequestForIndexOperation(
            workspace: workspace,
            prepareTargets: prepareTargets,
            workspaceOperation: workspaceOperation,
            runDestination: runDestination,
            sourceLocation: sourceLocation
        )

        // The build request may have no run destination (for a workspace description), but we always build for a
        // specific target.
        let runDestination = runDestination ?? RunDestinationInfo.macOS
        let operationParameters = buildRequest.parameters.replacing(activeRunDestination: runDestination, activeArchitecture: nil)
        let operationBuildRequest = buildRequest.with(parameters: operationParameters, buildTargets: [])

        return try await checkBuild(runDestination: nil, buildRequest: buildRequest, operationBuildRequest: operationBuildRequest, persistent: persistent, sourceLocation: sourceLocation, body: body, performBuild: { await $0.buildWithTimeout() })
    }

    package struct BuildGraphResult: Sendable {
        package let buildRequestContext: BuildRequestContext
        package let buildGraph: any TargetGraph
        package let graphType: TargetGraphFactory.GraphType
        package let delegate: EmptyTargetDependencyResolverDelegate

        fileprivate init(buildRequestContext: BuildRequestContext, buildGraph: any TargetGraph, graphType: TargetGraphFactory.GraphType, delegate: EmptyTargetDependencyResolverDelegate) {
            self.buildRequestContext = buildRequestContext
            self.buildGraph = buildGraph
            self.graphType = graphType
            self.delegate = delegate
        }

        package func targetNameAndPlatform(_ configuredTarget: ConfiguredTarget) -> String {
            return "\(configuredTarget.target.name)-\(configuredTarget.platformDiscriminator ?? "")"
        }

        package func checkDependencies(of testTarget: any TestTarget, are testDependencies: [TestTargetPlatform], sourceLocation: SourceLocation = #_sourceLocation) throws {
            try checkDependencies(of: .init(testTarget), are: testDependencies, sourceLocation: sourceLocation)
        }

        package func checkDependencies(of testTarget: TestTargetPlatform, are testDependencies: [TestTargetPlatform], sourceLocation: SourceLocation = #_sourceLocation) throws {
            let expected = try testDependencies.map { try target($0, sourceLocation: sourceLocation) }
            let actual = try dependencies(testTarget, sourceLocation: sourceLocation)
            #expect(actual == expected, sourceLocation: sourceLocation)
        }

        package func checkSelectedPlatform(of testTarget: any TestTarget, _ lhsPlatform: String, _ rhsPlatform: String, _ runDestination: RunDestinationInfo, expectedPlatform: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let lhsTarget = try target(.init(testTarget, lhsPlatform))
            let rhsTarget = try target(.init(testTarget, rhsPlatform))
            let expectedPlatform = try #require(target(.init(testTarget, expectedPlatform)).platformDiscriminator)
            let chosenPlatform = try #require(buildRequestContext.selectConfiguredTargetForIndex(lhsTarget, rhsTarget, hasEnabledIndexBuildArena: true, runDestination: runDestination).platformDiscriminator)
            let chosenPlatformReversed = try #require(buildRequestContext.selectConfiguredTargetForIndex(rhsTarget, lhsTarget, hasEnabledIndexBuildArena: true, runDestination: runDestination).platformDiscriminator)
            #expect(chosenPlatform == expectedPlatform, sourceLocation: sourceLocation)
            #expect(chosenPlatformReversed == expectedPlatform, sourceLocation: sourceLocation)
        }

        package func target(_ testTarget: TestTargetPlatform, sourceLocation: SourceLocation = #_sourceLocation) throws -> ConfiguredTarget {
            let foundTargets = buildGraph.allTargets.filter { $0.target.guid == testTarget.target.guid && (testTarget.platform == nil || $0.platformDiscriminator == testTarget.platform) }
            return try #require(foundTargets.only, foundTargets.isEmpty ? "unable to find target '\(testTarget.target.name)', platform '\(testTarget.platform ?? "<nil>")'" : "found more than one target '\(testTarget.target.name)', platform '\(testTarget.platform ?? "<nil>")': \(foundTargets.map { targetNameAndPlatform($0) })", sourceLocation: sourceLocation)
        }

        package func targets(_ testTarget: (any TestTarget)? = nil, sourceLocation: SourceLocation = #_sourceLocation) -> [ConfiguredTarget] {
            guard let testTarget else {
                return buildGraph.allTargets.elements
            }
            return buildGraph.allTargets.filter { $0.target.guid == testTarget.guid }
        }

        private func dependencies(_ testTarget: TestTargetPlatform, sourceLocation: SourceLocation = #_sourceLocation) throws -> [ConfiguredTarget] {
            return buildGraph.dependencies(of: try target(testTarget, sourceLocation: sourceLocation))
        }

        package struct TestTargetPlatform: Sendable {
            package let target: any TestTarget
            package let platform: String?

            package init(_ target: any TestTarget, _ platform: String? = nil) {
                self.target = target
                self.platform = platform
            }
        }
    }

    package func checkIndexBuildGraph(
        targets: [any TestTarget]? = nil,
        workspaceOperation: Bool? = nil,
        activeRunDestination: RunDestinationInfo? = nil,
        graphTypes: [TargetGraphFactory.GraphType] = [.dependency],
        sourceLocation: SourceLocation = #_sourceLocation,
        body: (BuildGraphResult) throws -> Void
    ) async throws {
        let workspaceOperation = workspaceOperation ?? (targets == nil)

        let buildRequest = try Self.buildRequestForIndexOperation(
            workspace: workspace,
            buildTargets: targets,
            workspaceOperation: workspaceOperation,
            runDestination: activeRunDestination,
            sourceLocation: sourceLocation
        )

        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        for type in graphTypes {
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)
            try body(BuildGraphResult(buildRequestContext: buildRequestContext, buildGraph: buildGraph, graphType: type, delegate: delegate))
        }
    }
}

@available(*, unavailable)
extension BuildOperationTester: Sendable { }

@available(*, unavailable)
extension BuildOperationTester.BuildResults: Sendable { }

@available(*, unavailable)
extension BuildOperationTester.BuildDescriptionResults: Sendable { }

package final class MockTestClientDelegate: ClientDelegate, Sendable {
    package init() {}

    package func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> ExternalToolResult {
        return .deferred
    }
}

private extension Task {
    convenience init(_ executableTask: any ExecutableTask) {
        var builder = PlannedTaskBuilder(type: executableTask.type, ruleInfo: executableTask.ruleInfo, additionalSignatureData: "", commandLine: executableTask.commandLine, additionalOutput: executableTask.additionalOutput, environment: executableTask.environment, inputs: [], outputs: [], mustPrecede: [])
        builder.forTarget = executableTask.forTarget
        self.init(&builder)
    }
}

private final class BuildOperationTesterDelegate: BuildOperationDelegate {
    var aggregatedCounters: [BuildOperationMetrics.Counter : Int] = [:]
    var aggregatedTaskCounters: [String: [BuildOperationMetrics.TaskCounter: Int]] = [:]

    typealias DiagnosticKind = BuildOperationTester.DiagnosticKind
    typealias BuildEvent = BuildOperationTester.BuildEvent

    private final class TestTaskOutputParserHandler: TaskOutputParserDelegate {
        let buildOperationIdentifier: BuildSystemOperationIdentifier

        let diagnosticsEngine = DiagnosticsEngine()
        init(buildOperationIdentifier: BuildSystemOperationIdentifier) {
            self.buildOperationIdentifier = buildOperationIdentifier
        }
        func skippedSubtask(signature: ByteString) {}
        func startSubtask(buildOperationIdentifier: BuildSystemOperationIdentifier, taskName: String, id: ByteString, signature: ByteString, ruleInfo: String, executionDescription: String, commandLine: [ByteString], additionalOutput: [String], interestingPath: Path?, workingDirectory: Path?, serializedDiagnosticsPaths: [Path]) -> any TaskOutputParserDelegate { return self }
        func emitOutput(_ data: ByteString) {}
        func close() {}
        func taskCompleted(exitStatus: Processes.ExitStatus) {}
    }

    private final class TestSubtaskProgressReporter: SubtaskProgressReporter {

        let delegate: BuildOperationTesterDelegate

        init(delegate: BuildOperationTesterDelegate) {
            self.delegate = delegate
        }

        func subtasksScanning(count: Int, forTargetName targetName: String?) {
            delegate.queue.async {
                self.delegate.events.append(.subtaskDidReportProgress(.scanning, count: count))
            }
        }

        func subtasksSkipped(count: Int, forTargetName targetName: String?) {
            delegate.queue.async {
                self.delegate.events.append(.subtaskDidReportProgress(.upToDate, count: count))
            }
        }

        func subtasksStarted(count: Int, forTargetName targetName: String?) {
            delegate.queue.async {
                self.delegate.events.append(.subtaskDidReportProgress(.started, count: count))
            }
        }

        func subtasksFinished(count: Int, forTargetName targetName: String?) {
            delegate.queue.async {
                self.delegate.events.append(.subtaskDidReportProgress(.finished, count: count))
            }
        }
    }

    private class TesterBuildOutputDelegate: BuildOutputDelegate {
        private let delegate: BuildOperationTesterDelegate
        private var _diagnosticsEngines = LockedValue<[ConfiguredTarget?: DiagnosticsEngine]>(.init())

        init(delegate: BuildOperationTesterDelegate) {
            self.delegate = delegate
        }

        let diagnosticContext: DiagnosticContextData = .init(target: nil)

        func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            .init(_diagnosticsEngines.withLock({ diagnosticsEngines in
                diagnosticsEngines.getOrInsert(target, {
                    let engine = DiagnosticsEngine()
                    engine.addHandler { [weak self] diag in
                        self?.log(target, diag)
                    }
                    return engine
                })
            }))
        }

        private func log(_ target: ConfiguredTarget?, _ diagnostic: Diagnostic) {
            delegate.queue.async {
                if let target {
                    self.delegate.events.append(.targetHadEvent(target, event: .hadDiagnostic(diagnostic)))
                } else {
                    self.delegate.events.append(.buildHadDiagnostic(diagnostic))
                }
            }
        }
    }

    private class TesterTaskOutputDelegate: TaskOutputDelegate {
        func incrementClangCacheHit() {
            self.counters[.clangCacheHits, default: 0] += 1
        }

        func incrementClangCacheMiss() {
            self.counters[.clangCacheMisses, default: 0] += 1
        }

        func incrementSwiftCacheHit() {
            self.counters[.swiftCacheHits, default: 0] += 1
        }

        func incrementSwiftCacheMiss() {
            self.counters[.swiftCacheMisses, default: 0] += 1
        }

        func incrementTaskCounter(_ counter: BuildOperationMetrics.TaskCounter) {
            self.taskCounters[counter, default: 0] += 1
        }

        var counters: [BuildOperationMetrics.Counter : Int] = [.clangCacheHits: 0, .clangCacheMisses: 0, .swiftCacheHits: 0, .swiftCacheMisses: 0]
        var taskCounters: [BuildOperationMetrics.TaskCounter : Int] = [:]


        let startTime = Date()
        private let _diagnosticsEngine = DiagnosticsEngine()
        let task: Task
        let operation: any BuildSystemOperation
        let delegate: BuildOperationTesterDelegate
        var _result: TaskResult?
        let parser: (any TaskOutputParser)?
        var output = ByteString()
        var hadErrors: Bool {
            return _diagnosticsEngine.hasErrors
        }

        init(task: Task, operation: any BuildSystemOperation, delegate: BuildOperationTesterDelegate, parser: (any TaskOutputParser)?) {
            self.task = task
            self.operation = operation
            self.delegate = delegate
            self.parser = parser
            self._diagnosticsEngine.addHandler { [weak self] diag in
                self?.log(diag)
            }
        }

        private func log(_ diagnostic: Diagnostic) {
            delegate.queue.async { [self] in
                self.delegate.events.append(.taskHadEvent(task, event: .hadDiagnostic(diagnostic)))
            }
        }

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            .init(_diagnosticsEngine)
        }

        func emitOutput(_ data: ByteString) {
            delegate.queue.async { [self] in
                self.delegate.events.append(.taskHadEvent(task, event: .hadOutput(contents: data)))
                output += data
            }
            parser?.write(bytes: data)
        }

        func subtaskUpToDate(_ subtask: any SWBCore.ExecutableTask) {
            let taskIdentifier = TaskIdentifier(forTarget: subtask.forTarget, ruleInfo: subtask.ruleInfo, priority: subtask.priority)
            delegate.taskUpToDate(operation, taskIdentifier: taskIdentifier, task: subtask)
        }

        func previouslyBatchedSubtaskUpToDate(signature: SWBUtil.ByteString, target: SWBCore.ConfiguredTarget) {
            delegate.previouslyBatchedSubtaskUpToDate(operation, signature: signature, target: target)
        }

        func updateResult(_ result: TaskResult) {
            delegate.queue.async { [self] in
                self._result = result
            }
        }

        var result: TaskResult? {
            delegate.queue.blocking_sync {
                self._result
            }
        }

        func handleTaskCompletion() {
            parser?.close(result: result)

            // `updateResult` may be called multiple times, so use the latest value when the delegate is deallocated.
            delegate.queue.async { [self] in
                if let result = _result {
                    self.delegate.events.append(.taskHadEvent(task, event: .exit(result)))
                    if !self.hadErrors {
                        switch result {
                        case let .exit(exitStatus, _) where !exitStatus.isSuccess && !exitStatus.wasCanceled:
                            self.delegate.events.append(.buildHadDiagnostic(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Command \(task.ruleInfo[0]) failed. \(RunProcessNonZeroExitError(args: Array(task.commandLineAsStrings), workingDirectory: task.workingDirectory.str, environment: .init(task.environment.bindingsDictionary), status: exitStatus, mergedOutput: output).description)"))))
                        case .failedSetup:
                            self.delegate.events.append(.buildHadDiagnostic(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Command \(task.ruleInfo[0]) failed setup."))))
                        case .exit, .skipped:
                            return
                        }
                        assert(!result.isSuccess && !result.isCancelled)
                    }
                }
            }
        }
    }

    package unowned let tester: BuildOperationTester

    /// The map of tasks, keyed by task identifier.
    package private(set) var tasksByTaskIdentifier: [TaskIdentifier: Task]

    // ruleIdentifier -> [ruleIdentifier]
    private(set) var dynamicTaskDependencies: [String: [TaskIdentifier]] = [:]

    /// The map of dynamic tasks, keyed by their task identifier (see BuildKey.CustomTask.name)
    package private(set) var dynamicTasksByTaskIdentifier: [TaskIdentifier: Task] = [:]

    private var _activeTargets: Set<ConfiguredTarget> = []
    var activeTargets: Set<ConfiguredTarget> {
        queue.blocking_sync { _activeTargets }
    }
    private var _activeTasks: Set<TaskIdentifier> = []
    var activeTasks: Set<TaskIdentifier> {
        queue.blocking_sync { _activeTasks }
    }

    /// The capturing pseudo FS.
    package let fs: (any FSProxy)?

    /// The log of build events.
    package var events = [BuildEvent]()

    /// Serial queue used to order interactions with the operation delegate.
    package let queue = SWBQueue(label: "SWBBuildSystemTests.OperationSystemAdaptor.queue", qos: UserDefaults.defaultRequestQoS)

    package init(_ tester: BuildOperationTester, tasksByTaskIdentifier: [TaskIdentifier: Task], _ fs: (any FSProxy)?) {
        self.tester = tester
        self.tasksByTaskIdentifier = tasksByTaskIdentifier
        self.fs = fs
    }

    package func getEvents() -> [BuildEvent] {
        // Wait for all outstanding messages.
        queue.blocking_sync {}

        return events
    }

    var buildHadError: Bool {
        getEvents().contains(where: { event in
            guard case .buildHadDiagnostic(let diag) = event else { return false }
            return diag.behavior == .error
        })
    }

    // MARK: BuildOperationDelegate Implementation

    func reportPathMap(_ operation: BuildOperation, copiedPathMap: [String : String], generatedFilesPathMap: [String : String]) {
        queue.async {
            self.events.append(.buildReportedPathMap(copiedPathMap: copiedPathMap, generatedFilesPathMap: generatedFilesPathMap))
        }
    }

    func buildStarted(_ operation: any BuildSystemOperation) -> any BuildOutputDelegate {
        queue.async {
            self.events.append(.buildStarted)
        }
        return TesterBuildOutputDelegate(delegate: self)
    }

    func buildComplete(_ operation: any BuildSystemOperation, status: BuildOperationEnded.Status?, delegate: any BuildOutputDelegate, metrics: BuildOperationMetrics?) -> BuildOperationEnded.Status {
        queue.async {
            // There is no "build failed" event, so only explicit cancellation needs to map to `buildCancelled`
            self.events.append(status == .cancelled ? .buildCancelled : .buildCompleted)
        }
        return status ?? .succeeded
    }

    func targetPreparationStarted(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget) {
        queue.async {
            if !self._activeTargets.insert(configuredTarget).inserted {
                Issue.record("Target '\(configuredTarget)' prepared multiple times")
            }
            self.events.append(.targetHadEvent(configuredTarget, event: .preparationStarted))
        }
    }

    func targetStarted(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget) {
        queue.async {
            self._activeTargets.insert(configuredTarget)
            self.events.append(.targetHadEvent(configuredTarget, event: .started))
        }
    }

    func targetComplete(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget) {
        queue.async {
            if self._activeTargets.remove(configuredTarget) == nil {
                Issue.record("Target '\(configuredTarget)' was never started")
            }
            self.events.append(.targetHadEvent(configuredTarget, event: .completed))
        }
    }

    func targetPreparedForIndex(_ operation: any BuildSystemOperation, target: Target, info: PreparedForIndexResultInfo) {
        queue.async {
            self.events.append(.targetPreparedForIndex(target, info))
        }
    }

    /// Caches the given `executableTask` in `tasksByTaskIdentifier` or fetches from it.
    ///
    /// **NOTE**: Don't call this from `queue` to prevent deadlock.
    private func cacheTask(for taskIdentifier: TaskIdentifier, _ executableTask: any ExecutableTask) -> Task {
        queue.blocking_sync {
            let task: Task
            if let knownTask = tasksByTaskIdentifier[taskIdentifier] {
                return knownTask
            } else if let givenTask = executableTask as? Task {
                task = givenTask
            } else {
                task = Task(executableTask)
            }

            self.tasksByTaskIdentifier[taskIdentifier] = task
            return task
        }
    }

    func taskStarted(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task executableTask: any ExecutableTask, dependencyInfo: CommandLineDependencyInfo?) -> any TaskOutputDelegate {
        let task = self.cacheTask(for: taskIdentifier, executableTask)

        queue.async {
            if !self._activeTasks.insert(taskIdentifier).inserted {
                Issue.record("Task '\(taskIdentifier)' started multiple times")
            }
            self.events.append(.taskHadEvent(task, event: .started))
        }

        var outputParser: (any TaskOutputParser)? = nil
        if let parserType = task.type.customOutputParserType(for: task) {
            let outputHandler = TestTaskOutputParserHandler(buildOperationIdentifier: .init(operation.uuid))
            outputHandler.diagnosticsEngine.addHandler { [weak self] diagnostic in
                self?._taskHadDiagnostic(task: task, diagnostic: diagnostic)
            }
            let reporter = TestSubtaskProgressReporter(delegate: self)
            outputParser = parserType.init(for: task, workspaceContext: tester.workspaceContext, buildRequestContext: operation.requestContext, delegate: outputHandler, progressReporter: reporter)
        }

        return TesterTaskOutputDelegate(task: task, operation: operation, delegate: self, parser: outputParser)
    }

    private func _taskHadDiagnostic(task: Task, diagnostic: Diagnostic) {
        self.queue.async {
            self.events.append(.taskHadEvent(task, event: .hadDiagnostic(diagnostic)))
        }
    }

    func taskRequestedDynamicTask(_ operation: any BuildSystemOperation, requestingTask: any ExecutableTask, dynamicTaskIdentifier: TaskIdentifier) {
        queue.async {
            self.dynamicTaskDependencies[requestingTask.ruleIdentifier, default: []].append(dynamicTaskIdentifier)

        }
    }

    func registeredDynamicTask(_ operation: any BuildSystemOperation, task: any ExecutableTask, dynamicTaskIdentifier: TaskIdentifier) {
        self.dynamicTasksByTaskIdentifier[dynamicTaskIdentifier] = Task(task)
    }

    func taskUpToDate(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task executableTask: any ExecutableTask) {
        let task = cacheTask(for: taskIdentifier, executableTask)
        queue.async {
            if let target = executableTask.forTarget {
                self._activeTargets.insert(target)
            }
            self.events.append(.taskHadEvent(task, event: .upToDate))
        }
    }

    func previouslyBatchedSubtaskUpToDate(_ operation: any SWBBuildSystem.BuildSystemOperation, signature: SWBUtil.ByteString, target: SWBCore.ConfiguredTarget) {
        queue.async {
            self._activeTargets.insert(target)
            self.events.append(.previouslyBatchedSubtaskUpToDate(signature))
        }
    }

    func totalCommandProgressChanged(_ operation: BuildOperation, forTargetName targetName: String?, statistics stats: BuildOperation.ProgressStatistics) {
        queue.async {
            self.events.append(.totalProgressChanged(targetName: targetName, startedCount: stats.numCommandsStarted, maxCount: stats.numPossibleMaxExecutedCommands))
        }
    }

    func taskComplete(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task executableTask: any ExecutableTask, delegate: any TaskOutputDelegate) {
        let task = cacheTask(for: taskIdentifier, executableTask)
        (delegate as? TesterTaskOutputDelegate)?.handleTaskCompletion()
        self.aggregatedCounters.merge(delegate.counters) { (a, b) in a + b }
        if !delegate.taskCounters.isEmpty {
            self.aggregatedTaskCounters[task.ruleInfo[0], default: [:]].merge(delegate.taskCounters) { (a, b) in a+b }
        }
        queue.async {
            self.tasksByTaskIdentifier[taskIdentifier] = task
            if self._activeTasks.remove(taskIdentifier) == nil {
                Issue.record("Task '\(taskIdentifier)' was never started")
            }
            self.events.append(.taskHadEvent(task, event: .completed))
        }
    }

    private var nextActivityID: Int = 0
    private var activitiesByActivityID: [Int: String] = [:]

    func beginActivity(_ operation: any BuildSystemOperation, ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        queue.blocking_sync {
            self.events.append(.activityStarted(ruleInfo: ruleInfo))
            activitiesByActivityID[nextActivityID] = ruleInfo
            defer { nextActivityID += 1 }
            return ActivityID(rawValue: nextActivityID)
        }
    }

    func endActivity(_ operation: any BuildSystemOperation, id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        queue.async {
            guard let ruleInfo = self.activitiesByActivityID.removeValue(forKey: id.rawValue) else {
                assertionFailure("Received ended message for activity id '\(id.rawValue)' but it was not started, or has already ended")
                return
            }
            self.events.append(.activityEnded(ruleInfo: ruleInfo, status: status))
        }
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        queue.async {
            guard let ruleInfo = self.activitiesByActivityID[activity.rawValue] else {
                assertionFailure("Received emit message for activity id '\(activity.rawValue)' but it was not started, or has already ended")
                return
            }
            self.events.append(.activityEmittedData(ruleInfo: ruleInfo, data))
        }
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        queue.async {
            self.events.append(.activityHadDiagnostic(activity, diagnostic))
        }
    }

    var hadErrors: Bool {
        queue.blocking_sync {
            events.contains(where: { event in
                switch event {
                case let .buildHadDiagnostic(diagnostic):
                    return diagnostic.behavior == .error
                case .targetHadEvent(_, event: .hadDiagnostic(let diagnostic)):
                    return diagnostic.behavior == .error
                case .taskHadEvent(_, event: .hadDiagnostic(let diagnostic)):
                    return diagnostic.behavior == .error
                case .activityHadDiagnostic(_, let diagnostic):
                    return diagnostic.behavior == .error
                default:
                    return false
                }
            })
        }
    }

    func updateBuildProgress(statusMessage: String, showInLog: Bool) {
        queue.async {
            self.events.append(.updatedBuildProgress(statusMessage: statusMessage, showInLog: showInLog))
        }
    }

    func recordBuildBacktraceFrame(identifier: SWBProtocol.BuildOperationBacktraceFrameEmitted.Identifier, previousFrameIdentifier: SWBProtocol.BuildOperationBacktraceFrameEmitted.Identifier?, category: SWBProtocol.BuildOperationBacktraceFrameEmitted.Category, kind: SWBProtocol.BuildOperationBacktraceFrameEmitted.Kind, description: String) {
        queue.async {
            self.events.append(.emittedBuildBacktraceFrame(identifier: identifier, previousFrameIdentifier: previousFrameIdentifier, category: category, description: description))
        }
    }
}

fileprivate func makeUniqueTargetId(_ target: ConfiguredTarget?) -> String {
    guard let target else {
        return String()
    }
    // If there is SDK related parameter use the `guid` string which is longer but more unique than just the target name.
    return target.platformDiscriminator != nil ? target.guid.stringValue : target.target.name
}

extension Task: CommandLineCheckable {
    package var commandLineAsByteStrings: [ByteString] {
        self.commandLine.map(\.asByteString)
    }
}

extension Task {
    package var ruleIdentifier: String {
        return makeUniqueTargetId(forTarget) + "::" + ruleInfo.joined(separator: " ")
    }
}

extension ExecutableTask {
    package var ruleIdentifier: String {
        return makeUniqueTargetId(forTarget) + "::" + ruleInfo.joined(separator: " ")
    }
}

extension BuildKey {
    fileprivate var taskIdentifier: TaskIdentifier? {
        if let command = self as? BuildKey.Command {
            return TaskIdentifier(rawValue: command.name)
        } else if let customTask = self as? BuildKey.CustomTask {
            return TaskIdentifier(rawValue: customTask.name)
        } else {
            // Only commands and custom tasks are tasks in Swift Build
            return nil
        }
    }
}

extension Registry: BuildSystemCache where Key == Path, Value == SystemCacheEntry {
    package func clearCachedBuildSystem(for key: Path) {
        _ = removeValue(forKey: key)
    }
}

private let buildSystemOperationQueue = AsyncOperationQueue(concurrentTasks: 6)

extension BuildSystemOperation {
    /// Runs the build system operation -- responds to cooperative cancellation and limited to 6 concurrent operations per process.
    func buildWithTimeout() async {
        await buildSystemOperationQueue.withOperation {
            do {
                try await withTimeout(timeout: .seconds(1200), description: "Build system operation 20-minute limit") {
                    await withTaskCancellationHandler {
                        await self.build()
                    } onCancel: {
                        self.cancel()
                    }
                }
            } catch {
                // always TimeoutError
                Issue.record(error)
            }
        }
    }
}
