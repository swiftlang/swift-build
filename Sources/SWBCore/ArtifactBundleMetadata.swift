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

package import SWBUtil
import Foundation

package struct ArtifactBundleInfo: Hashable {
    package let bundlePath: Path
    package let metadata: ArtifactBundleMetadata

    package init(bundlePath: Path, metadata: ArtifactBundleMetadata) {
        self.bundlePath = bundlePath
        self.metadata = metadata
    }
}

package struct ArtifactBundleMetadata: Sendable, Hashable, Decodable {
    package let schemaVersion: String
    package let artifacts: [String: ArtifactMetadata]

    package struct ArtifactMetadata: Sendable, Hashable, Decodable {
        package let type: ArtifactType
        package let version: String
        package let variants: [VariantMetadata]
    }

    package enum ArtifactType: String, Sendable, Decodable {
        case executable
        case staticLibrary
        case swiftSDK
        case experimentalWindowsDLL
        case crossCompilationDestination
    }

    package struct VariantMetadata: Sendable, Hashable, Decodable {
        package let path: Path
        package let supportedTriples: [String]?
        package let staticLibraryMetadata: StaticLibraryMetadata?
    }

    package struct StaticLibraryMetadata: Sendable, Hashable, Decodable {
        package let headerPaths: [Path]
        package let moduleMapPath: Path?
    }

    package static func parse(
        at bundlePath: Path,
        fileSystem: any FSProxy
    ) throws -> ArtifactBundleMetadata {
        let infoPath = bundlePath.join("info.json")

        guard fileSystem.exists(infoPath) else {
            throw StubError.error("artifact bundle info.json not found at '\(infoPath.str)'")
        }

        do {
            let bytes = try fileSystem.read(infoPath)
            let data = Data(bytes.bytes)
            let decoder = JSONDecoder()
            let metadata = try decoder.decode(ArtifactBundleMetadata.self, from: data)

            guard let version = try? Version(metadata.schemaVersion) else {
                throw StubError.error("invalid schema version '\(metadata.schemaVersion)' in '\(infoPath.str)'")
            }

            switch version {
            case Version(1, 2), Version(1, 1), Version(1, 0):
                break
            default:
                throw StubError.error("invalid `schemaVersion` of bundle manifest at '\(infoPath)': \(version)")
            }

            return metadata
        } catch {
            throw StubError.error("failed to parse ArtifactBundle info.json at '\(infoPath.str)': \(error.localizedDescription)")
        }
    }
}
