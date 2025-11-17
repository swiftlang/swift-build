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
import SWBUtil

@Suite
fileprivate struct MetalTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS), .skipInGitHubActions("Metal toolchain is not installed on GitHub runners"))
    func indexOptions() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "ProjectName",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.metal")
                    ]),
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "COMPILER_INDEX_STORE_ENABLE": "YES",
                                    "INDEX_DATA_STORE_DIR": tmpDir.join("index").str,
                                    "INDEX_STORE_COMPRESS": "YES",
                                    "INDEX_STORE_ONLY_PROJECT_FILES": "YES",
                                    "CLANG_INDEX_STORE_IGNORE_MACROS": "YES",
                                ]
                            ),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.metal"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["INDEX_ENABLE_DATA_STORE": "YES"]), runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("CompileMetalFile")) { compileTask in
                    compileTask.checkCommandLineContains(["-index-store-path"])
                    compileTask.checkCommandLineContains(["-index-ignore-system-symbols"])
                    compileTask.checkCommandLineContains(["-index-ignore-pcms"])
                    // metal doesn't support index store compression at the moment.
                    compileTask.checkCommandLineDoesNotContain("-index-store-compress")
                }
            }
            // Check that we don't emit any index-related options when INDEX_ENABLE_DATA_STORE is not enabled
            await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: [:]), runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("CompileMetalFile")) { compileTask in
                    compileTask.checkCommandLineDoesNotContain("-index-store-path")
                    compileTask.checkCommandLineDoesNotContain("-index-store-compress")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-system-symbols")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-pcms")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .skipInGitHubActions("Metal toolchain is not installed on GitHub runners"))
    func  indexOptionsNotAddedIfIndexingIsDisabled() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "ProjectName",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.metal")
                    ]),
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "COMPILER_INDEX_STORE_ENABLE": "NO",
                                    "INDEX_DATA_STORE_DIR": tmpDir.join("index").str,
                                    "INDEX_STORE_COMPRESS": "YES",
                                    "INDEX_STORE_ONLY_PROJECT_FILES": "YES",
                                    "CLANG_INDEX_STORE_IGNORE_MACROS": "YES",
                                ]
                            ),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.metal"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["INDEX_ENABLE_DATA_STORE": "YES"]), runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("CompileMetalFile")) { compileTask in
                    compileTask.checkCommandLineDoesNotContain("-index-store-path")
                    compileTask.checkCommandLineDoesNotContain("-index-store-compress")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-system-symbols")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-pcms")
                }
            }
        }
    }
}
