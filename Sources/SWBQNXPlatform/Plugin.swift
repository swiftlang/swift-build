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
    manager.register(QNXPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(QNXEnvironmentExtension(), type: EnvironmentExtensionPoint.self)
    manager.register(QNXPlatformExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(QNXSDKRegistryExtension(), type: SDKRegistryExtensionPoint.self)
    manager.register(QNXToolchainRegistryExtension(), type: ToolchainRegistryExtensionPoint.self)
}

struct QNXPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles() -> Bundle? {
        .module
    }
}

struct QNXEnvironmentExtension: EnvironmentExtension {
    func additionalEnvironmentVariables(fs: any FSProxy) async throws -> [String : String] {
        if let latest = try await QNXSDP.findInstallations(fs: fs).first {
            return latest.environment
        }
        return [:]
    }
}

struct QNXPlatformExtension: PlatformInfoExtension {
    func knownDeploymentTargetMacroNames() -> Set<String> {
        ["QNX_DEPLOYMENT_TARGET"]
    }

    func additionalPlatforms() -> [(path: Path, data: [String: PropertyListItem])] {
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
    func additionalSDKs(platformRegistry: PlatformRegistry) async -> [(path: Path, platform: SWBCore.Platform?, data: [String : PropertyListItem])] {
        guard let qnxPlatform = platformRegistry.lookup(name: "qnx") else {
            return []
        }

        guard let qnxSdk = try? await QNXSDP.findInstallations(fs: localFS).first else {
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
    func additionalToolchains(fs: any FSProxy) async -> [Toolchain] {
        guard let toolchainPath = try? await QNXSDP.findInstallations(fs: fs).first?.hostPath else {
            return []
        }

        return [Toolchain("qnx", "QNX", Version(0, 0, 0), [], toolchainPath, [], [], [:], [:], [:], executableSearchPaths: [toolchainPath.join("usr").join("bin")], fs: fs)]
    }
}
