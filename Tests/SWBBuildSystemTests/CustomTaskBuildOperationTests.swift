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

    /// Returns a command line, appropriate for the host's command shell, which appends a line to
    /// `counter` and, if `output` is given, writes a file there.
    ///
    /// Appending to a counter file lets the tests observe exactly how many times a task really ran,
    /// independently of which tasks the build reported.
    private func appendToCounterCommandLine(hostOS: OperatingSystem, counter: Path, output: Path? = nil) throws -> [String] {
        if hostOS == .windows {
            let commandShellPath = try #require(getEnvironmentVariable("ComSpec"), "Can't determine path to cmd.exe because the ComSpec environment variable is not set")
            var script = "echo ran >> \"\(counter.str)\""
            if let output {
                script += " && echo done > \"\(output.str)\""
            }
            return [commandShellPath, "/c", script]
        } else {
            var script = "echo ran >> '\(counter.str)'"
            if let output {
                script += "; echo done > '\(output.str)'"
            }
            return ["/bin/sh", "-c", script]
        }
    }

    /// Counts the number of times a task recorded by `appendToCounterCommandLine` has run.
    private func executionCount(_ fs: any FSProxy, _ counter: Path) throws -> Int {
        guard fs.exists(counter) else { return 0 }
        return try fs.read(counter).asString.split(whereSeparator: \.isNewline).count
    }

    /// Check that a custom task marked `alwaysOutOfDate` re-runs on every build, while an otherwise
    /// identical custom task which participates in dependency analysis does not.
    @Test(.requireSDKs(.host))
    func alwaysOutOfDateIncrementalBehaviors() async throws {
        let hostOS = try ProcessInfo.processInfo.hostOperatingSystem()
        try await withTemporaryDirectory { tmpDirPath in
            let varDir = tmpDirPath.join("var")

            // Inputs, outputs, and execution counters for the two custom tasks.
            let analyzedInput = varDir.join("analyzed-input")
            let analyzedOutput = varDir.join("analyzed-output")
            let analyzedCounter = varDir.join("analyzed-counter")
            let alwaysInput = varDir.join("always-input")
            let alwaysOutput = varDir.join("always-output")
            let alwaysCounter = varDir.join("always-counter")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        targets: [
                            TestAggregateTarget(
                                "All",
                                customTasks: [
                                    // Participates in dependency analysis, so it should only run when its inputs change.
                                    TestCustomTask(
                                        commandLine: try appendToCounterCommandLine(hostOS: hostOS, counter: analyzedCounter, output: analyzedOutput),
                                        environment: [:],
                                        workingDirectory: tmpDirPath.str,
                                        executionDescription: "Analyzed Task",
                                        inputs: [analyzedInput.str],
                                        outputs: [analyzedOutput.str],
                                        enableSandboxing: false,
                                        preparesForIndexing: false,
                                        alwaysOutOfDate: false),
                                    // Identical apart from the flag, so it should run during every build.
                                    TestCustomTask(
                                        commandLine: try appendToCounterCommandLine(hostOS: hostOS, counter: alwaysCounter, output: alwaysOutput),
                                        environment: [:],
                                        workingDirectory: tmpDirPath.str,
                                        executionDescription: "Always Out Of Date Task",
                                        inputs: [alwaysInput.str],
                                        outputs: [alwaysOutput.str],
                                        enableSandboxing: false,
                                        preparesForIndexing: false,
                                        alwaysOutOfDate: true),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(analyzedInput) { stream in
                stream <<< "analyzed-input"
            }
            try await tester.fs.writeFileContents(alwaysInput) { stream in
                stream <<< "always-input"
            }

            func ranCount(_ counter: Path) throws -> Int {
                try executionCount(tester.fs, counter)
            }

            // Check the initial build: both custom tasks should run.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()
                results.checkTask(.matchRulePattern(["CustomTask", "Analyzed Task", .any])) { _ in }
                results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            #expect(try ranCount(analyzedCounter) == 1)
            #expect(try ranCount(alwaysCounter) == 1)

            // Check the incremental build: nothing changed, so only the always-out-of-date task should re-run.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask(.matchRulePattern(["CustomTask", "Analyzed Task", .any]))
                results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            #expect(try ranCount(analyzedCounter) == 1)
            #expect(try ranCount(alwaysCounter) == 2)

            // And once more, to confirm the behavior is not limited to the first incremental build.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask(.matchRulePattern(["CustomTask", "Analyzed Task", .any]))
                results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            #expect(try ranCount(analyzedCounter) == 1)
            #expect(try ranCount(alwaysCounter) == 3)
        }
    }

    /// Check that a custom task marked `alwaysOutOfDate` re-runs on every build even when it declares
    /// no outputs, in which case it is wired up to a virtual output node.
    @Test(.requireSDKs(.host))
    func alwaysOutOfDateIncrementalBehaviorsWithoutOutputs() async throws {
        let hostOS = try ProcessInfo.processInfo.hostOperatingSystem()
        try await withTemporaryDirectory { tmpDirPath in
            let varDir = tmpDirPath.join("var")
            let input = varDir.join("input")
            let counter = varDir.join("counter")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        targets: [
                            TestAggregateTarget(
                                "All",
                                customTasks: [
                                    TestCustomTask(
                                        commandLine: try appendToCounterCommandLine(hostOS: hostOS, counter: counter),
                                        environment: [:],
                                        workingDirectory: tmpDirPath.str,
                                        executionDescription: "Always Out Of Date Task",
                                        inputs: [input.str],
                                        outputs: [],
                                        enableSandboxing: false,
                                        preparesForIndexing: false,
                                        alwaysOutOfDate: true),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(input) { stream in
                stream <<< "input"
            }

            for expectedExecutionCount in 1...3 {
                try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                    results.consumeTasksMatchingRuleTypes()
                    results.checkTask(.matchRulePattern(["CustomTask", "Always Out Of Date Task", .any])) { _ in }
                    results.checkNoTask()
                    results.checkNoDiagnostics()
                }

                #expect(try executionCount(tester.fs, counter) == expectedExecutionCount)
            }
        }
    }
}
