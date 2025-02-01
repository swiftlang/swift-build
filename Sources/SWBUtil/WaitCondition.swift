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

/// An object which allows unstructured tracking of an asynchronous operation, whose completion can be signaled from synchronous code.
///
/// - note: While this has a similar API surface as `DispatchSemaphore`, the semantics are different in that `signal()` and `wait()` are idempotent.
public final class WaitCondition: Sendable {
    private let promise = Promise<Void, Never>()

    public init() {
    }

    /// Signals completion of the condition.
    ///
    /// - note: This function is idempotent.
    public func signal() {
        _ = promise.fulfill()
    }

    /// Asynchronously waits for the condition to complete. Continues waiting even if the current task is cancelled.
    ///
    /// - note: This function is idempotent. If the condition is already completed, the function returns immediately.
    public func wait() async {
        await promise.value
    }
}

/// An object which allows unstructured tracking of an asynchronous operation, whose completion can be signaled from synchronous code.
///
/// - note: While this has a similar API surface as `DispatchSemaphore`, the semantics are different in that `signal()` and `wait()` are idempotent.
public final class CancellableWaitCondition: Sendable {
    private let promise = Promise<Void, any Error>()

    public init() {
    }

    /// Cancels the wait condition. If the condition has already succeeded, does nothing.
    ///
    /// - note: This function is idempotent.
    public func cancel() {
        _ = promise.fail(throwing: CancellationError())
    }

    /// Signals completion of the condition.
    ///
    /// - note: This function is idempotent.
    public func signal() {
        _ = promise.fulfill()
    }

    /// Asynchronously waits for the condition to complete.
    ///
    /// - throws: ``CancellationError`` if the current task was cancelled.
    /// - note: This function is idempotent. If the condition is already completed, the function returns immediately.
    public func wait() async throws {
        try await withTaskCancellationHandler {
            try await promise.value
        } onCancel: {
            cancel()
        }
    }
}
