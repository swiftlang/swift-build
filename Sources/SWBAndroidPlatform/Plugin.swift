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
@_spi(SDKRegistryExtension) public import SWBCore
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

    @_spi(Testing) public init() {
    }

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
        let androidPlatformInfoPlist: [String: PropertyListItem] = [
            "Type": .plString("Platform"),
            "Name": .plString("android"),
            "Identifier": .plString("android"),
            "Description": .plString("android"),
            "FamilyName": .plString("Android"),
            "FamilyIdentifier": .plString("android"),
            "IsDeploymentPlatform": .plString("YES"),
        ]

        if context.hostOperatingSystem == .windows {
            let platforms = try context.developerPath.withPlatformsInWindowsLayout(named: "Android", fs: context.fs) { platformInfoPlistPath, platformInfoPlist, version in
                (platformInfoPlistPath.dirname, platformInfoPlist.addingContents(of: androidPlatformInfoPlist).addingContents(of: ["Version": .plString(version)]))
            }

            if !platforms.isEmpty {
                return platforms
            }
        }

        return [(.root, androidPlatformInfoPlist)]
    }

    public func adjustPlatformSDKSearchPaths(platformName: String, platformPath: Path, sdkSearchPaths: inout [Path]) {
        // Block the default registration mechanism from picking up the incomplete SDKSettings.plist on disk.
        // The AndroidSDKRegistryExtension will handle discovery and registration of the SDK.
        if platformName == "android" {
            sdkSearchPaths = []
        }
    }

    func platformName(triple: LLVMTriple) -> String? {
        if triple.isAndroid {
            return "android"
        }

        return nil
    }

    func deploymentTargetSettingName(triple: LLVMTriple) -> String? {
        if triple.isAndroid {
            return "ANDROID_DEPLOYMENT_TARGET"
        }

        return nil
    }

    func swiftSDKAdditionalContext(context: any PlatformInfoExtensionSwiftSDKAdditionalCustomPropertiesContext) throws -> SwiftSDKAdditionalContext? {
        guard context.platform.name == "android" else {
            return nil
        }

        guard let ndk = plugin.effectiveInstallationCache[context.hostOperatingSystem]??.ndk else {
            throw StubError.error("No Android NDK is installed at any of the standard locations")
        }

        return SwiftSDKAdditionalContext(
            // Trick the build system into passing -sdk <ndk-path>, as the flag is broken right now despite passing -sysroot
            overrideSdkRoot: ndk.sysroot.path,

            // HACK: All information in swift-toolset.json for Android Swift SDKs is redundant.
            // Ignore it until it can be removed from the SDK itself when the native build system is removed from SwiftPM, and then this can be removed.
            overrideToolsetAbsolutePaths: [],

            additionalCustomProperties: androidSDKAdditionalCustomProperties(ndk: ndk, hostOS: context.hostOperatingSystem)
        )
    }
}

// Properties applied to the builtin NDK-only SDK as well as Swift SDKs
fileprivate func androidSDKAdditionalCustomProperties(ndk: AndroidSDK.NDK, hostOS: OperatingSystem) -> [String: PropertyListItem] {
    [
        // Unlike most platforms, the Android version goes on the environment field rather than the system field
        // FIXME: Make this configurable in a better way so we don't need to push build settings at the SDK definition level
        "SWIFT_TARGET_TRIPLE": .plString("$(CURRENT_ARCH)-unknown-$(SWIFT_PLATFORM_TARGET_PREFIX)$(LLVM_TARGET_TRIPLE_SUFFIX)"),
        "LLVM_TARGET_TRIPLE_OS_VERSION": .plString("$(SWIFT_PLATFORM_TARGET_PREFIX)"),
        "LLVM_TARGET_TRIPLE_SUFFIX": .plString("-android$(SWIFT_DEPLOYMENT_TARGET)"),

        // Android NDK r28+ defaults to 16kb page sizes for aarch64 and x86_64.
        "OTHER_LDFLAGS[arch=aarch64]": .plArray([
            .plString("$(inherited)"),
            .plString("-Xlinker"),
            .plString("-z"),
            .plString("-Xlinker"),
            .plString("max-page-size=16384")
        ]),
        "OTHER_LDFLAGS[arch=x86_64]": .plArray([
            .plString("$(inherited)"),
            .plString("-Xlinker"),
            .plString("-z"),
            .plString("-Xlinker"),
            .plString("max-page-size=16384")
        ]),

        "ALTERNATE_LINKER": .plString("lld"),
        "ALTERNATE_LINKER_PATH": .plString(ndk.toolchainPath.path.join("bin").join(hostOS.imageFormat.executableName(basename: "ld.lld")).str),
        "SYSROOT": .plString(ndk.sysroot.path.str),
        "CLANG_RESOURCE_DIR": .plString(ndk.clangResourceDir.path.strWithPosixSlashes),
    ]
}

@_spi(Testing) public struct AndroidSDKRegistryExtension: SDKRegistryExtension {
    @_spi(Testing) public let plugin: AndroidPlugin

    public func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        let host = context.hostOperatingSystem
        guard let androidPlatform = context.platformRegistry.lookup(name: "android"), let (_, androidNdk) = try await plugin.effectiveInstallation(host: host) else {
            return []
        }

        // If we already have Android SDKs, don't generate a fallback one.
        // This will let Swift SDKs for Android transparently override the Android SDK in the Windows installer, if selected.
        guard androidPlatform.sdks.isEmpty else {
            return []
        }

        let defaultProperties: [String: PropertyListItem] = [
            "SDK_STAT_CACHE_ENABLE": "NO",

            // Workaround to avoid `-dependency_info` on Linux.
            "LD_DEPENDENCY_INFO_FILE": .plString(""),
            "PRELINK_DEPENDENCY_INFO_FILE": .plString(""),

            "GENERATE_TEXT_BASED_STUBS": "NO",
            "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

            "LIBTOOL": .plString(host.imageFormat.executableName(basename: "llvm-lib")),
            "AR": .plString(host.imageFormat.executableName(basename: "llvm-ar")),
        ]

        let alias: String
        let sdkPath: Path
        let customProperties: [String: PropertyListItem]

        let windowsSDKSettingsPlistPath = androidPlatform.path.join("Developer").join("SDKs").join("Android.sdk").join("SDKSettings.plist")
        if host == .windows && context.fs.exists(windowsSDKSettingsPlistPath) {
            // Synthesize an SDK for the SDK layout for Android that's embedded in the Windows installer, if present
            let windowsSDKSettingsPlist = try PropertyList.fromPath(windowsSDKSettingsPlistPath, fs: context.fs)
            guard case .plDict = windowsSDKSettingsPlist else {
                throw StubError.error("Unexpected top-level property list type in \(windowsSDKSettingsPlistPath.str) (expected dictionary)")
            }
            let testingLibraryPath = androidPlatform.path.join("Developer").join("Library")

            alias = "android.windows"
            // Trick the build system into passing -sdk <ndk-path>, as the flag is broken right now despite passing -sysroot
            //sdkPath = windowsSDKSettingsPlistPath.dirname
            sdkPath = androidNdk.sysroot.path

            customProperties = [
                "__ANDROID_SDK_DIR": .plString(windowsSDKSettingsPlistPath.dirname.str),
                "LIBRARY_SEARCH_PATHS": .plArray([
                    .plString("$(inherited)"),
                    .plString("$(SWIFT_LIBRARY_PATH)/$(CURRENT_ARCH)")
                ]),
                // Needed when not using -sdk properly
                "SWIFT_INCLUDE_PATHS": .plArray([
                    .plString("$(inherited)"),
                    .plString("$(SWIFT_LIBRARY_PATH)"),
                    .plString(windowsSDKSettingsPlistPath.dirname.join("usr").join("include").strWithPosixSlashes)
                ]),
                "SWIFT_LIBRARY_PATH": .plString(windowsSDKSettingsPlistPath.dirname.join("usr").join("lib").join("swift").join("android").strWithPosixSlashes),
                "SWIFT_RESOURCE_DIR": .plString(windowsSDKSettingsPlistPath.dirname.join("usr").join("lib").join("swift").strWithPosixSlashes),
                "TEST_LIBRARY_SEARCH_PATHS": .plArray([
                    .plString("\(testingLibraryPath.strWithPosixSlashes)/Testing-$(SWIFT_TESTING_VERSION)/usr/lib/swift/android"),
                    .plString("\(testingLibraryPath.strWithPosixSlashes)/Testing-$(SWIFT_TESTING_VERSION)/usr/lib/swift/android/$(CURRENT_ARCH)"),
                    .plString("\(testingLibraryPath.strWithPosixSlashes)/XCTest-$(XCTEST_VERSION)/usr/lib/swift/android"),
                    .plString("\(testingLibraryPath.strWithPosixSlashes)/XCTest-$(XCTEST_VERSION)/usr/lib/swift/android/$(CURRENT_ARCH)"),
                ])
            ]
        } else {
            // Otherwise, synthesize an NDK-only SDK that can be used for C/C++-only code if an NDK is present on the system
            alias = "android.ndk"
            sdkPath = androidNdk.sysroot.path
            customProperties = [:]
        }

        return [(sdkPath, androidPlatform, [
            "Type": .plString("SDK"),
            "Version": .plString(androidNdk.version.description),
            "CanonicalName": .plString("android"),
            "Aliases": .plArray([.plString(alias)]),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString("android"),
            ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
            "CustomProperties": .plDict(androidSDKAdditionalCustomProperties(ndk: androidNdk, hostOS: host).merging(customProperties, uniquingKeysWith: { _, new in new })),
            "SupportedTargets": .plDict([
                "android": .plDict([
                    "Archs": .plArray(androidNdk.abis.map { .plString($0.value.llvm_triple.arch) }),
                    "DeploymentTargetSettingName": .plString("ANDROID_DEPLOYMENT_TARGET"),
                    "DefaultDeploymentTarget": .plString("\(androidNdk.deploymentTargetRange.min)"),
                    "MinimumDeploymentTarget": .plString("\(androidNdk.deploymentTargetRange.min)"),
                    "MaximumDeploymentTarget": .plString("\(androidNdk.deploymentTargetRange.max)"),
                    "LLVMTargetTripleEnvironment": .plString("android"), // FIXME: androideabi for armv7!
                    "LLVMTargetTripleSys": .plString("linux"),
                    "LLVMTargetTripleVendor": .plString("unknown"),
                ])
            ]),
            "Toolchains": .plArray([
                .plString("android")
            ])
        ])]
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

extension LLVMTriple {
    var isAndroid: Bool {
        system == "linux" && (environment == "android" || environment == "androideabi")
    }
}
