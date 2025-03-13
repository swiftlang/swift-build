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

import SWBCore
public import SWBUtil

public struct SwiftCachingKeyQueryTaskKey: Serializable, CustomDebugStringConvertible {
    let casOptions: CASOptions
    let cacheKeys: [String]
    let compilerLocation: LibSwiftDriver.CompilerLocation

    init(casOptions: CASOptions, cacheKeys: [String], compilerLocation: LibSwiftDriver.CompilerLocation) {
        self.casOptions = casOptions
        self.cacheKeys = cacheKeys
        self.compilerLocation = compilerLocation
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(3) {
            serializer.serialize(casOptions)
            serializer.serialize(cacheKeys)
            serializer.serialize(compilerLocation)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        casOptions = try deserializer.deserialize()
        cacheKeys = try deserializer.deserialize()
        compilerLocation = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<SwiftCachingKeyQuery casOptions=\(casOptions) cacheKey=\(cacheKeys) compilerLocation=\(compilerLocation)>"
    }
}

public struct SwiftCachingOutputMaterializerTaskKey: Serializable, CustomDebugStringConvertible {
    let casOptions: CASOptions
    let casID: String
    let outputKind: String
    let compilerLocation: LibSwiftDriver.CompilerLocation

    init(
        casOptions: CASOptions,
        casID: String,
        outputKind: String,
        compilerLocation: LibSwiftDriver.CompilerLocation
    ) {
        self.casOptions = casOptions
        self.casID = casID
        self.outputKind = outputKind
        self.compilerLocation = compilerLocation
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(4) {
            serializer.serialize(casOptions)
            serializer.serialize(casID)
            serializer.serialize(outputKind)
            serializer.serialize(compilerLocation)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        casOptions = try deserializer.deserialize()
        casID = try deserializer.deserialize()
        outputKind = try deserializer.deserialize()
        compilerLocation = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<SwiftCachingOutputMaterializer casOptions=\(casOptions) casID=\(casID) outputKind=\(outputKind) compilerLocation=\(compilerLocation)>"
    }
}
