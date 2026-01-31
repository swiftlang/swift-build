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
import SWBUtil
import SWBCore

extension MutablePluginManager {
    func registerDeveloperCommandLineToolsExtensions() {
        register(DeveloperCommandLineToolsSDKRegistryExtension(), type: SDKRegistryExtensionPoint.self)
        register(DeveloperCommandLineToolsPlatformInfoExtension(), type: PlatformInfoExtensionPoint.self)
        register(DeveloperCommandLineToolsToolchainRegistryExtension(), type: ToolchainRegistryExtensionPoint.self)
    }
}

struct DeveloperCommandLineToolsSDKRegistryExtension: SDKRegistryExtension {
    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        let operatingSystem = context.hostOperatingSystem
        guard operatingSystem == .macOS, let commandLineToolsPath = context.developerPath.commandLineToolsPath, let platform = context.platformRegistry.lookup(name: "macosx") else {
            return []
        }

        let sdksPath = commandLineToolsPath.join("SDKs")
        let sdkPaths = try Set(context.fs.listdir(sdksPath).filter({ $0.hasSuffix(".sdk") }).map { try context.fs.realpath(sdksPath.join($0)) }).sorted()
        return try sdkPaths.map { sdkPath in
            guard let settings = try PropertyList.fromPath(sdkPath.join("SDKSettings.plist"), fs: context.fs).dictValue else {
                // The data should always be a dictionary.
                throw StubError.error("unexpected SDK data")
            }
            return (sdkPath, platform, settings)
        }
    }
}

struct DeveloperCommandLineToolsPlatformInfoExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        let operatingSystem = context.hostOperatingSystem
        guard operatingSystem == .macOS, let commandLineToolsPath = context.developerPath.commandLineToolsPath else {
            return []
        }

        let sdksPath = commandLineToolsPath.join("SDKs")
        let sdkVersions = try context.fs.listdir(sdksPath).compactMap { sdkName -> Version? in
            let settings = try PropertyList.fromPath(sdksPath.join(sdkName).join("SDKSettings.plist"), fs: context.fs)
            guard let sdkVersion = settings.dictValue?["Version"]?.stringValue else {
                return nil
            }
            return try Version(sdkVersion)
        }

        guard let latestVersion = sdkVersions.sorted().last else {
            return []
        }

        let versionString = latestVersion.normalized(toNumberOfComponents: 2).description

        return try [
            (
                commandLineToolsPath,
                [
                    "Type": .plString("Platform"),
                    "Name": .plString(operatingSystem.xcodePlatformName),
                    "Identifier": .plString("com.apple.platform.macosx"),
                    "Version": .plString(versionString),
                    "Description": .plString("macOS"),
                    "FamilyName": .plString("macOS"),
                    "FamilyDisplayName": .plString("macOS"),
                    "FamilyIdentifier": .plString(operatingSystem.xcodePlatformName),

                    // DefaultProperties/AdditionalInfo matches what's actually in the platform... we should aim to minimize/remove this.
                    "DefaultProperties": .plDict([
                        "COMPRESS_PNG_FILES": .plString("NO"),
                        "DEFAULT_COMPILER": .plString("com.apple.compilers.llvm.clang.1_0"),
                        "DEPLOYMENT_TARGET_SETTING_NAME": .plString("MACOSX_DEPLOYMENT_TARGET"),
                        "GCC_WARN_64_TO_32_BIT_CONVERSION[arch=*64]": .plString("YES"),
                        "STRIP_PNG_TEXT": .plString("NO")
                    ]),
                    "AdditionalInfo": .plDict([
                        "BuildMachineOSBuild": .plString("$(MAC_OS_X_PRODUCT_BUILD_VERSION)"),
                        "CFBundleSupportedPlatforms": .plArray([.plString("MacOSX")]),
                        "DTCompiler": .plString("$(GCC_VERSION)"),
                        "DTPlatformBuild": .plString("$(PLATFORM_PRODUCT_BUILD_VERSION)"),
                        "DTPlatformName": .plString(operatingSystem.xcodePlatformName),
                        "DTPlatformVersion": .plString(versionString),
                        "DTSDKBuild": .plString("$(SDK_PRODUCT_BUILD_VERSION)"),
                        "DTSDKName": .plString("$(SDK_NAME)"),
                        "DTXcode": .plString("$(XCODE_VERSION_ACTUAL)"),
                        "DTXcodeBuild": .plString("$(XCODE_PRODUCT_BUILD_VERSION)"),
                        "LSMinimumSystemVersion": .plString("$($(DEPLOYMENT_TARGET_SETTING_NAME))")
                    ]),
                ]
            )]
    }
}

struct DeveloperCommandLineToolsToolchainRegistryExtension: ToolchainRegistryExtension {
    func additionalToolchains(context: any ToolchainRegistryExtensionAdditionalToolchainsContext) async throws -> [Toolchain] {
        guard context.hostOperatingSystem == .macOS, let commandLineToolsPath = context.developerPath.commandLineToolsPath else {
            return []
        }

        let fs = context.fs
        return [
            Toolchain(
                identifier: ToolchainRegistry.defaultToolchainIdentifier,
                displayName: "Default",
                version: Version(),
                aliases: ["default"],
                path: commandLineToolsPath,
                frameworkPaths: [],
                libraryPaths: [commandLineToolsPath.join("usr").join("lib").str],
                defaultSettings: [:],
                overrideSettings: [:],
                defaultSettingsWhenPrimary: [:],
                executableSearchPaths: [commandLineToolsPath.join("usr").join("bin")],
                testingLibraryPlatformNames: [],
                fs: fs)
        ]
    }
}

extension Core.DeveloperPath {
    var commandLineToolsPath: Path? {
        switch self {
        case let .swiftToolchain(_, xcodeDeveloperPath: path?), let .xcode(path):
            // We shouldn't rely so heavily on the last path component being "CommandLineTools", but this is how xcrun does it.
            return path.basename == "CommandLineTools" ? path : nil
        case .swiftToolchain(_, xcodeDeveloperPath: nil):
            return nil
        }
    }
}
