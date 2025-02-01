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

public struct BuildFile: Sendable {
    // FIXME: Change this to an Int once we don't need the rawValue initializer elsewhere.
    public enum HeaderVisibility: String, CaseIterable, Serializable, Sendable, Codable {
        case `public`
        case `private`
    }

    // FIXME: Change this to an Int once we don't need the rawValue initializer elsewhere.
    public enum MigCodegenFiles: String, CaseIterable, Serializable, Sendable, Codable {
        case client
        case server
        case both
    }

    public enum IntentsCodegenVisibility: String, CaseIterable, Serializable, Sendable, Codable {
        case `public`
        case `private`
        case project
        case noCodegen = "no_codegen"
    }

    public enum ResourceRule: String, CaseIterable, Serializable, Sendable, Codable {
        case process
        case copy
        case embedInCode
    }

    public enum BuildableItemGUID: Sendable {
        /// A file like reference type.
        case reference(guid: String)
        /// A target product reference type.
        case targetProduct(guid: String)
        /// A reference by name.
        case namedReference(name: String, fileTypeIdentifier: String)
    }

    public let guid: String
    public let buildableItemGUID: BuildableItemGUID
    public let additionalArgs: MacroExpressionSource?
    public let decompress: Bool
    public let headerVisibility: HeaderVisibility?
    public let migCodegenFiles: MigCodegenFiles?
    public let intentsCodegenVisibility: IntentsCodegenVisibility
    public let resourceRule: ResourceRule
    public let codeSignOnCopy: Bool
    public let removeHeadersOnCopy: Bool
    public let shouldLinkWeakly: Bool
    public let assetTags: Set<String>
    public let platformFilters: Set<PlatformFilter>
    public let shouldWarnIfNoRuleToProcess: Bool

    public init(guid: String, buildableItemGUID: BuildableItemGUID, additionalArgs: MacroExpressionSource?, decompress: Bool = false, headerVisibility: HeaderVisibility?, migCodegenFiles: MigCodegenFiles?, intentsCodegenFiles: Bool = false, intentsCodegenVisibility: IntentsCodegenVisibility? = nil, resourceRule: ResourceRule = .process, codeSignOnCopy: Bool, removeHeadersOnCopy: Bool, shouldLinkWeakly: Bool, assetTags: Set<String> = Set() /* this default is here for revlock with PIF Generation */, platformFilters: Set<PlatformFilter> = [], shouldWarnIfNoRuleToProcess: Bool = true) {
        self.guid = guid
        self.buildableItemGUID = buildableItemGUID
        self.additionalArgs = additionalArgs
        self.decompress = decompress
        self.headerVisibility = headerVisibility
        self.migCodegenFiles = migCodegenFiles
        if let intentsCodegenVisibility {
            self.intentsCodegenVisibility = intentsCodegenVisibility
        } else {
            self.intentsCodegenVisibility = intentsCodegenFiles ? .public : .noCodegen
        }
        self.resourceRule = resourceRule
        self.codeSignOnCopy = codeSignOnCopy
        self.removeHeadersOnCopy = removeHeadersOnCopy
        self.shouldLinkWeakly = shouldLinkWeakly
        self.assetTags = assetTags
        self.platformFilters = platformFilters
        self.shouldWarnIfNoRuleToProcess = shouldWarnIfNoRuleToProcess
    }
}

// MARK: SerializableCodable

extension BuildFile: PendingSerializableCodable {
    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(14)
        self.guid = try deserializer.deserialize()
        self.buildableItemGUID = try deserializer.deserialize()
        self.additionalArgs = try deserializer.deserialize()
        self.decompress = try deserializer.deserialize()
        self.headerVisibility = try deserializer.deserialize()
        self.migCodegenFiles = try deserializer.deserialize()
        self.intentsCodegenVisibility = try deserializer.deserialize()
        self.resourceRule = try deserializer.deserialize()
        self.codeSignOnCopy = try deserializer.deserialize()
        self.removeHeadersOnCopy = try deserializer.deserialize()
        self.shouldLinkWeakly = try deserializer.deserialize()
        self.assetTags = try deserializer.deserialize()
        self.platformFilters = try deserializer.deserialize()
        self.shouldWarnIfNoRuleToProcess = try deserializer.deserialize()
    }

    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(14) {
            serializer.serialize(guid)
            serializer.serialize(buildableItemGUID)
            serializer.serialize(additionalArgs)
            serializer.serialize(decompress)
            serializer.serialize(headerVisibility)
            serializer.serialize(migCodegenFiles)
            serializer.serialize(intentsCodegenVisibility)
            serializer.serialize(resourceRule)
            serializer.serialize(codeSignOnCopy)
            serializer.serialize(removeHeadersOnCopy)
            serializer.serialize(shouldLinkWeakly)
            serializer.serialize(assetTags)
            serializer.serialize(platformFilters)
            serializer.serialize(shouldWarnIfNoRuleToProcess)
        }
    }
}

extension BuildFile.BuildableItemGUID: PendingSerializableCodable {
    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as Int {
        case 0:
            self = .reference(guid: try deserializer.deserialize())
        case 1:
            self = .targetProduct(guid: try deserializer.deserialize())
        case 2:
            try deserializer.beginAggregate(2)
            let name: String = try deserializer.deserialize()
            let fileTypeIdentifier: String = try deserializer.deserialize()
            self = .namedReference(name: name, fileTypeIdentifier: fileTypeIdentifier)
        case let v:
            throw DeserializerError.unexpectedValue("Unexpected type code (\(v))")
        }
    }

    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .reference(let value):
                serializer.serialize(0 as Int)
                serializer.serialize(value)
            case .targetProduct(let value):
                serializer.serialize(1 as Int)
                serializer.serialize(value)
            case .namedReference(let name, let fileTypeIdentifier):
                serializer.serialize(2 as Int)
                serializer.beginAggregate(2)
                serializer.serialize(name)
                serializer.serialize(fileTypeIdentifier)
                serializer.endAggregate()
            }
        }
    }
}
