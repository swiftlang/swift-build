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

@Suite
fileprivate struct CodeCoverageTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func codeCoverageFlags() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("SwiftFile.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SWIFT_EXEC": swiftCompilerPath.str,
                                        "SWIFT_VERSION": swiftVersion,
                                        "CLANG_USE_RESPONSE_FILE": "NO",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "Target",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                            "SwiftFile.swift",
                        ]),
                    ],
                    dependencies: [
                        TestTargetDependency("NoCoverageTarget")
                    ]
                ),
                TestStandardTarget(
                    "NoCoverageTarget",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ENABLE_CODE_COVERAGE" : "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                            "SwiftFile.swift",
                        ]),
                    ]
                ),
            ])
        let tester = try TaskConstructionTester(try await getCore(), testProject)

        // Check that coverage flags are present when compiling and linking with CLANG_COVERAGE_MAPPING set
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_COVERAGE_MAPPING": "YES"]), runDestination: .host) { results in
            results.checkTarget("Target") { target in
                // There should be one CompileC task, which includes coverage options
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains(["-fprofile-instr-generate", "-fcoverage-mapping"])
                }

                // There should be one CompileSwiftSources task, which includes coverage options
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-profile-coverage-mapping", "-profile-generate"])
                }

                // There should be one Ld task, which includes coverage options
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains(["-fprofile-instr-generate"])
                }
            }

            results.checkTarget("NoCoverageTarget") { target in
                // There should be one CompileC task, without coverage options
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineDoesNotContain("-fprofile-instr-generate")
                    task.checkCommandLineDoesNotContain("-fcoverage-mapping")
                }

                // There should be one CompileSwiftSources task, without coverage options
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineDoesNotContain("-profile-generate")
                    task.checkCommandLineDoesNotContain("-profile-coverage-mapping")
                }

                // There should be one Ld task, which includes coverage options
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains(["-fprofile-instr-generate"])
                }
            }

            results.checkNoDiagnostics()
        }
    }
}
