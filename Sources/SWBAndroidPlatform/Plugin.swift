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

public let initializePlugin: PluginInitializationFunction = { manager in
    let plugin = AndroidPlugin()
    manager.register(AndroidPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(AndroidEnvironmentExtension(plugin: plugin), type: EnvironmentExtensionPoint.self)
    manager.register(AndroidPlatformExtension(plugin: plugin), type: PlatformInfoExtensionPoint.self)
    manager.register(AndroidSDKRegistryExtension(plugin: plugin), type: SDKRegistryExtensionPoint.self)
    manager.register(AndroidToolchainRegistryExtension(plugin: plugin), type: ToolchainRegistryExtensionPoint.self)
}

@_spi(Testing) public final class AndroidPlugin: Sendable {
    private let androidSDKInstallations = AsyncCache<OperatingSystem, [AndroidSDK]>()
    private let androidOverrideNDKInstallation = AsyncCache<OperatingSystem, AndroidSDK.NDK?>()

    // HACK: The place where this is used is challenging to convert to async, and effectiveInstallation() will be called before it is.
    fileprivate let effectiveInstallationCache = Cache<OperatingSystem, (sdk: AndroidSDK?, ndk: AndroidSDK.NDK)?>()

    func cachedAndroidSDKInstallations(host: OperatingSystem) async throws -> [AndroidSDK] {
        try await androidSDKInstallations.value(forKey: host) {
            // Always pass localFS because this will be cached, and executes a process on the host system so there's no reason to pass in any proxy.
            try await AndroidSDK.findInstallations(host: host, fs: localFS)
        }
    }

    func cachedAndroidOverrideNDKInstallation(host: OperatingSystem) async throws -> AndroidSDK.NDK? {
        try await androidOverrideNDKInstallation.value(forKey: host) {
            if let overridePath = AndroidSDK.NDK.environmentOverrideLocation {
                return try AndroidSDK.NDK(host: host, path: overridePath, fs: localFS)
            }
            return nil
        }
    }

    @_spi(Testing) public func effectiveInstallation(host: OperatingSystem) async throws -> (sdk: AndroidSDK?, ndk: AndroidSDK.NDK)? {
        func effectiveInstallation() async throws -> (sdk: AndroidSDK?, ndk: AndroidSDK.NDK)? {
            guard let androidSdk = try? await cachedAndroidSDKInstallations(host: host).first else {
                // No SDK, but we might still have a standalone NDK from the env var override
                if let overrideNDK = try? await cachedAndroidOverrideNDKInstallation(host: host) {
                    return (nil, overrideNDK)
                }

                return nil
            }

            guard let androidNdk = androidSdk.preferredNDK else {
                return nil
            }

            return (androidSdk, androidNdk)
        }

        if let (sdk, ndk) = try await effectiveInstallation() {
            _ = effectiveInstallationCache.getOrInsert(host, { (sdk, ndk) })
            return (sdk, ndk)
        }

        return nil
    }
}

struct AndroidPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBAndroidPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    func specificationDomains() -> [String : [String]] {
        ["android": ["linux"]]
    }
}

struct AndroidEnvironmentExtension: EnvironmentExtension {
    let plugin: AndroidPlugin

    func additionalEnvironmentVariables(context: any EnvironmentExtensionAdditionalEnvironmentVariablesContext) async throws -> [String: String] {
        switch context.hostOperatingSystem {
        case .windows, .macOS, .linux:
            if let (sdk, ndk) = try? await plugin.effectiveInstallation(host: context.hostOperatingSystem) {
                let sdkPath = sdk?.path.path.str
                let ndkPath = ndk.path.path.str
                return [
                    "ANDROID_HOME": sdkPath,
                    "ANDROID_SDK_ROOT": sdkPath,
                    "ANDROID_NDK_ROOT": ndkPath,
                    "ANDROID_NDK_HOME": ndkPath,
                ].compactMapValues { $0 }
            }
        default:
            break
        }
        return [:]
    }
}

struct AndroidPlatformExtension: PlatformInfoExtension {
    let plugin: AndroidPlugin

    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
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

    func platformName(triple: LLVMTriple) -> String? {
        if triple.system == "linux" && triple.environment?.hasPrefix("android") == true {
            return "android"
        }

        return nil
    }

    func swiftSDKAdditionalCustomProperties(context: any PlatformInfoExtensionSwiftSDKAdditionalCustomPropertiesContext) -> [String: PropertyListItem] {
        guard context.platform.name == "android" else {
            return [:]
        }

        return androidSDKAdditionalCustomProperties().merging(
            [
                "SWIFT_TARGET_TRIPLE": .plString("$(CURRENT_ARCH)-unknown-$(SWIFT_PLATFORM_TARGET_PREFIX)$(LLVM_TARGET_TRIPLE_SUFFIX)"),
            ], uniquingKeysWith: { _, new in new })
            .merging((plugin.effectiveInstallationCache[context.hostOperatingSystem]??.ndk.sysroot.path.str).map { path in
            [
                "SYSROOT": .plString(path)
            ]
             } ?? [:], uniquingKeysWith: { _, new in new })
    }
}

// Properties applied to the builtin NDK-only SDK as well as Swift SDKs
fileprivate func androidSDKAdditionalCustomProperties() -> [String: PropertyListItem] {
    [
        // Unlike most platforms, the Android version goes on the environment field rather than the system field
        // FIXME: Make this configurable in a better way so we don't need to push build settings at the SDK definition level
        "LLVM_TARGET_TRIPLE_OS_VERSION": .plString("$(SWIFT_PLATFORM_TARGET_PREFIX)"),
        "LLVM_TARGET_TRIPLE_SUFFIX": .plString("-android$($(DEPLOYMENT_TARGET_SETTING_NAME))")
    ]
}

@_spi(Testing) public struct AndroidSDKRegistryExtension: SDKRegistryExtension {
    @_spi(Testing) public let plugin: AndroidPlugin

    public func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        let host = context.hostOperatingSystem
        guard let androidPlatform = context.platformRegistry.lookup(name: "android"), let (_, androidNdk) = try await plugin.effectiveInstallation(host: host) else {
            return []
        }

        return [
            // An NDK-only SDK that can be used for C/C++-only code if an NDK is present on the system even if there are no Swift SDKs
            sdk(androidPlatform: androidPlatform, androidNdk: androidNdk, defaultProperties: [
                "SDK_STAT_CACHE_ENABLE": "NO",

                // Workaround to avoid `-dependency_info` on Linux.
                "LD_DEPENDENCY_INFO_FILE": .plString(""),
                "PRELINK_DEPENDENCY_INFO_FILE": .plString(""),

                // Android uses lld, not the Apple linker
                // FIXME: Make this option conditional on use of the Apple linker (or perhaps when targeting an Apple triple?)
                "LD_DETERMINISTIC_MODE": "NO",

                "GENERATE_TEXT_BASED_STUBS": "NO",
                "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

                "LIBTOOL": .plString(host.imageFormat.executableName(basename: "llvm-lib")),
                "AR": .plString(host.imageFormat.executableName(basename: "llvm-ar")),
            ])
        ]
    }

    private func sdk(canonicalName: String? = nil, androidPlatform: Platform, androidNdk: AndroidSDK.NDK, defaultProperties: [String: PropertyListItem], customProperties: [String: PropertyListItem] = [:]) -> (path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem]) {
        return (androidNdk.sysroot.path, androidPlatform, [
            "Type": .plString("SDK"),
            "Version": .plString(androidNdk.version.description),
            "CanonicalName": .plString(canonicalName ?? "android\(androidNdk.version.description)"),
            // "android.ndk" is an alias for the "Android SDK without a Swift SDK" scenario in order for tests to deterministically pick a single Android destination regardless of how many Android Swift SDKs may be installed.
            "Aliases": .plArray([.plString("android")] + (canonicalName == nil ? [.plString("android.ndk")] : [])),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString("android"),
            ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
            "CustomProperties": .plDict(androidSDKAdditionalCustomProperties().merging(customProperties, uniquingKeysWith: { _, new in new })),
            "SupportedTargets": .plDict([
                "android": .plDict([
                    "Archs": .plArray(androidNdk.abis.map { .plString($0.value.llvm_triple.arch) }),
                    "DeploymentTargetSettingName": .plString("ANDROID_DEPLOYMENT_TARGET"),
                    "DefaultDeploymentTarget": .plString("\(androidNdk.deploymentTargetRange.min)"),
                    "MinimumDeploymentTarget": .plString("\(androidNdk.deploymentTargetRange.min)"),
                    "MaximumDeploymentTarget": .plString("\(androidNdk.deploymentTargetRange.max)"),
                    "LLVMTargetTripleEnvironment": .plString("android"), // FIXME: androideabi for armv7!
                    "LLVMTargetTripleSys": .plString("linux"),
                    "LLVMTargetTripleVendor": .plString("none"),
                ])
            ]),
            "Toolchains": .plArray([
                .plString("android")
            ])
        ])
    }
}

struct AndroidToolchainRegistryExtension: ToolchainRegistryExtension {
    let plugin: AndroidPlugin

    func additionalToolchains(context: any ToolchainRegistryExtensionAdditionalToolchainsContext) async throws -> [Toolchain] {
        guard let toolchainPath = try? await plugin.effectiveInstallation(host: context.hostOperatingSystem)?.ndk.toolchainPath else {
            return []
        }

        return [
            Toolchain(
                identifier: "android",
                displayName: "Android",
                version: Version(0, 0, 0),
                aliases: [],
                path: toolchainPath.path,
                frameworkPaths: [],
                libraryPaths: [],
                defaultSettings: [:],
                overrideSettings: [:],
                defaultSettingsWhenPrimary: [:],
                executableSearchPaths: [toolchainPath.path.join("bin")],
                testingLibraryPlatformNames: [],
                fs: context.fs)
        ]
    }
}
