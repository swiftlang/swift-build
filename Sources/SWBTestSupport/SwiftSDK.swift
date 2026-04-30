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

import Foundation
public import SWBUtil
@_spi(Testing) public import SWBProtocol
@_spi(Testing) public import SWBCore

extension SwiftSDK {
    /// The default location storing Swift SDKs installed by SwiftPM.
    static func defaultSwiftSDKsDirectory(hostOperatingSystem: OperatingSystem) throws -> Path {
        let spmURL: URL
        if hostOperatingSystem == .macOS {
            spmURL = try FileManager.default.url(
                for: .libraryDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appendingPathComponent("org.swift.swiftpm")
        } else {
            spmURL = URL.homeDirectory.appendingPathComponent(".swiftpm")
        }
        return try spmURL.appendingPathComponent("swift-sdks").filePath
    }

    /// Find Swift SDKs installed by SwiftPM.
    public static func findSDKs(targetTriples: [String]?, fs: any FSProxy, hostOperatingSystem: OperatingSystem) throws -> [SwiftSDK] {
        try findSDKsWithIdentifiers(targetTriples: targetTriples, fs: fs, hostOperatingSystem: hostOperatingSystem).map(\.sdk)
    }

    /// Find Swift SDKs installed by SwiftPM, along with their artifact bundle identifiers.
    static func findSDKsWithIdentifiers(targetTriples: [String]?, fs: any FSProxy, hostOperatingSystem: OperatingSystem) throws -> [(identifier: String, sdk: SwiftSDK)] {
        let swiftSDKsDirectory = try defaultSwiftSDKsDirectory(hostOperatingSystem: hostOperatingSystem)
        guard fs.exists(swiftSDKsDirectory) else {
            return []
        }
        return try findSDKsWithIdentifiers(swiftSDKsDirectory: swiftSDKsDirectory, targetTriples: targetTriples, fs: fs)
    }

    private static func findSDKsWithIdentifiers(swiftSDKsDirectory: Path, targetTriples: [String]?, fs: any FSProxy) throws -> [(identifier: String, sdk: SwiftSDK)] {
        var sdks: [(identifier: String, sdk: SwiftSDK)] = []
        // Find .artifactbundle in the SDK directory (e.g. ~/Library/org.swift.swiftpm/swift-sdks)
        for artifactBundle in try fs.listdir(swiftSDKsDirectory) {
            guard artifactBundle.hasSuffix(".artifactbundle") else { continue }
            let artifactBundlePath = swiftSDKsDirectory.join(artifactBundle)
            guard fs.isDirectory(artifactBundlePath) else { continue }

            sdks.append(contentsOf: (try? findSDKsWithIdentifiers(artifactBundle: artifactBundlePath, targetTriples: targetTriples, fs: fs)) ?? [])
        }
        return sdks
    }

    private struct BundleInfo: Codable {
        let artifacts: [String: Artifact]

        struct Artifact: Codable {
            let type: String
            let version: String
            let variants: [Variant]
        }

        struct Variant: Codable {
            let path: String
            let supportedTriples: [String]?
        }
    }

    /// Find Swift SDKs in an artifact bundle supporting one of the given targets.
    public static func findSDKs(artifactBundle: Path, targetTriples: [String]?, fs: any FSProxy) throws -> [SwiftSDK] {
        try findSDKsWithIdentifiers(artifactBundle: artifactBundle, targetTriples: targetTriples, fs: fs).map(\.sdk)
    }

    static func findSDKsWithIdentifiers(artifactBundle: Path, targetTriples: [String]?, fs: any FSProxy) throws -> [(identifier: String, sdk: SwiftSDK)] {
        // Load info.json from the artifact bundle
        let infoPath = artifactBundle.join("info.json")
        guard try fs.isFile(infoPath) else { return [] }

        let infoData = try Data(fs.read(infoPath))

        let schema = try JSONDecoder().decode(SchemaVersionInfo.self, from: infoData)
        guard schema.schemaVersion == "1.0" else {
            // Ignore unknown artifact bundle format
            return []
        }

        let info = try JSONDecoder().decode(BundleInfo.self, from: infoData)

        var sdks: [(identifier: String, sdk: SwiftSDK)] = []

        for (identifier, artifact) in info.artifacts {
            for variant in artifact.variants {
                var sdkPath = artifactBundle.join(variant.path)
                let sdkJSONFilename = "swift-sdk.json"
                if fs.isDirectory(sdkPath) {
                    sdkPath = sdkPath.join(sdkJSONFilename)
                }
                guard fs.exists(sdkPath) else {
                    continue
                }

                // FIXME: For now, we only support SDKs that are compatible with any host triple.
                guard variant.supportedTriples?.isEmpty ?? true else { continue }

                guard let sdk = try SwiftSDK(manifestPath: sdkPath, fs: fs) else { continue }
                // Filter out SDKs that don't support any of the target triples.
                if let targetTriples {
                    guard targetTriples.contains(where: { sdk.targetTriples[$0] != nil }) else { continue }
                }
                sdks.append((identifier: identifier, sdk: sdk))
            }
        }

        return sdks
    }
}
