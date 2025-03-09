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
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct ReadOnlySettingsTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func readOnlySettings() async throws {
        func getTestProject(productSpecificLdFlagsSetting: String) -> TestProject {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("ClassOne.cpp"),
                        TestFile("Info.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "macosx",
                            "PRODUCT_SPECIFIC_LDFLAGS": productSpecificLdFlagsSetting,
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "Info.plist"]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "ClassOne.cpp",
                            ]),
                            TestFrameworksBuildPhase([
                            ]),
                        ]
                    ),
                ])
            return testProject
        }
        let core = try await getCore()

        // Test with an empty setting
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(productSpecificLdFlagsSetting: "")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkError(.equal("PRODUCT_SPECIFIC_LDFLAGS assigned at level: project. This setting is append-only and cannot be overridden without prepending $(inherited). (in target 'AppTarget' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }

        // Test overriding without prepending $(inherited)
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(productSpecificLdFlagsSetting: "-e _foo")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkError(.equal("PRODUCT_SPECIFIC_LDFLAGS assigned at level: project. This setting is append-only and cannot be overridden without prepending $(inherited). (in target 'AppTarget' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }

        // Test overriding with $(inherited) in the wrong spot
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(productSpecificLdFlagsSetting: "-e _foo $(inherited)")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkError(.equal("PRODUCT_SPECIFIC_LDFLAGS assigned at level: project. This setting is append-only and cannot be overridden without prepending $(inherited). (in target 'AppTarget' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }

        // Test overriding with $(inherited) in the right spot
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(productSpecificLdFlagsSetting: "$(inherited) -e _foo")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
            }
        }

        // Test with just $(inherited) (effective no-op)
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(productSpecificLdFlagsSetting: "$(inherited)")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
