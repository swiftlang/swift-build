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
    let plugin = QNXPlugin()
    manager.register(QNXPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(QNXEnvironmentExtension(plugin: plugin), type: EnvironmentExtensionPoint.self)
    manager.register(QNXPlatformExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(QNXSDKRegistryExtension(plugin: plugin), type: SDKRegistryExtensionPoint.self)
    manager.register(QNXToolchainRegistryExtension(plugin: plugin), type: ToolchainRegistryExtensionPoint.self)
}

final class QNXPlugin: Sendable {
    private let qnxInstallations = AsyncCache<OperatingSystem, [QNXSDP]>()

    func cachedQNXSDPInstallations(host: OperatingSystem) async throws -> [QNXSDP] {
        try await qnxInstallations.value(forKey: host) {
            // Always pass localFS because this will be cached, and executes a process on the host system so there's no reason to pass in any proxy.
            try await QNXSDP.findInstallations(host: host, fs: localFS)
        }
    }
}

struct QNXPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBQNXPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }
}

struct QNXEnvironmentExtension: EnvironmentExtension {
    let plugin: QNXPlugin

    func additionalEnvironmentVariables(context: any EnvironmentExtensionAdditionalEnvironmentVariablesContext) async throws -> [String : String] {
        if let latest = try await plugin.cachedQNXSDPInstallations(host: context.hostOperatingSystem).first {
            return .init(latest.environment)
        }
        return [:]
    }
}

struct QNXPlatformExtension: PlatformInfoExtension {
    func knownDeploymentTargetMacroNames() -> Set<String> {
        ["QNX_DEPLOYMENT_TARGET"]
    }

    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString("qnx"),
                "Identifier": .plString("qnx"),
                "Description": .plString("qnx"),
                "FamilyName": .plString("QNX"),
                "FamilyIdentifier": .plString("qnx"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }
}

struct QNXSDKRegistryExtension: SDKRegistryExtension {
    let plugin: QNXPlugin

    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String : PropertyListItem])] {
        guard let qnxPlatform = context.platformRegistry.lookup(name: "qnx") else {
            return []
        }

        guard let qnxSdk = try? await plugin.cachedQNXSDPInstallations(host: context.hostOperatingSystem).first else {
            return []
        }

        let defaultProperties: [String: PropertyListItem] = [
            // None of these flags are understood by qcc/q++
            "GCC_ENABLE_PASCAL_STRINGS": .plString("NO"),
            "ENABLE_BLOCKS": .plString("NO"),
            "GCC_CW_ASM_SYNTAX": .plString("NO"),
            "print_note_include_stack": .plString("NO"),

            "CLANG_DISABLE_SERIALIZED_DIAGNOSTICS": "YES",
            "CLANG_DISABLE_DEPENDENCY_INFO_FILE": "YES",

            "GENERATE_TEXT_BASED_STUBS": "NO",
            "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

            "AR": .plString("$(QNX_HOST)/usr/bin/$(QNX_AR)"),

            "QNX_AR": .plString(qnxSdk.host.imageFormat.executableName(basename: "nto$(CURRENT_ARCH)-ar")),
            "QNX_QCC": .plString(qnxSdk.host.imageFormat.executableName(basename: "qcc")),
            "QNX_QPLUSPLUS": .plString(qnxSdk.host.imageFormat.executableName(basename: "q++")),

            "ARCH_NAME_x86_64": .plString("x86_64"),
            "ARCH_NAME_aarch64": .plString("aarch64le"),
        ]

        return [(qnxSdk.sysroot, qnxPlatform, [
            "Type": .plString("SDK"),
            "Version": .plString(qnxSdk.version?.description ?? "0.0.0"),
            "CanonicalName": .plString("qnx"),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString("qnx"),
                "QNX_TARGET": .plString(qnxSdk.path.str),
                "QNX_HOST": .plString(qnxSdk.hostPath?.str ?? ""),
            ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
            "CustomProperties": .plDict([
                // Unlike most platforms, the QNX version goes on the environment field rather than the system field
                // FIXME: Make this configurable in a better way so we don't need to push build settings at the SDK definition level
                "LLVM_TARGET_TRIPLE_OS_VERSION": .plString("nto"),
                "LLVM_TARGET_TRIPLE_SUFFIX": .plString("-qnx"),
            ]),
            "SupportedTargets": .plDict([
                "qnx": .plDict([
                    "Archs": .plArray([.plString("aarch64"), .plString("x86_64")]),
                    "LLVMTargetTripleEnvironment": .plString("qnx\(qnxSdk.version?.description ?? "0.0.0")"),
                    "LLVMTargetTripleSys": .plString("nto"),
                    "LLVMTargetTripleVendor": .plString("unknown"), // FIXME: pc for x86_64!
                ])
            ]),
            "Toolchains": .plArray([
                .plString("qnx")
            ])
        ])]
    }
}

struct QNXToolchainRegistryExtension: ToolchainRegistryExtension {
    let plugin: QNXPlugin

    func additionalToolchains(context: any ToolchainRegistryExtensionAdditionalToolchainsContext) async throws -> [Toolchain] {
        guard let toolchainPath = try? await plugin.cachedQNXSDPInstallations(host: context.hostOperatingSystem).first?.hostPath else {
            return []
        }

        return [
            Toolchain(
                identifier: "qnx",
                displayName: "QNX",
                version: Version(0, 0, 0),
                aliases: [],
                path: toolchainPath,
                frameworkPaths: [],
                libraryPaths: [],
                defaultSettings: [:],
                overrideSettings: [:],
                defaultSettingsWhenPrimary: [:],
                executableSearchPaths: [toolchainPath.join("usr").join("bin")],
                testingLibraryPlatformNames: [],
                fs: context.fs)
        ]
    }
}
