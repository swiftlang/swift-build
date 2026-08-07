//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing

import SWBBuildSystem
import SWBCore
import enum SWBProtocol.BuildAction
import SWBTestSupport
import SWBTaskExecution
import SWBUtil

import class Foundation.ProcessInfo

@Suite
fileprivate struct CustomTaskBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func outputParsing() async throws {
        try await withTemporaryDirectory { tmpDir in
            let destination: RunDestinationInfo = .host
            let core = try await getCore()
            let environment = try destination.hostRuntimeEnvironment(core)

            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("tool.swift"),
                        TestFile("foo.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": try await swiftVersion,
                            "SDKROOT": "$(HOST_PLATFORM)",
                            "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "MACOSX_DEPLOYMENT_TARGET": "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)"
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "CoreFoo", type: .dynamicLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["foo.c"])
                        ],
                        customTasks: [
                            TestCustomTask(
                                commandLine: ["$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/tool\(destination == .windows ? ".exe" : "")"],
                                environment: .init(environment),
                                workingDirectory: tmpDir.str,
                                executionDescription: "My Custom Task",
                                inputs: ["$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/tool\(destination == .windows ? ".exe" : "")"],
                                outputs: [Path.root.join("output").str],
                                enableSandboxing: false,
                                preparesForIndexing: false)
                        ],
                        dependencies: ["tool"]
                    ),
                    TestStandardTarget(
                        "tool", type: .hostBuildTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["tool.swift"])
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .host)

            try await tester.fs.writeFileContents(tmpDir.join("Sources").join("tool.swift")) { stream in
                stream <<<
                    """
                    @main
                    struct Entry {
                        static func main() {
                            print("warning: this is a warning")
                        }
                    }
                    """
            }

            try await tester.fs.writeFileContents(tmpDir.join("Sources").join("foo.c")) { stream in
                stream <<<
                    """
                    void foo(void) {}
                    """
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .host) { results in
                results.checkWarning(.contains("this is a warning"))
                // The swift-driver may emit this warning when it can't write incremental build state (e.g. permission issues in some CI environments).
                results.checkWarning(.contains("next compile won't be incremental"), failIfNotFound: false)
                results.checkNoDiagnostics()
            }
        }
    }

    /// Check that a custom task marked `alwaysOutOfDate` re-runs on every build, while an otherwise
    /// identical custom task which participates in dependency analysis does not.
    @Test(.requireSDKs(.host))
    func alwaysOutOfDateIncrementalBehaviors() async throws {
        let command: [String]
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            let commandShellPath = try #require(getEnvironmentVariable("ComSpec"), "Can't determine path to cmd.exe because the ComSpec environment variable is not set")
            command = [commandShellPath, "/c", "echo"]
        } else {
            command = ["/bin/sh", "-c", "echo"]
        }
        try await withTemporaryDirectory { tmpDirPath in
            let output1 = tmpDirPath.join("output1")
            let output2 = tmpDirPath.join("output2")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources",
                            children: [
                                TestFile("input"),
                            ]
                        ),
                        targets: [
                            TestAggregateTarget(
                                "All",
                                customTasks: [
                                    // Participates in dependency analysis, so it should only run when its inputs change.
                                    TestCustomTask(
                                        commandLine: command,
                                        environment: [:],
                                        workingDirectory: tmpDirPath.str,
                                        executionDescription: "Analyzed Task",
                                        inputs: ["$(SRCROOT)/Sources/input"],
                                        outputs: [output1.str],
                                        enableSandboxing: false,
                                        preparesForIndexing: false,
                                        alwaysOutOfDate: false),
                                    // Identical apart from the flag, so it should run during every build.
                                    TestCustomTask(
                                        commandLine: command,
                                        environment: [:],
                                        workingDirectory: tmpDirPath.str,
                                        executionDescription: "Always Out Of Date Task",
                                        inputs: ["$(SRCROOT)/Sources/input"],
                                        outputs: [output2.str],
                                        enableSandboxing: false,
                                        preparesForIndexing: false,
                                        alwaysOutOfDate: true),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Sources/input")) { stream in stream <<< "" }

            // Check the initial build: both custom tasks should run.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes()
                results.checkTask(.matchRulePattern(["CustomTask", "Analyzed Task", .any])) { _ in }
                results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                results.checkNoTask()
            }

            // Check the incremental build: nothing changed, so only the always-out-of-date task should re-run.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask(.matchRulePattern(["CustomTask", "Analyzed Task", .any]))
                results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                results.checkNoTask()
            }

            // And once more, to confirm the behavior is not limited to the first incremental build.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask(.matchRulePattern(["CustomTask", "Analyzed Task", .any]))
                results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                results.checkNoTask()
            }
        }
    }

    /// Check that a custom task marked `alwaysOutOfDate` re-runs on every build even when it declares
    /// no outputs, in which case it is wired up to a virtual output node.
    @Test(.requireSDKs(.host))
    func alwaysOutOfDateIncrementalBehaviorsWithoutOutputs() async throws {
        let command: [String]
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            let commandShellPath = try #require(getEnvironmentVariable("ComSpec"), "Can't determine path to cmd.exe because the ComSpec environment variable is not set")
            command = [commandShellPath, "/c", "echo"]
        } else {
            command = ["/bin/sh", "-c", "echo"]
        }
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources",
                            children: [
                                TestFile("input")
                            ]
                        ),
                        targets: [
                            TestAggregateTarget(
                                "All",
                                customTasks: [
                                    TestCustomTask(
                                        commandLine: command,
                                        environment: [:],
                                        workingDirectory: tmpDirPath.str,
                                        executionDescription: "Always Out Of Date Task",
                                        inputs: ["$(SRCROOT)/Sources/input"],
                                        outputs: [],
                                        enableSandboxing: false,
                                        preparesForIndexing: false,
                                        alwaysOutOfDate: true),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Sources/input")) { stream in stream <<< "" }

            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes()
                results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                results.checkNoTask()
            }
        }
    }
}
