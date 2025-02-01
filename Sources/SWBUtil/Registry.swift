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

import SWBLibc

/// A threadsafe mapping of hashable keys to values.  Unlike a Dictionary, which has independent lookup and insertion operations, a registry has an atomic lookup-or-insert operation that takes a constructor block, which is called only if the key isn't already in the registry.  The block is guaranteed to be called only once, even if multiple threads lookup-or-insert the same key at the same time (this allows it to have side effects without needing additional checking).  Unlike a Cache, a Registry never discards entries based on memory pressure.  Unlike a LazyCache, the value creation block is provided for each call and not just once per instance.
// FIXME: We should consider whether we should combine Cache, LazyCache, and Registry, possibly with per-instance options for things like whether background deletion is allowed, whether a value creator block is guaranteed to run only once, etc.  At the moment, the various clients in Swift Build depend on the semantics of the various utility types they use.
public final class Registry<K: Hashable, V>: KeyValueStorage {
    public typealias Key = K
    public typealias Value = V

    /// Underlying dictionary, which is accessed only while holding the lock.
    private let dict = LockedValue<Dictionary<K, V>>([:])

    /// Public initializer of a new, empty registry.
    public init() {
        // This is needed in order to allow instances to be created from other modules.
    }

    public var count: Int {
        return dict.withLock(\.count)
    }

    public var isEmpty: Bool {
        return dict.withLock(\.isEmpty)
    }

    /// Gets an existing value, or invokes `creator` to create a new value, which is then inserted.  Either way, the value is returned.  The block is guaranteed to only be invoked if the key isn’t present in the registry, but will potentially block other access while running.
    ///
    /// NOTE:  Currently there is only one lock for the whole registry.  If contention becomes a problem we could also have a separate lock for each value, and only hold the registry-wide lock while probing for (and potentially creating a slot for) the key.  The per-value lock would then be held while checking for (and potentially creating) the value.  This is possible because the key is known without invoking the creator block.
    public func getOrInsert(_ key: K, _ creator: () throws -> V) rethrows -> V {
        try dict.withLock {
            // If there is already a value for the key, return it
            if let value = $0[key] {
                return value
            }

            // Otherwise, create the value and assign it (while holding the lock).
            let value = try creator()
            $0[key] = value
            return value
        }
    }

    public subscript(_ key: K) -> V? {
        get {
            return dict.withLock {
                $0[key]
            }
        }
        set {
            dict.withLock {
                $0[key] = newValue
            }
        }
    }

    public func insert(_ key: K, value: V) {
        self[key] = value
    }

    public var keys: [K] {
        Array(dict.withLock(\.keys))
    }

    public var values: [V] {
        Array(dict.withLock(\.values))
    }

    public func removeValue(forKey key: K) -> V? {
        dict.withLock {
            $0.removeValue(forKey: key)
        }
    }

    public func forEach(_ body: (((K, V)) -> Void)) {
        dict.withLock {
            $0.forEach(body)
        }
    }

    public func removeAll() {
        dict.withLock {
            $0.removeAll()
        }
    }
}

extension Registry: Sendable where K: Sendable, V: Sendable { }
