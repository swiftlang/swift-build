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
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct RealityAssetsTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.xrOS))
    func realityAssets() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Reality.rkassets"),
                        TestFile("Foo.txt"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "xros",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "VERSIONING_SYSTEM": "apple-generic",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "FrameworkTarget",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "xros",
                                    "CODE_SIGNING_ALLOWED": "NO",
                                ]
                            )
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("Reality.rkassets"),
                                TestBuildFile("Foo.txt"),
                            ]),
                        ]
                    ),
                ], classPrefix: "XC")

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            await tester.checkBuild(runDestination: .xrOS) { results in
                results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    task.checkCommandLineContainsUninterrupted(["realitytool", "compile", "--platform", "xros", "--deployment-target", results.runDestinationSDK.defaultDeploymentTarget, "-o", "\(SRCROOT)/build/Debug-xros/FrameworkTarget.framework/Reality.reality", "\(SRCROOT)/Reality.rkassets"])
                }
                results.checkTask(.matchRuleType("CpResource")) { task in
                    task.checkCommandLineContainsUninterrupted(["\(SRCROOT)/Foo.txt", "\(SRCROOT)/build/Debug-xros/FrameworkTarget.framework"])
                }
                results.checkNoTask(.matchRuleType("RealityAssetsSchemaGen"))

                results.checkNoDiagnostics()
            }
        }
    }
}
