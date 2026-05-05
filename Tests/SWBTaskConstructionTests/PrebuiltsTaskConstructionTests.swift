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
        let prebuiltsDir = Path("/tmp/Test/prebuiltsProject/build/prebuilts")
        let prebuiltsInclude = prebuiltsDir.join("Modules")
        let prebuiltsLibrary = prebuiltsDir.join("libMacroSupport.a")

        let hostFilter = SWBProtocol.PlatformFilter(platform: "macos")
        let destFilter = SWBProtocol.PlatformFilter(platform: "macos", exclude: true)

        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup("ProjectFiles", children: [
                TestFile("Application.swift"),
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
                        "LIBTOOL": self.libtoolPath.str,
                    ]
                )
            ],
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SDKROOT": "auto",
                            "SDK_VARIANT": "auto",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "ARCHS": "arm64",
                            "ALWAYS_SEARCH_USER_PATHS": "false",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Application.swift"
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
            ]
        )

        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup("PackageFiles", children: [
                TestFile("SwiftSyntax.swift"),
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
                        "LIBTOOL": self.libtoolPath.str,
                    ]
                )
            ],
            targets: [
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
                                "OTHER_CFLAGS": "$(inherited) -I \(prebuiltsInclude.str)",
                                "OTHER_SWIFT_FLAGS": "$(inherited) -I \(prebuiltsInclude.str)",
                                "OTHER_LDFLAGS": "$(inherited) \(prebuiltsLibrary.str)",
                            ])
                        )
                    ]
                ),
            ]
        )

        let testWorkspace = TestWorkspace("prebuiltsWorkspace", projects: [testProject, testPackage])

        let fs = PseudoFS()
        try fs.createDirectory(prebuiltsInclude, recursive: true)
        try fs.write(prebuiltsLibrary, contents: "prebuilts")
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testWorkspace)
        let parameters = BuildParameters(configuration: "Debug")

        await tester.checkBuild(parameters, runDestination: .macOS, targetName: "Application", fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Application") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains([prebuiltsInclude.str])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains([prebuiltsLibrary.str])
                }
            }
        }

        await tester.checkBuild(parameters, runDestination: .iOS, targetName: "Application", fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Application") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineDoesNotContain(prebuiltsInclude.str)
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineDoesNotContain(prebuiltsLibrary.str)
                }
            }
        }
    }
}
