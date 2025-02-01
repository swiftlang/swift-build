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

public struct TargetDependency: Sendable {
    public let guid: String
    public let name: String?
    public let platformFilters: Set<PlatformFilter>

    public init(guid: String, name: String?, platformFilters: Set<PlatformFilter> = []) {
        self.guid = guid
        self.name = name
        self.platformFilters = platformFilters
    }
}

// MARK: SerializableCodable

extension TargetDependency: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(guid)
            serializer.serialize(name)
            serializer.serialize(platformFilters)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.guid = try deserializer.deserialize()
        self.name = try deserializer.deserialize()
        self.platformFilters = try deserializer.deserialize()
    }
}
