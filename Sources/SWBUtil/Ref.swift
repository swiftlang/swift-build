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

/// Generic reference-semantics wrapper for class types.
///
/// This wrapper avoids additional heap allocation, but does involve a runtime type cast on the accessor.
//
// FIXME: Reevaluate the presence of this wrapper in the face of Swift now auto-boxing any type into AnyObject.
public struct Ref<T>: Hashable {
    fileprivate let _instance: AnyObject

    public init(_ instance: T) {
        self._instance = instance as AnyObject
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(_instance))
    }

    public static func == (lhs: Ref<T>, rhs: Ref<T>) -> Bool {
        return lhs._instance === rhs._instance
    }

    /// The instance stored inside the wrapper.
    public var instance: T {
        return _instance as! T
    }
}

extension Ref: @unchecked Sendable where T: Sendable {}
