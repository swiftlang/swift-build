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
public import SWBCore
import SWBMacro
import Foundation

struct BareMetalPlatformExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString("none"),
                "Identifier": .plString("none"),
                "Description": .plString("Bare Metal"),
                "FamilyName": .plString("None"),
                "FamilyIdentifier": .plString("none"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }
}

@_spi(Testing) public struct BareMetalSDKRegistryExtension: SDKRegistryExtension {
    public func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: Platform?, data: [String: PropertyListItem])] {
        guard let platform = context.platformRegistry.lookup(name: "none") else {
            return []
        }

        let defaultProperties: [String: PropertyListItem] = [
            "SDK_STAT_CACHE_ENABLE": "NO",
        ]

        return [(.root, platform, [
            "Type": .plString("SDK"),
            "Version": .plString("0.0.0"),
            "CanonicalName": .plString("none"),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString("none"),
            ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
            "CustomProperties": .plDict([:]),
            "SupportedTargets": .plDict([
                "none": .plDict([
                    "Archs": .plArray([]),
                    "LLVMTargetTripleSys": .plString("none"),
                ])
            ]),
        ])]
    }
}
