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

/// A SourceTree enum describes the root of the path of a Reference object, for those subclasses of Reference which use the SourceTree-Path model.
public enum SourceTree: Equatable, CustomDebugStringConvertible, Sendable {
    /// A Reference whose SourceTree is Absolute has its absolute path fully described by its path variable.
    case absolute

    /// A Reference whose SourceTree is GroupRelative defines its path in terms of the path of its parent group.
    case groupRelative

    /// A Reference whose SourceTree is BuildSetting relative defines its path as relative to the evaluated value of the build setting name in the enum's associated value.
    //
    // FIXME: This should be a MacroExpressionSource.
    case buildSetting(String)

    public var debugDescription: String {
        switch self {
        case .absolute: return ".absolute"
        case .groupRelative: return ".groupRelative"
        case .buildSetting(let s): return ".buildSetting(\(s))"
        }
    }
}

// MARK: SerializableCodable

extension SourceTree: PendingSerializableCodable {
    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as Int {
        case 0:
            try deserializer.deserializeNilThrow()
            self = .absolute
        case 1:
            try deserializer.deserializeNilThrow()
            self = .groupRelative
        case 2:
            self = .buildSetting(try deserializer.deserialize())
        case let v:
            throw DeserializerError.unexpectedValue("Unexpected type code (\(v))")
        }
    }

    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .absolute:
                serializer.serialize(0 as Int)
                serializer.serializeNil()
            case .groupRelative:
                serializer.serialize(1 as Int)
                serializer.serializeNil()
            case .buildSetting(let value):
                serializer.serialize(2 as Int)
                serializer.serialize(value)
            }
        }
    }
}
