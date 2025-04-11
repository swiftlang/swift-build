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

package import SWBBuildSystem
public import SWBCore
import SWBLibc
import SWBProtocol
import SWBServiceCore
import SWBTaskConstruction
import SWBTaskExecution
package import SWBUtil
import SWBMacro
import Synchronization

// FIXME: Workaround: <rdar://problem/26249252> Unable to prefer my own type over NS renamed types
import class SWBTaskExecution.Task

public protocol ActiveBuildOperation {
    /// A unique identifier for this build.
    var id: Int { get }

    /// Start the build in the background.
    func start()

    /// Cancel the build (asynchronously).
    func cancel()

    var buildRequest: BuildRequest { get }

    var onlyCreatesBuildDescription: Bool { get }
}

/// An active build operation.
final class ActiveBuild: ActiveBuildOperation {
    /// The delegate used for an ongoing planning operation.
    private final class PreparationProgressDelegate: PlanningOperationDelegate, BuildDescriptionConstructionDelegate, TargetDependencyResolverDelegate {
        var diagnosticContext: DiagnosticContextData {
            return DiagnosticContextData(target: nil)
        }

        private let diagnosticsDelegate: ActiveBuildDiagnosticsHandler

        func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            diagnosticsDelegate.diagnosticsEngine(for: target)
        }

        var diagnostics: [ConfiguredTarget?: [Diagnostic]] {
            diagnosticsDelegate.diagnostics
        }

        package var hadErrors: Bool {
            diagnosticsDelegate.hadErrors || hadTaskErrors
        }

        fileprivate unowned let activeBuild: ActiveBuild
        var _cancelled: LockedValue<Bool> = .init(false)
        var cancelled: Bool {
            _cancelled.withLock { $0 }
        }
        private var hadTaskErrors = false

        init(activeBuild: ActiveBuild, diagnosticsDelegate: ActiveBuildDiagnosticsHandler) {
            self.activeBuild = activeBuild
            self.diagnosticsDelegate = diagnosticsDelegate
        }

        func cancel() {
            _cancelled.withLock { $0 = true }
        }

        func updateProgress(statusMessage: String, showInLog: Bool) {
            if activeBuild.shouldSendStatusUpdate(showInLog: showInLog) {
                activeBuild.request.send(BuildOperationProgressUpdated(statusMessage: statusMessage, percentComplete: -1, showInLog: showInLog))
            }
        }

        func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
            let activity = ActivityID(rawValue: activeBuild.activeTasks.takeID())
            assert(target == nil) // not supported yet
            activeBuild.request.send(BuildOperationTaskStarted(id: activity.rawValue, targetID: nil, parentID: parentActivity?.rawValue, info: .init(taskName: executionDescription, signature: .activitySignature(signature), ruleInfo: ruleInfo, executionDescription: executionDescription, commandLineDisplayString: nil, interestingPath: nil, serializedDiagnosticsPaths: [])))
            return activity
        }

        func endActivity(id activity: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
            activeBuild.request.send(BuildOperationTaskEnded(id: activity.rawValue, signature: .activitySignature(signature), status: status, signalled: false, metrics: nil))
        }

        func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
            activeBuild.request.send(BuildOperationConsoleOutputEmitted(data: data, taskID: activity.rawValue, taskSignature: .activitySignature(signature)))
        }

        func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
            activeBuild.request.send(BuildOperationDiagnosticEmitted(diagnostic, .globalTask(taskID: activity.rawValue, taskSignature: .activitySignature(signature))))

            // We need to track this separately because errors for an "ActivityID" emitting during build description construction don't go through the diagnostics engine and are instead sent directly to the message pipe. Something to fix as part of rdar://95735413 (Unify Activity reporting API/protocols for planning and execution)
            if diagnostic.behavior == .error {
                hadTaskErrors = true
            }
        }

        func buildDescriptionCreated(_ buildDescriptionID: BuildDescriptionID) {
            activeBuild.request.send(BuildOperationReportBuildDescription(buildDescriptionID: buildDescriptionID.rawValue))
        }

        func close() {
            activeBuild.request.send(BuildOperationPreparationCompleted())
        }

        func emit(_ diagnostic: Diagnostic) {
            diagnosticsEngine.emit(diagnostic)
        }
    }

    /// The state that the build is in.
    ///
    /// Builds always transition through the states in the following order (except for cancelled).
    enum State {
        case initial
        case registered
        case starting
        case planning
        case describing
        case created
        case started
        case complete

        case cancelled
        case aborted
    }

    /// Concurrent queue used to dispatch work to the background.
    private let workQueue: SWBQueue

    /// Serial queue used to order interactions with the operation delegate.
    private let operationDelegateQueue: SWBQueue

    /// A unique identifier for this build.
    let id: Int

    /// The session we are operation within.
    let session: Session

    /// The top-level request object.
    let request: Request

    /// The workspace context the build is for.
    let workspaceContext: WorkspaceContext

    /// The original build request.
    let buildRequest: BuildRequest

    let buildRequestContext: BuildRequestContext

    /// Whether this operation is intended only for creating and reporting the build description.
    let onlyCreatesBuildDescription: Bool

    /// The current state of the build.
    var state: State

    /// The delegate used to manage reporting of diagnostics for the active build.
    fileprivate let diagnosticsHandler: ActiveBuildDiagnosticsHandler

    /// The delegate used to report the status of the active build.
    private var preparationProgressDelegate: PreparationProgressDelegate? = nil

    /// The build operation, once available.
    private var buildOperation: (any BuildSystemOperation)? = nil

    /// Rate limiter controlling how many status updates per second we are
    /// willing to send.
    private let statusRateLimiter = SWBMutex<RateLimiter>(.init(interval: .milliseconds(100)))

    // TODO: Maybe this should go in its own object/delegate that can be shared between OperationDelegate and PreparationProgressDelegate.
    fileprivate let activeTasks = ObjectIDMapping<any ExecutableTask>()

    /// Reference to the Swift Concurrency task in which the build description construction and llbuild build operation are performed.
    /// This is captured in order to be able to cancel it when ``ActiveBuild/cancel()`` is called, so that cooperative cancellation
    /// propagates to anything which may be checking for it.
    // FIXME: over time, pre-concurrency cancellation flags should transition to check the task cancellation state instead, since having two mechanisms is redundant.
    private var _buildTask: _Concurrency.Task<Void, Never>?

    init(request: Request, message: CreateBuildRequest) throws {
        self.id = request.buildService.nextBuildOperationID()

        self.onlyCreatesBuildDescription = message.onlyCreateBuildDescription

        self.session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }

        self.workspaceContext = workspaceContext
        self.state = .initial

        self.buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        self.buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        self.workQueue = SWBQueue(label: "SWBBuildService.ActiveBuild.workQueue", qos: buildRequest.qos, attributes: .concurrent, autoreleaseFrequency: .workItem)
        self.operationDelegateQueue = SWBQueue(label: "SWBBuildService.ActiveBuild.operationDelegateQueue", qos: buildRequest.qos, autoreleaseFrequency: .workItem)

        // Create the request object to track our long-lived operation.
        //
        // All code paths after this point *must* result in a response on this request.
        self.request = Request(service: request.service, channel: message.responseChannel, name: "active_build")

        self.diagnosticsHandler = ActiveBuildDiagnosticsHandler(request: self.request)
    }

    deinit {
        assert(_buildTask == nil)
    }

    func registerWithSession() throws {
        try operationDelegateQueue.blocking_sync {
            assert(state == .initial)
            state = .registered

            do {
                try session.registerActiveBuild(self)
            } catch {
                // These two lines are mostly what abortBuild() does,
                // but we need to do less because we never even started
                state = .aborted
                request.reply(ErrorResponse("build aborted due to an internal error: \(error)"))

                throw error
            }
        }
    }

    func start() {
        assert(_buildTask == nil)

        // Synchronous to avoid blocking the message queue
        _buildTask = _Concurrency.Task<Void, Never>(priority: _Concurrency.TaskPriority(buildRequestQoS: buildRequest.qos)) {
            defer { _buildTask = nil }
            await _run()
        }
    }

    func _run() async {
        let wasCancelled: Bool = await operationDelegateQueue.sync { [self] in
            if state == .cancelled {
                return true
            }

            assert(state == .registered)
            state = .starting

            // Create the delegate to track preparation progress.
            self.preparationProgressDelegate = PreparationProgressDelegate(activeBuild: self, diagnosticsDelegate: diagnosticsHandler)
            return false
        }
        if wasCancelled {
            // Nothing to do, request already completed.
            return
        }

        // Clean build folder does not need planning, constructing a build description, etc.
        if case .cleanBuildFolder(let style) = self.buildRequest.buildCommand {
            return await self.cleanBuildFolder(style)
        }

        let buildDescription: BuildDescription?
        if let buildDescriptionID = self.buildRequest.buildDescriptionID {
            buildDescription = await getExistingBuildDescription(buildDescriptionID)
        } else {
            let result = await planBuild()

            guard let planRequest = result else {
                if let delegate = self.preparationProgressDelegate, delegate.hadErrors {
                    // The actual error diagnostics causing us to abort the build here will have been emitted back to the client when the abort error response is handled at that layer.
                    self.abortBuild(BuildOperationError.planningFailed)
                } else {
                    self.completeBuild(status: .cancelled, metrics: nil)
                }
                return
            }

            // Compute the build description.
            buildDescription = await describeBuild(planRequest)
        }

        guard let description = buildDescription else {
            self.completeBuild(status: .cancelled, metrics: nil)
            return
        }

        self.preparationProgressDelegate?.buildDescriptionCreated(description.ID)

        guard !self.onlyCreatesBuildDescription else {
            self.completeBuild(status: .succeeded, metrics: nil)
            return
        }

        // Create the build operation.
        let result = await createBuild(description)

        guard let operation = result else {
            self.completeBuild(status: .cancelled, metrics: nil)
            return
        }

        // Start the build.
        await self.runBuild(operation)
    }

    func cancel() {
        operationDelegateQueue.async {
            // If we are complete or aborted, we do not need to cancel the build.
            if self.state == .complete || self.state == .aborted { return }

            if self.state == .registered {
                self.state = .cancelled
                self.workQueue.async {
                    self.completeBuild(status: .cancelled, metrics: nil)
                }
                return
            }

            self.state = .cancelled

            self.preparationProgressDelegate?.cancel()

            self.buildOperation?.cancel()
            self._buildTask?.cancel()
        }
    }

    /// Abort the build on a fatal error.
    fileprivate func abortBuild(_ error: any Error) {
        operationDelegateQueue.blocking_sync {
            state = .aborted
            updateCompletedBuildStateAndReply(withMessage: ErrorResponse("build aborted due to an internal error: \(error)"))
        }
    }

    /// Complete the build.
    fileprivate func completeBuild(status: BuildOperationEnded.Status, metrics: BuildOperationMetrics?) {
        operationDelegateQueue.blocking_sync {
            if state == .aborted { return }

            // The state must either be cancelled or started, unless it is for build description creation.
            assert(state == .cancelled || (state == .started && !onlyCreatesBuildDescription) || (state == .describing && onlyCreatesBuildDescription))

            updateCompletedBuildStateAndReply(withMessage: BuildOperationEnded(id: self.id, status: status, metrics: metrics))
        }
    }

    private func updateCompletedBuildStateAndReply(withMessage message: any Message) {
        // Ensure we always report preparation as complete, even if cancelled.
        preparationProgressDelegate?.close()
        preparationProgressDelegate = nil

        // Unregister the build operation before sending the final reply,
        // so that clients can be confident that there are no active
        // build operations once the reply message has been received.
        session.unregisterActiveBuild(self)
        buildOperation = nil

        // reply() enqueues a message to be sent asynchronously, so it
        // should be called last.
        request.reply(message)
    }

    // MARK: Suboperations

    private func planBuild() async -> BuildPlanRequest? {
        let operation: PlanningOperation? = await operationDelegateQueue.sync {
            if self.state == .cancelled {
                return nil
            }

            assert(self.state == .starting)
            self.state = .planning

            return self.session.createPlanningOperation(request: self.request, workspaceContext: self.workspaceContext, buildRequest: self.buildRequest, buildRequestContext: self.buildRequestContext, delegate: self.preparationProgressDelegate!)
        }

        guard let operation else {
            return nil
        }

        let result = await operation.plan()
        await self.operationDelegateQueue.sync {
            // Discard the planning operation now that the build operation has been created.
            self.session.discardPlanningOperation(operation.uuid)
        }
        return result
    }

    private func describeBuild(_ planRequest: BuildPlanRequest) async -> BuildDescription? {
        let isCancelled = await operationDelegateQueue.sync {
            if self.state == .cancelled {
                return true
            }

            assert(self.state == .planning)
            self.state = .describing
            return false
        }

        if isCancelled {
            return nil
        }

        // Construct the build description.
        do {
            let preparationDelegate = self.preparationProgressDelegate!
            let clientDelegate = ClientExchangeDelegate(request: self.request, session: self.session)
            // FIXME: We should have a channel for reporting errors here which don't make it look like there was an internal service error. E.g., if we fail to create or write the build description or manifest because of some error outside of our control, we should simply report that and not make it look like we might have a bug.
            let description = try await MacroNamespace.withExpressionInterningEnabled { try await self.session.buildDescriptionManager.getBuildDescription(planRequest, clientDelegate: clientDelegate, constructionDelegate: preparationDelegate) }
            return description
        } catch {
            self.abortBuild(error)
            return nil
        }
    }

    private func getExistingBuildDescription(_ buildDescriptionID: BuildDescriptionID) async -> BuildDescription? {
        let isCancelled = await operationDelegateQueue.sync {
            if self.state == .cancelled {
                return true
            }

            assert(self.state == .starting)
            self.state = .describing
            return false
        }

        if isCancelled {
            return nil
        }

        do {
            let clientDelegate = ClientExchangeDelegate(request: self.request, session: self.session)
            let descRequest = BuildDescriptionManager.BuildDescriptionRequest.cachedOnly(buildDescriptionID, request: self.buildRequest, buildRequestContext: self.buildRequestContext, workspaceContext: self.workspaceContext)
            let retrievedBuildDescription = try await self.session.buildDescriptionManager.getNewOrCachedBuildDescription(descRequest, clientDelegate: clientDelegate, constructionDelegate: self.preparationProgressDelegate!)
            return retrievedBuildDescription?.buildDescription
        } catch {
            self.abortBuild(error)
            return nil
        }
    }

    private func createBuild(_ description: BuildDescription) async -> BuildOperation? {
        await operationDelegateQueue.sync {
            if self.state == .cancelled {
                return nil
            }

            assert(self.state == .describing)
            self.state = .created

            // Create the build operation.
            let clientDelegate = ClientExchangeDelegate(request: self.request, session: self.session)
            let operation = self.request.buildService.buildManager.enqueue(request: self.buildRequest, buildRequestContext: self.buildRequestContext, workspaceContext: self.workspaceContext, description: description, operationDelegate: OperationDelegate(activeBuild: self), clientDelegate: clientDelegate)
            self.buildOperation = operation
            return operation
        }
    }

    private func runBuild(_ buildOperation: any BuildSystemOperation) async {
        let wasCancelled: Bool = await operationDelegateQueue.sync { [self] in
            if state == .cancelled {
                return true
            }

            assert(state == .created)
            state = .started

            if case .cleanBuildFolder(_) = buildRequest.buildCommand {} else {
                // Once we have reached this point, we are done reporting preparation progress.
                let statusMessage = workspaceContext.userPreferences.activityTextShorteningLevel == .full ? "Starting" : "Starting build"
                preparationProgressDelegate!.updateProgress(statusMessage: statusMessage, showInLog: false)
                preparationProgressDelegate!.close()
                preparationProgressDelegate = nil
            }

            return false
        }

        // If the build was cancelled when we tried to start then complete it now.
        //
        // We defer this from execution in the block above because it must also be synchronous on the same queue.
        if wasCancelled {
            completeBuild(status: .cancelled, metrics: nil)
        } else {
            await request.buildService.buildManager.runBuild(buildOperation)
        }
    }

    private func cleanBuildFolder(_ style: BuildLocationStyle) async {
        let cleanOperation = await workQueue.sync {
            assert(self.state == .initial || self.state == .starting)
            let cleanOperation = self.request.buildService.buildManager.enqueueClean(request: self.buildRequest, buildRequestContext: self.buildRequestContext, workspaceContext: self.workspaceContext, style: style, operationDelegate: OperationDelegate(activeBuild: self), dependencyResolverDelegate: self.preparationProgressDelegate)
            self.buildOperation = cleanOperation
            self.state = .created
            return cleanOperation
        }

        await self.runBuild(cleanOperation)
    }

    /// Check whether it is appropriate to send a status update.
    fileprivate func shouldSendStatusUpdate(showInLog: Bool) -> Bool {
        // If we should show in the log, always send.
        if showInLog {
            return true
        }

        // If we aren't sending non-log progress, don't send.
        if !buildRequest.showNonLoggedProgress {
            return false
        }

        // Otherwise, don't send updates faster than a certain rate, the
        // UI/human cannot register them any faster than that, so it is just
        // wasteful of CPU. This is particularly important for null builds,
        // where the status updates can easily be more expensive than the actual
        // build work.
        return statusRateLimiter.withLock { statusRateLimiter in
            return statusRateLimiter.hasNextIntervalPassed()
        }
    }
}


// FIXME: This needs to be factored out as a reusable ObjectIDMapping soon (it's not actually set since it doesn't implement the actual Set protocol).
private final class ObjectIDMapping<T> {
    private struct State {
        // FIXME: Switch this to Atomic and move out of the lock, when available.
        var nextID = Int(1)
        var objsToIDs: [Ref<T>: Int] = [:]

        mutating func takeID() -> Int {
            defer{ nextID += 1 }
            return nextID
        }
    }

    private var state: LockedValue<State> = .init(State())

    func takeID() -> Int {
        return state.withLock { state in
            return state.takeID()
        }
    }

    func insert(_ obj: T) -> Int {
        return state.withLock { state in
            let objRef = Ref<T>(obj)
            precondition(state.objsToIDs[objRef] == nil)
            let id = state.takeID()
            state.objsToIDs[objRef] = id
            return id
        }
    }
    func lookup(_ obj: T) -> Int? {
        return state.withLock { state in
            let objRef = Ref<T>(obj)
            return state.objsToIDs[objRef]
        }
    }
    func remove(_ obj: T) -> Int {
        return state.withLock { state in
            let objRef = Ref<T>(obj)
            let id = state.objsToIDs.removeValue(forKey: objRef)
            precondition(id != nil)
            return id!
        }
    }
}

final class ActiveBuildDiagnosticsHandler: TargetDiagnosticProducingDelegate {
    let request: Request

    init(request: Request) {
        self.request = request
    }

    var diagnosticContext: DiagnosticContextData {
        return .init(target: nil)
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return targetDiagnosticsEngines.withLock { targetDiagnosticsEngines in
            .init(targetDiagnosticsEngines.getOrInsert(target, {
                let engine = DiagnosticsEngine()
                if target == nil {
                    let request = self.request
                    engine.addHandler { diag in
                        sendDiagnosticMessage(request, diag, .global)
                    }
                }
                return engine
            }))
        }
    }

    var diagnostics: [ConfiguredTarget?: [Diagnostic]] {
        targetDiagnosticsEngines.withLock { targetDiagnosticsEngines in
            targetDiagnosticsEngines.mapValues {
                $0.diagnostics
            }
        }
    }

    var hadErrors: Bool {
        targetDiagnosticsEngines.withLock { targetDiagnosticsEngines in
            targetDiagnosticsEngines.values.contains(where: { $0.diagnostics.contains(where: { $0.behavior == .error }) })
        }
    }

    /// Map of targets to diagnostics engines.
    /// The build output collector will defer emission of these diagnostics to the diagnostics engine until after the necessary target context has been created by the build operation.
    private let targetDiagnosticsEngines = SWBMutex<[ConfiguredTarget?: DiagnosticsEngine]>([:])

    fileprivate func emitDeferredTargetDiagnostics(for target: ConfiguredTarget, withID targetID: Int) {
        if let engine = targetDiagnosticsEngines.withLock({ $0.removeValue(forKey: target) }) {
            for diag in engine.diagnostics {
                sendDiagnosticMessage(request, diag, targetID: targetID, taskInfo: nil)
            }
        }
    }

    fileprivate var deferredTargets: [ConfiguredTarget] {
        targetDiagnosticsEngines.withLock { targetDiagnosticsEngines in
            Array(targetDiagnosticsEngines.keys.compactMap { $0 })
        }
    }
}

/// Helper function for dispatching a diagnostic.
private func sendDiagnosticMessage(_ request: Request, _ diagnostic: Diagnostic, targetID: Int?, taskInfo: (taskID: Int, taskSignature: BuildOperationTaskSignature)?) {
    switch (targetID, taskInfo) {
    case let (targetID?, taskInfo?):
        sendDiagnosticMessage(request, diagnostic, .task(taskID: taskInfo.taskID, taskSignature: taskInfo.taskSignature, targetID: targetID))
    case let (targetID?, nil):
        sendDiagnosticMessage(request, diagnostic, .target(targetID: targetID))
    case let (nil, taskInfo?):
        sendDiagnosticMessage(request, diagnostic, .globalTask(taskID: taskInfo.taskID, taskSignature: taskInfo.taskSignature))
    case (nil, nil):
        sendDiagnosticMessage(request, diagnostic, .global)
    }
}

/// Helper function for dispatching a diagnostic.
private func sendDiagnosticMessage(_ request: Request, _ diagnostic: Diagnostic, _ locationContext: BuildOperationDiagnosticEmitted.LocationContext) {
    request.send(BuildOperationDiagnosticEmitted(diagnostic, locationContext))
}

/// The task output delegate, which collects the output for sending back to the service.
private final class TaskOutputHandler: TaskOutputDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()
    let taskID: Int
    let taskSignature: BuildOperationTaskSignature
    // Consider replacing with a target signature in the future.
    let targetID: Int?
    private unowned let operation: any BuildSystemOperation
    let operationDelegate: OperationDelegate
    let parser: (any TaskOutputParser)?

    /// Wall clock time at which the task was started - NOT used to compute durations.
    package let startTime = Date()

    /// Measures the elapsed time of a build task.
    package let timer = ElapsedTimer()

    static let outputBufferSize = 10 * 1024
    private var outputBuffer: [UInt8]

    var result: TaskResult? = nil
    var request: Request { return operationDelegate.request }

    var counters: [BuildOperationMetrics.Counter: Int] = [:]
    var taskCounters: [BuildOperationMetrics.TaskCounter: Int] = [:]

    init(taskID: Int, taskSignature: BuildOperationTaskSignature, targetID: Int?, operation: any BuildSystemOperation, operationDelegate: OperationDelegate, parser: (any TaskOutputParser)?) {
        self.taskID = taskID
        self.taskSignature = taskSignature
        self.targetID = targetID
        self.operation = operation
        self.operationDelegate = operationDelegate
        self.parser = parser
        self.outputBuffer = Array<UInt8>()
        self.outputBuffer.reserveCapacity(Self.outputBufferSize)
        self._diagnosticsEngine.addHandler { [weak self] diag in
            let `self` = self!
            if diag.behavior == .error {
                self.operationDelegate.numErrors += 1
            }
            sendDiagnosticMessage(self.request, diag, targetID: targetID, taskInfo: (taskID, taskSignature))
        }
    }

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

    var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    func emitOutput(_ data: ByteString) {
        // If we have a custom parser, feed it the data.
        if let parser = self.parser {
            parser.write(bytes: data)
        } else {
            if !data.bytes.isEmpty {
                if outputBuffer.count + data.bytes.count > Self.outputBufferSize {
                    flushBufferedOutput()
                }
                outputBuffer.append(contentsOf: data.bytes)
            }
        }
    }

    private func flushBufferedOutput() {
        guard !outputBuffer.isEmpty else { return }
        request.send(BuildOperationConsoleOutputEmitted(data: outputBuffer, taskID: taskID, taskSignature: taskSignature))
        outputBuffer.removeAll(keepingCapacity: true)
    }

    func subtaskUpToDate(_ subtask: any ExecutableTask) {
        let taskIdentifier = TaskIdentifier(forTarget: subtask.forTarget, ruleInfo: subtask.ruleInfo, priority: subtask.priority)
        operationDelegate.taskUpToDate(operation, taskIdentifier: taskIdentifier, task: subtask)
    }

    func previouslyBatchedSubtaskUpToDate(signature: ByteString, target: ConfiguredTarget) {
        operationDelegate.previouslyBatchedSubtaskUpToDate(operation, signature: signature, target: target)
    }

    func updateResult(_ result: TaskResult) {
        self.result = result
    }

    func handleTaskCompletion() {
        flushBufferedOutput()
        // Close the parser, if in use.
        parser?.close(result: result)
    }
}

/// Compute the command line display string to use for a task.
package func commandLineDisplayString(
    _ commandLine: [ByteString],
    additionalOutput: [String],
    workingDirectory: Path?,
    environment: EnvironmentBindings?,
    dependencyInfo: CommandLineDependencyInfo?
) -> String {
    // Compute the command line display string.
    //
    // FIXME: See similar code in primary task started method.
    let codec = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .fullCommandLine)
    let stream = OutputByteStream()
    let indent = "    "
    if let workingDirectory {
        stream <<< indent <<< codec.encode(["cd", workingDirectory.str]) <<< "\n"
    }
    if let environment {
        for (key, value) in environment.bindings.sorted(by: { $0.0 < $1.0 }) {
            stream <<< indent <<< codec.encode(["export", "\(key)=\(value)"]) <<< "\n"
        }
    }

    // Indent each line of the additional output, even if it's empty.  Also bracket it with empty lines to make it slightly more prominent in the transcript.
    // In theory, if any line itself contains newlines we could break it up to indent them as well, but we don't yet do that.
    if !additionalOutput.isEmpty {
        stream <<< indent <<< "\n"
        for line in additionalOutput {
            stream <<< indent <<< line <<< "\n"
        }
        stream <<< indent <<< "\n"
    }

    stream <<< indent <<< codec.encode(commandLine.map { $0.unsafeStringValue }) <<< "\n"

    if let dependencyInfo {
        do {
            stream <<< "\n"
            stream <<< indent <<< "Task input dependencies:" <<< "\n"
            for input in dependencyInfo.inputDependencyPaths.map({ $0.str }) + dependencyInfo.executionInputIdentifiers {
                stream <<< indent <<< indent <<< input <<< "\n"
            }
        }

        do {
            stream <<< "\n"
            stream <<< indent <<< "Task output dependencies:" <<< "\n"
            for output in dependencyInfo.outputDependencyPaths.map({ $0.str }) {
                stream <<< indent <<< indent <<< output <<< "\n"
            }
        }
    }

    return stream.bytes.asString
}

extension BuildOperationTaskEnded.Status {
    init(_ exitStatus: Processes.ExitStatus) {
        switch exitStatus {
        case _ where exitStatus.isSuccess:
            self = .succeeded
        case _ where exitStatus.wasCanceled:
            self = .cancelled
        default:
            self = .failed
        }
    }
}

/// An adaptor for binding custom output parsers back to the service.
private final class TaskOutputParserHandler: TaskOutputParserDelegate {
    let buildOperationIdentifier: BuildSystemOperationIdentifier

    let diagnosticsEngine = DiagnosticsEngine()
    private let buildRequest: BuildRequest
    let taskID: Int
    let taskSignature: BuildOperationTaskSignature
    // Consider replacing with a target signature in the future.
    let targetID: Int?
    // This has to be late bound, because we have a cycle.
    unowned var handler: TaskOutputHandler!

    static let outputBufferSize = 10 * 1024
    private var outputBuffer: [UInt8]
    private var closed = false

    init(buildOperationIdentifier: BuildSystemOperationIdentifier, taskID: Int, taskSignature: BuildOperationTaskSignature, targetID: Int?, buildRequest: BuildRequest) {
        self.buildOperationIdentifier = buildOperationIdentifier
        self.taskID = taskID
        self.taskSignature = taskSignature
        self.targetID = targetID
        self.buildRequest = buildRequest
        self.outputBuffer = Array<UInt8>()
        self.outputBuffer.reserveCapacity(Self.outputBufferSize)
        self.diagnosticsEngine.addHandler { [weak self] diag in
            assert(self != nil)
            guard let `self` = self else { return }
            if diag.behavior == .error {
                self.handler.operationDelegate.numErrors += 1
            }
            sendDiagnosticMessage(self.handler.request, diag, targetID: targetID, taskInfo: (taskID, taskSignature))
        }
    }

    func skippedSubtask(signature: ByteString) {
        handler.request.send(BuildOperationTaskUpToDate(signature: .subtaskSignature(signature), targetID: targetID, parentID: handler.taskID))
    }

    func startSubtask(buildOperationIdentifier: BuildSystemOperationIdentifier, taskName: String, id: ByteString, signature: ByteString, ruleInfo: String, executionDescription: String, commandLine: [ByteString], additionalOutput: [String], interestingPath: Path?, workingDirectory: Path?, serializedDiagnosticsPaths: [Path]) -> any TaskOutputParserDelegate {
        // Create a new subtask.
        let subtaskID = handler.operationDelegate.activeTasks.takeID()
        let outputHandler = TaskOutputParserHandler(buildOperationIdentifier: buildOperationIdentifier, taskID: subtaskID, taskSignature: .subtaskSignature(signature), targetID: targetID, buildRequest: self.buildRequest)
        outputHandler.handler = handler

        let displayString = commandLineDisplayString(commandLine, additionalOutput: additionalOutput, workingDirectory: workingDirectory, environment: nil, dependencyInfo: nil)

        let info = BuildOperationTaskInfo(taskName: taskName, signature: .subtaskSignature(signature), ruleInfo: ruleInfo, executionDescription: executionDescription, commandLineDisplayString: displayString, interestingPath: interestingPath, serializedDiagnosticsPaths: serializedDiagnosticsPaths)

        handler.request.send(BuildOperationTaskStarted(id: subtaskID, targetID: targetID, parentID: handler.taskID, info: info))
        return outputHandler
    }

    func emitOutput(_ data: ByteString) {
        if !data.bytes.isEmpty {
            if outputBuffer.count + data.bytes.count > Self.outputBufferSize {
                flushBufferedOutput()
            }
            outputBuffer.append(contentsOf: data.bytes)
        }
    }

    private func flushBufferedOutput() {
        guard !outputBuffer.isEmpty else { return }
        handler.request.send(BuildOperationConsoleOutputEmitted(data: outputBuffer, taskID: taskID, taskSignature: taskSignature))
        outputBuffer.removeAll(keepingCapacity: true)
    }

    func close() {
        flushBufferedOutput()
        closed = true
    }

    func taskCompleted(exitStatus: Processes.ExitStatus) {
        // ConsoleOutputEmittedMessages must be sent before a TaskEnded message, so flush output here.
        flushBufferedOutput()
        handler.request.send(BuildOperationTaskEnded(id: taskID, signature: taskSignature, status: .init(exitStatus), signalled: exitStatus.wasSignaled, metrics: nil))
    }

    deinit {
        if !closed {
            assertionFailure("Expected TaskOutputParserHandler to be closed before deinit")
        }
    }
}

/// A task output collector which simply discards any data it receives.
private final class DiscardingTaskOutputHandler: TaskOutputDelegate {
    var counters: [BuildOperationMetrics.Counter : Int] = [:]
    var taskCounters: [BuildOperationMetrics.TaskCounter : Int] = [:]

    private let _diagnosticsEngine = DiagnosticsEngine()
    var result: TaskResult? { nil }
    let startTime = Date()

    init() {}

    var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    func emitOutput(_ data: ByteString) {}
    func handleTaskCompletion() {}
    func subtaskUpToDate(_ subtask: any ExecutableTask) {}
    func previouslyBatchedSubtaskUpToDate(signature: ByteString, target: ConfiguredTarget) {}
    func updateResult(_ result: TaskResult) {}
    func incrementClangCacheHit() {}
    func incrementClangCacheMiss() {}
    func incrementSwiftCacheHit() {}
    func incrementSwiftCacheMiss() {}
    func incrementTaskCounter(_ counter: BuildOperationMetrics.TaskCounter) {}
}

/// The build output delegate, which sends data back immediately.
final class BuildOutputCollector: BuildOutputDelegate {
    private let diagnosticsDelegate: any TargetDiagnosticProducingDelegate

    let diagnosticContext: DiagnosticContextData = .init(target: nil)

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        diagnosticsDelegate.diagnosticsEngine(for: target)
    }

    init(diagnosticsDelegate: any TargetDiagnosticProducingDelegate) {
        self.diagnosticsDelegate = diagnosticsDelegate
    }
}

/// The delegate used for a running build operation.
///
/// The delegate responds to delegate messages by sending build service protocol messages to the client.
///
/// NOTE: The operation guarantees that all messages sent to this delegate are done serially, so this delegate is *not* thread safe.
final class OperationDelegate: BuildOperationDelegate {
    final class TargetInfo {
        /// The ID of this target, unique within one operation.
        let id: Int

        /// Whether the target has actually started executing (some task within it is executing).
        var hasStarted: Bool = false

        /// The buffered list of any up-to-date task which have run before the target starts. These are dispatched immediately after the target starts.
        var upToDateTaskSignatures: [BuildOperationTaskSignature] = []

        init(id: Int) {
            self.id = id
        }
    }

    fileprivate unowned let activeBuild: ActiveBuild
    private var activeTargets = LockedValue<[ConfiguredTarget.GUID: TargetInfo]>([:])
    fileprivate var activeTasks: ObjectIDMapping<any ExecutableTask> {
        activeBuild.activeTasks
    }

    /// The running count of how many tasks have been started, for progress reporting purposes.
    private var numStartedTasks = 0

    /// Whether to skip reporting any task information.
    ///
    /// This is useful for estimating the overhead of log reporting (although
    /// this doesn't measure the cost in the build operation itself to provide
    /// this data).
    let skipCommandLevelInformation: Bool

    /// The proxy FS is nil, to disable proxying completely.
    let fs: (any FSProxy)? = nil

    /// The number of errors.
    var numErrors = 0

    /// The next unique target ID to use (protected by synchronous operation callback model).
    var nextTargetID = 0

    /// The build operation status.  This is used to abstract a represent the complicated logic which determined whether the build failed.  Note that this status could be anything while the build is in progress, and thus should not be used to determine other characteristics, e.g. whether the build is finished.
    ///
    /// Its value is set when a build task completes. If any task was cancelled, the status is cancelled. Otherwise, if any task failed, the status is cancelled. Finally, if no tasks were cancelled or failed, we presume the build succeeded.
    private var taskCompletionBasedStatus: BuildOperationEnded.Status = .succeeded

    // Summary of metrics during the build
    var aggregatedCounters: [BuildOperationMetrics.Counter: Int] = [:]
    var aggregatedTaskCounters: [String: [BuildOperationMetrics.TaskCounter: Int]] = [:]

    fileprivate var session: Session {
        return activeBuild.session
    }

    fileprivate var request: Request {
        return activeBuild.request
    }

    private var diagnosticsHandler: ActiveBuildDiagnosticsHandler {
        return activeBuild.diagnosticsHandler
    }

    private var workspaceContext: WorkspaceContext {
        return activeBuild.workspaceContext
    }

    init(activeBuild: ActiveBuild) {
        self.activeBuild = activeBuild
        self.skipCommandLevelInformation = UserDefaults.skipLogReporting
    }

    private var outputCollector: BuildOutputCollector?

    func buildStarted(_ operation: any BuildSystemOperation) -> any BuildOutputDelegate {
        request.send(BuildOperationStarted(id: activeBuild.id))
        let outputCollector = BuildOutputCollector(diagnosticsDelegate: diagnosticsHandler)
        self.outputCollector = outputCollector
        return outputCollector
    }

    func reportPathMap(_ operation: BuildOperation, copiedPathMap: [String : String], generatedFilesPathMap: [String : String]) {
        request.send(BuildOperationReportPathMap(copiedPathMap: copiedPathMap, generatedFilesPathMap: generatedFilesPathMap))
    }

    func buildComplete(_ operation: any BuildSystemOperation, status: BuildOperationEnded.Status?, delegate: any BuildOutputDelegate, metrics: BuildOperationMetrics?) -> BuildOperationEnded.Status {
        if !skipCommandLevelInformation {
            // Kick the target callbacks so that our target-level diagnostics get emitted in the right context in the case of an early build failure due to task construction errors.
            for target in diagnosticsHandler.deferredTargets {
                targetStarted(operation, configuredTarget: target)
                targetComplete(operation, configuredTarget: target)
            }
        }
        let realStatus = status ?? taskCompletionBasedStatus
        activeBuild.completeBuild(status: realStatus, metrics: metrics)
        return realStatus
    }

    private func getActiveTargetInfo(_ operation: any BuildSystemOperation, _ configuredTarget: ConfiguredTarget) -> TargetInfo {
        activeTargets.withLock { activeTargets in
            if !activeTargets.contains(configuredTarget.guid) {
                activeTargets[configuredTarget.guid] = TargetInfo(id: nextTargetID)
                nextTargetID += 1
            }
            return activeTargets[configuredTarget.guid]!
        }
    }

    func targetPreparationStarted(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget) {
        activeTargets.withLock { activeTargets in
            assert(!activeTargets.contains(configuredTarget.guid))
            activeTargets[configuredTarget.guid] = TargetInfo(id: nextTargetID)
            nextTargetID += 1
        }
    }

    func targetStarted(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget) {
        guard !skipCommandLevelInformation else { return }

        // Get the target info.
        let targetInfo = getActiveTargetInfo(operation, configuredTarget)
        let targetID = targetInfo.id

        // Send the target-did-start message.
        //
        // We also send back a snapshot of the information on the target we have, since we are in a better position to retrieve it (rather than force the client to have an immutable cache).
        //
        // FIXME: Compute configurationIsDefault correctly.
        // FIXME (rdar://53726633): It's really not safe to be using the `target` property off of the `configuredTarget` due to the fact that this can hold old references to project model items if the PIF/build descriptions are re-used, but the project model instances are re-created. This is a targeted fix for rdar://50962080, which should be address more correctly later.
        guard let target = workspaceContext.workspace.target(for: configuredTarget.target.guid) else {
            preconditionFailure("Unable to find target '\(configuredTarget.target.name)' in workspace '\(workspaceContext.workspace.name)'.")
        }

        let targetType: BuildOperationTargetType = {
            switch target.type {
            case .aggregate: return .aggregate
            case .external: return .external
            case .packageProduct: return .packageProduct
            case .standard: return .standard
            }
        }()
        // FIXME: It is unfortunate we have to query this again here; we should be able to get it from the operation.
        let settings = operation.requestContext.getCachedSettings(configuredTarget.parameters, target: target)
        let project = settings.project!
        let sdkCanonicalName = settings.sdk?.canonicalName
        let info = BuildOperationTargetInfo(name: target.name, type: targetType, projectInfo: BuildOperationProjectInfo(name: project.name, path: project.xcodeprojPath.str, isPackage: project.isPackage, isNameUniqueInWorkspace: workspaceContext.workspace.projects(named: project.name).count <= 1), configurationName: settings.targetConfiguration?.name ?? "", configurationIsDefault: false, sdkCanonicalName: sdkCanonicalName)
        request.send(BuildOperationTargetStarted(id: targetID, guid: configuredTarget.target.guid, info: info))

        // Mark the target as started, if necessary.
        if !targetInfo.hasStarted {
            targetInfo.hasStarted = true
            // Flush any pending up-to-date task notifications.
            for signature in targetInfo.upToDateTaskSignatures {
                request.send(BuildOperationTaskUpToDate(signature: signature, targetID: targetInfo.id))
            }
            targetInfo.upToDateTaskSignatures.removeAll(keepingCapacity: false)
        }

        diagnosticsHandler.emitDeferredTargetDiagnostics(for: configuredTarget, withID: targetID)
    }

    func targetComplete(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget) {
        // Pop the target info.
        let targetInfo = activeTargets.withLock { activeTargets in activeTargets.removeValue(forKey: configuredTarget.guid)! }

        guard !skipCommandLevelInformation else { return }

        // Send the appropriate finalization message.
        if targetInfo.hasStarted {
            request.send(BuildOperationTargetEnded(id: targetInfo.id))
        } else {
            request.send(BuildOperationTargetUpToDate(guid: configuredTarget.target.guid))
        }
    }

    func totalCommandProgressChanged(_ operation: BuildOperation, forTargetName targetName: String? = nil, statistics stats: BuildOperation.ProgressStatistics) {
        guard !skipCommandLevelInformation else { return }

        // Check if we should send progress status.
        guard activeBuild.shouldSendStatusUpdate(showInLog: false) else { return }

        let maxTotalTasks = max(stats.numCommandsScanned, stats.numCommandsLowerBound)

        // Compute the amount of scanning completed.
        let scanningProgress = Double(stats.numCommandsCompleted) / Double(max(1, maxTotalTasks))

        // Compute the amount of actual work completed.
        let executionProgress = Double(stats.numCommandsStarted) / Double(max(1, stats.numPossibleMaxExecutedCommands))

        // We currently show the percent completed as a combination of the scanning progress and execution progress.
        //
        // The scanning progress is as if we were considering the whole build from scratch -- i.e. the number of commands retired over the total number of commands. This ensures that this number will always progress orderly throughout the build, but it has the downside that it isn't the "percent complete" of the actual build.
        //
        // The execution progress is more likely to be where the real time is spent (if work needs to be done), but it doesn't give much granularity for large builds which are largely up-to-date.
        //
        // We currently use a complete ad hoc blend of these two numbers with 20% weighted for scanning.
        let percentComplete = 20.0 * scanningProgress + 80.0 * executionProgress

        // On the other hand, we report that status message itself in terms of the number of commands executed versus the maximum number of commands which might be required to be executed.

        let messageShortening = workspaceContext.userPreferences.activityTextShorteningLevel

        // If we haven't started, show a custom message (to prevent a "Building 0" message).
        if stats.numCommandsStarted == 0 {
            if  messageShortening != .full || workspaceContext.userPreferences.enableDebugActivityLogs {
                request.send(BuildOperationProgressUpdated(targetName: targetName, statusMessage: "Scanning build tasks", percentComplete: percentComplete, showInLog: false))
            }
        } else {
            let statusMessage = messageShortening > .legacy
                ? activityMessageFractionString(stats.numCommandsStarted, over: stats.numPossibleMaxExecutedCommands)
                : "Building \(stats.numCommandsStarted) of \(stats.numPossibleMaxExecutedCommands) tasks"
            request.send(BuildOperationProgressUpdated(targetName: targetName, statusMessage: statusMessage, percentComplete: percentComplete, showInLog: false))
        }
    }

    func taskUpToDate(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task: any ExecutableTask) {
        guard !skipCommandLevelInformation else { return }

        // Ignore hidden tasks for output purposes.
        guard task.showInLog else { return }

        guard let target = task.forTarget else {
            request.send(BuildOperationTaskUpToDate(signature: .taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue)), targetID: nil))
            return
        }

        // If this target has started, issue the notification immediately.
        let targetInfo = getActiveTargetInfo(operation, target)
        if targetInfo.hasStarted {
            request.send(BuildOperationTaskUpToDate(signature: .taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue)), targetID: targetInfo.id))
        } else {
            // Otherwise, buffer the information so that we can avoid needing to notify the client until the target actually starts. This optimizes for a common case where no tasks will run in a target, and we can just notify the client the target was up-to-date.
            targetInfo.upToDateTaskSignatures.append(.taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue)))
        }
    }

    func previouslyBatchedSubtaskUpToDate(_ operation: any BuildSystemOperation, signature: ByteString, target: ConfiguredTarget) {
        guard !skipCommandLevelInformation else { return }

        // If this target has started, issue the notification immediately.
        let targetInfo = getActiveTargetInfo(operation, target)
        if targetInfo.hasStarted {
            request.send(BuildOperationTaskUpToDate(signature: .subtaskSignature(signature), targetID: targetInfo.id))
        } else {
            // Otherwise, buffer the information so that we can avoid needing to notify the client until the target actually starts. This optimizes for a common case where no tasks will run in a target, and we can just notify the client the target was up-to-date.
            targetInfo.upToDateTaskSignatures.append(.subtaskSignature(signature))
        }
    }

    func taskStarted(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task: any ExecutableTask, dependencyInfo: CommandLineDependencyInfo?) -> any TaskOutputDelegate {
        guard !skipCommandLevelInformation else {
            return DiscardingTaskOutputHandler()
        }

        // Ignore tasks that are hidden for output purposes.
        guard task.showInLog else {
            return DiscardingTaskOutputHandler()
        }

        let targetID: Int?
        if let forTarget = task.forTarget {
            // Get the target ID associated with the task.
            let targetInfo = getActiveTargetInfo(operation, forTarget)
            assert(targetInfo.hasStarted)
            targetID = targetInfo.id
        } else {
            targetID = nil
        }

        // Insert the task in the tasks-to-ids mapping, which assigns and returns a new id.
        assert(activeTasks.lookup(task) == nil)
        let taskID = activeTasks.insert(task)

        // Send the task-did-start message.
        //
        // FIXME: Convert everything here to bytes.
        let environmentToShow = (task.showEnvironment && !operation.request.hideShellScriptEnvironment) ? task.environment : nil

        // Get the interesting path for the task.
        let interestingPath = task.type.interestingPath(for: task)

        let taskSpec = task.type as? Spec
        let info = BuildOperationTaskInfo(taskName: taskSpec?.name ?? "", signature: .taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue)), ruleInfo: task.ruleInfo.quotedDescription, executionDescription: (task.execDescription ?? task.ruleInfo.quotedDescription), commandLineDisplayString: task.showCommandLineInLog ? commandLineDisplayString(task.commandLine.map(\.asByteString), additionalOutput: task.additionalOutput, workingDirectory: task.workingDirectory, environment: environmentToShow, dependencyInfo: dependencyInfo) : nil, interestingPath: interestingPath, serializedDiagnosticsPaths: task.type.serializedDiagnosticsPaths(task, operation.requestContext.fs))

        request.send(BuildOperationTaskStarted(id: taskID, targetID: targetID, parentID: nil, info: info))

        // Create the output parser, if used.
        //
        // FIXME: Does this really belong at this layer, versus one layer below in the build system? It feels integral to the build, not the reporting of it.
        var outputHandler: TaskOutputParserHandler? = nil
        var outputParser: (any TaskOutputParser)? = nil
        if let parserType = task.type.customOutputParserType(for: task) {
            outputHandler = TaskOutputParserHandler(buildOperationIdentifier: .init(operation.uuid), taskID: taskID, taskSignature: .taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue)), targetID: targetID, buildRequest: operation.request)
            outputParser = parserType.init(for: task, workspaceContext: workspaceContext, buildRequestContext: operation.requestContext, delegate: outputHandler!, progressReporter: operation.subtaskProgressReporter)
        }

        // Finally, create and return an object that will receive and collect all the output from the task.  We record the current wall clock time as the process start time.
        let handler = TaskOutputHandler(taskID: taskID, taskSignature: .taskIdentifier(ByteString(encodingAsUTF8: taskIdentifier.rawValue)), targetID: targetID, operation: operation, operationDelegate: self, parser: outputParser)
        outputHandler?.handler = handler

        return handler
    }

    func taskRequestedDynamicTask(_ operation: any BuildSystemOperation, requestingTask: any ExecutableTask, dynamicTaskIdentifier: TaskIdentifier) {
        // This is tracking dynamic task dependency information, intentionally left empty for now
    }

    func registeredDynamicTask(_ operation: any SWBBuildSystem.BuildSystemOperation, task: any SWBCore.ExecutableTask, dynamicTaskIdentifier: SWBCore.TaskIdentifier) {
        // This is tracking dynamic task dependency information, intentionally left empty for now
    }

    func taskComplete(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task: any ExecutableTask, delegate taskDelegate: any TaskOutputDelegate) {
        guard !skipCommandLevelInformation else { return }

        // We expect the task output delegate to be a TaskOutputCollector, unless we are ignoring this task.
        guard let delegate = taskDelegate as? TaskOutputHandler else {
            assert(taskDelegate is DiscardingTaskOutputHandler)
            return
        }

        // Record the current time as the process end time.
        // FIXME: It's a little weird that this is stored on the task output handler, but we keep the existing code structure for now to minimize change risk.
        let duration = delegate.timer.elapsedTime()

        // Find the task ID (we expect to find one), and remove the task from the mapping.
        assert(activeTasks.lookup(task) != nil)
        let taskID = activeTasks.remove(task)

        // Make sure the task output collector has finished processing the output.
        delegate.handleTaskCompletion()

        // Finally, send the task-did-end message.
        //
        // FIXME: It isn't clear what signalled is supposed to mean here; lift this to be more structured information.
        let status: BuildOperationTaskEnded.Status
        switch delegate.result {
        case let .exit(exitStatus, _):
            status = .init(exitStatus)
        case .failedSetup:
            status = .failed
        case .skipped:
            status = .succeeded
        case nil:
            // The task has been cancelled if the delegate has no result after completion
            status = .cancelled
        }

        // Update our own status for the overall build.
        switch status {
        case .cancelled, .failed:
            // Any cancelled or failing tasks should mark the overall build failed.
            // If a cancellation of the overall build was requested in response to a user-initiated cancellation, that will be propagated to the overall build status when the operation delegate completes the build.
            self.taskCompletionBasedStatus = .failed
        case .succeeded:
            // Do nothing - we always presume the build succeeded until we detect otherwise.
            break
        }

        let metrics: BuildOperationTaskEnded.Metrics? = delegate.result?.metrics.map({
            // Note that although the metrics speak in terms of "wall time" our task duration is not strictly wall time since it uses a monotonic clock to guarantee non-negative durations.
            // Our start time is still stored as a wall clock based time measured in nanoseconds since the CFAbsoluteTime epoch, since existing code relies on this basis for now and it is no longer used to compute durations in this context.
            // We should consider changing this interface to use a more formalized time types which preserve the semantics of the epoch and the measurement unit across API boundaries.
            return BuildOperationTaskEnded.Metrics(
                utime: $0.utime,
                stime: $0.stime,
                maxRSS: $0.maxRSS,
                wcStartTime: UInt64(delegate.startTime.timeIntervalSinceReferenceDate * Double(USEC_PER_SEC)),
                // Using the more precise wall-time duration recorded for the task, if available.
                wcDuration: ($0.wcDuration ?? duration).microseconds
            )
        })

        self.aggregatedCounters.merge(delegate.counters) { (a, b) in a+b }
        if !delegate.taskCounters.isEmpty {
            self.aggregatedTaskCounters[task.ruleInfo[0], default: [:]].merge(delegate.taskCounters) { (a, b) in a+b }
        }

        request.send(BuildOperationTaskEnded(id: taskID, signature: .taskIdentifier(ByteString(encodingAsUTF8: taskIdentifier.rawValue)), status: status, signalled: status == .cancelled, metrics: metrics))
    }

    func beginActivity(_ operation: any BuildSystemOperation, ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        let targetID: Int?
        if let forTarget = target {
            // Get the target ID associated with the task.
            let targetInfo = getActiveTargetInfo(operation, forTarget)
            assert(targetInfo.hasStarted)
            targetID = targetInfo.id
        } else {
            targetID = nil
        }

        let activityID = ActivityID(rawValue: activeTasks.takeID())
        let info = BuildOperationTaskInfo(taskName: "", signature: .activitySignature(signature), ruleInfo: ruleInfo, executionDescription: executionDescription, commandLineDisplayString: nil, interestingPath: nil, serializedDiagnosticsPaths: [])
        request.send(BuildOperationTaskStarted(id: activityID.rawValue, targetID: targetID, parentID: parentActivity?.rawValue, info: info))
        return activityID
    }

    func endActivity(_ operation: any BuildSystemOperation, id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        request.send(BuildOperationTaskEnded(id: id.rawValue, signature: .activitySignature(signature), status: status, signalled: false, metrics: nil))
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        request.send(BuildOperationConsoleOutputEmitted(data: data, taskID: activity.rawValue, taskSignature: .activitySignature(signature)))
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        request.send(BuildOperationDiagnosticEmitted(diagnostic, .globalTask(taskID: activity.rawValue, taskSignature: .activitySignature(signature))))
    }

    var hadErrors: Bool {
        numErrors > 0
    }

    func targetPreparedForIndex(_ operation: any BuildSystemOperation, target: SWBCore.Target, info: PreparedForIndexResultInfo) {
        request.send(BuildOperationTargetPreparedForIndex(targetGUID: target.guid, info: info))
    }

    func updateBuildProgress(statusMessage: String, showInLog: Bool) {
        guard !skipCommandLevelInformation else { return }

        request.send(BuildOperationProgressUpdated(statusMessage: statusMessage, percentComplete: -1, showInLog: showInLog))
    }

    func recordBuildBacktraceFrame(identifier: BuildOperationBacktraceFrameEmitted.Identifier, previousFrameIdentifier: BuildOperationBacktraceFrameEmitted.Identifier?, category: BuildOperationBacktraceFrameEmitted.Category, kind: BuildOperationBacktraceFrameEmitted.Kind, description: String) {
        request.send(BuildOperationBacktraceFrameEmitted(identifier: identifier, previousFrameIdentifier: previousFrameIdentifier, category: category, kind: kind, description: description))
    }
}

private enum BuildOperationError: Error {
    case planningFailed
}
