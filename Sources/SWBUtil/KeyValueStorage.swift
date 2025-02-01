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

import Foundation

/// Generic protocol representing operations common to dictionaries, caches, and other key-value stores.
public protocol KeyValueStorage<Key, Value> {
    associatedtype Key
    associatedtype Value

    func getOrInsert(_ key: Key, _ body: () throws -> Value) rethrows -> Value
}

extension KeyValueStorage {
    public func getOrInsert<Wrapped>(_ key: Key, body: () throws -> Wrapped) rethrows -> Wrapped where Value == Lazy<Wrapped> {
        return try getOrInsert(key, isValid: { _ in true }, body: body)
    }

    /// Gets or inserts a value into the key-value store using `Lazy` as its value type.
    ///
    /// This is used as a convenience wrapper which effectively implements a uses two-level lock: one to protect the key-value store itself, and one lock per value, so that values can be computed in parallel while maintaining the guarantee that `body` is called only once per key.
    ///
    /// - parameter key: The key used to identify the value in the key-value store.
    /// - parameter isValid: A closure used to indicate whether the existing stored value for `key` is still valid. Return `false` to discard the currently cached value and call `body` to compute a new value.
    /// - parameter body: A closure used to compute the value for `key`. Will be called at most once per key in case of race conditions.
    public func getOrInsert<Wrapped>(_ key: Key, isValid: (Wrapped) throws -> Bool, body: () throws -> Wrapped) rethrows -> Wrapped where Value == Lazy<Wrapped> {
        return try getOrInsert(key) { .init() }.getValue(body, isValid: isValid)
    }
}
