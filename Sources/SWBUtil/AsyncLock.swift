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

/// Lock intended for use within an actor in order to prevent reentrancy in actor methods which themselves contain suspension points.
public actor ActorLock {
    private var busy = false
    private var queue: ArraySlice<CheckedContinuation<(), Never>> = []

    public init() {
    }

    public func withLock<T: Sendable, E>(_ body: @Sendable () async throws(E) -> T) async throws(E) -> T {
        while busy {
            await withCheckedContinuation { cc in
                queue.append(cc)
            }
        }
        busy = true
        defer {
            busy = false
            if let next = queue.popFirst() {
                next.resume(returning: ())
            } else {
                queue = [] // reallocate buffer if it's empty
            }
        }
        return try await body()
    }
}

/// Small concurrency-compatible wrapper to provide only locked, non-reentrant access to its value.
public final class AsyncLockedValue<Wrapped: Sendable> {
    @usableFromInline let lock = ActorLock()
    /// Don't use this from outside this class. Is internal to be inlinable.
    @usableFromInline var value: Wrapped
    public init(_ value: Wrapped) {
        self.value = value
    }

    @discardableResult @inlinable
    public func withLock<Result: Sendable, E>(_ block: @Sendable (inout Wrapped) async throws(E) -> Result) async throws(E) -> Result {
        return try await lock.withLock { () throws(E) -> Result in try await block(&value) }
    }
}

extension AsyncLockedValue: @unchecked Sendable where Wrapped: Sendable {
}
