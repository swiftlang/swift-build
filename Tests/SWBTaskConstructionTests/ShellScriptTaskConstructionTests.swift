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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import SWBCore

@Suite
fileprivate struct ShellScriptTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func shellScriptDeploymentTargetPruning_macOS() async throws {
        try await testShellScriptDeploymentTargetPruning(sdkroot: "macosx", expectedDeploymentTargetPrefix: "MACOSX")
    }

    @Test(.requireSDKs(.iOS))
    func shellScriptDeploymentTargetPruning_iOS() async throws {
        try await testShellScriptDeploymentTargetPruning(sdkroot: "iphoneos", expectedDeploymentTargetPrefix: "IPHONEOS")
        try await testShellScriptDeploymentTargetPruning(sdkroot: "iphonesimulator", expectedDeploymentTargetPrefix: "IPHONEOS")
    }

    @Test(.requireSDKs(.tvOS))
    func shellScriptDeploymentTargetPruning_tvOS() async throws {
        try await testShellScriptDeploymentTargetPruning(sdkroot: "appletvos", expectedDeploymentTargetPrefix: "TVOS")
        try await testShellScriptDeploymentTargetPruning(sdkroot: "appletvsimulator", expectedDeploymentTargetPrefix: "TVOS")
    }

    @Test(.requireSDKs(.watchOS))
    func shellScriptDeploymentTargetPruning_watchOS() async throws {
        try await testShellScriptDeploymentTargetPruning(sdkroot: "watchos", expectedDeploymentTargetPrefix: "WATCHOS")
        try await testShellScriptDeploymentTargetPruning(sdkroot: "watchsimulator", expectedDeploymentTargetPrefix: "WATCHOS")
    }

    @Test(.requireSDKs(.xrOS))
    func shellScriptDeploymentTargetPruning_visionOS() async throws {
        try await testShellScriptDeploymentTargetPruning(sdkroot: "xros", expectedDeploymentTargetPrefix: "XROS")
        try await testShellScriptDeploymentTargetPruning(sdkroot: "xrsimulator", expectedDeploymentTargetPrefix: "XROS")
    }

    @Test(.requireSDKs(.driverKit))
    func shellScriptDeploymentTargetPruning_DriverKit() async throws {
        try await testShellScriptDeploymentTargetPruning(sdkroot: "driverkit", expectedDeploymentTargetPrefix: "DRIVERKIT")
    }

    @Test(.requireSDKs(.macOS))
    func shellScriptDependencyAnalysisNoOutputsWarning() async throws {
        func generateTestProject(withOutputs hasOutputs: Bool, alwaysOutOfDate: Bool) -> TestProject {
            TestProject(
                "MyProject",
                sourceRoot: Path("/MyProject"),
                groupTree: TestGroup("Group"),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ])],
                targets: [
                    TestStandardTarget(
                        "MyFramework",
                        type: .framework,
                        buildPhases: [
                            TestShellScriptBuildPhase(name: "", shellPath: "/bin/bash", originalObjectID: "abc", contents: "env | sort", outputs: hasOutputs ? ["foo"] : [], alwaysOutOfDate: alwaysOutOfDate)
                        ]
                    )
                ]
            )
        }

        do {
            let tester = try await TaskConstructionTester(getCore(), generateTestProject(withOutputs: true, alwaysOutOfDate: false))
            await tester.checkBuild(runDestination: nil) { results in
                results.checkNoDiagnostics()
            }
        }
        do {
            let tester = try await TaskConstructionTester(getCore(), generateTestProject(withOutputs: false, alwaysOutOfDate: true))
            await tester.checkBuild(runDestination: nil) { results in
                results.checkNote("Run script build phase 'Run Script' will be run during every build because the option to run the script phase \"Based on dependency analysis\" is unchecked. (in target \'MyFramework\' from project \'MyProject\')")
                results.checkNoDiagnostics()
            }
        }
        do {
            let tester = try await TaskConstructionTester(getCore(), generateTestProject(withOutputs: true, alwaysOutOfDate: true))
            await tester.checkBuild(runDestination: nil) { results in
                results.checkNote("Run script build phase 'Run Script' will be run during every build because the option to run the script phase \"Based on dependency analysis\" is unchecked. (in target \'MyFramework\' from project \'MyProject\')")
                results.checkNoDiagnostics()
            }
        }
        do {
            let tester = try await TaskConstructionTester(getCore(), generateTestProject(withOutputs: false, alwaysOutOfDate: false))
            await tester.checkBuild(runDestination: nil) { results in
                results.checkWarning("Run script build phase 'Run Script' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'MyFramework' from project 'MyProject')")
            }
        }
    }
}

extension CoreBasedTests {
    func testShellScriptDeploymentTargetPruning(sdkroot: String, sdkVariant: String? = nil, expectedDeploymentTargetPrefix: String) async throws {
        let testProject = TestProject(
            "MyProject",
            sourceRoot: Path("/MyProject"),
            groupTree: TestGroup("Group"),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": sdkroot,
                        "SDK_VARIANT": sdkVariant ?? "",
                        "SUPPORTED_PLATFORMS": "appletvos appletvsimulator driverkit iphoneos iphonesimulator linux macosx watchos watchsimulator",

                        "IPHONEOS_DEPLOYMENT_TARGET": "13.0",
                        "MACOSX_DEPLOYMENT_TARGET": "10.15",
                        "TVOS_DEPLOYMENT_TARGET": "13.0",
                        "WATCHOS_DEPLOYMENT_TARGET": "6.0",
                        "DRIVERKIT_DEPLOYMENT_TARGET": "19.0",
                    ])],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildPhases: [
                        TestShellScriptBuildPhase(name: "", shellPath: "/bin/bash", originalObjectID: "abc", contents: "env | sort", onlyForDeployment: false, emitEnvironment: true, alwaysOutOfDate: true)
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: nil) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                let env = task.environment.bindingsDictionary
                let otherNames = Set(["SWIFT_DEPLOYMENT_TARGET", "RESOURCES_MINIMUM_DEPLOYMENT_TARGET"])
                let suffix = "_DEPLOYMENT_TARGET"
                let deploymentTargetSettingNames = env.compactMap { key, _ in !otherNames.contains(key) && !key.hasPrefix("SWIFT_MODULE_ONLY_") && !key.hasPrefix("RECOMMENDED_") && key.hasSuffix(suffix) ? key : nil }
                #expect(deploymentTargetSettingNames == [expectedDeploymentTargetPrefix + suffix])
            }
        }
    }
}
