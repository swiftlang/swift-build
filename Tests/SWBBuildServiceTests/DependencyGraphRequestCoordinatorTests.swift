//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Dispatch
import SWBBuildService
import SWBProtocol
import SWBUtil
import Synchronization
import Testing

@Suite(.serialized) fileprivate struct DependencyGraphRequestCoordinatorTests {
    @Test
    func executesEverySubmittedRequestAndReportsItsOutcome() async {
        let coordinator = makeCoordinator()
        let activity = ActivityRecorder()
        let firstRecorder = OutcomeRecorder()
        let secondRecorder = OutcomeRecorder()
        let firstStarted = WaitCondition()
        let releaseFirst = WaitCondition()

        coordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index")
            defer { activity.end("index") }
            firstStarted.signal()
            await releaseFirst.wait()
            return makeResponse("first")
        } completion: {
            firstRecorder.record($0)
        }

        await firstStarted.wait()

        coordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index")
            defer { activity.end("index") }
            throw TestError.expected
        } completion: {
            secondRecorder.record($0)
        }

        releaseFirst.signal()
        await coordinator.waitForQuiescence()

        #expect(activity.startCount("index") == 2)
        #expect(firstRecorder.outcomes == [.success(makeResponse("first"))])
        #expect(secondRecorder.outcomes == [.failure("expected")])
    }

    @Test
    func serializesIndexRequestsAcrossSessionsWithoutBlockingForeground() async {
        let firstCoordinator = DependencyGraphRequestCoordinator()
        let secondCoordinator = DependencyGraphRequestCoordinator()
        let activity = ActivityRecorder()
        let firstIndexStarted = WaitCondition()
        let releaseFirstIndex = WaitCondition()
        let secondIndexStarted = WaitCondition()
        let releaseSecondIndex = WaitCondition()
        let firstForegroundStarted = WaitCondition()
        let secondForegroundStarted = WaitCondition()
        let queuedForegroundStarted = WaitCondition()
        let releaseForeground = WaitCondition()

        firstCoordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index-a")
            defer { activity.end("index-a") }
            firstIndexStarted.signal()
            await releaseFirstIndex.wait()
            return makeResponse("index-a")
        } completion: { _ in
        }

        await firstIndexStarted.wait()

        secondCoordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index-b")
            defer { activity.end("index-b") }
            secondIndexStarted.signal()
            await releaseSecondIndex.wait()
            return makeResponse("index-b")
        } completion: { _ in
        }

        firstCoordinator.submit(lane: .foreground, priority: .userInitiated) {
            activity.begin("foreground-a")
            defer { activity.end("foreground-a") }
            firstForegroundStarted.signal()
            await releaseForeground.wait()
            return makeResponse("foreground-a")
        } completion: { _ in
        }

        secondCoordinator.submit(lane: .foreground, priority: .userInitiated) {
            activity.begin("foreground-b")
            defer { activity.end("foreground-b") }
            secondForegroundStarted.signal()
            await releaseForeground.wait()
            return makeResponse("foreground-b")
        } completion: { _ in
        }

        await firstForegroundStarted.wait()
        await secondForegroundStarted.wait()

        firstCoordinator.submit(lane: .foreground, priority: .userInitiated) {
            activity.begin("foreground-queued")
            defer { activity.end("foreground-queued") }
            queuedForegroundStarted.signal()
            return makeResponse("foreground-queued")
        } completion: { _ in
        }

        #expect(activity.startCount("index-b") == 0)
        #expect(activity.startCount("foreground-queued") == 0)
        #expect(activity.maximumConcurrentIndexOperations == 1)
        #expect(activity.maximumConcurrentForegroundOperations == 2)
        #expect(activity.maximumConcurrentOperations == 3)

        releaseForeground.signal()
        await queuedForegroundStarted.wait()
        releaseFirstIndex.signal()
        await secondIndexStarted.wait()
        releaseSecondIndex.signal()
        await firstCoordinator.waitForQuiescence()
        await secondCoordinator.waitForQuiescence()

        #expect(activity.maximumConcurrentIndexOperations == 1)
        #expect(activity.maximumConcurrentForegroundOperations == 2)
    }

    @Test
    func closeCancelsActiveAndQueuedRequestsAndWaitsForCompletion() async {
        let coordinator = makeCoordinator()
        let activeStarted = WaitCondition()
        let releaseActive = WaitCondition()
        let cancellationObserved = WaitCondition()
        let activity = ActivityRecorder()
        let sequence = SequenceRecorder()
        let lifecycleDriver = LifecycleDriver()
        let activeRecorder = OutcomeRecorder()
        let queuedRecorder = OutcomeRecorder()
        let lateRecorder = OutcomeRecorder()

        coordinator.submit(lane: .index, priority: .utility) {
            activity.begin("active")
            defer { activity.end("active") }
            sequence.record("operation-started")
            activeStarted.signal()
            await withTaskCancellationHandler {
                await releaseActive.wait()
            } onCancel: {
                cancellationObserved.signal()
            }
            sequence.record("operation-finished")
            return makeResponse("late-success")
        } completion: {
            sequence.record("active-reply")
            activeRecorder.record($0)
        }

        await activeStarted.wait()

        coordinator.submit(lane: .index, priority: .utility) {
            activity.begin("queued")
            defer { activity.end("queued") }
            return makeResponse("queued")
        } completion: {
            sequence.record("queued-reply")
            queuedRecorder.record($0)
        }

        let closeTask = _Concurrency.Task {
            await lifecycleDriver.close(coordinator, sequence: sequence)
        }

        await cancellationObserved.wait()
        await queuedRecorder.received.wait()
        #expect(activeRecorder.outcomes.isEmpty)

        coordinator.submit(lane: .index, priority: .utility) {
            Issue.record("A closed coordinator must not start new work")
            return makeResponse("unexpected")
        } completion: {
            sequence.record("late-reply")
            lateRecorder.record($0)
        }
        await lateRecorder.received.wait()

        await lifecycleDriver.release(releaseActive, sequence: sequence, event: "release-active")
        await closeTask.value
        await coordinator.close()

        #expect(activeRecorder.outcomes == [.cancelled])
        #expect(queuedRecorder.outcomes == [.cancelled])
        #expect(lateRecorder.outcomes == [.cancelled])
        #expect(activity.startCount("active") == 1)
        #expect(activity.startCount("queued") == 0)
        #expect(sequence.index(of: "operation-finished") < sequence.index(of: "active-reply"))
        #expect(sequence.index(of: "active-reply") < sequence.index(of: "close-returned"))
    }

    @Test
    func closeWaitsForCommittedReplyAndPreservesItsOutcome() async {
        await withTaskExecutorPreference(TestDriverExecutor()) {
            let coordinator = makeCoordinator()
            let releaseReply = DispatchSemaphore(value: 0)
            let replyStarted = WaitCondition()
            let closeStarted = WaitCondition()
            let sequence = SequenceRecorder()
            let recorder = OutcomeRecorder()
            let lifecycleDriver = LifecycleDriver()

            coordinator.submit(lane: .foreground, priority: .userInitiated) {
                makeResponse("success")
            } completion: {
                sequence.record("reply-started")
                replyStarted.signal()
                releaseReply.wait()
                sequence.record("reply-finished")
                recorder.record($0)
            }

            await replyStarted.wait()

            async let closeTask: Void = lifecycleDriver.close(
                coordinator,
                started: closeStarted,
                sequence: sequence
            )

            await closeStarted.wait()
            await lifecycleDriver.release(releaseReply)
            await recorder.received.wait()
            await closeTask

            #expect(recorder.outcomes == [.success(makeResponse("success"))])
            #expect(sequence.index(of: "reply-finished") < sequence.index(of: "close-returned"))
        }
    }

    @Test
    func quiescenceWaitsForOperationAndReplyCompletion() async {
        await withTaskExecutorPreference(TestDriverExecutor()) {
            let coordinator = makeCoordinator()
            let releaseReply = DispatchSemaphore(value: 0)
            let replyStarted = WaitCondition()
            let quiescenceStarted = WaitCondition()
            let sequence = SequenceRecorder()
            let lifecycleDriver = LifecycleDriver()

            coordinator.submit(lane: .index, priority: .utility) {
                sequence.record("operation-finished")
                return makeResponse("success")
            } completion: { _ in
                sequence.record("reply-started")
                replyStarted.signal()
                releaseReply.wait()
                sequence.record("reply-finished")
            }

            await replyStarted.wait()

            async let quiescenceTask: Void = lifecycleDriver.waitForQuiescence(
                of: coordinator,
                started: quiescenceStarted,
                sequence: sequence
            )

            await quiescenceStarted.wait()
            await lifecycleDriver.release(releaseReply)
            await quiescenceTask

            #expect(sequence.index(of: "reply-started") < sequence.index(of: "reply-finished"))
            #expect(sequence.index(of: "reply-finished") < sequence.index(of: "quiescence-returned"))
        }
    }

    @Test
    func closeDoesNotWaitForAnotherSessionsIndexOperation() async throws {
        let indexQueue = AsyncOperationQueue(concurrentTasks: 1)
        let started = WaitCondition()
        let release = WaitCondition()
        let blocker = _Concurrency.Task {
            try await indexQueue.withOperation {
                started.signal()
                await release.wait()
            }
        }
        await started.wait()

        let coordinator = makeCoordinator(indexQueue: indexQueue)
        let recorder = OutcomeRecorder()
        coordinator.submit(lane: .index, priority: .utility) {
            Issue.record("A cancelled queued request must not enter graph construction")
            return makeResponse("unexpected")
        } completion: {
            recorder.record($0)
        }

        await coordinator.close()
        #expect(recorder.outcomes == [.cancelled])
        release.signal()
        try await blocker.value
    }

    @Test
    func deinitRepliesBeforeActiveOperationFinishes() async throws {
        var coordinator: DependencyGraphRequestCoordinator? = makeCoordinator()
        let started = WaitCondition()
        let release = WaitCondition()
        let finished = WaitCondition()
        let recorder = OutcomeRecorder()

        try #require(coordinator).submit(lane: .foreground, priority: .userInitiated) {
            started.signal()
            await release.wait()
            finished.signal()
            return makeResponse("late-success")
        } completion: {
            recorder.record($0)
        }

        await started.wait()
        coordinator = nil
        #expect(recorder.outcomes == [.cancelled])
        release.signal()
        await finished.wait()
    }

    @Test
    func concurrentSubmissionAndCloseReplyExactlyOnce() async {
        let coordinator = makeCoordinator()
        let replyCounts = SWBMutex<[Int: Int]>([:])

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<128 {
                group.addTask {
                    coordinator.submit(lane: id.isMultiple(of: 2) ? .index : .foreground, priority: .medium) {
                        await _Concurrency.Task.yield()
                        return makeResponse(String(id))
                    } completion: { _ in
                        replyCounts.withLock { $0[id, default: 0] += 1 }
                    }
                }
                if id.isMultiple(of: 16) {
                    group.addTask {
                        await coordinator.close()
                    }
                }
            }
        }
        await coordinator.close()

        #expect(replyCounts.withLock { $0.count } == 128)
        #expect(replyCounts.withLock { $0.values.allSatisfy { $0 == 1 } })
    }
}

// Reply callbacks deliberately block so these tests can observe pending replies.
// Their drivers must progress independently of the cooperative pool they block.
private final class TestDriverExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "dependency-graph-test-driver")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

private actor LifecycleDriver {
    func close(
        _ coordinator: DependencyGraphRequestCoordinator,
        started: WaitCondition? = nil,
        sequence: SequenceRecorder
    ) async {
        started?.signal()
        await coordinator.close()
        sequence.record("close-returned")
    }

    func waitForQuiescence(
        of coordinator: DependencyGraphRequestCoordinator,
        started: WaitCondition,
        sequence: SequenceRecorder
    ) async {
        started.signal()
        await coordinator.waitForQuiescence()
        sequence.record("quiescence-returned")
    }

    func release(_ condition: WaitCondition, sequence: SequenceRecorder? = nil, event: String? = nil) {
        if let sequence, let event {
            sequence.record(event)
        }
        condition.signal()
    }

    func release(_ semaphore: DispatchSemaphore) {
        semaphore.signal()
    }
}

private enum TestError: Error, CustomStringConvertible {
    case expected

    var description: String {
        "expected"
    }
}

private final class OutcomeRecorder: Sendable {
    let received = WaitCondition()
    private let storage = SWBMutex<[DependencyGraphRequestCoordinator.Outcome]>([])

    var outcomes: [DependencyGraphRequestCoordinator.Outcome] {
        storage.withLock { $0 }
    }

    func record(_ outcome: DependencyGraphRequestCoordinator.Outcome) {
        storage.withLock { $0.append(outcome) }
        received.signal()
    }
}

private final class SequenceRecorder: Sendable {
    private let events = SWBMutex<[String]>([])

    func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    func index(of event: String) -> Int {
        events.withLock { events in
            events.firstIndex(of: event) ?? Int.max
        }
    }
}

private final class ActivityRecorder: Sendable {
    private struct State {
        var active: Set<String> = []
        var starts: [String: Int] = [:]
        var maximumConcurrentIndexOperations = 0
        var maximumConcurrentForegroundOperations = 0
        var maximumConcurrentOperations = 0
    }

    private let state = SWBMutex(State())

    func begin(_ name: String) {
        state.withLock { state in
            state.active.insert(name)
            state.starts[name, default: 0] += 1
            state.maximumConcurrentIndexOperations = max(
                state.maximumConcurrentIndexOperations,
                state.active.filter { $0.hasPrefix("index") }.count
            )
            state.maximumConcurrentForegroundOperations = max(
                state.maximumConcurrentForegroundOperations,
                state.active.filter { $0.hasPrefix("foreground") }.count
            )
            state.maximumConcurrentOperations = max(state.maximumConcurrentOperations, state.active.count)
        }
    }

    func end(_ name: String) {
        state.withLock { state in
            #expect(state.active.remove(name) != nil)
        }
    }

    func startCount(_ name: String) -> Int {
        state.withLock { $0.starts[name, default: 0] }
    }

    var maximumConcurrentIndexOperations: Int {
        state.withLock { $0.maximumConcurrentIndexOperations }
    }

    var maximumConcurrentForegroundOperations: Int {
        state.withLock { $0.maximumConcurrentForegroundOperations }
    }

    var maximumConcurrentOperations: Int {
        state.withLock { $0.maximumConcurrentOperations }
    }
}

private func makeCoordinator(
    indexQueue: AsyncOperationQueue = AsyncOperationQueue(concurrentTasks: 1),
    foregroundQueue: AsyncOperationQueue = AsyncOperationQueue(concurrentTasks: 1)
) -> DependencyGraphRequestCoordinator {
    DependencyGraphRequestCoordinator(indexQueue: indexQueue, foregroundQueue: foregroundQueue)
}

private func makeResponse(_ target: String) -> DependencyGraphResponse {
    let target = TargetGUID(rawValue: target)
    return DependencyGraphResponse(adjacencyList: [target: []])
}
