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

import SWBBuildSystem
import SWBCore
import SWBTestSupport
import SWBTaskExecution
@_spi(Testing) import SWBUtil
import SWBLibc

import class SWBBuildSystem.BuildOperation
import class SWBTaskExecution.Task
import SWBProtocol

private final class MockTaskTypeDescription: TaskTypeDescription {
    init(isUnsafeToInterrupt: Bool = false) {
        self.isUnsafeToInterrupt = isUnsafeToInterrupt
    }
    let payloadType: (any TaskPayload.Type)? = nil
    let isUnsafeToInterrupt: Bool
    var toolBasenameAliases: [String] { return [] }
    func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]? { return nil }
    func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] { return [] }
    func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] { return [] }
    func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] { return [] }
    func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] { return [] }
    func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] { return [] }
    func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? { return nil }
    func interestingPath(for task: any ExecutableTask) -> Path? { return nil }
}

fileprivate extension BuildOperationTester.BuildResults {
    /// Returns a list of all tasks which started running.
    ///
    /// This is intended for use in test variants initialized via a task set rather than a workspace, which is why the extension is limited to this file containing only such tets.
    ///
    /// By default this excludes `Gate` tasks, which are not usually interesting to check in build operation tests.
    func getStartedTasks(excludedTypes: Set<String> = ["Gate"]) -> [Task] {
        return events.compactMap { event in
            if case let .taskHadEvent(task, .started) = event, !excludedTypes.contains(task.ruleInfo[0]) {
                return task
            }
            return nil
        }
    }
}

/// Tests which probe specific features of the high-level build system feature set, by manually constructing custom tasks.
@Suite
fileprivate struct BuildTaskBehaviorTests: CoreBasedTests {
    /// Helper functions for creating PlannedTask/Task pairs.
    private func createTask(type: (any TaskTypeDescription)? = nil, forTarget: ConfiguredTarget? = nil, ruleInfo: [String], additionalSignatureData: String = "", commandLine: [String], additionalOutput: [String] = [], environment: EnvironmentBindings = EnvironmentBindings(), workingDirectory: Path = .root, inputs: [any PlannedNode], outputs: [any PlannedNode], mustPrecede: [any PlannedTask] = [], action: TaskAction?, execDescription: String? = nil, preparesForIndexing: Bool = false) -> ConstructedTask {

        var builder = PlannedTaskBuilder(type: type ?? MockTaskTypeDescription(), ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: commandLine.map{ .literal(ByteString(encodingAsUTF8: $0)) }, additionalOutput: additionalOutput, environment: environment, inputs: inputs, outputs: outputs)
        builder.forTarget = forTarget
        builder.workingDirectory = workingDirectory
        builder.mustPrecede = mustPrecede
        builder.action = action
        builder.execDescription = execDescription
        builder.preparesForIndexing = preparesForIndexing
        let execTask = Task(&builder)
        let constructedTask = ConstructedTask(&builder, execTask: execTask)
        return constructedTask
    }

    private func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, mustPrecede: [any PlannedTask]) -> GateTask {
        var builder = PlannedTaskBuilder(type: GateTask.type, ruleInfo: ["Gate", output.name], commandLine: [], environment: EnvironmentBindings(), inputs: inputs, outputs: [output], mustPrecede: mustPrecede)
        return GateTask(&builder, execTask: Task(&builder))
    }

    // FIXME: We should migrate these tests to primarily only use internal execution nodes, and not end up running tools (except for tests which are explicitly trying to test that behavior).

    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory, .skipHostOS(.windows, "no /bin/echo"))
    func simulatedSingleInputlessOutputlessCommand() async throws {
        let echoTask = createTask(ruleInfo: ["echo", "hi"], commandLine: ["/bin/echo", "hi"], inputs: [], outputs: [MakePlannedVirtualNode("<ECHO>")], action: nil)

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), [echoTask], simulated: true)

        try await tester.checkBuild(runDestination: .host) { results in
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()
            let echoTask = try #require(results.getTask(.matchRule(["echo", "hi"])))
            // Check that our task was started and stopped (in the correct order).
            results.check(event: .taskHadEvent(echoTask, event: .started), precedes: .taskHadEvent(echoTask, event: .completed))
        }
    }

    private func uniqueTaskNamesIncludedInEvents(_ events: [BuildOperationTester.BuildEvent]) -> [String] {
        return Array(Set(events.compactMap {
            switch $0 {
            case .taskHadEvent(let task, _): return task.ruleInfo.first
            default: return nil
            }
        }))
    }

    @Test(.requireSDKs(.host))
    func continueBuildingAfterErrorsOn() async throws {
        let otherOutput = MakePlannedPathNode(Path.root.join("mock"))
        let constructedOtherTask = createTask(ruleInfo: ["mock"], commandLine: ["true"], inputs: [], outputs: [otherOutput], action: MockTaskAction(contents: "", output: otherOutput))

        let failOutput = MakePlannedVirtualNode("<FAIL>")
        let constructedFailingTask = createTask(ruleInfo: ["failing"], commandLine: ["true"], inputs: [], outputs: [failOutput], action: FailingTaskAction(contents: "", output: failOutput))

        let tester = try await BuildOperationTester(getCore(), [constructedFailingTask, constructedOtherTask], simulated: true, continueBuildingAfterErrors: true)

        try await tester.checkBuild(runDestination: .host) { results in
            results.checkError(.prefix("Command failing failed."))
            results.checkNoDiagnostics()
            #expect(uniqueTaskNamesIncludedInEvents(results.events).sorted() == ["failing", "mock"])
            results.checkCapstoneEvents()
        }
    }

    @Test(.requireSDKs(.host))
    func continueBuildingAfterErrorsOff() async throws {
        let otherOutput = MakePlannedPathNode(Path.root.join("mock"))
        let constructedOtherTask = createTask(ruleInfo: ["mock"], commandLine: ["true"], inputs: [], outputs: [otherOutput], action: MockTaskAction(contents: "", output: otherOutput))

        let failOutput = MakePlannedVirtualNode("<FAIL>")
        let constructedFailingTask = createTask(ruleInfo: ["failing"], commandLine: ["true"], inputs: [], outputs: [failOutput], mustPrecede: [constructedOtherTask], action: FailingTaskAction(contents: "", output: failOutput))

        let tester = try await BuildOperationTester(getCore(), [constructedFailingTask, constructedOtherTask], simulated: true, continueBuildingAfterErrors: false)

        try await tester.checkBuild(runDestination: .host) { results in
            results.checkError(.prefix("Command failing failed."))
            results.checkNoDiagnostics()
            #expect(uniqueTaskNamesIncludedInEvents(results.events) == ["failing"])
            results.checkCapstoneEvents()
        }
    }

    /*
     This creates a task set with two tasks:
     - one that waits on the returned semaphore indefinitely
     - a second one that depends on the first one
     */
    private func createBuildOperationTesterForCancellation(temporaryDirectory: NamedTemporaryDirectory? = nil, contents: String = "") async throws -> (tester: BuildOperationTester, taskWaitsForSemaphore: WaitCondition, taskHasStartedSemaphore: WaitCondition) {
        let output = MakePlannedVirtualNode("<WAIT>")
        let waitTaskAction = WaitTaskAction(contents: contents, output: output)

        let constructedWaitTask = createTask(ruleInfo: ["wait"], commandLine: ["true"], inputs: [], outputs: [output], action: waitTaskAction)

        let constructedDependentTask = createTask(ruleInfo: ["dependent"], commandLine: ["true"], inputs: [output], outputs: [MakePlannedVirtualNode("<DEPENDENT>")], action: nil)

        let tester = try await BuildOperationTester(getCore(), [constructedWaitTask, constructedDependentTask], simulated: true, temporaryDirectory: temporaryDirectory)
        return (tester, waitTaskAction.taskWaitsForSemaphore, waitTaskAction.taskHasStartedSemaphore)
    }

    @Test(.requireSDKs(.host))
    func immediateCancellation() async throws {
        let (tester, _, _) = try await createBuildOperationTesterForCancellation()

        try await tester.checkBuild(runDestination: .host, body: { results in
            results.checkCapstoneEvents(last: .buildCancelled)
        }) { operation in
            operation.cancel()
            await operation.build()
        }
    }

    @Test(.requireSDKs(.host), .userDefaults(["EnableBuildBacktraceRecording": "false"]))
    func cancellationAfterStart() async throws {
        let (tester, taskWaitsForSemaphore, taskHasStartedSemaphore) = try await createBuildOperationTesterForCancellation()

        try await tester.checkBuild(runDestination: .host, body: { results in
            results.checkCapstoneEvents(last: .buildCancelled)

            let waitTask = try #require(results.getTask(.matchRule(["wait"])))

            // Check that waiting task did complete
            results.check(event: .taskHadEvent(waitTask, event: .started), precedes: .taskHadEvent(waitTask, event: .completed))

            // Ensure dependent task never ran (as we previously checked for 4 events which weren't involving it)
            #expect(results.events.sorted(by: { String(describing: $0) < String(describing: $1) }) == [
                .buildCancelled,
                .buildReportedPathMap(copiedPathMap: [:], generatedFilesPathMap: [:]),
                .buildStarted,
                .taskHadEvent(waitTask, event: .completed),
                .taskHadEvent(waitTask, event: .started),
                .taskHadEvent(waitTask, event: .exit(.succeeded())),
                .totalProgressChanged(targetName: nil, startedCount: 0, maxCount: 1),
                .totalProgressChanged(targetName: nil, startedCount: 0, maxCount: 2),
                .totalProgressChanged(targetName: nil, startedCount: 1, maxCount: 2),
            ])
        }) { operation in
            _Concurrency.Task<Void, Never> {
                await taskHasStartedSemaphore.wait()
                operation.cancel()
                taskWaitsForSemaphore.signal()
            }
            await operation.build()
        }
    }

    /// Stress concurrent access to the build system cache during rapid cancel
    /// then build scenarios.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "no /usr/bin/true"), .requireThreadSafeWorkingDirectory,
          // To aid in establishing the subtle concurrent
          // timing required to trigger chaos, we disable early build operation
          // cancellation.
          .userDefaults(["SkipEarlyBuildOperationCancellation": "1"])
    )
    func stressConcurrentCancellation() async throws {
        // We want to be sure that build system caching is turned on for this
        // test. This is the default, but an explicit set communicates intent
        // and keeps the test stable if the underlying defaults change.
        let prefs = UserPreferences.defaultForTesting.with(enableBuildDebugging: false, enableBuildSystemCaching: true)

        // Reuse the same temporary directory so that we get cache hits
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) async -> Void in
            // Repeated builds, since concurrency timing varies
            for i in 1...10 {
                let build1Ready = WaitCondition()
                let build2Ready = WaitCondition()
                let startBuilds = WaitCondition()
                let buildsDone = WaitCondition()

                // build1 cancels immediately
                _Concurrency.Task<Void, Never> {
                    do {
                        let (tester, _, _) = try await self.createBuildOperationTesterForCancellation(temporaryDirectory: temporaryDirectory, contents: "")

                        tester.userPreferences = prefs

                        try await tester.checkBuild(runDestination: .host, body: { results in
                            results.checkCapstoneEvents(last: .buildCancelled)
                        }) { operation in
                            build1Ready.signal()
                            await startBuilds.wait()

                            operation.cancel()

                            await operation.build()

                            // This sleep keeps the operation alive for a short
                            // while after the build. Although arguably its own
                            // race condition, it is not the one we are testing
                            // here.
                            try await _Concurrency.Task.sleep(for: .microseconds(10_000))
                        }
                    } catch {
                        Issue.record(error)
                    }
                }

                // Build 2 proceeds normally
                _Concurrency.Task<Void, Never> {
                    do {
                        let (tester, taskWaitsForSemaphore, _) = try await self.createBuildOperationTesterForCancellation(temporaryDirectory: temporaryDirectory, contents: "\(i)")

                        tester.userPreferences = prefs

                        try await tester.checkBuild(runDestination: .host, body: { results in
                            #expect(results.events.first! == .buildStarted)

                            let waitTask = try #require(results.getTask(.matchRule(["wait"])))

                            // Check that waiting task did complete
                            results.check(event: .taskHadEvent(waitTask, event: .started), precedes: .taskHadEvent(waitTask, event: .completed))
                        }) { operation in
                            build2Ready.signal()
                            await startBuilds.wait()
                            _Concurrency.Task<Void, any Error> {
                                defer { taskWaitsForSemaphore.signal() }
                                try await _Concurrency.Task.sleep(for: .microseconds(10))
                            }
                            await operation.build()
                            buildsDone.signal()

                            // This sleep keeps the operation alive for a short
                            // while after the build. Although arguably its own
                            // race condition, it is not the one we are testing
                            // here.
                            try await _Concurrency.Task.sleep(for: .microseconds(10_000))
                        }
                    } catch {
                        Issue.record(error)
                    }
                }

                // Wait for all of the setup to be complete
                await build1Ready.wait()
                await build2Ready.wait()

                // Release the hounds
                startBuilds.signal()
                startBuilds.signal()

                // -- here is where the chaos can happen when the cache entry is unprotected --

                await buildsDone.wait()
            }
        }
    }

    /// Check that we honor specs which are unsafe to interrupt.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "no bash shell"), .requireThreadSafeWorkingDirectory)
    func unsafeToInterrupt() async throws {
        let fs = localFS
        let output = MakePlannedVirtualNode("<WAIT>")

        // Create a temporary directory, for our script.
        try await withTemporaryDirectory(fs: fs) { tmpDirPath in
            let scriptPath = tmpDirPath.join("script-\(#function)")
            let sentinelPath = tmpDirPath.join("sentinel")
            try fs.write(scriptPath, contents: ByteString(encodingAsUTF8:
            """
            #!/bin/bash
            set -e
            echo "note: installing trap..."
            trap "echo \\"note: received SIGINT\\"" SIGINT\n
            echo OK > "\(sentinelPath.str)".tmp
            mv "\(sentinelPath.str)".tmp "\(sentinelPath.str)"
            while true; do sleep 1; done
            echo "note: exited normally"\n
            """))
            try fs.setFilePermissions(scriptPath, permissions: 0o755)

            // Enable fast llbuild cancellation.
            try POSIX.setenv("LLBUILD_TEST", "1", Int32(1))
            defer { try? POSIX.unsetenv("LLBUILD_TEST") }

            let unsafeTask = createTask(type: MockTaskTypeDescription(isUnsafeToInterrupt: true), ruleInfo: ["unsafe-to-interrupt"], commandLine: [scriptPath.str], inputs: [], outputs: [output], action: nil)
            let tester = try await BuildOperationTester(getCore(), [unsafeTask], simulated: false)

            func checkBuildResults(results: BuildOperationTester.BuildResults) throws {
                // Check the build was cancelled.
                results.checkCapstoneEvents(last: .buildCancelled)

                let unsafeTask = try #require(results.getTask(.matchRule(["unsafe-to-interrupt"])))

                // Check the task never saw a SIGINT (by checking its output).
                results.checkTaskOutput(unsafeTask) { taskOutput in
                    #expect(taskOutput.unsafeStringValue == "note: installing trap...\n")
                }
            }
            try await tester.checkBuild(runDestination: .host, body: checkBuildResults) { operation in
                let task = _Concurrency.Task<Void, any Error> {
                    defer {
                        // Cancel the build
                        operation.cancel()
                    }

                    // Wait for the script to write the sentinel file indicating it
                    // is waiting for a signal.
                    while !_Concurrency.Task.isCancelled {
                        if fs.exists(sentinelPath) {
                            #expect(try fs.read(sentinelPath) == "OK\n")
                            break
                        }
                        try await _Concurrency.Task.sleep(for: .microseconds(1))
                    }
                }

                try await withTaskCancellationHandler {
                    switch await operation.build() {
                    case .cancelled, .failed:
                        // If the build already failed, cancel the task that waits for the script so the test doesn't hang forever.
                        task.cancel()
                    case .succeeded:
                        break
                    }
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            }
        }
    }

    /// Check the behavior of gate tasks.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "no /usr/bin/true"), .requireThreadSafeWorkingDirectory)
    func simulatedTasksWithGate() async throws {
        let aNode = MakePlannedVirtualNode("A")
        let bNode = MakePlannedVirtualNode("B")
        let gate = MakePlannedVirtualNode("GATE")
        let gateTask = createGateTask(inputs: [], output: gate, mustPrecede: [])
        let aTask = createTask(ruleInfo: ["A"], commandLine: ["/usr/bin/true"], inputs: [], outputs: [aNode], mustPrecede: [gateTask], action: nil)
        let bTask = createTask(ruleInfo: ["B"], commandLine: ["/usr/bin/true"], inputs: [gate], outputs: [bNode], mustPrecede: [], action: nil)

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), [aTask, bTask, gateTask], simulated: true)

        try await tester.checkBuild(runDestination: .host) { results in
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            let aTask = try #require(results.getTask(.matchRule(["A"])))
            let bTask = try #require(results.getTask(.matchRule(["B"])))

            // Check that A always runs before B.
            results.check(event: .taskHadEvent(aTask, event: .completed), precedes: .taskHadEvent(bTask, event: .started))
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "no /bin/echo"), .requireThreadSafeWorkingDirectory)
    func simulatedDiamondGraph() async throws {
        let tasksToMake = [
            ("START", inputs: ["/INPUT"]),
            ("LEFT", inputs: ["/START"]),
            ("RIGHT", inputs: ["/START"]),
            ("END", inputs: ["/LEFT", "/RIGHT"]),
        ]
        var tasks: [any PlannedTask] = []
        for (name, inputs) in tasksToMake {
            let task = createTask(ruleInfo: [name], commandLine: ["/bin/echo", name], inputs: inputs.map { MakePlannedPathNode(Path("/\($0)")) }, outputs: [MakePlannedPathNode(Path("/\(name)"))], mustPrecede: [], action: nil)
            tasks.append(task)
        }

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)

        // Create the required INPUT node.
        try tester.fs.write(Path("/INPUT"), contents: [])

        try await tester.checkBuild(runDestination: .host) { results in
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            // Check the items in the diamond.
            let startTask = try #require(results.getTask(.matchRule(["START"])))
            let leftTask = try #require(results.getTask(.matchRule(["LEFT"])))
            let rightTask = try #require(results.getTask(.matchRule(["RIGHT"])))
            let endTask = try #require(results.getTask(.matchRule(["END"])))
            results.check(event: .taskHadEvent(startTask, event: .completed), precedes: .taskHadEvent(leftTask, event: .started))
            results.check(event: .taskHadEvent(startTask, event: .completed), precedes: .taskHadEvent(rightTask, event: .started))
            results.check(event: .taskHadEvent(leftTask, event: .completed), precedes: .taskHadEvent(endTask, event: .started))
            results.check(event: .taskHadEvent(rightTask, event: .completed), precedes: .taskHadEvent(endTask, event: .started))
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "no /usr/bin/true"), .requireThreadSafeWorkingDirectory)
    func simulatedMustPrecede() async throws {
        let tasksToMake = ["A", "B", "C", "D"]
        var tasks: [any PlannedTask] = []
        let gateTask = createGateTask(inputs: [], output: MakePlannedVirtualNode("GATE"), mustPrecede: [])
        tasks.append(gateTask)
        for name in tasksToMake {
            let task = createTask(ruleInfo: [name], commandLine: ["/usr/bin/true"], inputs: [], outputs: [MakePlannedVirtualNode(name)], mustPrecede: [gateTask], action: nil)
            tasks.append(task)
        }

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)
        try await tester.checkBuild(runDestination: .host) { results in
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            // Verify the gate was honored.
            //
            // NOTE: This test isn't completely deterministic, it could report a false negative, but in practice this is very unlikely. It should never have a false positive.
            results.checkCapstoneEvents()
            let gateTask = try #require(results.getTask(.matchRule(["Gate", "GATE"])))
            for name in tasksToMake {
                let task = try #require(results.getTask(.matchRule([name])))
                results.check(event: .taskHadEvent(task, event: .completed), precedes: .taskHadEvent(gateTask, event: .started))
            }
        }
    }

    /// Check the handling of a command which mutates an output.
    @Test(.requireSDKs(.host))
    func basicMutatedNode() async throws {
        let testPath = Path.root.join("input.txt")
        let testNode = MakePlannedPathNode(testPath)
        let initialVirtualNode = MakePlannedVirtualNode("<INITIAL>")
        let initialTaskAction = MockTaskAction(contents: "Hello", output: testNode)
        let initialTask = createTask(ruleInfo: ["INITIAL"], commandLine: ["builtin-create-file"], inputs: [], outputs: [testNode, initialVirtualNode], mustPrecede: [], action: initialTaskAction, preparesForIndexing: true)
        let appendVirtualNode = MakePlannedVirtualNode("<APPEND>")
        let appendTask = createTask(ruleInfo: ["APPEND"], commandLine: ["builtin-append-contents"], inputs: [testNode, initialVirtualNode], outputs: [testNode, appendVirtualNode], mustPrecede: [], action: AppendingTaskAction(contents: ", world!", to: testNode))
        let checkNode = MakePlannedVirtualNode("<CHECK>")
        let checkTaskAction = CheckingTaskAction(input: testNode, contents: "Hello, world!")
        // We must have a virtual input on the append task here, as the current mutable strategy does not promote outgoing edges to the mutator.
        let checkTask = createTask(ruleInfo: ["CHECK"], commandLine: ["builtin-check-contents"], inputs: [testNode, appendVirtualNode], outputs: [checkNode], mustPrecede: [], action: checkTaskAction)
        let tasks: [any PlannedTask] = [initialTask, appendTask, checkTask]

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)
        try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            let initialTask = try #require(results.getTask(.matchRule(["INITIAL"])))
            let appendTask = try #require(results.getTask(.matchRule(["APPEND"])))
            let checkTask = try #require(results.getTask(.matchRule(["CHECK"])))

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [initialTask, appendTask, checkTask])

            // Check the file has the expected contents.
            #expect(try results.fs.read(testPath) == ByteString(encodingAsUTF8: "Hello, world!"))
        }

        // Check that we get a null build.
        try await tester.checkNullBuild(runDestination: .host, persistent: true)

        // Update the initial file and rebuild.
        initialTaskAction.contents = "Hello again"
        checkTaskAction.contents = "Hello again, world!"
        try await tester.checkBuild(runDestination: .host, persistent: true) { results in
            let initialTask = try #require(results.getTask(.matchRule(["INITIAL"])))
            let appendTask = try #require(results.getTask(.matchRule(["APPEND"])))
            let checkTask = try #require(results.getTask(.matchRule(["CHECK"])))

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [initialTask, appendTask, checkTask])
        }

        // Update the file and do a prebuild, then check the next build runs the remaining tasks.
        //
        // This checks that downstream tasks of a trigger rerun properly even across separate builds.
        initialTaskAction.contents = "Hello once more"
        checkTaskAction.contents = "Hello once more, world!"
        try await tester.checkBuild(runDestination: .host, buildCommand: .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: false), persistent: true) { results in
            let initialTask = try #require(results.getTask(.matchRule(["INITIAL"])))

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [initialTask])
        }
        try await tester.checkBuild(runDestination: .host, persistent: true) { results in
            let appendTask = try #require(results.getTask(.matchRule(["APPEND"])))
            let checkTask = try #require(results.getTask(.matchRule(["CHECK"])))

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [appendTask, checkTask])
        }

        // Remove the output file and check the build.
        try tester.fs.remove(testPath)
        try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
            let initialTask = try #require(results.getTask(.matchRule(["INITIAL"])))
            let appendTask = try #require(results.getTask(.matchRule(["APPEND"])))
            let checkTask = try #require(results.getTask(.matchRule(["CHECK"])))

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [initialTask, appendTask, checkTask])

            // Check the file has the expected contents.
            #expect(try results.fs.read(testPath) == ByteString(encodingAsUTF8: "Hello once more, world!"))
        }
    }

    /// Check the handling of a node mutated by multiple tasks.
    @Test(.requireSDKs(.host))
    func chainedMutatedInput() async throws {
        let testPath = Path.root.join("input.txt")
        let testNode = MakePlannedPathNode(testPath)
        let initialVirtualNode = MakePlannedVirtualNode("<INITIAL>")

        // We intentionally declare these using mustPrecede to validate those edges are checked for chaining.
        let append1VirtualNode = MakePlannedVirtualNode("<APPEND-1>")
        let append1Task = createTask(ruleInfo: ["APPEND-1"], commandLine: ["builtin-append-contents"], inputs: [testNode], outputs: [testNode, append1VirtualNode], mustPrecede: [], action: AppendingTaskAction(contents: ", world", to: testNode))
        let initialTaskAction = MockTaskAction(contents: "Hello", output: testNode)
        let initialTask = createTask(ruleInfo: ["INITIAL"], commandLine: ["builtin-create-file"], inputs: [], outputs: [testNode, initialVirtualNode], mustPrecede: [append1Task], action: initialTaskAction, preparesForIndexing: true)
        let append2VirtualNode = MakePlannedVirtualNode("<APPEND-2>")
        let append2Task = createTask(ruleInfo: ["APPEND-2"], commandLine: ["builtin-append-contents"], inputs: [testNode, append1VirtualNode], outputs: [testNode, append2VirtualNode], mustPrecede: [], action: AppendingTaskAction(contents: "!", to: testNode))
        let checkNode = MakePlannedVirtualNode("<CHECK>")
        let checkTaskAction = CheckingTaskAction(input: testNode, contents: "Hello, world!")
        // We must have a virtual input on the append task here, as the current mutable strategy does not promote outgoing edges to the mutator.
        let checkTask = createTask(ruleInfo: ["CHECK"], commandLine: ["builtin-check-contents"], inputs: [testNode, append2VirtualNode], outputs: [checkNode], mustPrecede: [], action: checkTaskAction)
        let tasks: [any PlannedTask] = [initialTask, append1Task, append2Task, checkTask]

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)
        try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()
            let initialTask = try #require(results.getTask(.matchRule(["INITIAL"])))
            let append1Task = try #require(results.getTask(.matchRule(["APPEND-1"])))
            let append2Task = try #require(results.getTask(.matchRule(["APPEND-2"])))
            let checkTask = try #require(results.getTask(.matchRule(["CHECK"])))

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [initialTask, append1Task, append2Task, checkTask])

            // Check the file has the expected contents.
            #expect(try results.fs.read(testPath) == ByteString(encodingAsUTF8: "Hello, world!"))
        }

        // Check that we get a null build.
        try await tester.checkNullBuild(runDestination: .host, persistent: true)
    }

    /// Check the diagnostics for malformed tasks.
    @Test(.requireSDKs(.host))
    func chainedMutatedInputErrors() async throws {
        let testPath = Path.root.join("input.txt")
        let testNode = MakePlannedPathNode(testPath)
        let initialTaskAction = MockTaskAction(contents: "Hello", output: testNode)
        let initialTask = createTask(ruleInfo: ["INITIAL"], commandLine: ["builtin-create-file"], inputs: [], outputs: [testNode], mustPrecede: [], action: initialTaskAction, preparesForIndexing: true)
        let append1Task = createTask(ruleInfo: ["APPEND-1"], commandLine: ["builtin-append-contents"], inputs: [testNode], outputs: [testNode], mustPrecede: [], action: AppendingTaskAction(contents: ", world", to: testNode))
        let append2Task = createTask(ruleInfo: ["APPEND-2"], commandLine: ["builtin-append-contents"], inputs: [testNode], outputs: [testNode], mustPrecede: [], action: AppendingTaskAction(contents: "!", to: testNode))
        let tasks: [any PlannedTask] = [initialTask, append1Task, append2Task]

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)
        try await tester.checkBuild(runDestination: .host, persistent: true) { results in
            results.checkWarning(.contains("unexpected mutating task ('APPEND-1') with no relation to prior mutator ('INITIAL')"))
            results.checkWarning(.contains("unexpected mutating task ('APPEND-2') with no relation to prior mutator ('APPEND-1')"))
            results.checkError(.contains("invalid task ('APPEND-2') with mutable output but no other virtual output node"))
            results.checkNoDiagnostics()
        }
    }

    /// Check the handling of a task which mutates multiple nodes.
    @Test(.requireSDKs(.host))
    func multipleMutatedNodes() async throws {
        let testAPath = Path.root.join("input-a.txt")
        let testANode = MakePlannedPathNode(testAPath)
        let testBPath = Path.root.join("input-b.txt")
        let testBNode = MakePlannedPathNode(testBPath)

        // Create the input files.
        let initialAVirtualNode = MakePlannedVirtualNode("<INITIAL-A>")
        let initialATaskAction = MockTaskAction(contents: "Hello", output: testANode)
        let initialATask = createTask(ruleInfo: ["INITIAL-A"], commandLine: ["builtin-create-file"], inputs: [], outputs: [testANode, initialAVirtualNode], mustPrecede: [], action: initialATaskAction, preparesForIndexing: true)
        let initialBVirtualNode = MakePlannedVirtualNode("<INITIAL-B>")
        let initialBTaskAction = MockTaskAction(contents: "Hi", output: testBNode)
        let initialBTask = createTask(ruleInfo: ["INITIAL-B"], commandLine: ["builtin-create-file"], inputs: [initialAVirtualNode], outputs: [testBNode, initialBVirtualNode], mustPrecede: [], action: initialBTaskAction, preparesForIndexing: true)

        // Create the mutator.
        let appendVirtualNode = MakePlannedVirtualNode("<APPEND-MULTI>")
        let appendTask = createTask(ruleInfo: ["APPEND-MULTI"], commandLine: ["builtin-append-contents"], inputs: [testANode, testBNode, initialAVirtualNode, initialBVirtualNode], outputs: [testANode, testBNode, appendVirtualNode], mustPrecede: [], action: AppendingTaskAction(contents: ", world!", to: [testANode, testBNode]))

        // Create tasks to check the output.
        let checkANode = MakePlannedVirtualNode("<CHECK-A>")
        let checkATaskAction = CheckingTaskAction(input: testANode, contents: "Hello, world!")
        let checkBNode = MakePlannedVirtualNode("<CHECK-B>")
        let checkBTaskAction = CheckingTaskAction(input: testBNode, contents: "Hi, world!")
        // We must have a virtual input on the append task here, as the current mutable strategy does not promote outgoing edges to the mutator.
        let checkATask = createTask(ruleInfo: ["CHECK-A"], commandLine: ["builtin-check-contents"], inputs: [testANode, appendVirtualNode], outputs: [checkANode], mustPrecede: [], action: checkATaskAction)
        let checkBTask = createTask(ruleInfo: ["CHECK-B"], commandLine: ["builtin-check-contents"], inputs: [testBNode, appendVirtualNode, checkANode], outputs: [checkBNode], mustPrecede: [], action: checkBTaskAction)
        let tasks: [any PlannedTask] = [initialATask, initialBTask, appendTask, checkATask, checkBTask]

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)
        try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
            let initialATask = try #require(results.getTask(.matchRule(["INITIAL-A"])))
            let initialBTask = try #require(results.getTask(.matchRule(["INITIAL-B"])))
            let appendTask = try #require(results.getTask(.matchRule(["APPEND-MULTI"])))
            let checkATask = try #require(results.getTask(.matchRule(["CHECK-A"])))
            let checkBTask = try #require(results.getTask(.matchRule(["CHECK-B"])))

            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [initialATask, initialBTask, appendTask, checkATask, checkBTask])

            // Check the file has the expected contents.
            #expect(try results.fs.read(testAPath) == ByteString(encodingAsUTF8: "Hello, world!"))
            #expect(try results.fs.read(testBPath) == ByteString(encodingAsUTF8: "Hi, world!"))
        }

        // Check that we get a null build.
        try await tester.checkNullBuild(runDestination: .host, persistent: true)
    }

    /// Check that we properly sort a complex sequence of mutating tasks.
    @Test(.requireSDKs(.host))
    func complexMutatingSequence() async throws {
        let testPath = Path.root.join("input.txt")
        let testNode = MakePlannedPathNode(testPath)
        let initialVirtualNode = MakePlannedVirtualNode("<INITIAL>")

        // We intentionally declare these using mustPrecede to validate those edges are checked for chaining.
        let initialTaskAction = MockTaskAction(contents: "Hello", output: testNode)
        let initialTask = createTask(ruleInfo: ["INITIAL"], commandLine: ["builtin-create-file"], inputs: [], outputs: [testNode, initialVirtualNode], mustPrecede: [], action: initialTaskAction, preparesForIndexing: true)
        let append1VirtualNode = MakePlannedVirtualNode("<APPEND-1>")
        let append1Task = createTask(ruleInfo: ["APPEND-1"], commandLine: ["builtin-append-contents"], inputs: [testNode, initialVirtualNode], outputs: [testNode, append1VirtualNode], mustPrecede: [], action: AppendingTaskAction(contents: ", ", to: testNode))
        let append2VirtualNode = MakePlannedVirtualNode("<APPEND-2>")
        let append2Task = createTask(ruleInfo: ["APPEND-2"], commandLine: ["builtin-append-contents"], inputs: [testNode, append1VirtualNode], outputs: [testNode, append2VirtualNode], mustPrecede: [], action: AppendingTaskAction(contents: "world", to: testNode))
        let append3VirtualNode = MakePlannedVirtualNode("<APPEND-3>")
        let append3Task = createTask(ruleInfo: ["APPEND-3"], commandLine: ["builtin-append-contents"], inputs: [testNode, initialVirtualNode, append2VirtualNode], outputs: [testNode, append3VirtualNode], mustPrecede: [], action: AppendingTaskAction(contents: "!", to: testNode))
        let checkNode = MakePlannedVirtualNode("<CHECK>")
        let checkTaskAction = CheckingTaskAction(input: testNode, contents: "Hello, world!")
        // We must have a virtual input on the append task here, as the current mutable strategy does not promote outgoing edges to the mutator.
        let checkTask = createTask(ruleInfo: ["CHECK"], commandLine: ["builtin-check-contents"], inputs: [testNode, append3VirtualNode], outputs: [checkNode], mustPrecede: [], action: checkTaskAction)
        let tasks: [any PlannedTask] = [initialTask, append1Task, append2Task, append3Task, checkTask]

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)
        try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
            let initialTask = try #require(results.getTask(.matchRule(["INITIAL"])))
            let append1Task = try #require(results.getTask(.matchRule(["APPEND-1"])))
            let append2Task = try #require(results.getTask(.matchRule(["APPEND-2"])))
            let append3Task = try #require(results.getTask(.matchRule(["APPEND-3"])))
            let checkTask = try #require(results.getTask(.matchRule(["CHECK"])))
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            // Check that the expected tasks ran.
            let startedTasks = results.getStartedTasks()
            #expect(startedTasks == [initialTask, append1Task, append2Task, append3Task, checkTask])

            // Check the file has the expected contents.
            #expect(try results.fs.read(testPath) == ByteString(encodingAsUTF8: "Hello, world!"))
        }

        // Check that we get a null build.
        try await tester.checkNullBuild(runDestination: .host, persistent: true)
    }

    /// Check the stability of input ordering for a command which has multiple mutated inputs.
    @Test(.requireSDKs(.host))
    func mutatedInputOrderingStability() async throws {
        let N = 10
        let files = (0 ..< N).map { i in
            return MakePlannedPathNode(Path("/input-\(i).txt"))
        }
        let inputTasks = files.enumerated().map { (i, file) in
            return createTask(ruleInfo: ["create-\(i)"], commandLine: ["n"],
                              inputs: [], outputs: [file], mustPrecede: [],
                              action: MockTaskAction(contents: "create-\(i)", output: file), preparesForIndexing: true)
        }
        let merged = MakePlannedPathNode(Path("/merged.txt"))
        let mergedTask = createTask(ruleInfo: ["merge"], commandLine: ["n"],
                                    inputs: files, outputs: files, mustPrecede: [],
                                    action: MockTaskAction(contents: "merge", output: merged), preparesForIndexing: true)
        let tasks = inputTasks + [mergedTask]

        // Check for stability by comparing two manifests.
        let tester = try await BuildOperationTester(getCore(), tasks, simulated: true)
        try await tester.checkBuildDescription(runDestination: .host) { results in
            let manifest1Contents = try tester.fs.read(results.buildDescription.manifestPath).bytes
            try await tester.checkBuildDescription(runDestination: .host) { results in
                let manifest2Contents = try tester.fs.read(results.buildDescription.manifestPath).bytes
                #expect(String(decoding: manifest1Contents, as: Unicode.UTF8.self) == String(decoding: manifest2Contents, as: Unicode.UTF8.self))
            }
        }
    }

    /// Check the execution of internal (non-process based) commands.
    @Test(.requireSDKs(.host))
    func simulatedInternalCommand() async throws {
        let outputPath = Path.root.join("output.txt")
        let outputNode = MakePlannedPathNode(outputPath)
        let action = MockTaskAction(contents: "Hello, world!", output: outputNode)
        let task = createTask(ruleInfo: ["MOCK"], commandLine: ["builtin-mock"], inputs: [], outputs: [outputNode], mustPrecede: [], action: action)

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), [task], simulated: true)

        try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
            let task = try #require(results.getTask(.matchRule(["MOCK"])))
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            // Check the task ran.
            #expect(try results.fs.read(outputPath) == ByteString(encodingAsUTF8: "Hello, world!"))

            // Check the task events, which should have a strong order.
            let taskEvents = results.events.filter {
                if case .taskHadEvent = $0 {
                    return true
                } else {
                    return false
                }
            }
            #expect(taskEvents == [
                .taskHadEvent(task, event: .started),
                .taskHadEvent(task, event: .exit(.succeeded(metrics: nil))),
                .taskHadEvent(task, event: .completed)])
        }

        // Check that we get a null build.
        try await tester.checkNullBuild(runDestination: .host, persistent: true)

        // Change the mock task internal data, and verify the build updates properly.
        action.contents = "Hello, incremental world!"
        try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
            // Check the data was updated.
            #expect(try results.fs.read(outputPath) == ByteString(encodingAsUTF8: "Hello, incremental world!"))
        }
    }

    /// Check the simulated incremental build of an actual task action.
    ///
    /// This checks that we compute the signature on the internal action appropriately so that it rebuilds only when appropriate.
    @Test(.requireSDKs(.host))
    func simulatedAuxiliaryFileWrite() async throws {
        let outputPath = Path.root.join("output.txt")
        let outputNode = MakePlannedPathNode(outputPath)

        // We *must* use a shared output directory and file system for these tests to behave as intended.
        try await withTemporaryDirectory { tmpDir in
            let fs = PseudoFS()
            try fs.createDirectory(tmpDir.path, recursive: true)
            try fs.write(tmpDir.path.join("foo"), contents: "Hello, world!")

            do {
                let action = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: outputPath, input: tmpDir.path.join("foo"), permissions: nil, forceWrite: false, diagnostics: [], logContents: false))
                let task = createTask(ruleInfo: ["MOCK"], commandLine: ["builtin-mock"], inputs: [], outputs: [outputNode], mustPrecede: [], action: action)

                // Execute a test build against the task set.
                let tester = try await BuildOperationTester(getCore(), [task], simulated: true, temporaryDirectory: tmpDir, fileSystem: fs)
                try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
                    // Check the task ran.
                    let task = try #require(results.getTask(.matchRule(["MOCK"])))
                    #expect(results.getStartedTasks() == [task])
                    #expect(try results.fs.read(outputPath) == ByteString(encodingAsUTF8: "Hello, world!"))
                }
            }

            // Perform a build with a new, identical task set, and check for a null build.
            do {
                let action = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: outputPath, input: tmpDir.path.join("foo"), permissions: nil, forceWrite: false, diagnostics: [], logContents: false))
                let task = createTask(ruleInfo: ["MOCK"], commandLine: ["builtin-mock"], inputs: [], outputs: [outputNode], mustPrecede: [], action: action)

                // Execute a test build against the task set.
                let tester = try await BuildOperationTester(getCore(), [task], simulated: true, temporaryDirectory: tmpDir, fileSystem: fs)
                try await tester.checkNullBuild(runDestination: .host, persistent: true)
            }

            // Perform a build with a changed task.
            do {
                try fs.write(tmpDir.path.join("bar"), contents: "Hello, alternate world!")
                let action = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: outputPath, input: tmpDir.path.join("bar"), permissions: nil, forceWrite: false, diagnostics: [], logContents: false))
                let task = createTask(ruleInfo: ["MOCK"], commandLine: ["builtin-mock"], inputs: [], outputs: [outputNode], mustPrecede: [], action: action)

                // Execute a test build against the task set.
                let tester = try await BuildOperationTester(getCore(), [task], simulated: true, temporaryDirectory: tmpDir, fileSystem: fs)
                try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
                    let task = try #require(results.getTask(.matchRule(["MOCK"])))
                    #expect(results.getStartedTasks() == [task])
                    #expect(try results.fs.read(outputPath) == ByteString(encodingAsUTF8: "Hello, alternate world!"))
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func auxiliaryFileDiagnostics() async throws {
        let outputPath = Path.root.join("output.txt")
        let outputNode = MakePlannedPathNode(outputPath)

        try await withTemporaryDirectory { tmpDir in
            let fs = PseudoFS()
            try fs.createDirectory(tmpDir.path, recursive: true)
            try fs.write(tmpDir.path.join("foo"), contents: "Hello, world!")

            do {
                let context = AuxiliaryFileTaskActionContext(output: outputPath, input: tmpDir.path.join("foo"), permissions: nil, forceWrite: false, diagnostics: [.init(kind: .error, message: "Couldn't deal with this for some reason")], logContents: false)
                let action = AuxiliaryFileTaskAction(context)
                let task = createTask(ruleInfo: ["MOCK"], commandLine: ["builtin-mock"], inputs: [], outputs: [outputNode], mustPrecede: [], action: action)

                // Execute a test build against the task set.
                let tester = try await BuildOperationTester(getCore(), [task], simulated: true, temporaryDirectory: tmpDir, fileSystem: fs)
                try await tester.checkBuild(runDestination: .host, persistent: true) { results throws in
                    // Check the task ran.
                    let task = try #require(results.getTask(.matchRule(["MOCK"])))
                    #expect(results.getStartedTasks() == [task])
                    results.checkError(.equal("Couldn't deal with this for some reason (for task: [\"MOCK\"])"))
                    results.checkNoDiagnostics()
                    #expect(try fs.read(outputPath) == ByteString(encodingAsUTF8: "Hello, world!"))
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func mkdir() async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs = localFS
            let outputPath = tmpDir.path.join("input")

            let task = createTask(
                ruleInfo: ["MkDir", outputPath.str],
                commandLine: [],
                inputs: [],
                outputs: [MakePlannedDirectoryTreeNode(outputPath)],
                mustPrecede: [],
                action: nil)

            let tester = try await BuildOperationTester(getCore(), [task], simulated: false, temporaryDirectory: tmpDir, fileSystem: fs)

            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                let task = try #require(results.getTask(.matchRule(["MkDir", outputPath.str])))
                results.check(contains: .taskHadEvent(task, event: .exit(.succeeded(metrics: nil))))
            }
        }
    }

    /// Check the handling of directory tree nodes.
    @Test(.skipHostOS(.windows, "no /usr/bin/find"), .requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func directoryTreeInputs() async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs = localFS
            let inputPath = tmpDir.path.join("input")

            // Create the input directory.
            try fs.createDirectory(inputPath)
            let subdirPath = inputPath.join("subdir")
            try fs.createDirectory(subdirPath)
            try fs.write(subdirPath.join("a.txt"), contents: "a")

            let task = createTask(ruleInfo: ["CheckDir"], commandLine: ["/usr/bin/find", inputPath.str], inputs: [MakePlannedDirectoryTreeNode(inputPath)], outputs: [MakePlannedVirtualNode("<CHECK-DIR>")], mustPrecede: [], action: nil)
            let tester = try await BuildOperationTester(getCore(), [task], simulated: false, temporaryDirectory: tmpDir, fileSystem: fs)

            // Perform the initial build.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                // Check the task ran.
                let task = try #require(results.getTask(.matchRule(["CheckDir"])))
                #expect(results.getStartedTasks() == [task])

                // Check the output.
                results.checkTaskOutput(task) { output in
                    let lines = output.asString.split(separator: "\n").map(String.init).sorted()
                    XCTAssertMatch(lines, [
                        .suffix("/input"),
                        .suffix("/input/subdir"),
                        .suffix("/input/subdir/a.txt")])
                }
            }

            // Mutate the filesystem and rerun the test.
            try fs.write(subdirPath.join("b.txt"), contents: "b")
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                // Check the task ran.
                let task = try #require(results.getTask(.matchRule(["CheckDir"])))
                #expect(results.getStartedTasks() == [task])

                // Check the output.
                results.checkTaskOutput(task) { output in
                    let lines = output.asString.split(separator: "\n").map(String.init).sorted()
                    XCTAssertMatch(lines, [
                        .suffix("/input"),
                        .suffix("/input/subdir"),
                        .suffix("/input/subdir/a.txt"),
                        .suffix("/input/subdir/b.txt")])
                }
            }
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "no /bin/echo"), .requireThreadSafeWorkingDirectory)
    func additionalInfoOutput() async throws {
        let echoTask = createTask(ruleInfo: ["echo", "additional-output"], commandLine: ["/bin/echo", "additional-output"], additionalOutput: ["just some extra output"], inputs: [], outputs: [MakePlannedVirtualNode("<ECHO>")], action: nil)

        // Execute a test build against the task set.
        let tester = try await BuildOperationTester(getCore(), [echoTask], simulated: true)

        try await tester.checkBuild(runDestination: .host) { results in
            // Check that the delegate was passed build started and build ended events in the right place.
            results.checkCapstoneEvents()

            results.checkTask(.matchRuleType("echo")) { task in
                #expect(task.additionalOutput == ["just some extra output"])
            }
        }
    }
}

private class MockTaskAction: TaskAction {
    var contents: String
    let output: any PlannedNode

    init(contents: String, output: any PlannedNode) {
        self.contents = contents
        self.output = output
        super.init()
    }

    override class var toolIdentifier: String {
        return "mock-task"
    }

    override func computeInitialSignature() -> ByteString {
        return ByteString(encodingAsUTF8: contents)
    }

    /// Override base implementation, which expects signature to be constant for lifetime of the object.
    override func getSignature(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate) -> ByteString {
        return computeInitialSignature()
    }

    override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        do {
            try executionDelegate.fs.write(output.path, contents: ByteString(encodingAsUTF8: contents))
            outputDelegate.updateResult(.succeeded(metrics: nil))
            return .succeeded
        } catch {
            outputDelegate.emitError("unable to write output `\(output.path.str)`")
            outputDelegate.updateResult(.exit(exitStatus: .exit(EXIT_FAILURE), metrics: nil))
            return .failed
        }
    }

    public override func serialize<T: Serializer>(to serializer: T) { fatalError("not used") }
    public required init(from deserializer: any Deserializer) throws { fatalError("not used") }
}

/// A custom task which will append data to an existing file.
private final class AppendingTaskAction: TaskAction {
    let contents: String
    let inputs: [any PlannedNode]

    convenience init(contents: String, to input: any PlannedNode) {
        self.init(contents: contents, to: [input])
    }

    init(contents: String, to inputs: [any PlannedNode]) {
        self.contents = contents
        self.inputs = inputs
        super.init()
    }

    override class var toolIdentifier: String {
        return "appending-task"
    }

    override func computeInitialSignature() -> ByteString {
        return ByteString(encodingAsUTF8: contents + inputs.map{ $0.path.str }.joined(separator: " "))
    }

    override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        for input in inputs {
            do {
                let existingContents = try executionDelegate.fs.read(input.path).asString
                do {
                    try executionDelegate.fs.write(input.path, contents: ByteString(encodingAsUTF8: existingContents + contents))
                } catch {
                    outputDelegate.emitError("unable to write output `\(input.path.str)`: \(error)")
                    return .failed
                }
            } catch {
                outputDelegate.emitError("unable to read input `\(input.path.str)`: \(error)")
                return .failed
            }
        }
        return .succeeded
    }

    public override func serialize<T: Serializer>(to serializer: T) { fatalError("not used") }
    public required init(from deserializer: any Deserializer) throws { fatalError("not used") }
}

/// A custom task which checks that a file has some expected content.
private final class CheckingTaskAction: TaskAction {
    let input: any PlannedNode
    var contents: String

    init(input: any PlannedNode, contents: String) {
        self.input = input
        self.contents = contents
        super.init()
    }

    override class var toolIdentifier: String {
        return "checking-task"
    }

    override func computeInitialSignature() -> ByteString {
        return ByteString(encodingAsUTF8: contents + input.path.str)
    }

    override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        do {
            let existingContents = try executionDelegate.fs.read(input.path).asString
            if existingContents != contents {
                outputDelegate.emitError("unexpected contents mismatch (\(existingContents)) vs \(contents))")
                return .failed
            }
        } catch {
            outputDelegate.emitError("unable to read input `\(input.path.str)`: \(error)")
            return .failed
        }
        return .succeeded
    }

    public override func serialize<T: Serializer>(to serializer: T) { fatalError("not used") }
    public required init(from deserializer: any Deserializer) throws { fatalError("not used") }
}

private final class WaitTaskAction: MockTaskAction {
    let taskHasStartedSemaphore = WaitCondition()
    let taskWaitsForSemaphore = WaitCondition()

    override class var toolIdentifier: String {
        return "wait-task"
    }

    override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        taskHasStartedSemaphore.signal()
        await taskWaitsForSemaphore.wait()
        outputDelegate.updateResult(.succeeded(metrics: nil))
        return .succeeded
    }
}

private final class FailingTaskAction: MockTaskAction {
    override class var toolIdentifier: String {
        return "failing-task"
    }

    override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        return .failed
    }
}
