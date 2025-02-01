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

public struct ClangCachingTaskCacheKey: Serializable, CustomDebugStringConvertible {
    let libclangPath: Path
    let casOptions: CASOptions
    let cacheKey: String

    init(libclangPath: Path, casOptions: CASOptions, cacheKey: String) {
        self.libclangPath = libclangPath
        self.casOptions = casOptions
        self.cacheKey = cacheKey
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(3) {
            serializer.serialize(libclangPath)
            serializer.serialize(casOptions)
            serializer.serialize(cacheKey)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        libclangPath = try deserializer.deserialize()
        casOptions = try deserializer.deserialize()
        cacheKey = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<ClangCachingTaskCacheKey libclangPath=\(libclangPath) casOptions=\(casOptions) cacheKey=\(cacheKey)>"
    }
}
