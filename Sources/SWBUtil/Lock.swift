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

public import Synchronization

#if canImport(Darwin)
public import os

/// A more efficient lock than a DispatchQueue (esp. under contention).
public typealias Lock = OSAllocatedUnfairLock

/// Small wrapper to provide only locked access to its value.
/// Be aware that it's not possible to share this lock for multiple data
/// instances and using multiple of those can easily lead to deadlocks.
public final class LockedValue<Value: ~Copyable> {
    @usableFromInline let lock = Lock()
    /// Don't use this from outside this class. Is internal to be inlinable.
    @usableFromInline var value: Value
    public init(_ value: consuming sending Value) {
        self.value = value
    }
}

extension LockedValue where Value: ~Copyable {
    @discardableResult @inlinable
    public borrowing func withLock<Result: ~Copyable, E: Error>(_ block: (inout sending Value) throws(E) -> sending Result) throws(E) -> sending Result {
        lock.lock()
        defer { lock.unlock() }
        return try block(&value)
    }
}

extension LockedValue: @unchecked Sendable where Value: ~Copyable {
}

@available(macOS, deprecated: 15.0, renamed: "Synchronization.Mutex")
@available(iOS, deprecated: 18.0, renamed: "Synchronization.Mutex")
@available(tvOS, deprecated: 18.0, renamed: "Synchronization.Mutex")
@available(watchOS, deprecated: 11.0, renamed: "Synchronization.Mutex")
@available(visionOS, deprecated: 2.0, renamed: "Synchronization.Mutex")
public typealias SWBMutex = LockedValue
#else
public typealias SWBMutex = Mutex
#endif

extension SWBMutex where Value: ~Copyable, Value == Void {
    public borrowing func withLock<Result: ~Copyable, E: Error>(_ body: () throws(E) -> sending Result) throws(E) -> sending Result {
        try withLock { _ throws(E) -> sending Result in return try body() }
    }
}

extension SWBMutex where Value: Sendable {
    /// Sets the value of the wrapped value to `newValue` and returns the original value.
    public func exchange(_ newValue: Value) -> Value {
        withLock {
            let old = $0
            $0 = newValue
            return old
        }
    }
}
