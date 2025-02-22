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

/// Represents a type whose instances can be "empty".
public protocol EmptyState {
    var isEmpty: Bool { get }
}

extension EmptyState {
    /// Returns `nil` if this instance is considered empty, otherwise returns `self`.
    ///
    /// This is used to aid in constructing expressions of form `x.isEmpty ? x : y` where `x` is a complex expression, by allowing it to be instead written as `x.nilIfEmpty ?? y`.
    public var nilIfEmpty: Self? {
        return isEmpty ? nil : self
    }
}

// Add more types here as needed
extension Array: EmptyState { }
extension Path: EmptyState { }
extension String: EmptyState { }
extension Substring: EmptyState { }
extension Set: EmptyState { }
