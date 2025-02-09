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

public import Foundation

// FIXME: Can we eliminate some of these wrappers now?
private final class KeyWrapper<T: Hashable>: NSObject {
    let value: T

    init(_ value: T) {
        self.value = value
    }

    override func isEqual(_ object: Any?) -> Bool {
        return value == (object as! KeyWrapper<T>).value
    }

    override var hash: Int {
        return value.hashValue
    }
}

private final class ValueWrapper<T> {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

public protocol CacheableValue {
    var cost: Int { get }
}

// NSCache insert, remove, and lookup operations are documented as thread safe: https://developer.apple.com/documentation/foundation/nscache
fileprivate final class UnsafeNSCacheSendableWrapper<Key: Hashable, Value> {
    init(value: NSCache<KeyWrapper<Key>, ValueWrapper<Value>>) {
        self.value = value
    }
    let value: NSCache<KeyWrapper<Key>, ValueWrapper<Value>>
}
extension UnsafeNSCacheSendableWrapper: @unchecked Sendable where Key: Sendable, Value: Sendable {}

/// A thread-safe cache container.
///
/// This container will automatically evict entries when the system is under memory pressure.
public final class Cache<Key: Hashable, Value>: NSObject, KeyValueStorage, NSCacheDelegate {
    /// The underlying cache implementation.
    private let cache: UnsafeNSCacheSendableWrapper<Key, Value>
    private let willEvictCallback: (@Sendable (Value) -> Void)?

    public init(willEvictCallback: (@Sendable (Value)->Void)? = nil, totalCostLimit: Int? = nil) {
        self.cache = .init(value: NSCache())
        self.willEvictCallback = willEvictCallback
        super.init()
        if let totalCostLimit {
            self.cache.value.totalCostLimit = totalCostLimit
        }
        self.cache.value.delegate = self
    }

    /// Remove all objects in the cache.
    public func removeAll() {
        cache.value.removeAllObjects()
    }

    /// Remove the entry for a given `key`.
    public func remove(_ key: Key) {
        cache.value.removeObject(forKey: KeyWrapper(key))
    }

    /// Subscript access to the cache.
    public subscript(_ key: Key) -> Value? {
        get {
            if let wrappedValue = cache.value.object(forKey: KeyWrapper(key)) {
                return wrappedValue.value
            }
            return nil
        }
        set {
            if let newValue, let cacheableValue = newValue as? (any CacheableValue) {
                cache.value.setObject(ValueWrapper(newValue), forKey: KeyWrapper(key), cost: cacheableValue.cost)
            } else if let newValue = newValue {
                cache.value.setObject(ValueWrapper(newValue), forKey: KeyWrapper(key))
            } else {
                cache.value.removeObject(forKey: KeyWrapper(key))
            }
        }
    }

    /// Check whether a given key is present in the cache.
    public func contains(_ key: Key) -> Bool {
        return self[key] != nil
    }

    /// Get or insert a value.
    ///
    /// NOTE: The cache *does not* ensure that the block to compute a value is only called once for a given key. In race conditions, it may be called multiple times, even though only the last computed result will be used.
    public func getOrInsert(_ key: Key, _ body: () throws -> Value) rethrows -> Value {
        let wrappedKey = KeyWrapper(key)
        if let wrappedValue = cache.value.object(forKey: wrappedKey) {
            return wrappedValue.value
        }

        let value = try body()
        if let cacheableValue = value as? (any CacheableValue) {
            cache.value.setObject(ValueWrapper(value), forKey: wrappedKey, cost: cacheableValue.cost)

        } else {
            cache.value.setObject(ValueWrapper(value), forKey: wrappedKey)
        }
        return value
    }

    public func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let willEvictCallback else { return }
        guard let value = obj as? ValueWrapper<Value> else { return }
        willEvictCallback(value.value)
    }
}

extension Cache: Sendable where Key: Sendable, Value: Sendable { }
extension KeyWrapper: Sendable where T: Sendable { }
extension ValueWrapper: Sendable where T: Sendable { }
