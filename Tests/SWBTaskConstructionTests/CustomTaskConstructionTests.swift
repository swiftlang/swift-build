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
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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

            results.checkTask(.matchRulePattern(["CustomTask", "My Custom Task", .any])) { task in
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
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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

            results.checkTask(.matchRulePattern(["CustomTask", "My Custom Task", .any])) { task in
                task.checkCommandLine(["tool", "-foo", "-bar"])
                results.checkTaskDoesNotFollow(task, .matchRulePattern(["CustomTask", "My Custom Task 2", .any]))
            }

            results.checkTask(.matchRulePattern(["CustomTask", "My Custom Task 2", .any])) { task in
                task.checkCommandLine(["tool2", "-bar", "-foo"])
                results.checkTaskDoesNotFollow(task, .matchRulePattern(["CustomTask", "My Custom Task", .any]))
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
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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

            results.checkTask(.matchRulePattern(["CustomTask", "My Custom Task", .any])) { task in
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
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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

            results.checkTask(.matchRulePattern(["CustomTask", "My Custom Task", .any])) { task in
                task.checkEnvironment(["ENVVAR": "VALUE", "MY_SETTING": "FOO"])
            }
        }
    }

    @Test(.requireSDKs(.host))
    func customTasksWithDuplicateDescriptions() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("input.txt"),
                    TestFile("input2.txt"),
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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
                            preparesForIndexing: false),
                        TestCustomTask(
                            commandLine: ["tool", "-foo", "-bar"],
                            environment: ["ENVVAR": "VALUE"],
                            workingDirectory: Path.root.join("working/directory").str,
                            executionDescription: "My Custom Task",
                            inputs: ["$(SRCROOT)/Sources/input2.txt"],
                            outputs: [Path.root.join("output2").str],
                            enableSandboxing: false,
                            preparesForIndexing: false)
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .host) { results in
            // Ensure we don't incorrectly diagnose duplicate custom tasks
            results.checkNoDiagnostics()
        }
    }

    /// Custom tasks that produce compilation requirement file types (e.g. module maps or headers)
    /// should be ordered before the modules-ready gate so that downstream targets wait for them
    /// before starting compilation.
    @Test(.requireSDKs(.host))
    func customTaskWithModuleMapOutputIsCompilationRequirement() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("input.txt"),
                    TestFile("foo.c"),
                    TestFile("bar.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
            ],
            targets: [
                // Upstream target: has a custom task that produces a module map
                TestStandardTarget(
                    "Generator", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                    ],
                    customTasks: [
                        TestCustomTask(
                            commandLine: ["generate-modulemap", "--output", "$(BUILT_PRODUCTS_DIR)/module.modulemap"],
                            environment: [:],
                            workingDirectory: "$(SRCROOT)",
                            executionDescription: "Generate module map",
                            inputs: ["$(SRCROOT)/Sources/input.txt"],
                            outputs: ["$(BUILT_PRODUCTS_DIR)/module.modulemap"],
                            enableSandboxing: false,
                            preparesForIndexing: true),
                    ]
                ),
                // Downstream target: depends on Generator and compiles C sources
                TestStandardTarget(
                    "Consumer", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["bar.c"]),
                    ],
                    dependencies: ["Generator"]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .host, buildRequest: buildRequest) { results in
            results.checkNoDiagnostics()

            // The custom task that produces a module map should be a compilation requirement,
            // meaning downstream compilation must wait for it.
            results.checkTask(.matchTargetName("Consumer"), .matchRuleType("CompileC")) { compileTask in
                if let customTask = results.findOneMatchingTask([.matchTargetName("Generator"), .matchRulePattern(["CustomTask", "Generate module map", .any])]) {
                    results.checkTaskFollows(compileTask, antecedent: customTask)
                }

                // With eager compilation, the downstream compile should NOT have to wait for the upstream link.
                results.checkTaskDoesNotFollow(compileTask, .matchTargetName("Generator"), .matchRuleType("Ld"))
            }
        }
    }

    /// Custom tasks that produce non-compilation-requirement outputs should NOT block
    /// downstream compilation with eager compilation enabled.
    @Test(.requireSDKs(.host))
    func customTaskWithNonCompilationRequirementOutputDoesNotBlockCompilation() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("input.txt"),
                    TestFile("foo.c"),
                    TestFile("bar.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
            ],
            targets: [
                // Upstream target: has a custom task that produces a regular (non-header, non-modulemap) file
                TestStandardTarget(
                    "Generator", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                    ],
                    customTasks: [
                        TestCustomTask(
                            commandLine: ["generate-data", "--output", "$(BUILT_PRODUCTS_DIR)/data.txt"],
                            environment: [:],
                            workingDirectory: "$(SRCROOT)",
                            executionDescription: "Generate data",
                            inputs: ["$(SRCROOT)/Sources/input.txt"],
                            outputs: ["$(BUILT_PRODUCTS_DIR)/data.txt"],
                            enableSandboxing: false,
                            preparesForIndexing: false),
                    ]
                ),
                // Downstream target: depends on Generator and compiles C sources
                TestStandardTarget(
                    "Consumer", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["bar.c"]),
                    ],
                    dependencies: ["Generator"]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .host, buildRequest: buildRequest) { results in
            results.checkNoDiagnostics()

            // A custom task that produces a plain data file should NOT block downstream compilation
            // with eager compilation enabled.
            results.checkTask(.matchTargetName("Consumer"), .matchRuleType("CompileC")) { compileTask in
                if let customTask = results.findOneMatchingTask([.matchTargetName("Generator"), .matchRulePattern(["CustomTask", "Generate data", .any])]) {
                    results.checkTaskDoesNotFollow(compileTask, antecedent: customTask)
                }

                // With eager compilation, the downstream compile should NOT have to wait for the upstream link.
                results.checkTaskDoesNotFollow(compileTask, .matchTargetName("Generator"), .matchRuleType("Ld"))
            }
        }
    }
}
