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
    func specificationFiles() -> Bundle? {
        .module
    }

    func specificationDomains() -> [String : [String]] {
        ["webassembly": ["generic-unix"]]
    }
}

struct WebAssemblyPlatformExtension: PlatformInfoExtension {
    func knownDeploymentTargetMacroNames() -> Set<String> {
        ["WEBASSEMBLY_DEPLOYMENT_TARGET"]
    }

    func additionalPlatforms() -> [(path: Path, data: [String: PropertyListItem])] {
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

struct WebAssemblySDKRegistryExtension: SDKRegistryExtension {
    func additionalSDKs(platformRegistry: PlatformRegistry) async -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        guard let host = try? ProcessInfo.processInfo.hostOperatingSystem() else {
            return []
        }

        guard let wasmPlatform = platformRegistry.lookup(name: "webassembly") else {
            return []
        }

        let defaultProperties: [String: PropertyListItem] = [
            "SDK_STAT_CACHE_ENABLE": "NO",

            // Workaround to avoid `-add_ast_path` on WebAssembly, apparently this needs to perform some "swift modulewrap" step instead.
            "GCC_GENERATE_DEBUGGING_SYMBOLS": .plString("NO"),

            // Workaround to avoid `-dependency_info` on WebAssembly.
            "LD_DEPENDENCY_INFO_FILE": .plString(""),

            // WebAssembly uses wasm-ld, not the Apple linker
            "LD_DETERMINISTIC_MODE": "NO",
            // HACK: The following setting does not work. Need to set `ENABLE_TESTABILITY` to `NO`
            // // Workaround to avoid `-export-dynamic` on WebAssembly.
            // "LD_EXPORT_GLOBAL_SYMBOLS": "NO",

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
            fs: localFS
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
                        "OTHER_LDFLAGS": .plArray(["-lc++", "-lc++abi", "-resource-dir", "$(SWIFT_RESOURCE_DIR)/clang", "@$(SWIFT_LIBRARY_PATH)/static-executable-args.lnk"]),
                    ]),
                    "SupportedTargets": .plDict([
                        "webassembly": .plDict([
                            "Archs": .plArray([.plString(arch)]),
                            "DeploymentTargetSettingName": .plString("WEBASSEMBLY_DEPLOYMENT_TARGET"),
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
