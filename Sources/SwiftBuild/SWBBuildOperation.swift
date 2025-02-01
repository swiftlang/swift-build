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

public import Foundation

import SWBProtocol
import SWBUtil

/// Represents the state of a build operation.
public enum SWBBuildOperationState: Sendable {
    /// The request to start the build operation has been submitted, but it hasn’t yet started.
    case requested
    /// The build operation has started running.
    case running
    /// The build operation has been cancelled. This is an endpoint state for the build operation.
    case cancelled
    /// The build operation has ended with failure. This is an endpoint state for the build operation.
    case failed
    /// The build operation has ended with success. This is an endpoint state for the build operation.
    case succeeded
    /// A fatal error was encountered during the build, and it was aborted. This is an endpoint state for the build operation.
    case aborted
}

/// Represents a build operation that has been requested of the build service.  A delegate is informed of any events that relate to the build operation.  SWBBuildOperation objects are not directly created by the client, but are instead created and returned from the ``SWBBuildServiceSession/createBuildOperation(request:delegate:completion:)`` method.
public final class SWBBuildOperation: Sendable {
    /// The session in which this build operation is running.
    private weak var session: SWBBuildServiceSession?

    /// The delegate for this build operation.
    public let delegate: (any SWBPlanningOperationDelegate)?

    /// A signal that allows clients to await completion of the build operation via the ``waitForCompletion()`` API.
    ///
    /// In most cases, enumerating the event stream is sufficient, because the last event is always ``SwiftBuildMessage/BuildCompletedInfo``, and receipt of this event guarantees that the build operation is in a terminal state. However, enumeration of the event stream may be interrupted if the current task is cancelled, and separating the completion signal from the event stream allows clients to have a stronger guarantee that the build operation has actually finished, without necessarily having to wrap the iteration in a detached task, or if consuming the event stream is not required for the use case.
    private let completion: WaitCondition

    private let events: AsyncStream<SwiftBuildMessage>

    internal let buildUUID = Foundation.UUID()

    /// The identifier of the build.
    private var buildID: Int? = nil

    private let lockedState: LockedValue<SWBBuildOperationState>

    /// The state of the operation.
    public private(set) var state: SWBBuildOperationState {
        get {
            return lockedState.withLock{$0}
        }
        set {
            lockedState.withLock{$0 = newValue}
        }
    }

#if DEBUG
    /// The set of active targets, for assertion purposes.
    private var activeTargets = Set<Int>()
#endif

#if DEBUG
    /// The set of active tasks, for assertion purposes.
    private var activeTasks = Set<Int>()
#endif

    init(session: SWBBuildServiceSession, delegate: (any SWBPlanningOperationDelegate)?, request: SWBBuildRequest, onlyCreateBuildDescription: Bool) async throws {
        self.session = session
        self.delegate = delegate
        self.lockedState = .init(.requested)

        let (events, continuation) = AsyncStream<SwiftBuildMessage>.makeStream()
        self.events = events
        self.completion = WaitCondition()

        // Create the channel to communicate on.
        //
        // Because the `handler` captures `self`, the build service's connection will maintain a strong reference to this build operation.
        // `channel` is closed when a `BuildOperationEnded` message is received, eliminating this reference and a potential retain cycle (rdar://84783647). Any communication which might continue after `BuildOperationEnded` is received (e.g. a cancellation response) must use a dedicated channel.
        let channel = session.service.openChannel { (channel, message) in
            self.handleMessage(continuation: continuation, channel: channel, message: message)
        }

        // Send an asynchronous message to add the build request.  This will cause it to start running at any point.
        let msg = try await session.service.send(request: CreateBuildRequest(sessionHandle: session.uid, responseChannel: channel, request: request.messagePayloadRepresentation, onlyCreateBuildDescription: onlyCreateBuildDescription))

        // At the moment, by setting this here we guarantee the client can never cause any communication with the SWBBuildOperation before the ID is set.
        assert(state == .requested, "invalid state: \(state)")
        buildID = msg.id
    }

    private func handleMessage(continuation: AsyncStream<SwiftBuildMessage>.Continuation, channel: UInt64, message: any SWBProtocol.Message) {
        assert(buildID != nil || message is ErrorResponse, "unexpected message received before build ID.")

        // If we have been aborted, ignore any subsequent messages.
        //
        // We have already informed the client...
        if state == .aborted {
            return
        }

        switch message {
        // Planning operation messages
        case let message as PlanningOperationWillStart:
            continuation.yield(.init(message))
        case let message as PlanningOperationDidFinish:
            continuation.yield(.init(message))
        case let message as GetProvisioningTaskInputsRequest:
            if let session {
                Task<Void, Never> {
                    await handle(message: message, session: session, delegate: self.delegate)
                }
            } else {
                // Cannot respond to GetProvisioningTaskInputsRequest because the session has been deallocated
            }
        case let message as ExternalToolExecutionRequest:
            if let session {
                Task<Void, Never> {
                    await handle(message: message, session: session, delegate: self.delegate)
                }
            } else {
                // Cannot respond to ExternalToolExecutionRequest because the session has been deallocated
            }

        // Build operation messages

        case let message as BuildOperationReportBuildDescription:
            continuation.yield(.init(message))
        case let message as BuildOperationReportPathMap:
            continuation.yield(.init(message))
        case let message as BuildOperationStarted:
            assert(state == .requested, "invalid state: \(state)")
            state = .running
            continuation.yield(.init(message))
        case let message as BuildOperationEnded:
            assert(state == .running || state == .requested, "invalid state: \(state)")
            switch message.status {
            case .succeeded:
                state = .succeeded
            case .cancelled:
                state = .cancelled
            case .failed:
                state = .failed
            }
            continuation.yield(.init(message))
            self.session?.service.closeChannel(channel)
            continuation.finish()
            self.completion.signal()
        case let message as BuildOperationTargetStarted:
            assert(state == .running, "invalid state: \(state)")
#if DEBUG
            do {
                let inserted = activeTargets.insert(message.id).inserted
                assert(inserted)
            }
#endif
            continuation.yield(.init(message))
        case let message as BuildOperationTargetUpToDate:
            assert(state == .running, "invalid state: \(state)")
            continuation.yield(.targetUpToDate(.init(guid: message.guid)))
        case let message as BuildOperationTargetEnded:
            assert(state == .running, "invalid state: \(state)")
#if DEBUG
            guard activeTargets.remove(message.id) != nil else {
                fatalError("unexpected target message")
            }
#endif
            continuation.yield(.init(message))
        case let message as BuildOperationTaskUpToDate:
            continuation.yield(.init(message))
        case let message as BuildOperationTaskStarted:
            assert(state == .requested || state == .running, "invalid state: \(state)")
#if DEBUG
            do {
                let inserted = activeTasks.insert(message.id).inserted
                assert(inserted)
            }
#endif
            continuation.yield(.init(message))
        case let message as BuildOperationTaskEnded:
            assert(state == .requested || state == .running, "invalid state: \(state)")
#if DEBUG
            do {
                guard activeTasks.remove(message.id) != nil else {
                    fatalError("unexpected target message")
                }
            }
#endif
            continuation.yield(.init(message))
        case let message as BuildOperationTargetPreparedForIndex:
            assert(state == .running, "invalid state: \(state)")
            continuation.yield(.init(message))
        case let message as BuildOperationProgressUpdated:
            assert(state == .running || state == .requested, "invalid state: \(state)")
            continuation.yield(.init(message))
        case let message as BuildOperationPreparationCompleted:
            assert(state == .running || state == .requested, "invalid state: \(state)")
            continuation.yield(.init(message))
        case let message as BuildOperationDiagnosticEmitted:
            assert(state == .running || state == .requested, "invalid state: \(state)")
            [SwiftBuildMessage](message).forEach { continuation.yield($0) }
        case let message as BuildOperationConsoleOutputEmitted:
            assert(state == .requested || state == .running, "invalid state: \(state)")
            [SwiftBuildMessage](message).forEach { continuation.yield($0) }
        case let message as BuildOperationBacktraceFrameEmitted:
            continuation.yield(.init(message))

        case let message as BoolResponse:
            assert(message.value, "Did not receive an OK response")

        case is VoidResponse:
            break

        case let errorResponse as ErrorResponse:
            if state == .aborted { return }
            state = .aborted

            // If the error response was `planningFailed`, we should have already emitted diagnostics that capture the failure reason.
            if errorResponse.description != "build aborted due to an internal error: planningFailed" {
                [SwiftBuildMessage](BuildOperationDiagnosticEmitted(kind: .error, location: .unknown, message: "unexpected service error: \(errorResponse.description)", sourceRanges: [], fixIts: [], childDiagnostics: [])).forEach { continuation.yield($0) }
            }

            continuation.yield(.buildCompleted(.init(result: .failed, metrics: nil)))
            session?.service.closeChannel(channel)
            continuation.finish()
            self.completion.signal()

            // Inform the service we have lost interest in this build, in case it happens to be continuing.
            cancel()

        // Other messages
        case let reply:
            fatalError("fatal error: unexpected build operation message: \(String(describing: reply)))")
        }
    }

    /// Starts the build operation and returns an async stream containing the event messages produced by the ongoing build operation.
    ///
    /// - note: The build operation state is not guaranteed to have changed by the time this method returns. Once all events have been consumed from the async stream, the build operation is guaranteed to be in a terminal state.
    public func start() async throws -> AsyncStream<SwiftBuildMessage> {
        assert(state == .requested, "Can only start unstarted builds")

        guard let session else {
            throw SwiftBuildError.requestError(description: "missing session reference")
        }

        guard let buildID else {
            throw SwiftBuildError.requestError(description: "unexpected message received before build ID.")
        }

        _ = try await session.service.send(request: BuildStartRequest(sessionHandle: session.uid, id: buildID))

        await session.trackBuildOperation(self)

        return events
    }

    /// Waits for the build operation to complete.
    ///
    /// - note: This method may be called before or after the build operation has started. It will _not_ respond to cooperative cancellation, which should be manually propagated to the build operation, and in turn, signal this function to return once the cancellation operation has reached quiescence.
    public func waitForCompletion() async {
        await completion.wait()
    }

    public func cancel() {
        switch state {
        case .succeeded, .failed, .cancelled:
            // Due to timing it's possible that `state` may "complete" before the `cancel()` caller becomes aware that the build finished.
            return
        case .requested, .running, .aborted:
            // If we have a build ID, send the cancellation message.
            // `buildID` might still be nil here if the build service crashed and therefore build operation
            // creation itself aborted before the build received its ID or got a chance to start.
            if let session, let buildID {
                let message = BuildCancelRequest(sessionHandle: session.uid, id: buildID)
                Task {
                    // Sending the cancellation message can fail if the session is no longer valid on the service side.
                    // Since cancellation is best-effort and may even do nothing depending on the state of the operation, we don't care to handle any potential failures.
                    _ = try await session.service.send(request: message)
                }
            }
        }
    }
}

public protocol SWBPlanningOperationDelegate {
    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult
}

public enum SWBProcessExitStatus: Sendable {
    case exit(_ code: Int32)
    case uncaughtSignal(_ signal: Int32)

    public var isSuccess: Bool {
        switch self {
        case let .exit(exitStatus):
            return exitStatus == 0
        case .uncaughtSignal:
            return false
        }
    }
}

public enum SWBExternalToolResult: Sendable {
    /// Defer to direct execution by the build engine
    case deferred

    /// Result of an external tool execution by the client.
    case result(status: SWBProcessExitStatus, stdout: Data, stderr: Data)
}

/// Wrapper for information provided about a task metrics during a build.
public struct SWBBuildOperationTaskMetrics: Sendable, Codable {
    /// Total amount of time (in µs) spent by the process executing in user mode.
    public let utime: UInt64

    /// Total amount of time (in µs) spent by the system executing on behalf of the process.
    public let stime: UInt64

    /// Maximum resident memory set size (in bytes).
    public let maxRSS: UInt64

    /// Wall clock time (in µs since the epoch) at which the process was started.
    public let wcStartTime: UInt64

    /// Wall clock time (in µs) from start to finish of process.
    public let wcDuration: UInt64

    init(utime: UInt64, stime: UInt64, maxRSS: UInt64, wcStartTime: UInt64, wcDuration: UInt64) {
        self.utime = utime
        self.stime = stime
        self.maxRSS = maxRSS
        self.wcStartTime = wcStartTime
        self.wcDuration = wcDuration
    }
}
