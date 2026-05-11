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

public import SWBUtil

public struct PlatformFilter: Hashable, Sendable {
    public let platform: String
    public let exclude: Bool
    public let environment: String

    public init(platform: String, exclude: Bool = false, environment: String? = nil) {
        self.platform = platform
        self.exclude = exclude
        self.environment = environment ?? ""
    }
}

extension PlatformFilter: Comparable {
    public static func < (lhs: PlatformFilter, rhs: PlatformFilter) -> Bool {
        return lhs.comparisonString < rhs.comparisonString
    }

    fileprivate var comparisonString: String {
        return platform + (!environment.isEmpty ? "-\(environment)" : "")
    }
}

// MARK: SerializableCodable

extension PlatformFilter: PendingSerializableCodable {
    public init(fromLegacy deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(2...3)
        self.platform = try deserializer.deserialize()
        if count >= 3 {
            self.exclude = try deserializer.deserialize()
        } else {
            self.exclude = false
        }
        self.environment = try deserializer.deserialize()
    }

    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(self.platform)
            serializer.serialize(self.exclude)
            serializer.serialize(self.environment)
        }
    }
}
