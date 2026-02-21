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

public let initializePlugin: PluginInitializationFunction = { manager in
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

struct GenericUnixDeveloperDirectoryExtension: DeveloperDirectoryExtension {
    func fallbackDeveloperDirectory(hostOperatingSystem: OperatingSystem) async throws -> Core.DeveloperPath? {
        if hostOperatingSystem == .windows || hostOperatingSystem == .macOS {
            // Handled by the Windows and Apple plugins
            return nil
        }

        if let override = ProcessInfo.processInfo.environment["GENERIC_UNIX_DEVELOPER_DIR_TESTING_OVERRIDE"].map({ Path($0) }), override.isAbsolute {
            print("GENERIC_UNIX_DEVELOPER_DIR_TESTING_OVERRIDE: \(override)")
            return .swiftToolchain(override, xcodeDeveloperPath: nil)
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
        return try OperatingSystem.createFallbackSystemToolchains.compactMap { operatingSystem in
            // Only create platforms if the host OS allows a fallback toolchain, or we're cross compiling.
            guard operatingSystem.createFallbackSystemToolchain || operatingSystem != context.hostOperatingSystem else {
                return nil
            }
            return try (.root, [
                "Type": .plString("Platform"),
                "Name": .plString(operatingSystem.xcodePlatformName),
                "Identifier": .plString(operatingSystem.xcodePlatformName),
                "Description": .plString(operatingSystem.xcodePlatformName),
                "FamilyName": .plString(operatingSystem.xcodePlatformName.capitalized),
                "FamilyIdentifier": .plString(operatingSystem.xcodePlatformName),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        }
    }

    func platformName(triple: LLVMTriple) -> String? {
        switch triple.system {
        case "linux" where triple.environment?.hasPrefix("gnu") == true || triple.environment == "musl",
            "freebsd",
            "openbsd":
            return triple.system
        default:
            return nil
        }
    }
}

struct GenericUnixSDKRegistryExtension: SDKRegistryExtension {
    let plugin: GenericUnixPlugin

    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        return try await OperatingSystem.createFallbackSystemToolchains.asyncMap { operatingSystem in
            // Only create SDKs if the host OS allows a fallback toolchain, or we're cross compiling.
            guard operatingSystem.createFallbackSystemToolchain || operatingSystem != context.hostOperatingSystem else {
                return nil
            }

            // Don't create any SDKs for the platform if the platform itself isn't registered.
            guard let platform = try context.platformRegistry.lookup(name: operatingSystem.xcodePlatformName) else {
                return nil
            }

            var defaultProperties: [String: PropertyListItem]
            switch operatingSystem {
            case .linux, .freebsd:
                defaultProperties = [
                    // Workaround to avoid `-dependency_info`.
                    "LD_DEPENDENCY_INFO_FILE": .plString(""),
                    "PRELINK_DEPENDENCY_INFO_FILE": .plString(""),

                    "GENERATE_TEXT_BASED_STUBS": "NO",
                    "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

                    "AR": "llvm-ar",
                ]
            default:
                defaultProperties = [:]
            }

            let shouldUseLLD = {
                switch operatingSystem {
                case .freebsd:
                    // FreeBSD is always LLVM-based.
                    return true
                case .linux:
                    // Amazon Linux 2 has a gold linker bug see: https://sourceware.org/bugzilla/show_bug.cgi?id=23016.
                    guard let distribution = operatingSystem.distribution else {
                        return false
                    }
                    return distribution.kind == .amazon && distribution.version == "2"
                default:
                    // Cross-compiling.
                    return operatingSystem != context.hostOperatingSystem
                }
            }()

            if shouldUseLLD {
                defaultProperties["ALTERNATE_LINKER"] = "lld"
            }

            let tripleEnvironment: String
            switch operatingSystem {
            case .linux:
                tripleEnvironment = "gnu"
            default:
                tripleEnvironment = ""
            }

            let swiftSDK: SwiftSDK?
            let sysroot: Path
            let architectures: [String]
            let tripleVersion: String?
            let customProperties: [String: PropertyListItem]
            if operatingSystem == context.hostOperatingSystem {
                swiftSDK = nil
                sysroot = .root
                architectures = [Architecture.hostStringValue ?? "unknown"]
                tripleVersion = nil
                customProperties = [
                    "SWIFTC_PASS_SDKROOT": "NO",
                ]
            } else {
                do {
                    let swiftSDKs = try SwiftSDK.findSDKs(
                        targetTriples: nil,
                        fs: context.fs,
                        hostOperatingSystem: context.hostOperatingSystem
                    ).filter { sdk in
                        try sdk.targetTriples.keys.map {
                            try LLVMTriple($0)
                        }.contains {
                            switch operatingSystem {
                            case .linux:
                                $0.system == "linux" && $0.environment?.hasPrefix("gnu") == true
                            case .freebsd:
                                $0.system == "freebsd"
                            case .openbsd:
                                $0.system == "openbsd"
                            default:
                                throw StubError.error("Unhandled operating system: \(operatingSystem)")
                            }
                        }
                    }
                    // FIXME: Do something better than just skipping the platform if more than one SDK matches
                    swiftSDK = swiftSDKs.only
                    guard let swiftSDK else {
                        return nil
                    }
                    sysroot = swiftSDK.path
                    architectures = try swiftSDK.targetTriples.keys.map { try LLVMTriple($0).arch }.sorted()
                    tripleVersion = try Set(swiftSDK.targetTriples.keys.compactMap { try LLVMTriple($0).version }).only?.description
                    customProperties = try Dictionary(uniqueKeysWithValues: swiftSDK.targetTriples.map { targetTriple in
                        try ("__SYSROOT_\(LLVMTriple(targetTriple.key).arch)", .plString(swiftSDK.path.join(targetTriple.value.sdkRootPath).str))
                    }).merging([
                        "SYSROOT": "$(__SYSROOT_$(CURRENT_ARCH))",
                    ], uniquingKeysWith: { _, new in new })
                } catch {
                    // FIXME: Handle errors?
                    return nil
                }
            }

            let deploymentTargetSettings: [String: PropertyListItem]
            if operatingSystem == .freebsd {
                let realTripleVersion: String
                if context.hostOperatingSystem == operatingSystem {
                    guard let swift = plugin.swiftExecutablePath(fs: context.fs) else {
                        throw StubError.error("Cannot locate swift executable path for determining the FreeBSD triple version")
                    }
                    let swiftTargetInfo = try await plugin.swiftTargetInfo(swiftExecutablePath: swift)
                    guard let foundTripleVersion = try swiftTargetInfo.target.triple.version?.description else {
                        throw StubError.error("Unknown FreeBSD triple version")
                    }
                    realTripleVersion = foundTripleVersion
                } else if let tripleVersion {
                    realTripleVersion = tripleVersion
                } else {
                    return nil // couldn't compute triple version for FreeBSD
                }
                deploymentTargetSettings = [
                    "DeploymentTargetSettingName": .plString("FREEBSD_DEPLOYMENT_TARGET"),
                    "DefaultDeploymentTarget": .plString(realTripleVersion),
                    "MinimumDeploymentTarget": .plString(realTripleVersion),
                    "MaximumDeploymentTarget": .plString(realTripleVersion),
                ]
            } else {
                deploymentTargetSettings = [:]
            }

            return try (sysroot, platform, [
                "Type": .plString("SDK"),
                "Version": .plString(Version(ProcessInfo.processInfo.operatingSystemVersion).zeroTrimmed.description),
                "CanonicalName": .plString(operatingSystem.xcodePlatformName),
                "IsBaseSDK": .plBool(true),
                "DefaultProperties": .plDict([
                    "PLATFORM_NAME": .plString(operatingSystem.xcodePlatformName),
                ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
                "CustomProperties": .plDict(customProperties),
                "SupportedTargets": .plDict([
                    operatingSystem.xcodePlatformName: .plDict([
                        "Archs": .plArray(architectures.map { .plString($0) }),
                        "LLVMTargetTripleEnvironment": .plString(tripleEnvironment),
                        "LLVMTargetTripleSys": .plString(operatingSystem.xcodePlatformName),
                        "LLVMTargetTripleVendor": .plString("unknown"),
                    ].merging(deploymentTargetSettings, uniquingKeysWith: { _, new in new }))
                ]),
            ])
        }.compactMap { $0 }
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
    static var createFallbackSystemToolchains: [OperatingSystem] {
        [.linux, .freebsd, .openbsd]
    }

    /// Whether the Core is allowed to create a fallback toolchain, SDK, and platform for this operating system in cases where no others have been provided.
    fileprivate var createFallbackSystemToolchain: Bool {
        return Self.createFallbackSystemToolchains.contains(self)
    }
}
