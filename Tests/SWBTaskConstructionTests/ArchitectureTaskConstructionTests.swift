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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct ArchitectureTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS), .requireMinimumSDKBuildVersion(sdkName: "macosx", requiredVersion: "26A1"))
    func macOSX86BackDeployment() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CC": clangCompilerPath.str,
                            "SDKROOT": "macosx",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["MACOSX_DEPLOYMENT_TARGET": "26.0"]), runDestination: .anyMac) { results in
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItem("arm64"))
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItem("x86_64"))
            }
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["MACOSX_DEPLOYMENT_TARGET": "27.0"]), runDestination: .anyMac) { results in
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItem("arm64"))
                results.checkNoTask(.matchRuleType("CompileC"), .matchRuleItem("x86_64"))
            }
        }
    }

    // We must check the SDK version (e.g. 26.0) here rather than the build version (e.g. 26A1) because DriverKit SDKs do not provide the latter.
    @Test(.requireSDKs(.driverKit), .requireMinimumSDKVersion(sdkName: "driverkit", requiredVersion: Version(27, 0)))
    func driverKitX86BackDeployment() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CC": clangCompilerPath.str,
                            "SDKROOT": "driverkit",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c"]),
                        ]
                    )
                ])

            let fs = PseudoFS()
            try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["DRIVERKIT_DEPLOYMENT_TARGET": "25.0"]), runDestination: .anyDriverKit, fs: fs) { results in
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItem("arm64"))
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItem("x86_64"))
            }
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["DRIVERKIT_DEPLOYMENT_TARGET": "27.0"]), runDestination: .anyDriverKit, fs: fs) { results in
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItem("arm64"))
                results.checkNoTask(.matchRuleType("CompileC"), .matchRuleItem("x86_64"))
            }
        }
    }
}
