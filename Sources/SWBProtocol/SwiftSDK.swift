//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil
import Foundation

/// Represents a Swift SDK
///
/// See https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md
public struct SwiftSDK: Sendable, Hashable, Codable, SerializableCodable {
    @_spi(Testing) public struct SchemaVersionInfo: Codable {
        @_spi(Testing) public let schemaVersion: String
    }

    public struct TripleProperties: Hashable, Codable, Sendable {
        /// The SDK root, that is, the directory given to the `-sdk` flag of the Swift compiler.
        /// This also doubles as the sysroot (`-sysroot` or `--sysroot`), but should really have its own dedicated property.
        public var sdkRootPath: String?
        public var swiftResourcesPath: String?
        public var swiftStaticResourcesPath: String?
        public var clangResourcesPath: String? {
            guard let swiftResourcesPath = self.swiftResourcesPath else {
                return nil
            }

            // The clang resource path is conventionally the clang subdirectory of the swift resource path
            return Path(swiftResourcesPath).join("clang").str
        }
        public var clangStaticResourcesPath: String? {
            guard let swiftResourcesPath = self.swiftStaticResourcesPath else {
                return nil
            }

            // The clang resource path is conventionally the clang subdirectory of the swift resource path
            return Path(swiftResourcesPath).join("clang").str
        }
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

        public func loadToolsets(sdk: SwiftSDK, fs: any FSProxy) throws -> [Toolset] {
            var toolsets: [Toolset] = []

            for toolsetPath in self.toolsetPaths ?? [] {
                let metadataData = try Data(fs.read(sdk.path.join(toolsetPath)))

                let schema = try JSONDecoder().decode(SchemaVersionInfo.self, from: metadataData)
                guard schema.schemaVersion == "1.0" else { return [] } // FIXME throw an error

                let toolset = try JSONDecoder().decode(Toolset.self, from: metadataData)
                toolsets.append(toolset)
            }

            return toolsets
        }
    }
    struct MetadataV4: Codable {
        let targetTriples: [String: TripleProperties]
    }

    public struct Toolset: Codable, Sendable {
        public struct Tool: Codable, Sendable {
            public let path: String?
            public let extraCLIOptions: [String]?

            public init(path: String? = nil, extraCLIOptions: [String]? = nil) {
                self.path = path
                self.extraCLIOptions = extraCLIOptions
            }
        }

        public let schemaVersion: String
        public let rootPath: String?
        public let cCompiler: Tool?
        public let cxxCompiler: Tool?
        public let swiftCompiler: Tool?
        public let linker: Tool?
        public let librarian: Tool?

        public init(schemaVersion: String = "1.0", rootPath: String? = nil, cCompiler: Tool? = nil, cxxCompiler: Tool? = nil, swiftCompiler: Tool? = nil, linker: Tool? = nil, librarian: Tool? = nil) {
            self.schemaVersion = schemaVersion
            self.rootPath = rootPath
            self.cCompiler = cCompiler
            self.cxxCompiler = cxxCompiler
            self.swiftCompiler = swiftCompiler
            self.linker = linker
            self.librarian = librarian
        }

        public func resolveToolPath(_ path: String, toolsetPath: Path) -> Path {
            let toolPath = Path(path)
            if toolPath.isAbsolute {
                return toolPath
            }
            if let rootPath {
                let root = Path(rootPath)
                if root.isAbsolute {
                    return root.join(toolPath)
                } else {
                    return toolsetPath.dirname.join(root).join(toolPath)
                }
            }
            return toolsetPath.dirname.join(toolPath)
        }
    }

    /// The path to the SDK.
    public var path: Path {
        manifestPath.dirname
    }
    public let manifestPath: Path
    /// Target-specific properties for this SDK.
    public let targetTriples: [String: TripleProperties]

    public init(manifestPath: Path, targetTriples: [String: TripleProperties]) {
        self.manifestPath = manifestPath
        self.targetTriples = targetTriples
    }

    public init?(manifestPath: Path, fs: any FSProxy) throws {
        self.manifestPath = manifestPath

        guard fs.exists(manifestPath) else { return nil }

        let metadataData = try Data(fs.read(manifestPath))
        let schema = try JSONDecoder().decode(SchemaVersionInfo.self, from: metadataData)
        guard schema.schemaVersion == "4.0" else { return nil }

        let metadata = try JSONDecoder().decode(MetadataV4.self, from: metadataData)
        self.targetTriples = metadata.targetTriples
    }
}
