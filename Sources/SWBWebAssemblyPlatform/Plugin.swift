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
    manager.register(WebAssemblyPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(WebAssemblyPlatformExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(WebAssemblySDKRegistryExtension(), type: SDKRegistryExtensionPoint.self)
}

struct WebAssemblyPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBWebAssemblyPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    func specificationDomains() -> [String: [String]] {
        ["webassembly": ["generic-unix"]]
    }
}

struct WebAssemblyPlatformExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString("webassembly"),
                "Identifier": .plString("webassembly"),
                "Description": .plString("webassembly"),
                "FamilyName": .plString("WebAssembly"),
                "FamilyIdentifier": .plString("webassembly"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }
}

// TODO: We currently hardcode WebAssembly-specific information here but
// ideally we should be able to generalize this to any Swift SDK. Some of
// issues including https://github.com/swiftlang/swift-build/issues/3 prevent
// us from doing this today but we should revisit this later and consider
// renaming this plugin to something like `SWBSwiftSDKPlatform`.
struct WebAssemblySDKRegistryExtension: SDKRegistryExtension {
    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        let host = context.hostOperatingSystem
        guard let wasmPlatform = context.platformRegistry.lookup(name: "webassembly") else {
            return []
        }

        let defaultProperties: [String: PropertyListItem] = [
            "SDK_STAT_CACHE_ENABLE": "NO",

            "GENERATE_TEXT_BASED_STUBS": "NO",
            "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

            "CHOWN": "/usr/bin/chown",

            "LIBTOOL": .plString(host.imageFormat.executableName(basename: "llvm-lib")),
            "AR": .plString(host.imageFormat.executableName(basename: "llvm-ar")),
        ]

        // Map triple to parsed triple components
        let supportedTriples: [String: (arch: String, os: String, env: String?)] = [
            "wasm32-unknown-wasi": ("wasm32", "wasi", nil),
            "wasm32-unknown-wasip1": ("wasm32", "wasip1", nil),
            "wasm32-unknown-wasip1-threads": ("wasm32", "wasip1", "threads"),
        ]

        let wasmSwiftSDKs = (try? SwiftSDK.findSDKs(
            targetTriples: Array(supportedTriples.keys),
            fs: context.fs,
            hostOperatingSystem: context.hostOperatingSystem
        )) ?? []

        var wasmSDKs: [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] = []

        for wasmSDK in wasmSwiftSDKs {
            for (triple, tripleProperties) in wasmSDK.targetTriples {
                guard let (arch, os, env) = supportedTriples[triple] else {
                    continue
                }

                let wasiSysroot = wasmSDK.path.join(tripleProperties.sdkRootPath)
                let swiftResourceDir = wasmSDK.path.join(tripleProperties.swiftResourcesPath)

                wasmSDKs.append((wasiSysroot, wasmPlatform, [
                    "Type": .plString("SDK"),
                    "Version": .plString("1.0.0"),
                    "CanonicalName": .plString(wasmSDK.identifier),
                    "Aliases": ["webassembly", "wasi"],
                    "IsBaseSDK": .plBool(true),
                    "DefaultProperties": .plDict([
                        "PLATFORM_NAME": .plString("webassembly"),
                    ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
                    "CustomProperties": .plDict([
                        "LLVM_TARGET_TRIPLE_OS_VERSION": .plString(os),
                        "SWIFT_LIBRARY_PATH": .plString(swiftResourceDir.join("wasi").str),
                        "SWIFT_RESOURCE_DIR": .plString(swiftResourceDir.str),
                        // HACK: Ld step does not use swiftc as linker driver but instead uses clang, so we need to add some Swift specific flags
                        // assuming static linking.
                        // Tracked in https://github.com/swiftlang/swift-build/issues/3
                        "OTHER_LDFLAGS": .plArray(["-lc++", "-lc++abi", "-resource-dir", "$(SWIFT_RESOURCE_DIR)/clang", "@$(SWIFT_LIBRARY_PATH)/static-executable-args.lnk"]),
                    ]),
                    "SupportedTargets": .plDict([
                        "webassembly": .plDict([
                            "Archs": .plArray([.plString(arch)]),
                            "LLVMTargetTripleEnvironment": .plString(env ?? ""),
                            "LLVMTargetTripleSys": .plString(os),
                            "LLVMTargetTripleVendor": .plString("unknown"),
                        ])
                    ]),
                    // TODO: Leave compatible toolchain information in Swift SDKs
                    // "Toolchains": .plArray([])
                ]))
            }
        }

        return wasmSDKs
    }
}
