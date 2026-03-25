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

import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil

import SWBTaskConstruction
import Foundation

@Suite
fileprivate struct GenericUnixSwiftSDKTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host), arguments: ["aarch64", "x86_64"])
    func staticLinuxSwiftSDKRunDestination(architecture: String) async throws {
        try await withTemporaryDirectory { tmpDir in
            let clangCompilerPath = try await self.clangCompilerPath
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyLibrary",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "CLANG_ENABLE_MODULES": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CC": clangCompilerPath.str,
                                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SourceFile.c"),
                                TestBuildFile("SwiftFile.swift"),
                            ]),
                        ]),
                ])
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            // Swift SDK contents
            let sdkManifestContents = """
            {
                "schemaVersion": "4.0",
                "targetTriples": {
                    "x86_64-swift-linux-musl": {
                        "toolsetPaths": [
                            "toolset.json"
                        ],
                        "sdkRootPath": "musl-1.2.5.sdk/x86_64",
                        "swiftResourcesPath": "musl-1.2.5.sdk/x86_64/usr/lib/swift_static",
                        "swiftStaticResourcesPath": "musl-1.2.5.sdk/x86_64/usr/lib/swift_static"
                    },
                    "aarch64-swift-linux-musl": {
                        "toolsetPaths": [
                            "toolset.json"
                        ],
                        "sdkRootPath": "musl-1.2.5.sdk/aarch64",
                        "swiftResourcesPath": "musl-1.2.5.sdk/aarch64/usr/lib/swift_static",
                        "swiftStaticResourcesPath": "musl-1.2.5.sdk/aarch64/usr/lib/swift_static"
                    }
                }
            }
            """
            let sdkManifestDir = tmpDir
            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestDir.join("swift-sdk.json"), waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath": "swift.xctoolchain/usr/bin",
                    "swiftCompiler" : {
                        "extraCLIOptions" : [
                            "-static-executable",
                            "-static-stdlib"
                        ]
                    },
                    "schemaVersion": "1.0"
                }
                """)
            })

            let sysroot = sdkManifestDir.join("musl-1.2.5.sdk").join(architecture)
            let sdkroot = sdkManifestDir.join("musl-1.2.5.sdk").join(architecture)

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "\(architecture)-swift-linux-musl", targetArchitecture: architecture, supportedArchitectures: ["aarch64", "x86_64"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)
            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains([
                        [clangCompilerPath.str],
                        ["-target", "\(architecture)-swift-linux-musl"],
                        ["--sysroot", sysroot.str],
                    ].reduce([], +))
                }

                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        ["-resource-dir", sdkManifestDir.join("musl-1.2.5.sdk").join(architecture).join("usr").join("lib").join("swift_static").str],
                        ["-static-stdlib"],
                        ["-sdk", sdkroot.str],
                        ["-sysroot", sysroot.str],
                        ["-target", "\(architecture)-swift-linux-musl"],
                    ].reduce([], +))
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }
}
