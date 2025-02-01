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

public actor AsyncCache<Key: Hashable & Sendable, Value: Sendable> {
    private enum ResultState {
        case done(Result<Value, any Error>)
        case retry
    }

    private enum KeyState {
        case requested([CheckedContinuation<ResultState, Never>])
        case finished(Result<Value, any Error>)
    }

    private var cache: [Key: KeyState] = [:]

    /// Creates a new cache.
    public init() { }

    /// Retrieves the value for the specified key, invoking the `body` closure to cache the value if it is not already present.
    ///
    /// This function will never invoke `body` more than once for the same key, unless the body throws a ``CancellationError``. In that case, the cancellation error will be thrown back to the caller which initiated the computation, and any concurrent waiters will retry. In no case will `body` ever be invoked _concurrently_ for the same key.
    ///
    /// Any other errors thrown from `body` will be cached just like a successful value, and returned from subsequent calls.
    public func value(forKey key: Key, _ body: @Sendable () async throws -> Value) async throws -> Value {
        switch cache[key] {
        case nil:
            cache[key] = .requested([])

            let result = await Result.catching { try await body() }
            switch cache[key] {
            case let .requested(continuations):
                let isCancelled = result.isCancelled
                for continuation in continuations {
                    continuation.resume(returning: isCancelled ? .retry : .done(result))
                }
                cache[key] = isCancelled ? nil : .finished(result)
                return try result.get()
            case .finished, nil:
                preconditionFailure()
            }
        case let .requested(continuations):
            let result = await withCheckedContinuation { continuation in
                cache[key] = .requested(continuations + [continuation])
            }
            switch result {
            case let .done(value):
                return try value.get()
            case .retry:
                return try await value(forKey: key, body)
            }
        case let .finished(result):
            return try result.get()
        }
    }
}

extension Result where Failure == any Error {
    fileprivate var isCancelled: Bool {
        if case let .failure(error) = self, error is CancellationError {
            return true
        }
        return false
    }
}
