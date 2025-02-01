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

public extension Dictionary
{
    /// Check if the dictionary contains an entry for `element`.
    func contains(_ element: Key) -> Bool {
        return index(forKey: element) != nil
    }

    /// Adds the contents of `otherDict` into the receiver.  If a given key is already defined in the receiver, then its value is replaced by the corresponding value in `otherDict`.
    mutating func addContents(of otherDict: Dictionary) {
        for (key, value) in otherDict {
            self[key] = value
        }
    }

    /// Adds the contents of `otherDict` into the receiver.  If a given key is already defined in the receiver, then its value is replaced by the corresponding value in `otherDict`.
    func addingContents(of dictionary: Dictionary) -> Dictionary {
        var result = self
        result.addContents(of: dictionary)
        return result
    }

    /// Get the value for a key, inserting a new entry if necessary.
    mutating func getOrInsert(_ key: Key, _ body: () throws -> Value) rethrows -> Value {
        if let value = self[key] {
            return value
        }

        let value = try body()
        self[key] = value
        return value
    }

    /// Get the value for a key, inserting a new entry if necessary.
    mutating func getOrInsert(_ key: Key, _ body: () async throws -> Value) async rethrows -> Value {
        if let value = self[key] {
            return value
        }

        let value = try await body()
        self[key] = value
        return value
    }
}

/// Dictionary extensions for proposal to Swift stdlib
public extension Dictionary {
    init(merging values: [Dictionary], uniquingKeysWith: (Value, Value) -> Value) {
        self = values.reduce([:]) { result, dict in result.merging(dict, uniquingKeysWith: uniquingKeysWith) }
    }

    /// Returns the elements of the dictionary, sorted using the given predicate as the comparison between elements.
    ///
    /// This overload uses only the *keys* of the dictionary as parameters to the predicate, which allows using shorthand like `sorted(byKey: <)` versus `sorted(by: { $0.0 < $1.0 })`.
    ///
    /// - seealso: sorted(by:)
    /// - parameter areInIncreasingOrder: A predicate that returns true if its first argument should be ordered before its second argument; otherwise, false.
    /// - returns: A sorted array of the dictionary's elements.
    @inlinable func sorted(byKey areInIncreasingOrder: (Key, Key) throws -> Bool) rethrows -> [(key: Key, value: Value)] {
        return try sorted(by: { try areInIncreasingOrder($0.key, $1.key) })
    }

    /// Returns the elements of the dictionary, sorted using the given key path as the comparison between elements.
    @inlinable func sorted<KeyValue: Comparable>(byKey predicate: (Key) -> KeyValue) -> [(key: Key, value: Value)] {
        return sorted(<, byKey: predicate)
    }

    /// Returns the elements of the dictionary, sorted using the given key path as the comparison between elements.
    @inlinable func sorted<KeyValue: Comparable>( _ areInIncreasingOrder: (KeyValue, KeyValue) throws -> Bool, byKey predicate: (Key) -> KeyValue) rethrows -> [(key: Key, value: Value)] {
        return try sorted(byKey: { try areInIncreasingOrder(predicate($0), predicate($1)) })
    }

    /// Returns a new dictionary containing the keys of this dictionary with the
    /// values transformed by the given closure.
    ///
    /// - Parameter transform: A closure that transforms a value. `transform`
    ///   accepts each key-value pair of the dictionary as its parameter and
    ///   returns a transformed value of the same or of a different type.
    /// - Returns: A dictionary containing the keys and transformed values of
    ///   this dictionary.
    func compactMapValues<T>(_ transform: (Key, Value) throws -> T?) rethrows -> [Key: T] {
        let values = try compactMap({ (key, value) -> (Key, T)? in
            if let newValue = try transform(key, value) {
                return (key, newValue)
            }
            return nil
        })
        return Dictionary<Key, T>(uniqueKeysWithValues: values)
    }

    /// Returns a new dictionary containing the key-value pairs of the dictionary
    /// whose keys are present in `keys`.
    ///
    /// - Parameter keys: The set of keys indicating which key-value pairs
    ///   should be included in the returned dictionary.
    /// - Returns: A dictionary of the key-value pairs that `keys` allows.
    func filter<KeyCollection: Collection>(keys: KeyCollection) -> [Key: Value] where KeyCollection.Element == Key {
        return filter { key, _ in keys.contains(key) }
    }
}
