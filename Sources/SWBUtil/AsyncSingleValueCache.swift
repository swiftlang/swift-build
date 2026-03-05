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

public struct AsyncSingleValueCache<Value: Sendable>: ~Copyable, Sendable {
    enum Key: Hashable {
        case key
    }
    private let cache = AsyncCache<Key, Value>()

    public init() { }

    public func value(body: @Sendable () async throws -> sending Value) async throws -> sending Value {
        try await cache.value(forKey: Key.key, body)
    }
}
