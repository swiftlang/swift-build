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


/// Utility wrapper for pairs of values.
public struct Pair<First, Second> {
    private let values: (First, Second)

    public var first: First {
        return values.0
    }

    public var second: Second {
        return values.1
    }

    public init(_ first: First, _ second: Second) {
        values = (first, second)
    }
}

// Make Pair hashable if the values are also hashable.
extension Pair: Hashable, Equatable where First: Hashable, Second: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(values.0)
        hasher.combine(values.1)
    }

    public static func == (lhs: Pair<First, Second>, rhs: Pair<First, Second>) -> Bool {
        lhs.values == rhs.values
    }
}

extension Pair: Sendable where First: Sendable, Second: Sendable {}
