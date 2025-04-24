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

import SWBLibc
import Synchronization

// Workaround compiler crash: rdar://138854389 (Compiler crashes when compiling code using a Mutex with an Optional)
#if os(Windows)
private struct Storage<T> {
    let _value: Any?

    init(value: T? = nil) { _value = value }

    var value: T? {
        _value as! T?
    }

    static var none: Storage {
        .init()
    }

    static func some(_ value: T) -> Storage {
        .init(value: value)
    }
}
private typealias LazyStorage = Storage
#else
private typealias LazyStorage = Optional
fileprivate extension Optional {
    var value: Wrapped? {
        switch self {
        case let .some(wrapped):
            return wrapped
        case .none:
            return nil
        }
    }
}
#endif

/// Wrapper for thread-safe lazily computed values.
public final class Lazy<T: Sendable>: Sendable {
    private let cachedValue = SWBMutex<LazyStorage<T>>(.none)

    public func getValue(_ body: () throws -> T, isValid: (T) throws -> Bool = { _ in true }) rethrows -> T {
        try cachedValue.withLock { cachedValue in
            if let value = cachedValue.value, try isValid(value) {
                return value
            } else {
                let result = try body()
                cachedValue = .some(result)
                return result
            }
        }
    }
}

/// Wrapper for thread-safe lazily computed values.
public final class LazyCache<Class, T> {
    private let body: @Sendable (Class) -> T
    private let cachedValue = LockedValue<T?>(nil)

    public init(body: @escaping @Sendable (Class) -> T) {
        self.body = body
    }

    public func getValue(_ instance: Class) -> T {
        return cachedValue.withLock { cachedValue in
            if let value = cachedValue {
                return value
            } else {
                let result = body(instance)
                cachedValue = result
                return result
            }
        }
    }
}

extension LazyCache: Sendable where T: Sendable {}

/// Wrapper for thread-safe lazily computed key-value pairs.
public final class LazyKeyValueCache<Class, Key: Hashable & Sendable, Value> {
    private let body: @Sendable (Class, Key) -> Value
    private let cachedValues = LockedValue<[Key: Value]>([:])

    public init(body: @escaping @Sendable (Class, Key) -> Value) {
        self.body = body
    }

    public func getValue(_ instance: Class, forKey key: Key) -> Value {
        return cachedValues.withLock { cachedValues in
            if let value = cachedValues[key] {
                return value
            } else {
                let result = body(instance, key)
                cachedValues[key] = result
                return result
            }
        }
    }
}

extension LazyKeyValueCache: Sendable where Value: Sendable {}
