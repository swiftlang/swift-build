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

import Foundation
package import SWBProtocol
package import SWBUtil
import Synchronization

package final class DependencyGraphRequestCoordinator: Sendable {
    package enum Lane: Sendable {
        case index
        case foreground
    }

    package enum Outcome: Equatable, Sendable {
        case success(DependencyGraphResponse)
        case failure(String)
        case cancelled
    }

    package typealias Completion = @Sendable (Outcome) -> Void

    private struct Operation: Sendable {
        let task: _Concurrency.Task<Void, Never>
        let completion: Completion
    }

    private struct State: ~Copyable {
        var acceptsNewOperations = true
        var operations: [UUID: Operation] = [:]
    }

    // Index graph requests are background work and can arrive from multiple sessions at once.
    // Keep a process-wide admission limit while allowing foreground graphs to proceed independently.
    private static let sharedIndexQueue = AsyncOperationQueue(concurrentTasks: 1)

    private let state = SWBMutex(State())
    private let indexQueue: AsyncOperationQueue
    private let foregroundQueue: AsyncOperationQueue

    package init(indexQueue: AsyncOperationQueue? = nil, foregroundQueue: AsyncOperationQueue? = nil) {
        self.indexQueue = indexQueue ?? Self.sharedIndexQueue
        self.foregroundQueue = foregroundQueue ?? AsyncOperationQueue(concurrentTasks: 1)
    }

    deinit {
        // Request.service is unowned, so pending replies must not outlive session
        // teardown. A task calling finish retains this coordinator through its reply;
        // once deinit starts, the remaining tasks cannot promote their weak reference.
        let operations = state.withLock { Array($0.operations.values) }
        for operation in operations {
            operation.task.cancel()
        }
        for operation in operations {
            operation.completion(.cancelled)
        }
    }

    package func submit(
        lane: Lane,
        priority: _Concurrency.TaskPriority,
        operation: @escaping @Sendable () async throws -> DependencyGraphResponse,
        completion: @escaping Completion
    ) {
        let id = UUID()
        let queue =
            switch lane {
            case .index: indexQueue
            case .foreground: foregroundQueue
            }
        let shouldCancelImmediately = state.withLock { state -> Bool in
            guard state.acceptsNewOperations else {
                return true
            }

            let task = _Concurrency.Task<Void, Never>(priority: priority) { [weak self] in
                let outcome: Outcome
                do {
                    let response = try await queue.withOperation {
                        try _Concurrency.Task.checkCancellation()
                        let response = try await operation()
                        try _Concurrency.Task.checkCancellation()
                        return response
                    }
                    outcome = .success(response)
                } catch is _Concurrency.CancellationError {
                    outcome = .cancelled
                } catch {
                    outcome = .failure(String(describing: error))
                }
                self?.finish(id: id, outcome: outcome, completion: completion)
            }
            state.operations[id] = Operation(task: task, completion: completion)
            return false
        }

        if shouldCancelImmediately {
            completion(.cancelled)
        }
    }

    package func close() async {
        let tasks = state.withLock { state in
            state.acceptsNewOperations = false
            return state.operations.values.map(\.task)
        }
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    package func waitForQuiescence() async {
        // Operations remain tracked until both graph construction and the terminal reply
        // callback have finished. The Task may still be returning from its final
        // bookkeeping call after it is removed from this state.
        // ServiceHostConnection processes requests serially, so production callers cannot
        // submit more work while awaiting this method. It is not an admission barrier for
        // arbitrary concurrent callers.
        while true {
            let tasks = state.withLock { state in
                state.operations.values.map(\.task)
            }
            if tasks.isEmpty {
                return
            }
            for task in tasks {
                await task.value
            }
        }
    }

    private func finish(id: UUID, outcome: Outcome, completion: Completion) {
        let committedOutcome = state.withLock { state in
            state.acceptsNewOperations ? outcome : .cancelled
        }
        // Keep the task registered through the callback so close and quiescence
        // cannot return while a terminal reply is still being sent.
        completion(committedOutcome)
        state.withLock { state in
            state.operations[id] = nil
        }
    }
}
