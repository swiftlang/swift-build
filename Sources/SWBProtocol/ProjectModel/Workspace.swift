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

public struct Workspace: Sendable {
    public let guid: String
    public let name: String
    public let path: Path
    public let projectSignatures: [String]

    public init(guid: String, name: String, path: Path, projectSignatures: [String]) {
        self.guid = guid
        self.name = name
        self.path = path
        self.projectSignatures = projectSignatures
    }
}

// MARK: SerializableCodable

extension Workspace: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(guid)
            serializer.serialize(name)
            serializer.serialize(path)
            serializer.serialize(projectSignatures)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.guid = try deserializer.deserialize()
        self.name = try deserializer.deserialize()
        self.path = try deserializer.deserialize()
        self.projectSignatures = try deserializer.deserialize()
    }
}
