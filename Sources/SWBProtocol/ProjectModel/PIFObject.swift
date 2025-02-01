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

/// A typealias to define the representation of the PIF schema version.
public typealias PIFSchemaVersion = Int

/// The type of a top-level PIF object.
public enum PIFObjectType: String, Serializable, Sendable, CaseIterable {
    case workspace
    case project
    case target
}

/// An individual PIF object.
public enum PIFObject: Sendable {
    case workspace(Workspace)
    case project(Project)
    case target(Target)

    /// This is the version of the PIF that is supported by the service. This must match the version in `IDEPIFGenerationCategories.swift`, though for staging purposes, a less-than check is used. See comments there for additional information.
    public static var supportedPIFEncodingSchemaVersion: PIFSchemaVersion {
        // NOTE: A computed property is used to ensure the compiler doesn't bake in the constant value.
        return 12
    }
}

/// A set of PIF objects.
public struct PIFObjectList: Sendable {
    public let objects: [PIFObject]

    public init(_ objects: [PIFObject]) {
        self.objects = objects
    }
}

// MARK: SerializableCodable

extension PIFObject: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .workspace(let value):
                serializer.serialize(0 as Int)
                serializer.serialize(value)
            case .project(let value):
                serializer.serialize(1 as Int)
                serializer.serialize(value)
            case .target(let value):
                serializer.serialize(2 as Int)
                serializer.serialize(value)
            }
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as Int {
        case 0:
            self = .workspace(try deserializer.deserialize())
        case 1:
            self = .project(try deserializer.deserialize())
        case 2:
            self = .target(try deserializer.deserialize())
        case let v:
            throw DeserializerError.unexpectedValue("Unexpected type code (\(v))")
        }
    }
}

extension PIFObjectList: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(objects)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        objects = try deserializer.deserialize()
    }
}
