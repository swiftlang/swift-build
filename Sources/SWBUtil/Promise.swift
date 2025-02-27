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

/// Represents a placeholder for a value which will be provided by synchronous code running in another execution context.
public final class Promise<Success: Sendable, Failure: Swift.Error>: Sendable {
    private struct State {
        var waiters: [CheckedContinuation<Success, Failure>] = []
        var value: Result<Success, Failure>?
    }

    private let state: LockedValue<State>

    /// Creates a new promise in the unfulfilled state.
    public init() {
        state = LockedValue(State(value: nil))
    }

    deinit {
        state.withLock { state in
            precondition(state.waiters.isEmpty, "Deallocated with remaining waiters")
        }
    }

    /// Fulfills the promise with the specified result.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    public func fulfill(with result: Result<Success, Failure>) -> Bool {
        let (waiters, alreadyFulfilled): ([CheckedContinuation<Success, Failure>], Bool) = state.withLock { state in
            if state.value != nil {
                return ([], true)
            }
            state.value = result
            let waiters = state.waiters
            state.waiters.removeAll()
            return (waiters, false)
        }

        // Resume the continuations outside the lock to avoid potential deadlock if invoked in a cancellation handler.
        for waiter in waiters {
            waiter.resume(with: result)
        }

        return alreadyFulfilled
    }

    /// Fulfills the promise with the specified value.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    public func fulfill(with value: Success) -> Bool {
        fulfill(with: .success(value))
    }

    /// Fulfills the promise with the specified error.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    public func fail(throwing error: Failure) -> Bool {
        fulfill(with: .failure(error))
    }
}

extension Promise where Success == Void {
    /// Fulfills the promise.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    public func fulfill() -> Bool {
        fulfill(with: ())
    }
}

extension Promise where Failure == Never {
    /// Suspends if the promise is not yet fulfilled, and returns the value once it is.
    public var value: Success {
        get async {
            await withCheckedContinuation { continuation in
                let value: Result<Success, Never>? = state.withLock { state in
                    if let value = state.value {
                        return value
                    } else {
                        state.waiters.append(continuation)
                        return nil
                    }
                }

                // Resume the continuations outside the lock to avoid potential deadlock if invoked in a cancellation handler.
                if let value {
                    continuation.resume(with: value)
                }
            }
        }
    }

    /// Suspends if the promise is not yet fulfilled, and returns the result once it is.
    public var result: Result<Success, Failure> {
        get async {
            await .success(value)
        }
    }
}

extension Promise where Failure == any Swift.Error {
    /// Suspends if the promise is not yet fulfilled, and returns the value once it is.
    public var value: Success {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    if let value = state.value {
                        continuation.resume(with: value)
                    } else {
                        state.waiters.append(continuation)
                    }
                }
            }
        }
    }

    /// Suspends if the promise is not yet fulfilled, and returns the result once it is.
    public var result: Result<Success, Failure> {
        get async throws {
            do {
                return try await .success(value)
            } catch {
                return .failure(error)
            }
        }
    }
}
