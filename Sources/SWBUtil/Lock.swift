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

public typealias SWBMutex = Mutex

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
