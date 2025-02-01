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

public struct ImpartedBuildProperties: Sendable {
    public let buildSettings: [BuildConfiguration.MacroBindingSource]

    public init(buildSettings: [BuildConfiguration.MacroBindingSource]) {
        self.buildSettings = buildSettings
    }
}

// MARK: SerializableCodable

extension ImpartedBuildProperties: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(buildSettings)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.buildSettings = try deserializer.deserialize()
    }
}
