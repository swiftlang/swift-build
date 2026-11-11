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

import SWBUtil
import SWBCore
import SWBMacro
import Foundation

/// The platform name of bare-metal targets whose images are Mach-O, for example Swift SDKs for Apple OSes or `armv7em-apple-none-macho`.
/// It is separate from the generic bare-metal platform ("none"), whose specs derive from the generic Unix ones and assume ELF. This platform
/// takes the Darwin specs instead (see `ApplePlatformSpecsExtension.specificationDomains()`).
let bareMetalMachOPlatformName = "none-macho"

struct BareMetalMachOPlatformExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString(bareMetalMachOPlatformName),
                "Identifier": .plString(bareMetalMachOPlatformName),
                "Description": .plString("Bare Metal (Mach-O)"),
                "FamilyName": .plString("None"),
                "FamilyIdentifier": .plString("none"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }
}

struct BareMetalMachOSDKRegistryExtension: SDKRegistryExtension {
    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: Platform?, data: [String: PropertyListItem])] {
        guard let platform = context.platformRegistry.lookup(name: bareMetalMachOPlatformName) else {
            return []
        }

        return [(.root, platform, [
            "Type": .plString("SDK"),
            "Version": .plString("0.0.0"),
            "CanonicalName": .plString(bareMetalMachOPlatformName),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString(bareMetalMachOPlatformName),
                "SDK_STAT_CACHE_ENABLE": .plString("NO"),
            ]),
            "CustomProperties": .plDict([:]),
            "SupportedTargets": .plDict([
                bareMetalMachOPlatformName: .plDict([
                    "Archs": .plArray([]),
                    "LLVMTargetTripleSys": .plString("none"),
                    "ImageFormat": .plString("macho"),
                ])
            ]),
        ])]
    }
}
