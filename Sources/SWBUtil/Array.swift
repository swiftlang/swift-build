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

public extension Array
{
    // Typechecking of operator+ can be extraordinarily slow, even for small expressions; use this instead when needed.
    func appending(contentsOf other: [Element]) -> [Element] {
        return self + other
    }
}

public extension Array where Element: Equatable
{
    /// Returns the element immediately following the first contiguous subsequence of elements equal to `elements`.
    func elementAfterElements(_ elements: [Element]) -> Element? {
        if let range = self.firstRange(of: elements), range.upperBound != endIndex {
            // Open range, so the upper bound is the target element
            return self[range.upperBound]
        }
        return nil
    }

    @discardableResult
    mutating func removeAll(where predicate: (Element) throws -> Bool) rethrows -> Int {
        let count = self.count
        try self.removeAll(where: predicate) as Void
        return count - self.count
    }
}

public extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        return OrderedSet(self).elements
    }
}

public extension Array where Element == String {
    /// Constructs and returns an array consisting of all the elements in the receiver that have the prefix `prefix`.
    ///
    /// The prefix is stripped off of the strings in the returned array.
    /// If a prefix appears by itself, the array element following it (if any) is returned instead.
    /// For example, the array `["-c", "-I/usr/include", "-I", "/usr/local/include", "-O", "-I.", "a.c"]` and prefix `"-I"` yields `["/usr/include", "/usr/local/include", "."]`. If there are no matches, the empty array is returned.
    /// If `prefix` is an empty string, the original array is returned.
    ///
    /// - parameter prefix: The prefix preceding each of the elements of the returned array, in the original array.
    func byExtractingElementsHavingPrefix(_ prefix: String) -> [Element] {
        if isEmpty {
            return []
        }

        // Optimization; the code path below would result in this anyways
        if prefix.isEmpty {
            return self
        }

        var args = [String]()
        var i = makeIterator()
        while let arg = i.next() {
            if arg.hasPrefix(prefix) {
                if arg == prefix {
                    if let val = i.next() {
                        args.append(val)
                    }
                } else {
                    args.append(arg.withoutPrefix(prefix))
                }
            }
        }

        return args
    }
}

public extension Array where Element: Numeric {

    /// Returns the sum of the values of the receiver.
    func sum() -> Element {
        return self.reduce(0, +)
    }

}

public extension Array where Element: FloatingPoint {

    /// Returns the average (mean) of the values in the receiver.
    ///
    /// This isn't supported for non-floating types since the result is highly likely to be a non-integer.
    func average() -> Element {
        precondition(!self.isEmpty, "cannot request the average of an empty array")
        return self.sum() / Element(self.count)
    }

    /// Returns the standard deviation of the values in the receiver.
    ///
    /// This is a sample standard deviation, not a population standard deviation.
    ///
    /// This isn't supported for non-floating types since the result is highly likely to be a non-integer.
    func standardDeviation() -> Element {
        // The standard deviation is always 0 if there are 0 or 1 elements.
        guard self.count > 1 else {
            return Element(0)
        }
        let average = self.average()
        let v = self.reduce(0) { (acc: Element, next: Element) in acc + (next-average)*(next-average) }
        return (v / (Element(self.count) - 1)).squareRoot()
    }

}

extension Sequence {
    public func asyncFilter<E>(_ isIncluded: (Element) async throws(E) -> Bool) async throws(E) -> [Element] {
        var elements: [Element] = []
        for element in self {
            if try await isIncluded(element) {
                elements.append(element)
            }
        }
        return elements
    }

    public func asyncMap<T, E>(_ transform: (Element) async throws(E) -> T) async throws(E) -> [T] {
        var elements: [T] = []
        for element in self {
            try await elements.append(transform(element))
        }
        return elements
    }

    public func asyncFlatMap<SegmentOfResult, E>(_ transform: (Self.Element) async throws(E) -> SegmentOfResult) async throws(E) -> [SegmentOfResult.Element] where SegmentOfResult : Sequence {
        var elements: [SegmentOfResult.Element] = []
        for element in self {
            try await elements.append(contentsOf: transform(element))
        }
        return elements
    }
}

extension Sequence where Element: Sendable {
    public func concurrentMap<T: Sendable>(maximumParallelism: Int, _ body: @Sendable @escaping (Element) async throws -> T) async rethrows -> [T] {
        var results: [T?] = []

        var started = 0
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var index = 0
            for element in self {
                // Expand the results array with initial value nil
                // which will be later be replaced with the final value
                results.append(nil)
                defer {
                    index += 1
                }
                group.addTask { [index] in
                    let transformedElement = try await body(element)
                    return (index, transformedElement)
                }
                started += 1

                if started >= maximumParallelism {
                    if let (index, transformedElement) = try await group.next() {
                        assert(results[index] == nil)
                        results[index] = transformedElement
                    }
                }
            }
            while let (index, transformedElement) = try await group.next() {
                assert(results[index] == nil)
                results[index] = transformedElement
            }
        }
        assert(results.allSatisfy { $0 != nil })
        return results.map { $0! }
    }
}

extension Array {
    /// Returns only one of the elements in the array by traversing the array and choosing a preferred element from each pair of adjacent elements until there is only a single element remaining.
    /// If the array is empty, returns `nil`. If the array contains only one element, returns that element.
    public func one(by selectingElement: (Element, Element) throws -> Element) rethrows -> Element? {
        return isEmpty ? nil : try dropFirst().reduce(self[0], selectingElement)
    }
}

public struct NWayMergeElement<T: Equatable & Sendable>: Equatable, CustomDebugStringConvertible, Sendable {
    public let element: T
    public fileprivate(set) var elementOf: Set<Int>

    @_spi(Testing) public init(element: T, elementOf: Set<Int>) {
        self.element = element
        self.elementOf = elementOf
    }

    public var debugDescription: String {
        "(\(element) in \(elementOf)"
    }
}

public func nWayMerge<T: Equatable & Sendable>(_ arrays: [[T]]) -> [NWayMergeElement<T>] {
    guard !arrays.isEmpty else { return [] }
    guard arrays.count > 1 else { return arrays[0].map { NWayMergeElement(element: $0, elementOf: Set([0])) } }

    var merged = arrays[0].map { NWayMergeElement(element: $0, elementOf: Set([0])) }
    for (idx, array) in arrays.enumerated().dropFirst() {
        merged = merged.map { NWayMergeElement(element: $0.element, elementOf: $0.elementOf.union([idx])) }
        let next =  array.map { NWayMergeElement(element: $0, elementOf: Set([idx])) }
        let diff = next.difference(from: merged, by: { first, second in first.element == second.element })
        for change in diff {
            switch change {
            case .insert(offset: let offset, element: let element, associatedWith: _):
                let adjustment = diff.removals.filter { $0.offset <= offset }.count
                merged.insert(element, at: offset+adjustment)
            case .remove(offset: let offset, element: _, associatedWith: _):
                merged[offset].elementOf.remove(idx)
            }
        }

    }
    return merged
}

extension CollectionDifference.Change {
    var offset: Int {
        switch self {
        case .insert(offset: let offset, element: _, associatedWith: _), .remove(offset: let offset, element: _, associatedWith: _):
            return offset
        }
    }
}
