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

public struct AsyncSingleValueCache<Value: Sendable, E: Error>: ~Copyable, Sendable {
    private let value = AsyncLockedValue<Value?>(nil)

    public init() { }

    public func value(body: sending () async throws(E) -> sending Value) async throws(E) -> sending Value {
        try await value.withLock { value throws(E) in
            if let value {
                return value
            } else {
                let newValue = try await body()
                value = newValue
                return newValue
            }
        }
    }
}
