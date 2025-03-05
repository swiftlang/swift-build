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
fileprivate struct CustomTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func basics() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("input.txt"),
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])
                    ],
                    customTasks: [
                        TestCustomTask(
                            commandLine: ["tool", "-foo", "-bar"],
                            environment: ["ENVVAR": "VALUE"],
                            workingDirectory: Path.root.join("working/directory").str,
                            executionDescription: "My Custom Task",
                            inputs: ["$(SRCROOT)/Sources/input.txt"],
                            outputs: [Path.root.join("output").str],
                            enableSandboxing: false,
                            preparesForIndexing: false)
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .host) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRule(["CustomTask", "My Custom Task"])) { task in
                task.checkCommandLine(["tool", "-foo", "-bar"])
                task.checkEnvironment(["ENVVAR": "VALUE"])
                #expect(task.workingDirectory == Path.root.join("working/directory"))
                #expect(task.execDescription == "My Custom Task")
                task.checkInputs(contain: [.pathPattern(.suffix("Sources/input.txt"))])
                task.checkOutputs([.path(Path.root.join("output").str)])
            }
        }
    }

    @Test(.requireSDKs(.host))
    func customTasksAreIndependent() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("input.txt"),
                    TestFile("input2.txt"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [],
                    customTasks: [
                        TestCustomTask(
                            commandLine: ["tool", "-foo", "-bar"],
                            environment: ["ENVVAR": "VALUE"],
                            workingDirectory: "/working/directory",
                            executionDescription: "My Custom Task",
                            inputs: ["$(SRCROOT)/Sources/input.txt"],
                            outputs: ["/output"],
                            enableSandboxing: false,
                            preparesForIndexing: false),
                        TestCustomTask(
                            commandLine: ["tool2", "-bar", "-foo"],
                            environment: ["ENVVAR": "VALUE"],
                            workingDirectory: "/working/directory",
                            executionDescription: "My Custom Task 2",
                            inputs: ["$(SRCROOT)/Sources/input2.txt"],
                            outputs: ["/output2"],
                            enableSandboxing: false,
                            preparesForIndexing: false)
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .host) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRule(["CustomTask", "My Custom Task"])) { task in
                task.checkCommandLine(["tool", "-foo", "-bar"])
                results.checkTaskDoesNotFollow(task, .matchRule(["CustomTask", "My Custom Task 2"]))
            }

            results.checkTask(.matchRule(["CustomTask", "My Custom Task 2"])) { task in
                task.checkCommandLine(["tool2", "-bar", "-foo"])
                results.checkTaskDoesNotFollow(task, .matchRule(["CustomTask", "My Custom Task"]))
            }
        }
    }

    @Test(.requireSDKs(.host))
    func customTasksSucceedWithNoOutputs() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("input.txt"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [],
                    customTasks: [
                        TestCustomTask(
                            commandLine: ["tool", "-foo", "-bar"],
                            environment: ["ENVVAR": "VALUE"],
                            workingDirectory: "/working/directory",
                            executionDescription: "My Custom Task",
                            inputs: ["$(SRCROOT)/Sources/input.txt"],
                            outputs: [],
                            enableSandboxing: false,
                            preparesForIndexing: false),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .host) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRule(["CustomTask", "My Custom Task"])) { task in
                task.checkCommandLine(["tool", "-foo", "-bar"])
                task.checkOutputs([
                    // Virtual output
                    .namePattern(.prefix("CustomTask-"))
                ])
            }
        }
    }

    @Test(.requireSDKs(.host))
    func customTaskInjectsShellScriptEnvironment() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("input.txt"),
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                        "MY_SETTING": "FOO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])
                    ],
                    customTasks: [
                        TestCustomTask(
                            commandLine: ["tool", "-foo", "-bar"],
                            environment: ["ENVVAR": "VALUE"],
                            workingDirectory: Path.root.join("working/directory").str,
                            executionDescription: "My Custom Task",
                            inputs: ["$(SRCROOT)/Sources/input.txt"],
                            outputs: [Path.root.join("output").str],
                            enableSandboxing: false,
                            preparesForIndexing: false)
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .host) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRule(["CustomTask", "My Custom Task"])) { task in
                task.checkEnvironment(["ENVVAR": "VALUE", "MY_SETTING": "FOO"])
            }
        }
    }
}
