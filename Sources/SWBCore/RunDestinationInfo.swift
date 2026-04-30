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

public import struct SWBProtocol.RunDestinationInfo
public import struct SWBProtocol.SwiftSDK
public import SWBUtil

public enum BuildTarget: SerializableCodable, Hashable, Sendable {
    case toolchainSDK(sdk: String)
    case swiftSDK(sdkManifestPath: Path, triple: String)
    case inMemorySwiftSDK(swiftSDK: SwiftSDK, triple: String)
}

/// Resolved run destination info with platform name and SDK variant derived from Core.
///
/// This type shadows `SWBProtocol.RunDestinationInfo` within SWBCore.
/// The protocol-level type carries the unresolved wire-format request,
/// while this type carries the resolved platform information.
public struct RunDestinationInfo: SerializableCodable, Hashable, Sendable {
    public let buildTarget: BuildTarget

    /// The resolved platform name (e.g. "macosx", "linux", "iphoneos").
    public let platform: String

    /// The resolved SDK variant name (e.g. "iosmac" for Mac Catalyst).
    public let sdkVariant: String?

    public let targetArchitecture: String
    public let supportedArchitectures: OrderedSet<String>
    public let disableOnlyActiveArch: Bool
    public let hostTargetedPlatform: String?

    /// Resolve from protocol-level RunDestinationInfo using Core.
    public init(from payload: SWBProtocol.RunDestinationInfo, core: Core) throws {
        switch payload.buildTarget {
        case let .toolchainSDK(platform, sdk, sdkVariant):
            self.buildTarget = .toolchainSDK(sdk: sdk)
            self.platform = platform
            self.sdkVariant = sdkVariant
        case let .swiftSDK(sdkManifestPath, triple):
            self.buildTarget = .swiftSDK(sdkManifestPath: sdkManifestPath, triple: triple)
            let info = try core.buildTargetInfo(triple: triple)
            self.platform = info.platformName
            self.sdkVariant = info.sdkVariant
        case let .inMemorySwiftSDK(swiftSDK, triple):
            self.buildTarget = .inMemorySwiftSDK(swiftSDK: swiftSDK, triple: triple)
            let info = try core.buildTargetInfo(triple: triple)
            self.platform = info.platformName
            self.sdkVariant = info.sdkVariant
        }
        self.targetArchitecture = payload.targetArchitecture
        self.supportedArchitectures = payload.supportedArchitectures
        self.disableOnlyActiveArch = payload.disableOnlyActiveArch
        self.hostTargetedPlatform = payload.hostTargetedPlatform
    }

    /// Direct construction with explicit platform name and SDK variant.
    public init(buildTarget: BuildTarget, platform: String, sdkVariant: String?, targetArchitecture: String, supportedArchitectures: OrderedSet<String>, disableOnlyActiveArch: Bool, hostTargetedPlatform: String? = nil) {
        self.buildTarget = buildTarget
        self.platform = platform
        self.sdkVariant = sdkVariant
        self.targetArchitecture = targetArchitecture
        self.supportedArchitectures = supportedArchitectures
        self.disableOnlyActiveArch = disableOnlyActiveArch
        self.hostTargetedPlatform = hostTargetedPlatform
    }
}

extension RunDestinationInfo {
    /// The SDK canonical name for toolchain SDKs; the SDK manifest path for Swift SDKs.
    package var sdk: String {
        switch buildTarget {
        case let .toolchainSDK(sdk):
            return sdk
        case let .swiftSDK(sdkManifestPath, _):
            return sdkManifestPath.str
        case let .inMemorySwiftSDK(swiftSDK, _):
            return swiftSDK.manifestPath.str
        }
    }

    /// Whether this run destination represents a Mac Catalyst destination.
    package var isMacCatalyst: Bool {
        sdkVariant == MacCatalystInfo.sdkVariantName
    }
}
