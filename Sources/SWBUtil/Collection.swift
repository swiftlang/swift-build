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

public extension Collection {
    /// Return the element if in bounds, or nil.
    subscript(safe index: Index) -> Iterator.Element? {
        return index >= startIndex && index < endIndex ? self[index] : nil
    }

    /// Return the only element in the collection, if it has exactly one element.
    /// - complexity: O(1).
    var only: Iterator.Element? {
        return !isEmpty && index(after: startIndex) == endIndex ? self.first : nil
    }

    /// Returns the elements of the sequence, sorted using the given key path as the comparison between elements.
    @inlinable func sorted<Value: Comparable>(by predicate: (Element) -> Value) -> [Element] {
        return sorted(<, by: predicate)
    }

    /// Returns the elements of the sequence, sorted using the given key path as the comparison between elements.
    @inlinable func sorted<Value: Comparable>(_ areInIncreasingOrder: (Value, Value) throws -> Bool, by predicate: (Element) -> Value) rethrows -> [Element] {
        return try sorted { try areInIncreasingOrder(predicate($0), predicate($1)) }
    }
}

extension Collection where Element: Equatable, SubSequence: Equatable, Index == Int {
    /// Returns a Boolean value indicating whether the collection begins with the specified prefix.
    public func hasPrefix(_ prefix: Self) -> Bool {
        guard count >= prefix.count else { return false }
        return self[..<prefix.count] == prefix[...]
    }

    /// Returns a Boolean value indicating whether the collection ends with the specified suffix.
    public func hasSuffix(_ suffix: Self) -> Bool {
        guard count >= suffix.count else { return false }
        return self[(count - suffix.count)...] == suffix[...]
    }
}

public extension RandomAccessCollection where Element: Equatable {
    /// Returns the element immediately following the first element equal to `element`.
    func elementAfterElement(_ element: Element) -> Element? {
        return elementAfterElement(where: { $0 == element })
    }

    /// Returns the element immediately following the first element matching `predicate`.
    func elementAfterElement(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        if let index = try firstIndex(where: predicate) {
            let next = self.index(after: index)
            if next != endIndex {
                return self[next]
            }
        }
        return nil
    }
}
