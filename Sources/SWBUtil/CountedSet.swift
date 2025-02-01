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

/// A collection of unique `Element` instances with no defined ordering, but with a per-element count of the number of times that element is present in the counted set.
// FIXME: We should make CountedSet a CollectionType.
// FIXME: We should also make CountedSet a SequenceType.
public struct CountedSet<T: Hashable> : CustomStringConvertible {

    /// Private mapping from elements to counts.
    private var _elmsToCounts = Dictionary<T, Int>()

    /// Total count (equal to sum of all counts in `elmsToCounts`).
    private var _totalCount = 0

    /// Initializes a new CountedSet with the given elements.
    public init(_ elements: T ...) {
        for elm in elements {
            insert(elm)
        }
    }

    /// Inserts `element` into the counted set, incrementing the count associated with it if it was already present in the counted set, or adding it with a count of one if it isn't.
    public mutating func insert(_ element: T) {
        if let count = _elmsToCounts[element] {
            _elmsToCounts[element] = count + 1
        }
        else {
            _elmsToCounts[element] = 1
        }
        _totalCount += 1
    }

    /// Removes `element` from the counted set, decrementing the count associated with it if it is present in the counted set, or doing nothing the element isn't in the set.  If the count becomes to zero, the element is removed.
    public mutating func remove(_ element: T) {
        if let count = _elmsToCounts[element] {
            _elmsToCounts[element] = (count > 1) ? (count - 1) : nil
            _totalCount -= 1
        }
    }

    /// Returns true iff the counted set is empty.
    public var isEmpty: Bool {
        return _elmsToCounts.isEmpty;
    }

    /// The number of distinct elements in the set (-not- the total number of counts for all the elements).
    public var count: Int {
        return _elmsToCounts.count;
    }

    /// The total number of elements in the set, i.e. the sum of the counts associated with all of the elements.
    public var totalCount: Int {
        assert(_totalCount >= _elmsToCounts.count)
        return _totalCount
    }

    /// Returns the count associated with `element` or zero if it isn't in the set.
    public func countOf(_ element: T) -> Int {
        return _elmsToCounts[element] ?? 0
    }

    /// Returns a string description of the mapping from elements to counts.
    public var description: String {
        return _elmsToCounts.description
    }
}

extension CountedSet: Sendable where T: Sendable {}
