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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct ObjectLibraryTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func objectLibraryBasics() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("a.c"),
                    TestFile("b.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .objectLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["a.c", "b.c"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("AssembleObjectLibrary")) { task in
                task.checkCommandLineMatches([
                    "builtin-ObjectLibraryAssembler",
                    .suffix("a.o"),
                    .suffix("b.o"),
                    "--output",
                    .suffix("Library.objlib")
                ])
                task.checkInputs([
                    .pathPattern(.suffix("a.o")),
                    .pathPattern(.suffix("b.o")),
                    .namePattern(.any),
                    .namePattern(.any),
                ])
                task.checkOutputs([
                    .pathPattern(.suffix("Library.objlib"))
                ])
            }
        }
    }

    @Test(.requireSDKs(.host))
    func objectLibraryConsumer() async throws {
        let testWorkspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("a.swift"),
                            TestFile("b.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": try await swiftVersion,
                                "SWIFT_EXEC": try await swiftCompilerPath.str
                            ]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "Tool",
                            type: .commandLineTool,
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    "b.swift",
                                ]),
                                TestFrameworksBuildPhase([
                                    "Library.objlib"
                                ])
                            ],
                            dependencies: [
                                "Library",
                            ]
                        ),
                        TestStandardTarget(
                            "Library",
                            type: .objectLibrary,
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    "a.swift",
                                ]),
                            ]
                        ),
                    ])
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testWorkspace)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.and(.suffix("args.resp"), .prefix("@"))])
            }
        }
    }
}
