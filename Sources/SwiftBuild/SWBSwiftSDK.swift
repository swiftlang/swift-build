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

import SWBProtocol
import SWBUtil

public struct SWBSwiftSDK: Codable, Sendable {
    public struct TripleProperties: Codable, Sendable {
        public var sdkRootPath: String?
        public var swiftResourcesPath: String?
        public var swiftStaticResourcesPath: String?
        public var includeSearchPaths: [String]?
        public var librarySearchPaths: [String]?
        public var toolsetPaths: [String]?

        public init(sdkRootPath: String?, swiftResourcesPath: String?, swiftStaticResourcesPath: String?, includeSearchPaths: [String]?, librarySearchPaths: [String]?, toolsetPaths: [String]?) {
            self.sdkRootPath = sdkRootPath
            self.swiftResourcesPath = swiftResourcesPath
            self.swiftStaticResourcesPath = swiftStaticResourcesPath
            self.includeSearchPaths = includeSearchPaths
            self.librarySearchPaths = librarySearchPaths
            self.toolsetPaths = toolsetPaths
        }
    }

    public let manifestPath: String
    public let targetTriples: [String: TripleProperties]

    public init(manifestPath: String, targetTriples: [String: TripleProperties]) {
        self.manifestPath = manifestPath
        self.targetTriples = targetTriples
    }
}

extension SWBProtocol.SwiftSDK {
    init(_ other: SWBSwiftSDK) {
        self.init(
            manifestPath: Path(other.manifestPath),
            targetTriples: other.targetTriples.mapValues(SWBProtocol.SwiftSDK.TripleProperties.init)
        )
    }
}

extension SWBProtocol.SwiftSDK.TripleProperties {
    init(_ other: SWBSwiftSDK.TripleProperties) {
        self.init(
            sdkRootPath: other.sdkRootPath,
            swiftResourcesPath: other.swiftResourcesPath,
            swiftStaticResourcesPath: other.swiftStaticResourcesPath,
            includeSearchPaths: other.includeSearchPaths,
            librarySearchPaths: other.librarySearchPaths,
            toolsetPaths: other.toolsetPaths
        )
    }
}
