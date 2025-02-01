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

public class Reference: PolymorphicSerializable, @unchecked Sendable {
    public static let implementations: [SerializableTypeCode : any PolymorphicSerializable.Type] = [
        0: FileReference.self,
        1: VersionGroup.self,
        2: VariantGroup.self,
        3: FileGroup.self,
        4: ProductReference.self,
    ]

    public let guid: String

    public init(guid: String) {
        self.guid = guid
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(guid)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.guid = try deserializer.deserialize()
    }
}

public class GroupTreeReference: Reference, @unchecked Sendable {
    public let sourceTree: SourceTree
    public let path: MacroExpressionSource

    public init(guid: String, sourceTree: SourceTree, path: MacroExpressionSource) {
        self.sourceTree = sourceTree
        self.path = path
        super.init(guid: guid)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(sourceTree)
            serializer.serialize(path)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.sourceTree = try deserializer.deserialize()
        self.path = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

/// Text encoding associated with a file reference.
public struct FileTextEncoding: Hashable, CustomStringConvertible, Sendable {
    /// IANA "charset" identifying the encoding.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let utf8 = FileTextEncoding("utf-8") // 4
    public static let utf16 = FileTextEncoding("utf-16") // 10
    public static let utf16be = FileTextEncoding("utf-16be") // 0x90000100
    public static let utf16le = FileTextEncoding("utf-16le") // 0x94000100
    public static let utf32 = FileTextEncoding("utf-32") // 0x8c000100
    public static let utf32be = FileTextEncoding("utf-32be") // 0x98000100
    public static let utf32le = FileTextEncoding("utf-32le") // 0x9c000100

    public var description: String {
        return rawValue
    }

    /// Returns the Unicode byte order mark for the given encoding.
    /// Returns an empty array if the encoding does not have an associated BOM.
    public var byteOrderMark: [UInt8] {
        switch self {
        case .utf8:
            return [0xEF, 0xBB, 0xBF]
        case .utf16be:
            return [0xFE, 0xFF]
        case .utf16le:
            return [0xFF, 0xFE]
        case .utf32be:
            return [0x00, 0x00, 0xFE, 0xFF]
        case .utf32le:
            return [0xFF, 0xFE, 0x00, 0x00]
        default:
            return []
        }
    }
}

extension FileTextEncoding: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serialize(rawValue)
    }

    /// Create a new instance of the receiver from a deserializer.
    public init(fromLegacy deserializer: any Deserializer) throws {
        self.init(try deserializer.deserialize())
    }
}

public final class FileReference: GroupTreeReference, @unchecked Sendable {
    public let fileTypeIdentifier: String
    public let regionVariantName: String?
    public let fileTextEncoding: FileTextEncoding?
    public let expectedSignature: String?

    public init(guid: String, sourceTree: SourceTree, path: MacroExpressionSource, fileTypeIdentifier: String, regionVariantName: String?, fileTextEncoding: FileTextEncoding?, expectedSignature: String?) {
        self.fileTypeIdentifier = fileTypeIdentifier
        self.regionVariantName = regionVariantName
        self.fileTextEncoding = fileTextEncoding
        self.expectedSignature = expectedSignature
        super.init(guid: guid, sourceTree: sourceTree, path: path)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(5) {
            serializer.serialize(fileTypeIdentifier)
            serializer.serialize(regionVariantName)
            serializer.serialize(fileTextEncoding)
            serializer.serialize(expectedSignature)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.fileTypeIdentifier = try deserializer.deserialize()
        self.regionVariantName = try deserializer.deserialize()
        self.fileTextEncoding = try deserializer.deserialize()
        self.expectedSignature = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

public final class VersionGroup: GroupTreeReference, @unchecked Sendable {
    public let children: [GroupTreeReference]

    public init(guid: String, sourceTree: SourceTree, path: MacroExpressionSource, children: [GroupTreeReference]) {
        self.children = children
        super.init(guid: guid, sourceTree: sourceTree, path: path)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(children)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.children = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

public final class VariantGroup: GroupTreeReference, @unchecked Sendable {
    public let name: String
    public let children: [GroupTreeReference]

    public init(guid: String, sourceTree: SourceTree, path: MacroExpressionSource, name: String, children: [GroupTreeReference]) {
        self.name = name
        self.children = children
        super.init(guid: guid, sourceTree: sourceTree, path: path)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(name)
            serializer.serialize(children)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.name = try deserializer.deserialize()
        self.children = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

public final class FileGroup: GroupTreeReference, @unchecked Sendable {
    public let name: String
    public let children: [GroupTreeReference]

    public init(guid: String, sourceTree: SourceTree, path: MacroExpressionSource, name: String, children: [GroupTreeReference]) {
        self.name = name
        self.children = children
        super.init(guid: guid, sourceTree: sourceTree, path: path)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(name)
            serializer.serialize(children)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.name = try deserializer.deserialize()
        self.children = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

public final class ProductReference: Reference, @unchecked Sendable {
    public let name: String

    public init(guid: String, name: String) {
        self.name = name
        super.init(guid: guid)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(name)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.name = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}
