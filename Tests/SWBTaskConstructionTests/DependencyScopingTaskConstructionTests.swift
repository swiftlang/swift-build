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
import SWBTestSupport
import SWBCore
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct DependencyScopingTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func tasksPlannedWithActiveDependencyScope() async throws {

        let testWorkspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("file.c"),
                            TestFile("file2.c"),
                            TestFile("file3.c"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ])],
                    targets: [
                        TestStandardTarget(
                            "StaticLibrary",
                            type: .staticLibrary,
                            buildConfigurations: [TestBuildConfiguration("Debug")],
                            buildPhases: [
                                TestSourcesBuildPhase(["file.c"]),
                            ], dependencies: ["StaticLibrary2", "StaticLibrary3"]),
                        TestStandardTarget(
                            "StaticLibrary2",
                            type: .staticLibrary,
                            buildConfigurations: [TestBuildConfiguration("Debug")],
                            buildPhases: [
                                TestSourcesBuildPhase(["file3.c"]),
                            ]),
                        TestStandardTarget(
                            "StaticLibrary3",
                            type: .staticLibrary,
                            buildConfigurations: [TestBuildConfiguration("Debug")],
                            buildPhases: [
                                TestSourcesBuildPhase(["file2.c"]),
                            ]),
                    ])])

        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let params = BuildParameters(configuration: "Debug")
        let f1 = BuildRequest.BuildTargetInfo(parameters: params, target: tester.workspace.target(named: "StaticLibrary")!)
        let f2 = BuildRequest.BuildTargetInfo(parameters: params, target: tester.workspace.target(named: "StaticLibrary2")!)
        let f3 = BuildRequest.BuildTargetInfo(parameters: params, target: tester.workspace.target(named: "StaticLibrary3")!)
        do {
            let buildRequest = BuildRequest(parameters: params, buildTargets: [f1, f2, f3], dependencyScope: .buildRequest, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(runDestination: .host, buildRequest: buildRequest, fs: localFS) { results in
                results.checkNoDiagnostics()
                results.checkTarget("StaticLibrary") { libraryTarget in
                    results.checkTaskExists(.matchTarget(libraryTarget), .matchRuleType("CompileC"))
                }
                results.checkTarget("StaticLibrary2") { libraryTarget in
                    results.checkTaskExists(.matchTarget(libraryTarget), .matchRuleType("CompileC"))
                }
                results.checkTarget("StaticLibrary3") { libraryTarget in
                    results.checkTaskExists(.matchTarget(libraryTarget), .matchRuleType("CompileC"))
                }
            }
        }
        do {
            let buildRequest = BuildRequest(parameters: params, buildTargets: [f1, f2], dependencyScope: .buildRequest, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(runDestination: .host, buildRequest: buildRequest, fs: localFS) { results in
                results.checkNoDiagnostics()
                results.checkTarget("StaticLibrary") { libraryTarget in
                    results.checkTaskExists(.matchTarget(libraryTarget), .matchRuleType("CompileC"))
                }
                results.checkTarget("StaticLibrary2") { libraryTarget in
                    results.checkTaskExists(.matchTarget(libraryTarget), .matchRuleType("CompileC"))
                }
                results.checkNoTarget("StaticLibrary3")
            }
        }
    }

    @Test(.requireSDKs(.host))
    func tasksPlannedWithActiveDependencyScopeRemovingInteriorTarget() async throws {

        let testWorkspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("file.c"),
                            TestFile("file2.c"),
                            TestFile("file3.c"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ])],
                    targets: [
                        TestStandardTarget(
                            "StaticLibrary",
                            type: .staticLibrary,
                            buildConfigurations: [TestBuildConfiguration("Debug")],
                            buildPhases: [
                                TestSourcesBuildPhase(["file.c"]),
                            ], dependencies: ["Framework2"]),
                        TestStandardTarget(
                            "StaticLibrary2",
                            type: .staticLibrary,
                            buildConfigurations: [TestBuildConfiguration("Debug")],
                            buildPhases: [
                                TestSourcesBuildPhase(["file3.c"]),
                            ], dependencies: ["StaticLibrary3"]),
                        TestStandardTarget(
                            "StaticLibrary3",
                            type: .staticLibrary,
                            buildConfigurations: [TestBuildConfiguration("Debug")],
                            buildPhases: [
                                TestSourcesBuildPhase(["file2.c"]),
                            ]),
                    ])])

        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let params = BuildParameters(configuration: "Debug")
        let sL1 = BuildRequest.BuildTargetInfo(parameters: params, target: tester.workspace.target(named: "StaticLibrary")!)
        let sL3 = BuildRequest.BuildTargetInfo(parameters: params, target: tester.workspace.target(named: "StaticLibrary3")!)
        do {
            let buildRequest = BuildRequest(parameters: params, buildTargets: [sL1, sL3], dependencyScope: .buildRequest, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(runDestination: .host, buildRequest: buildRequest, fs: localFS) { results in
                results.checkNoDiagnostics()
                results.checkTarget("StaticLibrary") { libraryTarget in
                    results.checkTaskExists(.matchTarget(libraryTarget), .matchRuleType("CompileC"))
                }
                results.checkTarget("StaticLibrary3") { libraryTarget in
                    results.checkTaskExists(.matchTarget(libraryTarget), .matchRuleType("CompileC"))
                }
                results.checkNoTarget("StaticLibrary2")
            }
        }
    }
}
