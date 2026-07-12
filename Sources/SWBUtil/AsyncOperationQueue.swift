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

import Foundation

/// A queue for running async operations with a limit on the number of concurrent tasks.
public final class AsyncOperationQueue: @unchecked Sendable {

    // This implementation is identical to the AsyncOperationQueue in swift-package-manager.
    // Any modifications made here should also be made there.
    // https://github.com/swiftlang/swift-build/blob/main/Sources/SWBUtil/AsyncOperationQueue.swift#L13

    fileprivate typealias ID = UUID
    fileprivate typealias WaitingContinuation = CheckedContinuation<Void, any Error>

    private let concurrentTasks: Int
    private var waitingTasks: [WorkTask] = []
    private let waitingTasksLock = NSLock()

    fileprivate enum WorkTask {
        case creating(ID)
        case waiting(ID, WaitingContinuation)
        case running(ID)
        case cancelled(ID)

        var id: ID {
            switch self {
            case .creating(let id), .waiting(let id, _), .running(let id), .cancelled(let id):
                return id
            }
        }
    }

    /// Creates an `AsyncOperationQueue` with a specified number of concurrent tasks.
    /// - Parameter concurrentTasks: The maximum number of concurrent tasks that can be executed concurrently.
    public init(concurrentTasks: Int) {
        self.concurrentTasks = concurrentTasks
    }

    deinit {
        waitingTasksLock.withLock {
            if !waitingTasks.isEmpty {
                preconditionFailure("Deallocated with waiting tasks")
            }
        }
    }

    /// Executes an asynchronous operation, ensuring that the number of concurrent tasks
    // does not exceed the specified limit.
    /// - Parameter operation: The asynchronous operation to execute.
    /// - Returns: The result of the operation.
    /// - Throws: An error thrown by the operation, or a `CancellationError` if the operation is cancelled.
    public func withOperation<ReturnValue>(
        _ operation: () async throws -> sending ReturnValue
    ) async throws -> ReturnValue {
        let taskId = try await waitIfNeeded()
        defer { signalCompletion(taskId) }
        return try await operation()
    }

    private func waitIfNeeded() async throws -> ID {
        let workTask = waitingTasksLock.withLock({
            let shouldWait = waitingTasks.count >= concurrentTasks
            let workTask = shouldWait ? WorkTask.creating(ID()) : .running(ID())
            waitingTasks.append(workTask)
            return workTask
        })

        // If we aren't creating a task that needs to wait, we're under the concurrency limit.
        guard case .creating(let taskId) = workTask else {
            return workTask.id
        }

        enum TaskAction {
            case start(WaitingContinuation)
            case cancel(WaitingContinuation)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: WaitingContinuation) -> Void in
                let action: TaskAction? = waitingTasksLock.withLock {
                    guard let index = waitingTasks.firstIndex(where: { $0.id == taskId }) else {
                        // The task may have been marked as cancelled already and then removed from
                        // waitingTasks in `signalCompletion`.
                        return .cancel(continuation)
                    }

                    switch waitingTasks[index] {
                        case .cancelled:
                            // If the task was cancelled in between creating the task cancellation handler and acquiring the lock,
                            // we should resume the continuation with a `CancellationError`.
                            waitingTasks.remove(at: index)
                            return .cancel(continuation)
                        case .creating, .running, .waiting:
                            // A task may have completed since we initially checked if we should wait. Re-check here, but
                            // count only the *running* tasks: this task is currently in `waitingTasks` as `.creating`, so
                            // counting the whole array would count it against itself and could leave it parked with no
                            // running task left to ever resume it. If a slot is free, mark this task as running in place
                            // (keeping it in `waitingTasks` so it continues to occupy a concurrency slot until it
                            // completes) and start it immediately.
                            let runningCount = waitingTasks.reduce(into: 0) { count, task in
                                if case .running = task { count += 1 }
                            }
                            if runningCount >= concurrentTasks {
                                waitingTasks[index] = .waiting(taskId, continuation)
                                return nil
                            } else {
                                waitingTasks[index] = .running(taskId)
                                return .start(continuation)
                            }
                    }
                }

                switch action {
                    case .some(.cancel(let continuation)):
                        continuation.resume(throwing: _Concurrency.CancellationError())
                    case .some(.start(let continuation)):
                        continuation.resume()
                    case .none:
                        return
                }
            }
        } onCancel: {
            let continuation: WaitingContinuation? = self.waitingTasksLock.withLock {
                guard let taskIndex = self.waitingTasks.firstIndex(where: { $0.id == taskId }) else {
                    return nil
                }

                switch self.waitingTasks[taskIndex] {
                    case .waiting(_, let continuation):
                        self.waitingTasks.remove(at: taskIndex)

                        // If the parent task is cancelled then we need to manually handle resuming the
                        // continuation for the waiting task with a `CancellationError`. Return the continuation
                        // here so it can be resumed once the `waitingTasksLock` is released.
                        return continuation
                    case .creating:
                        // If the task was still being created, mark it as cancelled in `waitingTasks` so that
                        // the handler for `withCheckedThrowingContinuation` can immediately cancel it.
                        self.waitingTasks[taskIndex] = .cancelled(taskId)
                        return nil
                    case .running:
                        // The task has already been promoted and started running, so it is no longer waiting on
                        // its continuation. Leave it in place to keep occupying its slot; it will observe the
                        // cancellation cooperatively and be removed by `signalCompletion` when it completes.
                        return nil
                    case .cancelled:
                        preconditionFailure("Attempting to cancel a task that was already cancelled")
                }
            }

            continuation?.resume(throwing: _Concurrency.CancellationError())
        }
        return workTask.id
    }

    private func signalCompletion(_ taskId: ID) {
        let continuationToResume = waitingTasksLock.withLock { () -> WaitingContinuation? in
            guard !waitingTasks.isEmpty else {
                return nil
            }

            // Remove the completed task from the list to free its concurrency slot.
            if let taskIndex = self.waitingTasks.firstIndex(where: { $0.id == taskId }) {
                waitingTasks.remove(at: taskIndex)
            }

            // Find the next task to start, removing any cancelled tombstones we pass along the way.
            var index = 0
            while index < waitingTasks.count {
                switch waitingTasks[index] {
                case .running:
                    // Already occupying a slot; keep looking for a task that hasn't started yet.
                    index += 1
                case .creating:
                    // The task is in the process of being created, i.e. it is between reserving its slot and
                    // registering its continuation. We cannot resume it here (it has no continuation yet), but we
                    // must keep looking for a waiting task behind it to promote: relying on the creating task to
                    // start itself would strand those waiting tasks if it is cancelled before it ever runs. It is
                    // safe to promote a later waiting task because the running-count re-check in `waitIfNeeded` will
                    // make this creating task park once it observes the slot is taken.
                    index += 1
                case .waiting(let id, let continuation):
                    // Promote the next waiting task to running in place so it keeps occupying a concurrency slot
                    // until it completes, then resume its continuation once the lock is released.
                    waitingTasks[index] = .running(id)
                    return continuation
                case .cancelled:
                    // Drop cancelled tasks and keep looking for one that still needs to run.
                    waitingTasks.remove(at: index)
                }
            }

            return nil
        }

        continuationToResume?.resume()
    }
}
