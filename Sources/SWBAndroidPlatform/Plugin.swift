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
import SWBCore
import SWBMacro
import Foundation

@PluginExtensionSystemActor public func initializePlugin(_ manager: PluginManager) {
    manager.register(AndroidPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(AndroidEnvironmentExtension(), type: EnvironmentExtensionPoint.self)
    manager.register(AndroidPlatformExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(AndroidSDKRegistryExtension(), type: SDKRegistryExtensionPoint.self)
    manager.register(AndroidToolchainRegistryExtension(), type: ToolchainRegistryExtensionPoint.self)
}

struct AndroidPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles() -> Bundle? {
        .module
    }

    func specificationDomains() -> [String : [String]] {
        ["android": ["linux"]]
    }
}

struct AndroidEnvironmentExtension: EnvironmentExtension {
    func additionalEnvironmentVariables(fs: any FSProxy) async throws -> [String: String] {
        switch try ProcessInfo.processInfo.hostOperatingSystem() {
        case .windows, .macOS, .linux:
            if let latest = try? await AndroidSDK.findInstallations(fs: fs).first {
                return [
                    "ANDROID_SDK_ROOT": latest.path.str,
                    "ANDROID_NDK_ROOT": latest.ndkPath?.str,
                ].compactMapValues { $0 }
            }
        default:
            break
        }
        return [:]
    }
}

struct AndroidPlatformExtension: PlatformInfoExtension {
    func knownDeploymentTargetMacroNames() -> Set<String> {
        ["ANDROID_DEPLOYMENT_TARGET"]
    }
    
    func additionalPlatforms() -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString("android"),
                "Identifier": .plString("android"),
                "Description": .plString("android"),
                "FamilyName": .plString("Android"),
                "FamilyIdentifier": .plString("android"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }
}

struct AndroidSDKRegistryExtension: SDKRegistryExtension {
    func additionalSDKs(platformRegistry: PlatformRegistry) async -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        guard let host = try? ProcessInfo.processInfo.hostOperatingSystem() else {
            return []
        }

        guard let androidPlatform = platformRegistry.lookup(name: "android") else {
            return []
        }

        let defaultProperties: [String: PropertyListItem] = [
            "SDK_STAT_CACHE_ENABLE": "NO",

            // Workaround to avoid `-dependency_info` on Linux.
            "LD_DEPENDENCY_INFO_FILE": .plString(""),

            // Android uses lld, not the Apple linker
            // FIXME: Make this option conditional on use of the Apple linker (or perhaps when targeting an Apple triple?)
            "LD_DETERMINISTIC_MODE": "NO",

            "GENERATE_TEXT_BASED_STUBS": "NO",
            "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

            "CHOWN": "/usr/bin/chown",

            "LIBTOOL": .plString(host.imageFormat.executableName(basename: "llvm-lib")),
            "AR": .plString(host.imageFormat.executableName(basename: "llvm-ar")),
        ]

        guard let androidSdk = try? await AndroidSDK.findInstallations(fs: localFS).first else {
            return []
        }

        guard let abis = androidSdk.abis, let deploymentTargetRange = androidSdk.deploymentTargetRange else {
            return []
        }

        return [(androidSdk.sysroot ?? .root, androidPlatform, [
            "Type": .plString("SDK"),
            "Version": .plString("0.0.0"),
            "CanonicalName": .plString("android"),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString("android"),
            ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
            "CustomProperties": .plDict([
                // Unlike most platforms, the Android version goes on the environment field rather than the system field
                // FIXME: Make this configurable in a better way so we don't need to push build settings at the SDK definition level
                "LLVM_TARGET_TRIPLE_OS_VERSION": .plString("linux"),
                "LLVM_TARGET_TRIPLE_SUFFIX": .plString("-android$(ANDROID_DEPLOYMENT_TARGET)"),
            ]),
            "SupportedTargets": .plDict([
                "android": .plDict([
                    "Archs": .plArray(abis.map { .plString($0.value.llvm_triple.arch) }),
                    "DeploymentTargetSettingName": .plString("ANDROID_DEPLOYMENT_TARGET"),
                    "DefaultDeploymentTarget": .plString("\(deploymentTargetRange.min)"),
                    "MinimumDeploymentTarget": .plString("\(deploymentTargetRange.min)"),
                    "MaximumDeploymentTarget": .plString("\(deploymentTargetRange.max)"),
                    "LLVMTargetTripleEnvironment": .plString("android"), // FIXME: androideabi for armv7!
                    "LLVMTargetTripleSys": .plString("linux"),
                    "LLVMTargetTripleVendor": .plString("none"),
                ])
            ]),
            "Toolchains": .plArray([
                .plString("android")
            ])
        ])]
    }
}

struct AndroidToolchainRegistryExtension: ToolchainRegistryExtension {
    func additionalToolchains(fs: any FSProxy) async -> [Toolchain] {
        guard let toolchainPath = try? await AndroidSDK.findInstallations(fs: fs).first?.toolchainPath else {
            return []
        }

        return [Toolchain("android", "Android", Version(0, 0, 0), [], toolchainPath, [], [], [:], [:], [:], executableSearchPaths: [toolchainPath.join("bin")], fs: fs)]
    }
}
