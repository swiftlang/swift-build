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
    manager.register(GenericUnixDeveloperDirectoryExtension(plugin: plugin), type: DeveloperDirectoryExtensionPoint.self)
    manager.register(GenericUnixPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(GenericUnixPlatformInfoExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(GenericUnixSDKRegistryExtension(plugin: plugin), type: SDKRegistryExtensionPoint.self)
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
        let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: swiftExecutablePath.str), arguments: args, environment: [:])
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
    let plugin: GenericUnixPlugin

    func fallbackDeveloperDirectory(hostOperatingSystem: OperatingSystem) async throws -> Core.DeveloperPath? {
        if hostOperatingSystem == .windows || hostOperatingSystem == .macOS {
            // Handled by the Windows and Apple plugins
            return nil
        }

        let fs = localFS
        guard let swift = plugin.swiftExecutablePath(fs: fs) else {
            return nil
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

        return .swiftToolchain(path, xcodeDeveloperPath: nil)
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

    func deploymentTargetSettingName(triple: LLVMTriple) -> String? {
        _deploymentTargetSettingName(os: triple.system)
    }

    func swiftSDKAdditionalContext(context: any PlatformInfoExtensionSwiftSDKAdditionalCustomPropertiesContext) throws -> SwiftSDKAdditionalContext? {
        switch context.platform.name {
        case "freebsd":
            return SwiftSDKAdditionalContext(additionalCustomProperties: [
                "ALTERNATE_LINKER": "lld"
            ])
        default:
            return nil
        }
    }
}

func _deploymentTargetSettingName(os: String) -> String? {
    switch os {
    case "freebsd":
        return "FREEBSD_DEPLOYMENT_TARGET"
    case "openbsd":
        return "OPENBSD_DEPLOYMENT_TARGET"
    default:
        return nil
    }
}

struct GenericUnixSDKRegistryExtension: SDKRegistryExtension {
    let plugin: GenericUnixPlugin

    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        return try await OperatingSystem.createFallbackSystemToolchains.asyncMap { operatingSystem in
            // Only create SDKs if the host OS allows a fallback toolchain, and we're not cross compiling (Swift SDKs handle the cross compilation path).
            guard operatingSystem.createFallbackSystemToolchain && operatingSystem == context.hostOperatingSystem else {
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
            case .openbsd:
                defaultProperties = [
                    "GENERATE_TEXT_BASED_STUBS": "NO",
                    "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",
                    "AR": "ar",
                ]
            default:
                defaultProperties = [:]
            }

            let shouldUseLLD = {
                switch operatingSystem {
                case .freebsd, .openbsd:
                    // FreeBSD and OpenBSD are always LLVM-based.
                    return true
                case .linux:
                    // Amazon Linux 2 has a gold linker bug see: https://sourceware.org/bugzilla/show_bug.cgi?id=23016.
                    guard let distribution = operatingSystem.distribution else {
                        return false
                    }
                    return distribution.kind == .amazon && distribution.version == "2"
                default:
                    return false
                }
            }()

            if shouldUseLLD {
                defaultProperties["ALTERNATE_LINKER"] = "lld"
            }

            let tripleSystem = try operatingSystem.xcodePlatformName
            let tripleEnvironment: String
            switch operatingSystem {
            case .linux:
                tripleEnvironment = "gnu"
            default:
                tripleEnvironment = ""
            }

            let realTripleVersion = try Version(ProcessInfo.processInfo.operatingSystemVersion).zeroTrimmed.description
            let deploymentTargetSettings: [String: PropertyListItem]
            if let deploymentTargetSettingName = _deploymentTargetSettingName(os: tripleSystem) {
                deploymentTargetSettings = [
                    "DeploymentTargetSettingName": .plString(deploymentTargetSettingName),
                    "DefaultDeploymentTarget": .plString(realTripleVersion),
                    "MinimumDeploymentTarget": .plString(realTripleVersion),
                    "MaximumDeploymentTarget": .plString(realTripleVersion),
                ]
            } else {
                deploymentTargetSettings = [:]
            }

            return try (.root, platform, [
                "Type": .plString("SDK"),
                "Version": .plString(realTripleVersion),
                "CanonicalName": .plString(operatingSystem.xcodePlatformName),
                "IsBaseSDK": .plBool(true),
                "DefaultProperties": .plDict([
                    "PLATFORM_NAME": .plString(operatingSystem.xcodePlatformName),
                ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
                "CustomProperties": .plDict([
                    // When using the fallback system SDK, pass neither -sdk nor -sysroot. Doing so
                    // breaks the VFS-based modularization of SwiftGlibc.
                    "SWIFTC_PASS_SDKROOT": "NO",
                    "SWIFTC_PASS_SYSROOT": "NO",
                ]),
                "SupportedTargets": .plDict([
                    operatingSystem.xcodePlatformName: .plDict([
                        "Archs": .plArray(Architecture.hostStringValue.map { [.plString($0)] } ?? []),
                        "LLVMTargetTripleEnvironment": .plString(tripleEnvironment),
                        "LLVMTargetTripleSys": .plString(tripleSystem),
                        "LLVMTargetTripleVendor": .plString("unknown"),
                    ].merging(deploymentTargetSettings, uniquingKeysWith: { _, new in new }))
                ]),
            ])
        }.compactMap { $0 }
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
