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
    public let environment: String

    public init(platform: String, environment: String? = nil) {
        self.platform = platform
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
        try deserializer.beginAggregate(2)
        self.platform = try deserializer.deserialize()
        self.environment = try deserializer.deserialize()
    }

    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.platform)
            serializer.serialize(self.environment)
        }
    }
}
