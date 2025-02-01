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

/// The results of diffing two sequences
public struct Diff<T: Comparable> {
    /// Values that were present in the left sequence but absent in the right sequence.
    public var left: [T] = []

    /// Values that were present in both sequences.
    public var equal: [T] = []

    /// Values that were present in the right sequence but absent in the left sequence.
    public var right: [T] = []
}

extension Diff: Sendable where T: Sendable {}

public extension Sequence where Element: Comparable {
    /// Compares the contents of two sequences of comparable contents.
    ///
    /// Puts each item in both sequences into a bucket according to which sequence(s) contain it.
    func diff<T: Sequence>(against other: T) -> Diff<Element> where T.Element == Element {
        var diff = Diff<Element>()

        var leftIterator = sorted().makeIterator()
        var rightIterator = other.sorted().makeIterator()

        var leftItem = leftIterator.next()
        var rightItem = rightIterator.next()

        while let left = leftItem, let right = rightItem {
            if left == right {
                diff.equal.append(left)
                leftItem = leftIterator.next()
                rightItem = rightIterator.next()
            } else if left < right {
                diff.left.append(left)
                leftItem = leftIterator.next()
            } else {
                diff.right.append(right)
                rightItem = rightIterator.next()
            }
        }

        while let left = leftItem {
            diff.left.append(left)
            leftItem = leftIterator.next()
        }

        while let right = rightItem {
            diff.right.append(right)
            rightItem = rightIterator.next()
        }

        return diff
    }
}
