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

#if canImport(os)
import os
#endif

/// Base protocol used for global operations over generic type.
private protocol _HeavyCacheBase: AnyObject {
    /// Clear the cache.
    func removeAll()
}

/// All heavy-weight caches are available as a global, to support mass eviction.
@TaskLocal private var allHeavyCaches = LockedValue<[WeakRef<any _HeavyCacheBase>]>([])

// MARK: Global Operations

public func clearAllHeavyCaches() {
    allHeavyCaches.withLock { allHeavyCaches in
        for idx in allHeavyCaches.indices.reversed() {
            if let cache = allHeavyCaches[idx].instance {
                cache.removeAll()
            } else {
                allHeavyCaches.remove(at: idx)
            }
        }
    }
}

public func withHeavyCacheGlobalState<T>(isolated: Bool = true, _ body: () throws -> T) rethrows -> T {
    if isolated {
        try $allHeavyCaches.withValue(.init([])) {
            try body()
        }
    } else {
        try body()
    }
}

@_spi(Testing) public func withHeavyCacheGlobalState<T>(isolated: Bool = true, _ body: () async throws -> T) async rethrows -> T {
    if isolated {
        try await $allHeavyCaches.withValue(.init([])) {
            try await body()
        }
    } else {
        try await body()
    }
}

/// A cache designed for holding few, relatively heavy-weight objects.
///
/// This cache is specifically designed for holding a limited number of objects (usually less than 100) which are expensive enough to merit particular attention in terms of being purgeable under memory pressure, evictable in-mass, or cached with more complex parameters like time-to-live (TTL).
public final class HeavyCache<Key: Hashable, Value>: _HeavyCacheBase, KeyValueStorage, @unchecked Sendable {
    public typealias HeavyCacheClock = SuspendingClock

    /// Controls the non-deterministic eviction policy of the cache. Note that this is distinct from deterministic _pruning_ (due to TTL or size limits).
    public enum EvictionPolicy: Sendable {
        /// Never evict due to memory pressure.
        case never

        /// Default `NSCache` eviction behaviors.
        case `default`(totalCostLimit: Int?, willEvictCallback: (@Sendable (Value) -> Void)? = nil)
    }

    fileprivate final class Entry {
        /// The actual value.
        let value: Value

        /// The last access timestamp.
        var accessTime: HeavyCacheClock.Instant

        init(_ value: Value, _ accessTime: HeavyCacheClock.Instant) {
            self.value = value
            self.accessTime = accessTime
        }
    }

    /// The lock to protect shared instance state.
    private let stateLock = Lock()

    /// The underlying cache.
    private let _cache: any HeavyCacheImpl<Key, Entry>

    /// The set of keys potentially in the cache (not necessarily, since the cache can itself evict).
    ///
    /// The underlying cache doesn't expose access to the full contents, so we need to duplicate this information.
    private var _keys = Set<Key>()

    /// The current time-to-live of this cache, if enabled.
    private var _timeToLive: Duration? = nil

    /// The maximum size of the cache.
    private var _maximumSize: Int? = nil

    /// The timer used to enforce TTL.
    private var _timer: Task<Void, any Error>? = nil

    /// Create a new cache instance.
    public init(maximumSize: Int? = nil, timeToLive: Duration? = nil, evictionPolicy: EvictionPolicy = .default(totalCostLimit: nil, willEvictCallback: nil)) {
        switch evictionPolicy {
        case .never:
            self._cache = Registry<Key, Entry>()
        case .default(let totalCostLimit, let willEvictCallback):
            let evictionCallback: (@Sendable (Entry) -> Void)?
            if let willEvictCallback {
                evictionCallback = { entry in
                    willEvictCallback(entry.value)
                }
            } else {
                evictionCallback = nil
            }
            self._cache = Cache<Key, Entry>(willEvictCallback: evictionCallback, totalCostLimit: totalCostLimit)
        }
        allHeavyCaches.withLock { allHeavyCaches in
            allHeavyCaches.append(WeakRef(self))
        }
        self.maximumSize = maximumSize
        self.timeToLive = timeToLive
    }

    deinit {
        _timer?.cancel()
        stateLock.withLock {
            for waiter in _expirationWaiters {
                waiter.resume()
            }
            _expirationWaiters = []
        }
    }

    // MARK: Cache Operations

    /// The number of items in the cache.
    ///
    /// Due to the implementation details, this may overestimate the number of active items, if some items have been recently evicted.
    public var count: Int {
        return stateLock.withLock { _keys.count }
    }

    /// Clear all items in the cache.
    public func removeAll() {
        stateLock.withLock {
            _cache.removeAll()
            _keys.removeAll()
        }
    }

    /// Get the value for a key, or compute it if missing.
    ///
    /// This function is thread-safe, but may allow computing the value multiple times in case of a race.
    public func getOrInsert(_ key: Key, _ body: () throws -> Value) rethrows -> Value {
        return try stateLock.withLock {
            let entry = try _cache.getOrInsert(key) {
                return Entry(try body(), currentTime())
            }
            _keys.insert(key)
            entry.accessTime = currentTime()
            _pruneCache()
            return entry.value
        }
    }

    /// Subscript access to the cache.
    public subscript(_ key: Key) -> Value? {
        get {
            return stateLock.withLock {
                if let entry = _cache[key] {
                    entry.accessTime = currentTime()
                    return entry.value
                }
                return nil
            }
        }
        set {
            stateLock.withLock {
                if let newValue {
                    let entry = Entry(newValue, currentTime())
                    _cache[key] = entry
                    _keys.insert(key)
                    _pruneCache()
                } else {
                    _cache.remove(key)
                    _keys.remove(key)
                }
            }
        }
    }

    /// Check whether a given key is present in the cache.
    public func contains(_ key: Key) -> Bool {
        return self[key] != nil
    }

    /// Prune the cache following an insert.
    ///
    /// This method is expected to be called on `queue`.
    private func _pruneCache() {
        // Enforce the cache maximum size.
        guard let max = maximumSize else { return }

        // Prune one item at a time. This is not efficient for pruning large numbers of items, but that is not the intended use case currently.
        //
        // We take some care to make sure we drop keys already evicted by the underlying cache before anything else.
    whileLoop:
        while _keys.count > max {
            // Prune the oldest entry.
            var oldest: (key: Key, entry: Entry)? = nil
            for key in _keys {
                guard let entry = _cache[key] else {
                    _keys.remove(key)
                    _cache.remove(key)
                    continue whileLoop
                }
                if oldest == nil || oldest!.entry.accessTime > entry.accessTime {
                    oldest = (key, entry)
                }
            }
            if let oldest {
                _keys.remove(oldest.key)
                _cache.remove(oldest.key)
            }
        }
    }

    /// Prune the cache based on the TTL value.
    ///
    /// This method is expected to be called on `queue`.
    private func _pruneForTTL() {
        guard let ttl = _timeToLive else { return }

        let time = currentTime()
        var keysToRemove = [Key]()
        for key in _keys {
            guard let entry = _cache[key] else {
                keysToRemove.append(key)
                continue
            }
            if time - entry.accessTime > ttl {
                keysToRemove.append(key)
            }
        }
        for key in keysToRemove {
            _keys.remove(key)
            _cache.remove(key)
        }

        for waiter in _expirationWaiters {
            waiter.resume()
        }
        _expirationWaiters = []
    }

    // MARK: Cache Tuning Parameters

    /// Set the maximum size of the cache, beyond which it will be pruned.
    ///
    /// When a maximum size is configured, the cache will always behave in an LRU manner.
    public var maximumSize: Int? {
        get {
            return _maximumSize
        }
        set {
            stateLock.withLock {
                _maximumSize = newValue
                _pruneCache()
            }
        }
    }

    /// Set the time-to-live for items in the cache.
    ///
    /// The time-to-live is measured against the last access time of the item.
    public var timeToLive: Duration? {
        get {
            return _timeToLive
        }
        set {
            stateLock.withLock {
                _timeToLive = newValue

                // Install the TTL timer.
                if let ttl = _timeToLive {
                    // We always schedule at the requested TTL, on average an object will live 50% longer than the TTL.
                    _timer?.cancel()
                    _timer = Task { [weak self] in
                        while !Task.isCancelled {
                            if let self = self {
                                self.preventExpiration {
                                    self.stateLock.withLock {
                                        self._pruneForTTL()
                                    }
                                }
                            }
                            try await Task.sleep(for: ttl)
                        }
                    }
                } else {
                    _timer?.cancel()
                    _timer = nil
                }
            }
        }
    }

    private let _preventExpirationLock = Lock()
    private var _expirationWaiters: [CheckedContinuation<Void, Never>] = []
    private var _currentTimeTestingOverride: HeavyCacheClock.Instant?

    private func currentTime() -> HeavyCacheClock.Instant {
        _currentTimeTestingOverride ?? .now
    }
}

extension HeavyCache {
    /// Allows freezing the current time as seen by the object, for TTL pruning testing purposes.
    @_spi(Testing) @discardableResult public func setTime(instant: HeavyCacheClock.Instant?) -> HeavyCacheClock.Instant {
        stateLock.withLock {
            _currentTimeTestingOverride = instant
            return instant ?? .now
        }
    }

    /// Waits until the next time pruning for TTL occurs.
    @_spi(Testing) public func waitForExpiration() async {
        await withCheckedContinuation { continuation in
            stateLock.withLock {
                _expirationWaiters.append(continuation)
            }
        }
    }

    /// Performs the given body while preventing TTL-based cache expiration.
    @_spi(Testing) public func preventExpiration(_ body: @Sendable () throws -> Void) rethrows {
        try _preventExpirationLock.withLock(body)
    }
}

extension HeavyCache.Entry: CacheableValue where Value: CacheableValue {
    var cost: Int {
        self.value.cost
    }
}

private protocol HeavyCacheImpl<Key, Value>: Sendable, KeyValueStorage, _HeavyCacheBase {
    subscript(_ key: Key) -> Value? { get set }
    func remove(_ key: Key)
}

extension Cache: HeavyCacheImpl {
}

extension Registry: HeavyCacheImpl {
    func remove(_ key: K) {
        _ = removeValue(forKey: key)
    }
}
