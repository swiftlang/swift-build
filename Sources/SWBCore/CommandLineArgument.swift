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

public enum CommandLineArgument: Equatable, Hashable, ExpressibleByStringLiteral, Serializable, Sendable {
    case literal(ByteString)
    case path(Path)
    case parentPath(Path)

    public var asString: String {
        switch self {
        case .literal(let byteString):
            return byteString.asString
        case .path(let path):
            return path.str
        case .parentPath(let path):
            return path.dirname.str
        }
    }

    public var asByteString: ByteString {
        switch self {
        case .literal(let byteString):
            return byteString
        case .path(let path):
            return ByteString(encodingAsUTF8: path.str)
        case .parentPath(let path):
            return ByteString(encodingAsUTF8: path.dirname.str)
        }
    }

    public init(stringLiteral value: StringLiteralType) {
        self = .literal(ByteString(stringLiteral: value))
    }

    public func serialize<T>(to serializer: T) where T : SWBUtil.Serializer {
        switch self {
        case .literal(let byteString):
            // FIXME: pack in one byte
            serializer.beginAggregate(2)
            serializer.serialize(0 as UInt8)
            serializer.serialize(byteString)
            serializer.endAggregate()
        case .path(let path):
            serializer.beginAggregate(2)
            serializer.serialize(1 as UInt8)
            serializer.serialize(path)
            serializer.endAggregate()
        case .parentPath(let path):
            serializer.beginAggregate(2)
            serializer.serialize(2 as UInt8)
            serializer.serialize(path)
            serializer.endAggregate()
        }
    }

    public init(from deserializer: any SWBUtil.Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as UInt8 {
        case 0:
            self = .literal(try deserializer.deserialize())
        case 1:
            self = .path(try deserializer.deserialize())
        case 2:
            self = .parentPath(try deserializer.deserialize())
        default:
            throw StubError.error("unknown command line argument type")
        }
    }
}
