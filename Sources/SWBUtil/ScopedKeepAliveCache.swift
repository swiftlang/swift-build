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

import Synchronization

/// Supports using an evicting base cache but temporarily preventing eviction during `cache.keepAlive { ... }`.
///
/// - It doesn't prevent the base cache from evicting, but instead temporarily uses an additional non-evicting store
/// - Only protects cache entries inserted or retrieved during `keepAlive`, not entries present when starting `keepAlive`
/// - Supports recursive and concurrent invocations of `keepAlive`, which effectively extend the lifetime of cache entries until the last active `keepAlive`
/// - After `keepAlive`, entries are removed from the non-evicting store on a background task which doesn't block cache clients
public final class ScopedKeepAliveCache<Key: Hashable & Sendable, Value: Sendable, BaseCache: KeyValueStorage<Key, Value> & Sendable>: KeyValueStorage & Sendable {
    private typealias Store = Registry<Key, Value>

    private struct State {
        /// Tracks the number of active invocations of `keepAlive`
        var keepAliveCount = UInt(0)

        /// Used to store cache entries when `keepAlive` is active
        var store = Store()
    }

    private let state = SWBMutex(State())

    /// Client's chosen base cache to use when `keepAlive` is not active. We'll populate it when `keepAlive` is active as well, and it can choose independently which entries to keep around.
    private let baseCache: BaseCache

    public init(_ baseCache: BaseCache) {
        self.baseCache = baseCache
    }

    private func retain() {
        state.withLock { $0.keepAliveCount += 1 }
    }

    private func release() {
        state.withLock {
            precondition($0.keepAliveCount > 0)
            $0.keepAliveCount -= 1

            if $0.keepAliveCount == 0 {
                // Eviction could take some time if there are many objects to deinit/free, so do it outside the lock to avoid blocking the next `keepAlive` or `getOrInsert`. We use a detached unstructured task because we don't need to support cancellation or track its lifetime since we're letting go of the entire store object.
                let previous = $0.store
                $0.store = Store()
                Task.detached(priority: .low) {
                    previous.removeAll()
                }
            }
        }
    }

    public func keepAlive<R>(_ f: () throws -> R) rethrows -> R {
        retain()
        defer { release() }
        return try f()
    }

    public func keepAlive<R>(_ f: () async throws -> R) async rethrows -> R {
        retain()
        defer { release() }
        return try await f()
    }

    public func getOrInsert(_ key: Key, _ body: () throws -> Value) rethrows -> Value {
        let store = state.withLock {
            $0.keepAliveCount > 0 ? $0.store : nil
        }

        // This non-evicting store may actually have been cleared between the lock and here, that's okay, it'll get fully released after this use
        if let store {
            return try store.getOrInsert(key) {
                try baseCache.getOrInsert(key, body)
            }
        }
        else {
            return try baseCache.getOrInsert(key, body)
        }
    }
}
