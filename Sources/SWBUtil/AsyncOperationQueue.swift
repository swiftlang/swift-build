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

public actor AsyncOperationQueue {
    private let concurrentTasks: Int
    private var activeTasks: Int = 0
    private var waitingTasks: [CheckedContinuation<Void, Never>] = []

    public init(concurrentTasks: Int) {
        self.concurrentTasks = concurrentTasks
    }

    deinit {
        if !waitingTasks.isEmpty {
            preconditionFailure("Deallocated with waiting tasks")
        }
    }

    public func withOperation<ReturnValue>(
        _ operation: @Sendable () async -> sending ReturnValue
    ) async -> ReturnValue {
        await waitIfNeeded()
        defer { signalCompletion() }
        return await operation()
    }

    public func withOperation<ReturnValue>(
        _ operation: @Sendable () async throws -> sending ReturnValue
    ) async throws -> ReturnValue {
        await waitIfNeeded()
        defer { signalCompletion() }
        return try await operation()
    }

    private func waitIfNeeded() async {
        if activeTasks >= concurrentTasks {
            await withCheckedContinuation { continuation in
                waitingTasks.append(continuation)
            }
        }

        activeTasks += 1
    }

    private func signalCompletion() {
        activeTasks -= 1

        if let continuation = waitingTasks.popLast() {
            continuation.resume()
        }
    }
}
