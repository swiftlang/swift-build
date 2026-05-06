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
import struct SWBProtocol.ArenaInfo
import struct SWBProtocol.PlatformFilter
import SWBTestSupport
@_spi(Testing) import SWBUtil

import SWBTaskConstruction
import Foundation

/// Task construction tests related to prebuilts from SwiftPM.
@Suite
fileprivate struct PrebuiltsTaskConstructionTests: CoreBasedTests {
    @Test func prebuiltsAreHostOnly() async throws {
        let prebuiltsDir = Path.root.join("tmp").join("Test").join("prebuiltsProject").join("build").join("prebuilts")
        let prebuiltsInclude = prebuiltsDir.join("Modules")
        let prebuiltsLibrary = prebuiltsDir.join("libMacroSupport.a")

        let hostFilter: SWBProtocol.PlatformFilter
        let destFilter: SWBProtocol.PlatformFilter
        switch RunDestinationInfo.host {
        case .macOS:
            hostFilter = .init(platform: "macos")
            destFilter = .init(platform: "macos", exclude: true)
        case .linux:
            hostFilter = .init(platform: "linux", environment: "gnu")
            destFilter = .init(platform: "linux", exclude: true, environment: "gnu")
        case .windows:
            hostFilter = .init(platform: "windows", environment: "msvc")
            destFilter = .init(platform: "windows", exclude: true, environment: "msvc")
        default:
            return
        }

        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup("PackageFiles", children: [
                TestFile("SwiftSyntax.swift"),
                TestFile("Executable.swift")
            ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO",
                        "SKIP_INSTALL": "YES",
                        "SWIFT_EXEC": self.swiftCompilerPath.str,
                        "SWIFT_VERSION": self.swiftVersion,
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)"
                    ]
                )
            ],
            targets: [
                TestStandardTarget(
                    "Executable",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Executable.swift"
                        ]),
                        TestFrameworksBuildPhase([
                            .init(.target("MacroSupportProduct"), platformFilters: [hostFilter])
                        ]),
                    ],
                    dependencies: [
                        .init("MacroSupportProduct", platformFilters: [hostFilter]),
                        .init("SwiftSyntax", platformFilters: [destFilter]),
                    ]
                ),
                TestStandardTarget(
                    "SwiftSyntax",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SwiftSyntax.swift"
                        ]),
                    ]
                ),
                TestPackageProductTarget(
                    "MacroSupportProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        .init(.target("MacroSupportProduct")),
                    ]),
                    dependencies: ["MacroSupport"]
                ),
                TestAggregateTarget(
                    "MacroSupport",
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            impartedBuildProperties: .init(buildSettings: [
                                "OTHER_CFLAGS": ["$(inherited)", "-I", prebuiltsInclude.strWithPosixSlashes].joined(separator: " "),
                                "OTHER_SWIFT_FLAGS": ["$(inherited)", "-I", prebuiltsInclude.strWithPosixSlashes].joined(separator: " "),
                                "OTHER_LDFLAGS": ["$(inherited)", prebuiltsLibrary.strWithPosixSlashes].joined(separator: " "),
                            ])
                        )
                    ]
                ),
            ]
        )

        let testWorkspace = TestWorkspace("prebuiltsWorkspace", projects: [testPackage])

        let fs = PseudoFS()
        try fs.createDirectory(prebuiltsInclude, recursive: true)
        try fs.write(prebuiltsLibrary, contents: "prebuilts")

        // Test host
        let tester = try TaskConstructionTester(try await getCore(), testWorkspace)
        await tester.checkBuild(runDestination: .host, targetName: "Executable", fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Executable") { target in
                // Make sure the prebuilts were used
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains([prebuiltsInclude.strWithPosixSlashes])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains([prebuiltsLibrary.strWithPosixSlashes])
                }
            }
            // Make sure the source target wasn't used
            results.checkNoTarget("SwiftSyntax")
        }

        // Test cross with a mocked Swift SDK
        try await withTemporaryDirectory { tmpDir in
            let sdkDir = tmpDir.join("TestSDK.artifactbundle")
            try localFS.createDirectory(sdkDir)
            let sdkManifestPath = sdkDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestPath) { $0 <<< """
                {
                    "schemaVersion": "4.0",
                    "targetTriples": {
                        "wasm32-unknown-wasip1" : {
                            "sdkRootPath" : "WASI.sdk",
                            "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                            "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        }
                    }
                }
                """
            }

            let core = try await Self.makeCore()  // dedicated core, not getCore()
            let destination = try RunDestinationInfo(
                sdkManifestPath: sdkManifestPath,
                triple: "wasm32-unknown-wasip1",
                targetArchitecture: "wasm32",
                supportedArchitectures: ["wasm32"],
                disableOnlyActiveArch: false,
                core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            let tester = try TaskConstructionTester(core, testWorkspace)
            await tester.checkBuild(parameters, runDestination: nil, targetName: "Executable", fs: localFS) { results in
                results.checkNoDiagnostics()
                results.checkTarget("Executable") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                        // Make sure the prebuilts weren't used and the source target was
                        task.checkCommandLineDoesNotContain(prebuiltsInclude.strWithPosixSlashes)
                        results.checkTaskFollows(task, .matchTargetName("SwiftSyntax"), .matchRuleType("SwiftDriver Compilation Requirements"))
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineDoesNotContain(prebuiltsLibrary.strWithPosixSlashes)
                    }
                }
                results.checkNoTarget("MacroSupport")
            }
        }
    }
}
