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

/// An ordered set is an ordered collection of instances of `Element` in which uniqueness of the objects is guaranteed.
///
/// This API is designed to match the API surface of `OrderedSet` from `swift-collections` until we can bring in that actual package.
public struct OrderedSet<Element: Hashable>: Hashable {
    public typealias Index = Int

    public typealias Indices = Range<Int>

    fileprivate var array: Array<Element>
    private var uniqueIndices: [Element: Array<Element>.Index]

    /// Creates an empty ordered set.
    public init() {
        self.array = []
        self.uniqueIndices = [:]
    }

    /// Creates an ordered set with the contents of `array`.  If an element occurs more than once in `element`, only the first one will be included.
    public init<S: Sequence>(_ sequence: S) where S.Element == Element {
        self.init()
        append(contentsOf: sequence)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(array)
    }

    public static func ==<T>(lhs: OrderedSet<T>, rhs: OrderedSet<T>) -> Bool {
        return lhs.array == rhs.array
    }

    // MARK: Working with an ordered set

    /// The number of elements the ordered set stores.
    public var count: Int { return array.count }

    /// Returns `true` if the set is empty.
    public var isEmpty: Bool { return array.isEmpty }

    /// Returns the array form of the ordered set.
    ///
    /// This is useful when performing `XCTest` assertions on an `OrderedSet`.
    public var elements: Array<Element> { return array }

    /// Returns `true` if the ordered set contains `member`.
    public func contains(_ member: Element) -> Bool {
        return uniqueIndices.contains(member)
    }

    /// Returns the `Index` of a given member, or `nil` if the member is not present in the set.
    ///
    /// - complexity: O(1)
    public func firstIndex(of element: Element) -> Index? {
        uniqueIndices[element]
    }

    /// Returns the first element of the receiver, without removing it.
    public var first: Element? {
        return array.first
    }

    /// Returns the last element of the receiver, without removing it.
    public var last: Element? {
        return array.last
    }

    /// Removes the elements of the given set from this set.
    /// - parameter other: A set of the same type as the current set.
    public mutating func subtract<S>(_ other: S) where Element == S.Element, S : Sequence {
        let removeIndices = other.compactMap { uniqueIndices.removeValue(forKey: $0) }.sorted()
        for index in removeIndices.reversed() {
            array.remove(at: index)
        }
        if let firstIndex = removeIndices.first {
            updateIndices(from: firstIndex)
        }
    }

    private mutating func updateIndices(from startIndex: Int) {
        for (index, element) in array.dropFirst(startIndex).enumerated() {
            uniqueIndices[element] = index + startIndex
        }
    }

    /// Returns a new set containing the elements of the receiver that do not occur in the given sequence.
    /// - parameter sequence: Another sequence whose elements will be removed from the receiver if present.
    /// - returns: A new ordered set.
    public func subtracting<S>(_ sequence: S) -> OrderedSet<Element> where Element == S.Element, S : Sequence {
        var newSet = self
        newSet.subtract(sequence)
        return newSet
    }

    /// Adds an element to the ordered set. If it already contains the element, then the set is unchanged.
    ///
    /// - returns: True if the item was inserted (false if the set already contained the item).
    @discardableResult
    public mutating func append(_ newElement: Element) -> (inserted: Bool, index: Index) {
        insert(newElement, at: array.count)
    }

    /// Adds a sequence of elements to the ordered set.
    public mutating func append<S: Sequence>(contentsOf sequence: S) where S.Iterator.Element == Element {
        for element in sequence {
            append(element)
        }
    }

    /// Remove and return the element at the end of the ordered set.
    public mutating func removeLast() -> Element {
        let lastElement = array.removeLast()
        uniqueIndices.removeValue(forKey: lastElement)
        return lastElement
    }

    /// Insert `newElement` at index `i`.  If the ordered set already contains the element, returns `false` with the existing index.
    @discardableResult public mutating func insert(_ newElement: Element, at i: Int) -> (inserted: Bool, index: Index) {
        if let existingIndex = firstIndex(of: newElement) {
            return (false, existingIndex)
        }
        array.insert(newElement, at: i)
        updateIndices(from: i)
        return (true, i)
    }

    /// Remove and return the element at index `i`.
    @discardableResult public mutating func remove(at index: Int) -> Element {
        let removedElement = array.remove(at: index)
        uniqueIndices.removeValue(forKey: removedElement)
        updateIndices(from: index)
        return removedElement
    }

    /// Remove all elements.
    public mutating func removeAll(keepingCapacity capacity: Bool) {
        array.removeAll(keepingCapacity: capacity)
        uniqueIndices.removeAll(keepingCapacity: capacity)
    }
}

extension OrderedSet: Sendable where Element: Sendable {
}

extension OrderedSet: ExpressibleByArrayLiteral {
    /// Create an instance initialized with `elements`.  If an element occurs more than once in `element`, only the first one will be included.
    public init(arrayLiteral elements: OrderedSet.Element...) {
        self.init()
        for element in elements {
            self.append(element)
        }
    }
}

extension OrderedSet: RandomAccessCollection {
    public var startIndex: Int { return array.startIndex }
    public var endIndex: Int { return array.endIndex }
    public subscript(i: Int) -> Element {
        return array[i]
    }
}

extension OrderedSet: CustomStringConvertible {
    public var description: String {
        elements.description
    }
}

extension OrderedSet: Codable where Element: Codable {
    public init(from decoder: any Swift.Decoder) throws {
        try self.init(Array<Element>(from: decoder))
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try elements.encode(to: encoder)
    }
}

// MARK: Custom extensions

extension OrderedSet {
    /// Returns a new set containing the elements of the receiver followed by the elements of another sequence.
    /// - parameter sequence: Another sequence.
    /// - returns: A new ordered set.
    public func appending<S>(contentsOf sequence: S) -> OrderedSet<Element> where Element == S.Element, S : Sequence {
        var newSet = self
        newSet.append(contentsOf: sequence)
        return newSet
    }
}
