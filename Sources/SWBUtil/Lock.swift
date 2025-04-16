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

#if canImport(os)
public import os
#elseif os(Windows)
public import WinSDK
#else
public import SWBLibc
#endif

// FIXME: Replace the contents of this file with the Swift standard library's Mutex type once it's available everywhere we deploy.

/// A more efficient lock than a DispatchQueue (esp. under contention).
#if canImport(os)
public typealias Lock = OSAllocatedUnfairLock
#else
public final class Lock: @unchecked Sendable {
    #if os(Windows)
    @usableFromInline
    let mutex: UnsafeMutablePointer<SRWLOCK> = UnsafeMutablePointer.allocate(capacity: 1)
    #elseif os(OpenBSD)
    @usableFromInline
    let mutex: UnsafeMutablePointer<pthread_mutex_t?> = UnsafeMutablePointer.allocate(capacity: 1)
    #else
    @usableFromInline
    let mutex: UnsafeMutablePointer<pthread_mutex_t> = UnsafeMutablePointer.allocate(capacity: 1)
    #endif

    public init() {
        #if os(Windows)
        InitializeSRWLock(self.mutex)
        #else
        let err = pthread_mutex_init(self.mutex, nil)
        precondition(err == 0)
        #endif
    }

    deinit {
        #if os(Windows)
        // SRWLOCK does not need to be freed
        #else
        let err = pthread_mutex_destroy(self.mutex)
        precondition(err == 0)
        #endif
        mutex.deallocate()
    }

    @usableFromInline
    func lock() {
        #if os(Windows)
        AcquireSRWLockExclusive(self.mutex)
        #else
        let err = pthread_mutex_lock(self.mutex)
        precondition(err == 0)
        #endif
    }

    @usableFromInline
    func unlock() {
        #if os(Windows)
        ReleaseSRWLockExclusive(self.mutex)
        #else
        let err = pthread_mutex_unlock(self.mutex)
        precondition(err == 0)
        #endif
    }

    @inlinable
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return try body()
    }
}
#endif

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

extension LockedValue {
    /// Sets the value of the wrapped value to `newValue` and returns the original value.
    public func exchange(_ newValue: Value) -> Value {
        withLock {
            let old = $0
            $0 = newValue
            return old
        }
    }
}

#if canImport(Darwin)
@available(macOS, deprecated: 15.0, renamed: "Synchronization.Mutex")
@available(iOS, deprecated: 18.0, renamed: "Synchronization.Mutex")
@available(tvOS, deprecated: 18.0, renamed: "Synchronization.Mutex")
@available(watchOS, deprecated: 11.0, renamed: "Synchronization.Mutex")
@available(visionOS, deprecated: 2.0, renamed: "Synchronization.Mutex")
public typealias SWBMutex = LockedValue
#else
public import Synchronization
public typealias SWBMutex = Mutex
#endif

extension SWBMutex where Value: ~Copyable, Value == Void {
    public borrowing func withLock<Result: ~Copyable, E: Error>(_ body: () throws(E) -> sending Result) throws(E) -> sending Result {
        try withLock { _ throws(E) -> sending Result in return try body() }
    }
}
