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

/// Helper to provide convenient access to an AsyncStream's continuation, which is one of the few in Swift Concurrency allowed to escape.
public final class AsyncStreamController<Element: Sendable, Failure>: Sendable where Failure: Error {
    private let continuation: AsyncStream<Element>.Continuation
    fileprivate let task: Task<Void, Failure>

    init(continuation: AsyncStream<Element>.Continuation, task: Task<Void, Failure>) {
        self.continuation = continuation
        self.task = task
    }

    deinit {
        invalidate()
    }

    @discardableResult public func yield(_ value: Element) -> AsyncStream<Element>.Continuation.YieldResult {
        continuation.yield(value)
    }

    public func finish() {
        continuation.finish()
    }

    public func invalidate() {
        finish()
        task.cancel()
    }
}

extension AsyncStreamController where Failure == any Error {
    public convenience init(priority: TaskPriority? = nil, _ task: @Sendable @escaping (AsyncStream<Element>) async throws -> Void) {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        self.init(continuation: continuation, task: Task<Void, Failure>(priority: priority) { try await task(stream) })
    }

    public func wait() async throws {
        try await task.value
    }
}

extension AsyncStreamController where Failure == Never {
    public convenience init(priority: TaskPriority? = nil, _ task: @Sendable @escaping (AsyncStream<Element>) async -> Void) {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        self.init(continuation: continuation, task: Task<Void, Failure>(priority: priority) { await task(stream) })
    }

    public func wait() async {
        await task.value
    }
}
