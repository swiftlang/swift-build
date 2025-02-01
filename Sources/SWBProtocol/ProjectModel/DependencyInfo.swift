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

/// A format for how dependency information is communicated from a rule.
public enum DependencyInfo: CustomDebugStringConvertible, Sendable {
    /// A Darwin linker style dependency info file.
    case dependencyInfo(MacroExpressionSource)

    /// A '.d'-style Makefile.
    case makefile(MacroExpressionSource)

    /// A list of multiple '.d'-style Makefiles.
    case makefiles([MacroExpressionSource])

    private enum DependencyInfoCode: UInt, Serializable {
        case dependencyInfo = 0
        case makefile = 1
        case makefiles = 2
    }

    public var debugDescription: String {
        switch self {
        case .dependencyInfo(let path): return ".dependencyInfo(\(path))"
        case .makefile(let path): return ".makefile(\(path))"
        case .makefiles(let paths): return ".makefiles(\(paths))"
        }
    }
}

// MARK: SerializableCodable

extension DependencyInfo: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .dependencyInfo(let path):
                serializer.serialize(DependencyInfoCode.dependencyInfo)
                serializer.serialize(path)
            case .makefile(let path):
                serializer.serialize(DependencyInfoCode.makefile)
                serializer.serialize(path)
            case .makefiles(let paths):
                serializer.serialize(DependencyInfoCode.makefiles)
                serializer.serialize(paths)
            }
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as DependencyInfoCode {
        case .dependencyInfo:
            self = .dependencyInfo(try deserializer.deserialize())
        case .makefile:
            self = .makefile(try deserializer.deserialize())
        case .makefiles:
            self = .makefiles(try deserializer.deserialize())
        }
    }
}
