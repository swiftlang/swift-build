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
    manager.register(GenericUnixDeveloperDirectoryExtension(), type: DeveloperDirectoryExtensionPoint.self)
    manager.register(GenericUnixPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(GenericUnixPlatformInfoExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(GenericUnixSDKRegistryExtension(), type: SDKRegistryExtensionPoint.self)
    manager.register(GenericUnixToolchainRegistryExtension(), type: ToolchainRegistryExtensionPoint.self)
}

struct GenericUnixDeveloperDirectoryExtension: DeveloperDirectoryExtension {
    func fallbackDeveloperDirectory(hostOperatingSystem: OperatingSystem) async throws -> Path? {
        if hostOperatingSystem == .windows || hostOperatingSystem == .macOS {
            // Handled by the Windows and Apple plugins
            return nil
        }

        return .root
    }
}

struct GenericUnixPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBGenericUnixPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    func specificationDomains() -> [String: [String]] {
        ["linux": ["generic-unix"]]
    }
}

struct GenericUnixPlatformInfoExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        let operatingSystem = context.hostOperatingSystem
        guard operatingSystem.createFallbackSystemToolchain else {
            return []
        }

        return try [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString(operatingSystem.xcodePlatformName),
                "Identifier": .plString(operatingSystem.xcodePlatformName),
                "Description": .plString(operatingSystem.xcodePlatformName),
                "FamilyName": .plString(operatingSystem.xcodePlatformName.capitalized),
                "FamilyIdentifier": .plString(operatingSystem.xcodePlatformName),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }
}

struct GenericUnixSDKRegistryExtension: SDKRegistryExtension {
    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        let operatingSystem = context.hostOperatingSystem
        guard operatingSystem.createFallbackSystemToolchain, let platform = try context.platformRegistry.lookup(name: operatingSystem.xcodePlatformName) else {
            return []
        }

        let defaultProperties: [String: PropertyListItem]
        switch operatingSystem {
        case .linux:
            defaultProperties = [
                // Workaround to avoid `-dependency_info` on Linux.
                "LD_DEPENDENCY_INFO_FILE": .plString(""),

                "GENERATE_TEXT_BASED_STUBS": "NO",
                "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

                "CHOWN": "/usr/bin/chown",
                "AR": "llvm-ar",
            ]
        default:
            defaultProperties = [:]
        }

        let tripleEnvironment: String
        switch operatingSystem {
        case .linux:
            tripleEnvironment = "gnu"
        default:
            tripleEnvironment = ""
        }

        return try [(.root, platform, [
            "Type": .plString("SDK"),
            "Version": .plString(Version(ProcessInfo.processInfo.operatingSystemVersion).zeroTrimmed.description),
            "CanonicalName": .plString(operatingSystem.xcodePlatformName),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString(operatingSystem.xcodePlatformName),
            ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
            "SupportedTargets": .plDict([
                operatingSystem.xcodePlatformName: .plDict([
                    "Archs": .plArray([.plString(Architecture.hostStringValue ?? "unknown")]),
                    "LLVMTargetTripleEnvironment": .plString(tripleEnvironment),
                    "LLVMTargetTripleSys": .plString(operatingSystem.xcodePlatformName),
                    "LLVMTargetTripleVendor": .plString("unknown"),
                ])
            ]),
        ])]
    }
}

struct GenericUnixToolchainRegistryExtension: ToolchainRegistryExtension {
    func additionalToolchains(context: any ToolchainRegistryExtensionAdditionalToolchainsContext) async throws -> [Toolchain] {
        let operatingSystem = context.hostOperatingSystem
        guard operatingSystem.createFallbackSystemToolchain else {
            return []
        }

        let fs = context.fs

        if let swift = StackedSearchPath(environment: .current, fs: fs).lookup(Path("swift")), fs.exists(swift) {
            let realSwiftPath = try fs.realpath(swift).dirname.normalize()
            let hasUsrBin = realSwiftPath.str.hasSuffix("/usr/bin")
            let hasUsrLocalBin = realSwiftPath.str.hasSuffix("/usr/local/bin")
            let path: Path
            switch (hasUsrBin, hasUsrLocalBin) {
            case (true, false):
                path = realSwiftPath.dirname.dirname
            case (false, true):
                path = realSwiftPath.dirname.dirname.dirname
            case (false, false):
                throw StubError.error("Unexpected toolchain layout for Swift installation path: \(realSwiftPath)")
            case (true, true):
                preconditionFailure()
            }
            let llvmDirectories = try Array(fs.listdir(Path("/usr/lib")).filter { $0.hasPrefix("llvm-") }.sorted().reversed())
            let llvmDirectoriesLocal = try Array(fs.listdir(Path("/usr/local")).filter { $0.hasPrefix("llvm") }.sorted().reversed())
            return [
                Toolchain(
                    identifier: ToolchainRegistry.defaultToolchainIdentifier,
                    displayName: "Default",
                    version: Version(),
                    aliases: ["default"],
                    path: path,
                    frameworkPaths: [],
                    libraryPaths: llvmDirectories.map { "/usr/lib/\($0)/lib" } + llvmDirectoriesLocal.map { "/usr/local/\($0)/lib" } + ["/usr/lib64"],
                    defaultSettings: [:],
                    overrideSettings: [:],
                    defaultSettingsWhenPrimary: [:],
                    executableSearchPaths: realSwiftPath.dirname.relativeSubpath(from: path).map { [path.join($0).join("bin")] } ?? [],
                    testingLibraryPlatformNames: [],
                    fs: fs)
            ]
        }

        return []
    }
}

extension OperatingSystem {
    /// Whether the Core is allowed to create a fallback toolchain, SDK, and platform for this operating system in cases where no others have been provided.
    var createFallbackSystemToolchain: Bool {
        return self == .linux
    }
}
