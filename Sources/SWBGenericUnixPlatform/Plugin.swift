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
    let plugin = GenericUnixPlugin()
    manager.register(GenericUnixDeveloperDirectoryExtension(), type: DeveloperDirectoryExtensionPoint.self)
    manager.register(GenericUnixPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(GenericUnixPlatformInfoExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(GenericUnixSDKRegistryExtension(plugin: plugin), type: SDKRegistryExtensionPoint.self)
    manager.register(GenericUnixToolchainRegistryExtension(plugin: plugin), type: ToolchainRegistryExtensionPoint.self)
}

final class GenericUnixPlugin: Sendable {
    func swiftExecutablePath(fs: any FSProxy) -> Path? {
        [
            Environment.current["SWIFT_EXEC"].map(Path.init),
            StackedSearchPath(environment: .current, fs: fs).lookup(Path("swift"))
        ].compactMap { $0 }.first(where: fs.exists)
    }

    func swiftTargetInfo(swiftExecutablePath: Path) async throws -> SwiftTargetInfo {
        let args = ["-print-target-info"]
        let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: swiftExecutablePath.str), arguments: args)
        guard executionResult.exitStatus.isSuccess else {
            throw RunProcessNonZeroExitError(args: [swiftExecutablePath.str] + args, workingDirectory: nil, environment: [:], status: executionResult.exitStatus, stdout: ByteString(executionResult.stdout), stderr: ByteString(executionResult.stderr))
        }
        return try JSONDecoder().decode(SwiftTargetInfo.self, from: executionResult.stdout)
    }
}

struct SwiftTargetInfo: Decodable {
    struct TargetInfo: Decodable {
        let triple: LLVMTriple
        let unversionedTriple: LLVMTriple
    }
    let target: TargetInfo
}

extension SwiftTargetInfo.TargetInfo {
    var tripleVersion: String? {
        triple != unversionedTriple && triple.system.hasPrefix(unversionedTriple.system) ? String(triple.system.dropFirst(unversionedTriple.system.count)).nilIfEmpty : nil
    }
}

struct GenericUnixDeveloperDirectoryExtension: DeveloperDirectoryExtension {
    func fallbackDeveloperDirectory(hostOperatingSystem: OperatingSystem) async throws -> Core.DeveloperPath? {
        if hostOperatingSystem == .windows || hostOperatingSystem == .macOS {
            // Handled by the Windows and Apple plugins
            return nil
        }

        return .swiftToolchain(.root, xcodeDeveloperPath: nil)
    }
}

struct GenericUnixPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBGenericUnixPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    func specificationDomains() -> [String: [String]] {
        [
            "linux": ["generic-unix"],
            "freebsd": ["generic-unix"],
            "openbsd": ["generic-unix"],
        ]
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
    let plugin: GenericUnixPlugin

    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        let operatingSystem = context.hostOperatingSystem
        guard operatingSystem.createFallbackSystemToolchain, let platform = try context.platformRegistry.lookup(name: operatingSystem.xcodePlatformName), let swift = plugin.swiftExecutablePath(fs: context.fs) else {
            return []
        }

        let defaultProperties: [String: PropertyListItem]
        switch operatingSystem {
        case .linux, .freebsd:
            defaultProperties = [
                // Workaround to avoid `-dependency_info`.
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

        let swiftTargetInfo = try await plugin.swiftTargetInfo(swiftExecutablePath: swift)

        let deploymentTargetSettings: [String: PropertyListItem]
        if operatingSystem == .freebsd {
            guard let tripleVersion = swiftTargetInfo.target.tripleVersion else {
                throw StubError.error("Unknown FreeBSD triple version")
            }
            deploymentTargetSettings = [
                "DeploymentTargetSettingName": .plString("FREEBSD_DEPLOYMENT_TARGET"),
                "DefaultDeploymentTarget": .plString(tripleVersion),
                "MinimumDeploymentTarget": .plString(tripleVersion),
                "MaximumDeploymentTarget": .plString(tripleVersion),
            ]
        } else {
            deploymentTargetSettings = [:]
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
                ].merging(deploymentTargetSettings, uniquingKeysWith: { _, new in new }))
            ]),
        ])]
    }
}

struct GenericUnixToolchainRegistryExtension: ToolchainRegistryExtension {
    let plugin: GenericUnixPlugin

    func additionalToolchains(context: any ToolchainRegistryExtensionAdditionalToolchainsContext) async throws -> [Toolchain] {
        let operatingSystem = context.hostOperatingSystem
        let fs = context.fs
        guard operatingSystem.createFallbackSystemToolchain, let swift = plugin.swiftExecutablePath(fs: fs) else {
            return []
        }

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
}

extension OperatingSystem {
    /// Whether the Core is allowed to create a fallback toolchain, SDK, and platform for this operating system in cases where no others have been provided.
    var createFallbackSystemToolchain: Bool {
        return self == .linux || self == .freebsd || self == .openbsd
    }
}
