//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil

public struct BuildConfigurationFilter: Hashable, Sendable {
    public let buildConfiguration: String

    public init(buildConfiguration: String) {
        self.buildConfiguration = buildConfiguration
    }
}

extension BuildConfigurationFilter: Comparable {
    public static func < (lhs: BuildConfigurationFilter, rhs: BuildConfigurationFilter) -> Bool {
        return lhs.comparisonString < rhs.comparisonString
    }

    fileprivate var comparisonString: String {
        return buildConfiguration
    }
}

// MARK: SerializableCodable

extension BuildConfigurationFilter: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.buildConfiguration)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.buildConfiguration = try deserializer.deserialize()
    }
}
