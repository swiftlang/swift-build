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

/// An unparsed source for a macro expression.
///
/// This type encapsulates the information needed to precisely define a macro expression (which could either be or a string expression or a list expression) from a source (which could be a string or list of strings).
public enum MacroExpressionSource: Sendable {
    case string(String)
    case stringList([String])
}

// MARK: SerializableCodable

extension MacroExpressionSource: PendingSerializableCodable {
    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as Int {
        case 0:
            self = .string(try deserializer.deserialize())
        case 1:
            self = .stringList(try deserializer.deserialize())
        case let v:
            throw DeserializerError.unexpectedValue("Unexpected type code (\(v))")
        }
    }

    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .string(let value):
                serializer.serialize(0 as Int)
                serializer.serialize(value)
            case .stringList(let value):
                serializer.serialize(1 as Int)
                serializer.serialize(value)
            }
        }
    }
}
