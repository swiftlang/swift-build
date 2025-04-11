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
public import SWBMacro

public struct PlatformInfoExtensionPoint: ExtensionPoint, Sendable {
    public typealias ExtensionProtocol = PlatformInfoExtension

    public static let name = "PlatformInfoExtensionPoint"

    public init() {}
}

public protocol PlatformInfoExtension: Sendable {
    func knownDeploymentTargetMacroNames() -> Set<String>

    func preferredArchValue(for: String) -> String?

    func additionalTestLibraryPaths(scope: MacroEvaluationScope, platform: Platform?, fs: any FSProxy) -> [Path]

    func additionalKnownTestLibraryPathSuffixes() -> [Path]

    func additionalPlatformExecutableSearchPaths(platformName: String, platformPath: Path, fs: any FSProxy) async -> [Path]

    func additionalToolchainExecutableSearchPaths(toolchainIdentifier: String, toolchainPath: Path) -> [Path]

    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])]

    func adjustPlatformSDKSearchPaths(platformName: String, platformPath: Path, sdkSearchPaths: inout [Path])
}

extension PlatformInfoExtension {
    public func knownDeploymentTargetMacroNames() -> Set<String> {
        []
    }

    public func preferredArchValue(for: String) -> String? {
        nil
    }

    public func additionalTestLibraryPaths(scope: MacroEvaluationScope, platform: SWBCore.Platform?, fs: any FSProxy) -> [Path] {
        []
    }

    public func additionalKnownTestLibraryPathSuffixes() -> [Path] {
        []
    }

    public func additionalPlatformExecutableSearchPaths(platformName: String, platformPath: Path, fs: any FSProxy) async -> [Path] {
        []
    }

    public func additionalToolchainExecutableSearchPaths(toolchainIdentifier: String, toolchainPath: Path) -> [Path] {
        []
    }

    public func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        []
    }

    public func adjustPlatformSDKSearchPaths(platformName: String, platformPath: Path, sdkSearchPaths: inout [Path]) {
    }
}

public protocol PlatformInfoExtensionAdditionalPlatformsContext: Sendable {
    var hostOperatingSystem: OperatingSystem { get }
    var developerPath: Core.DeveloperPath { get }
    var fs: any FSProxy { get }
}
