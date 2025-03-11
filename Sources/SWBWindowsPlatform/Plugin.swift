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
import Foundation

@PluginExtensionSystemActor public func initializePlugin(_ manager: PluginManager) {
    let plugin = WindowsPlugin()
    manager.register(WindowsPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(WindowsEnvironmentExtension(plugin: plugin), type: EnvironmentExtensionPoint.self)
    manager.register(WindowsPlatformExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(WindowsSDKRegistryExtension(), type: SDKRegistryExtensionPoint.self)
}

final class WindowsPlugin: Sendable {
    private let vsInstallations = AsyncSingleValueCache<[VSInstallation], any Error>()

    func cachedVSInstallations() async throws -> [VSInstallation] {
        try await vsInstallations.value {
            // Always pass localFS because this will be cached, and executes a process on the host system so there's no reason to pass in any proxy.
            try await VSInstallation.findInstallations(fs: localFS)
        }
    }
}

struct WindowsPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBWindowsPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }
}

struct WindowsEnvironmentExtension: EnvironmentExtension {
    let plugin: WindowsPlugin

    func additionalEnvironmentVariables(context: any EnvironmentExtensionAdditionalEnvironmentVariablesContext) async throws -> [String: String] {
        if context.hostOperatingSystem == .windows {
            // Add the environment variable for the MSVC toolset for Swift and Clang to find it
            let vcToolsInstallDir = "VCToolsInstallDir"
            let installations = try await plugin.cachedVSInstallations()
                .sorted(by: { $0.installationVersion > $1.installationVersion })
            if let latest = installations.first {
                let msvcDir = latest.installationPath.join("VC").join("Tools").join("MSVC")
                if context.fs.exists(msvcDir) {
                    let versions = try context.fs.listdir(msvcDir).map { try Version($0) }.sorted { $0 > $1 }
                    if let latestVersion = versions.first {
                        let dir = msvcDir.join(latestVersion.description).str
                        return [vcToolsInstallDir: dir]
                    }
                }
            }
        }
        return [:]
    }
}

struct WindowsPlatformExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        let operatingSystem = context.hostOperatingSystem
        guard operatingSystem == .windows else {
            return []
        }

        let platformsPath = context.developerPath.join("Platforms")
        return try context.fs.listdir(platformsPath).compactMap { version in
            let versionedPlatformsPath = platformsPath.join(version)
            guard context.fs.isDirectory(versionedPlatformsPath) else {
                return nil
            }

            let windowsInfoPlistPath = versionedPlatformsPath.join("Windows.platform").join("Info.plist")
            guard context.fs.exists(windowsInfoPlistPath) else {
                return nil
            }

            let windowsInfoPlist = try PropertyList.fromPath(windowsInfoPlistPath, fs: context.fs)
            guard case let .plDict(dict) = windowsInfoPlist else {
                throw StubError.error("Unexpected top-level property list type in \(windowsInfoPlistPath.str) (expected dictionary)")
            }

            return (windowsInfoPlistPath.dirname, dict.merging([
                "Type": .plString("Platform"),
                "Name": .plString("windows"),
                "Identifier": .plString("windows"),
                "Description": .plString("Windows"),
                "FamilyName": .plString("Windows"),
                "FamilyIdentifier": .plString("windows"),
                "IsDeploymentPlatform": .plString("YES"),
                "Version": .plString(version),
            ]) { old, new in new })
        }
    }

    public func adjustPlatformSDKSearchPaths(platformName: String, platformPath: Path, sdkSearchPaths: inout [Path]) {
        // Block the default registration mechanism from picking up the incomplete SDKSettings.plist on disk.
        // The WindowsSDKRegistryExtension will handle discovery and registration of the SDK.
        if platformName == "windows" {
            sdkSearchPaths = []
        }
    }
}

struct WindowsSDKRegistryExtension: SDKRegistryExtension {
    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        guard let windowsPlatform = context.platformRegistry.lookup(name: "windows") else {
            return []
        }

        let windowsSDKSettingsPlistPath = windowsPlatform.path.join("Developer").join("SDKs").join("Windows.sdk").join("SDKSettings.plist")
        let windowsSDKSettingsPlist = try PropertyList.fromPath(windowsSDKSettingsPlistPath, fs: context.fs)
        guard case let .plDict(dict) = windowsSDKSettingsPlist else {
            throw StubError.error("Unexpected top-level property list type in \(windowsSDKSettingsPlistPath.str) (expected dictionary)")
        }

        let defaultProperties: [String: PropertyListItem] = [
            "GCC_GENERATE_DEBUGGING_SYMBOLS": .plString("NO"),
            "LD_DEPENDENCY_INFO_FILE": .plString(""),

            "GENERATE_TEXT_BASED_STUBS": "NO",
            "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

            "LIBRARY_SEARCH_PATHS": "$(inherited) $(SDKROOT)/usr/lib/swift/windows/$(CURRENT_ARCH)",

            "OTHER_SWIFT_FLAGS": "$(inherited) -libc $(DEFAULT_USE_RUNTIME)",

            "DEFAULT_USE_RUNTIME": "MD",
        ]

        return try [
            (windowsSDKSettingsPlistPath.dirname, windowsPlatform, dict.merging([
                "Type": .plString("SDK"),
                "Version": .plString(Version(ProcessInfo.processInfo.operatingSystemVersion).zeroTrimmed.description),
                "CanonicalName": .plString("windows"),
                "IsBaseSDK": .plBool(true),
                "DefaultProperties": .plDict([
                    "PLATFORM_NAME": .plString("windows"),
                ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
                "SupportedTargets": .plDict([
                    "windows": .plDict([
                        "Archs": .plArray([.plString("x86_64"), .plString("i686"), .plString("aarch64"), .plString("thumbv7")]),
                        "LLVMTargetTripleEnvironment": .plString("msvc"),
                        "LLVMTargetTripleSys": .plString("windows"),
                        "LLVMTargetTripleVendor": .plString("unknown"),
                    ])
                ]),
            ]) { old, new in new })
        ]
    }
}
