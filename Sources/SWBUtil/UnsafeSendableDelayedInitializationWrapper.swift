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

/// An Unsafe wrapper for values that are initialized exactly once
public final class UnsafeDelayedInitializationSendableWrapper<T: Sendable>: @unchecked Sendable {
    private var _value: T?

    public init() {
        self._value = nil
    }

    public func initialize(to initializedValue: T) {
        precondition(_value == nil, "value is already initialized")
        _value = initializedValue
    }

    public var value: T {
        guard let _value else {
            preconditionFailure("value was accessed before it was initialized")
        }
        return _value
    }
}
