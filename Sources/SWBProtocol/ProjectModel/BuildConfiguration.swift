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

public struct BuildConfiguration: Sendable {
    public struct MacroBindingSource: Sendable {
        // The key, including any conditions if present.
        public let key: String
        public let value: MacroExpressionSource

        public init(key: String, value: MacroExpressionSource) {
            self.key = key
            self.value = value
        }
    }

    public let name: String
    public let buildSettings: [MacroBindingSource]
    public let baseConfigurationFileReferenceGUID: String?
    public let impartedBuildProperties: ImpartedBuildProperties

    public init(name: String, buildSettings: [MacroBindingSource], baseConfigurationFileReferenceGUID: String?, impartedBuildProperties: ImpartedBuildProperties) {
        self.name = name
        self.buildSettings = buildSettings
        self.baseConfigurationFileReferenceGUID = baseConfigurationFileReferenceGUID
        self.impartedBuildProperties = impartedBuildProperties
    }
}

// MARK: SerializableCodable

extension BuildConfiguration: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(name)
            serializer.serialize(buildSettings)
            serializer.serialize(baseConfigurationFileReferenceGUID)
            serializer.serialize(impartedBuildProperties)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.name = try deserializer.deserialize()
        self.buildSettings = try deserializer.deserialize()
        self.baseConfigurationFileReferenceGUID = try deserializer.deserialize()
        self.impartedBuildProperties = try deserializer.deserialize()
    }
}

extension BuildConfiguration.MacroBindingSource: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(key)
            serializer.serialize(value)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.key = try deserializer.deserialize()
        self.value = try deserializer.deserialize()
    }
}
