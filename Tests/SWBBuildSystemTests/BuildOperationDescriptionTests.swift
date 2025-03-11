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

import SWBUtil
import SWBCore
import SWBTestSupport
import SWBTaskExecution

/// Tests for how the build operation interacts with the build description objects.
@Suite
fileprivate struct BuildOperationDescriptionTests: CoreBasedTests {
    private func compareTasks(_ oldTask: Task, _ newTask: Task, tasksShouldBeTheSameObject: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        if tasksShouldBeTheSameObject {
            #expect(oldTask === newTask, "restored-from-cache task is not the same as the constructed task, but should be: \(newTask)", sourceLocation: sourceLocation)
            return
        } else {
            guard oldTask !== newTask else {
                Issue.record("restored-from-cache task is the same as the constructed task, but should be a different instance: \(newTask)", sourceLocation: sourceLocation)
                return
            }
        }

        // Compare the old and new tasks.
        #expect(oldTask.ruleInfo == newTask.ruleInfo)
        let ruleInfo = oldTask.ruleInfo.joined(separator: " ")
        #expect(oldTask.commandLine == newTask.commandLine)
        #expect(oldTask.environment == newTask.environment)
        if oldTask.action == nil {
            #expect(newTask.action == nil, "task actions differ for restored Task '\(ruleInfo)': should be nil, but is \(type(of: oldTask.action))", sourceLocation: sourceLocation)
        } else {
            #expect(type(of: oldTask.action) == type(of: newTask.action), "task actions differ for Task '\(ruleInfo)': should be \(type(of: oldTask.action)), but is \(type(of: oldTask.action))", sourceLocation: sourceLocation)
        }
        #expect(oldTask.forTarget == newTask.forTarget)
        #expect(oldTask.execDescription == newTask.execDescription)
        if oldTask.type === GateTask.type || newTask.type === GateTask.type {
            #expect(oldTask.type === GateTask.type && newTask.type === GateTask.type)
        } else {
            let oldTaskType = try #require(oldTask.type as? CommandLineToolSpec)
            let newTaskType = try #require(newTask.type as? CommandLineToolSpec)
            #expect(oldTaskType == newTaskType, "taskTypes differ for restored Task '\(ruleInfo)': \(String(describing: oldTask.type)) is not equal to \(String(describing: newTask.type))", sourceLocation: sourceLocation)
        }
    }

    private func compareRunTasks(_ oldTask: Task, _ newTask: Task, tasksShouldBeTheSameObject: Bool, _ newResults: BuildOperationTester.BuildResults, sourceLocation: SourceLocation = #_sourceLocation) throws {
        // Compare the old and new tasks.
        try compareTasks(oldTask, newTask, tasksShouldBeTheSameObject: tasksShouldBeTheSameObject, sourceLocation: sourceLocation)

        // Make sure the new tasks ran.
        newResults.check(event: .taskHadEvent(newTask, event: .started), precedes: .taskHadEvent(newTask, event: .completed))
    }

    private func getTestWorkspace(in tmpDir: Path) async throws -> TestWorkspace {
        let swiftVersion = try await self.swiftVersion
        return TestWorkspace(
            "Test",
            sourceRoot: tmpDir.join("Test"),
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources", children: [
                            // Application sources
                            TestFile("main.c"),
                            TestFile("Info-Foo.plist"),

                            // Framework sources
                            TestFile("Bar.h"),
                            TestFile("Bar.m"),
                            TestFile("Baz.h"),
                            TestFile("Baz.m"),
                            TestFile("Quux.swift"),
                            TestFile("Crux.swift"),
                            TestFile("Info-Bar.plist"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "VERSIONING_SYSTEM": "apple-generic",
                            "CURRENT_PROJECT_VERSION": "3.1",
                            "ENABLE_SDK_IMPORTS": "NO",
                        ]
                    )],
                    targets: [
                        TestStandardTarget(
                            "Foo", type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "INFOPLIST_FILE": "Info-Foo.plist",
                                        "SWIFT_VERSION": swiftVersion,
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestHeadersBuildPhase([]),
                                TestSourcesBuildPhase(["main.c"]),
                                TestFrameworksBuildPhase(["Bar.framework"]),
                                TestCopyFilesBuildPhase(["Bar.framework"], destinationSubfolder: .frameworks, onlyForDeployment: false),
                            ],
                            dependencies: ["Bar"]
                        ),
                        TestStandardTarget(
                            "Bar", type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "INFOPLIST_FILE": "Info-Bar.plist",
                                        "DEFINES_MODULE": "YES",
                                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                                        "CLANG_ENABLE_MODULES": "YES",
                                        "SWIFT_VERSION": swiftVersion,
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestHeadersBuildPhase([
                                    TestBuildFile("Bar.h", headerVisibility: .public),
                                    TestBuildFile("Baz.h", headerVisibility: .public),
                                ]),
                                TestSourcesBuildPhase(["Bar.m", "Baz.m", "Quux.swift", "Crux.swift"]),
                                TestFrameworksBuildPhase([]),
                            ]),
                    ])
            ])
    }

    /// Generate a `BuildDescription` from our test workspace, build it, and check results.  Then try doing it again to make sure we can use the results loaded from the on-disk cache.
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func onDiskBuildDescriptionCache() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await getTestWorkspace(in: tmpDirPath)

            // Don't use an in-memory cache since we are testing deserializing build descriptions from disk.
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, buildDescriptionMaxCacheSize: (inMemory: 0, onDisk: 2))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info-Foo.plist"), .plDict(["key": .plString("value")]))
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Bar.h"))  { $0 <<< "#include \"Baz.h\"\n" }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Bar.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Baz.h"))  { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Baz.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Quux.swift")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Crux.swift")) { _ in }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info-Bar.plist"), .plDict(["key": .plString("value")]))

            // Create a new build description, build from it, and check results.
            let firstDesc = try await tester.checkBuild(runDestination: .macOS) { results in
                let firstDesc = results.buildDescription

                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .new)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 0)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 1)

                // Make sure the description's files exist on disk.
                #expect(tester.fs.exists(firstDesc.packagePath))
                #expect(tester.fs.exists(firstDesc.manifestPath))
                #expect(tester.fs.exists(firstDesc.serializedBuildDescriptionPath))

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // FIXME: We should be running swift-stdlib-tool for the app here, since the framework contains Swift, but presently it breaks due to <rdar://problem/28343103> [Swift Build] Build failure when building a Swift app (swift-stdlib-tool issue?)

                // Do some checking of the results to make sure we got the commands we expect.
                #expect(results.checkTasks(.matchRuleType("MkDir")) { $0 }.count == 9)
                #expect(results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { $0 }.count == 31)
                #expect(results.checkTasks(.matchRuleType("SymLink")) { $0 }.count == 6)
                #expect(results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("CompileC")) { $0 }.count == 5)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver Compilation Requirements")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftCompile")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("SwiftEmitModule")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftMergeGeneratedHeaders")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("Ld")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("CpHeader")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("Copy")) { $0 }.count == 6)
                #expect(results.checkTasks(.matchRuleType("Touch")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { $0 }.count == 1)

                return firstDesc
            }

            // Build again with different overrides, to make sure we build a new set of tasks.
            let secondParameters = BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "$(inherited) -DFOO"])
            let secondBuildRequest = BuildRequest(parameters: secondParameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: secondParameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let secondDesc = try await tester.checkBuild(parameters: secondParameters, runDestination: .macOS, buildRequest: secondBuildRequest) { results in
                let secondDesc = results.buildDescription

                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .new)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 0)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 2)

                // Make sure the files for both descriptions exist on disk.
                #expect(tester.fs.exists(firstDesc.packagePath))
                #expect(tester.fs.exists(firstDesc.manifestPath))
                #expect(tester.fs.exists(firstDesc.serializedBuildDescriptionPath))
                #expect(tester.fs.exists(secondDesc.packagePath))
                #expect(tester.fs.exists(secondDesc.manifestPath))
                #expect(tester.fs.exists(secondDesc.serializedBuildDescriptionPath))

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Compare the tasks and make sure the cached tasks ran.
                let newDesc = results.buildDescriptionInfo.buildDescription
                #expect(firstDesc.tasks.count == newDesc.tasks.count)
                for task in newDesc.tasks {
                    results.check(event: .taskHadEvent(task, event: .started), precedes: .taskHadEvent(task, event: .completed))
                }

                return secondDesc
            }

            // Build again using the cached build description, and check results.
            let thirdDesc = try await tester.checkBuild(runDestination: .macOS) { results in
                var thirdDesc = results.buildDescription

                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .onDiskCache)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 0)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 2)

                // Make sure the files for "all" descriptions exist on disk.  (The first and third descriptions should be identical, but we can't directly confirm that; instead we compare that they did the same work below.)
                #expect(tester.fs.exists(firstDesc.manifestPath))
                #expect(tester.fs.exists(firstDesc.serializedBuildDescriptionPath))
                #expect(tester.fs.exists(secondDesc.manifestPath))
                #expect(tester.fs.exists(secondDesc.serializedBuildDescriptionPath))
                #expect(tester.fs.exists(thirdDesc.manifestPath))
                #expect(tester.fs.exists(thirdDesc.serializedBuildDescriptionPath))
                #expect(firstDesc.serializedBuildDescriptionPath == thirdDesc.serializedBuildDescriptionPath)
                #expect(firstDesc.manifestPath == thirdDesc.manifestPath)

                // Check that its signature is the same as the first one above (since we restored it from the cache), but different from the second one above.
                thirdDesc = results.buildDescription
                #expect(thirdDesc.signature == firstDesc.signature)
                #expect(thirdDesc.signature != secondDesc.signature)

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Compare the tasks and make sure the cached tasks ran.
                #expect(firstDesc.tasks.count == thirdDesc.tasks.count)
                if firstDesc.tasks.count == thirdDesc.tasks.count {
                    for i in 0..<firstDesc.tasks.count {
                        try compareRunTasks(firstDesc.tasks[i], thirdDesc.tasks[i], tasksShouldBeTheSameObject: false, results)
                    }
                }

                // Compare the task action maps.
                #expect(firstDesc.taskActionMap.count == thirdDesc.taskActionMap.count)
                if firstDesc.taskActionMap.count == thirdDesc.taskActionMap.count {
                    for (tool, oldAction) in firstDesc.taskActionMap {
                        if let newAction = thirdDesc.taskActionMap[tool] {
                            #expect(oldAction == newAction)
                        } else {
                            Issue.record("new description's taskActionMap does not have a TaskAction for tool: \(tool)")
                        }
                    }
                }

                // TODO: Compare errors and warnings.

                // Make sure there were only 2 configured targets deserialized among all the tasks, and that all of the configured targets in the build request are contained in the deserialized description.
                var targets = Set<ConfiguredTarget>()
                var targetRefs = Set<Ref<ConfiguredTarget>>()
                for task in thirdDesc.tasks {
                    if let target = task.forTarget, !task.isGate {
                        targets.insert(target)
                        targetRefs.insert(Ref(target))
                    }
                }
                // This check uses Refs because it is verifying that only 2 discrete objects were deserialized.
                #expect(targetRefs.count == 2)

                return thirdDesc
            }

            // Build yet again with a third set of overrides, to make sure we build a new set of tasks, and to check that files on disk were purged as expected.  This will cause 'secondDesc' to be purged, as it is the last-recently-used one.
            let fourthParameters = BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "$(inherited) -DBAR"])
            let fourthBuildRequest = BuildRequest(parameters: fourthParameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: fourthParameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let fourthDesc = try await tester.checkBuild(parameters: fourthParameters, runDestination: .macOS, buildRequest: fourthBuildRequest) { results in
                let fourthDesc = results.buildDescription

                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .new)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 0)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 2)

                // Make sure the files for the first/third and fourth descriptions exist on disk, but that the files for the second description have been removed..
                #expect(tester.fs.exists(firstDesc.manifestPath))
                #expect(tester.fs.exists(firstDesc.serializedBuildDescriptionPath))
                #expect(!tester.fs.exists(secondDesc.manifestPath))
                #expect(!tester.fs.exists(secondDesc.serializedBuildDescriptionPath))
                #expect(tester.fs.exists(thirdDesc.manifestPath))
                #expect(tester.fs.exists(thirdDesc.serializedBuildDescriptionPath))
                #expect(tester.fs.exists(fourthDesc.manifestPath))
                #expect(tester.fs.exists(fourthDesc.serializedBuildDescriptionPath))

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Compare the tasks and make sure the cached tasks ran.
                let newDesc = results.buildDescriptionInfo.buildDescription
                #expect(firstDesc.tasks.count == newDesc.tasks.count)
                for task in newDesc.tasks {
                    results.check(event: .taskHadEvent(task, event: .started), precedes: .taskHadEvent(task, event: .completed))
                }

                return fourthDesc
            }

            _ = fourthDesc
        }
    }

    /// Generate a `BuildDescription` from our test workspace, build it, and check results.  Then try doing it again to make sure we can use the results loaded from the on-disk cache.
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func inMemoryBuildDescriptionCache() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await getTestWorkspace(in: tmpDirPath)

            // Use an in-memory cache.
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info-Foo.plist"), .plDict(["key": .plString("value")]))
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Bar.h"))  { $0 <<< "#include \"Baz.h\"\n" }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Bar.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Baz.h"))  { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Baz.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Quux.swift")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Crux.swift")) { _ in }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info-Bar.plist"), .plDict(["key": .plString("value")]))

            // This test is explicitly testing results after reading the description from disk, so disable caching
            tester.userPreferences = tester.userPreferences.with(enableBuildSystemCaching: false)

            // Create a new build description, build from it, and check results.
            let firstDesc = try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .new)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 1)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 1)

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Save the build description for later use.
                let firstDesc = results.buildDescription

                // FIXME: We should be running swift-stdlib-tool for the app here, since the framework contains Swift, but presently it breaks due to <rdar://problem/28343103> [Swift Build] Build failure when building a Swift app (swift-stdlib-tool issue?)

                // Do some checking of the results to make sure we got the commands we expect.
                #expect(results.checkTasks(.matchRuleType("MkDir")) { $0 }.count == 9)
                #expect(results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { $0 }.count == 31)
                #expect(results.checkTasks(.matchRuleType("SymLink")) { $0 }.count == 6)
                #expect(results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("CompileC")) { $0 }.count == 5)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver Compilation Requirements")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftCompile")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("SwiftEmitModule")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftMergeGeneratedHeaders")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("Ld")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("CpHeader")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("Copy")) { $0 }.count == 6)
                #expect(results.checkTasks(.matchRuleType("Touch")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { $0 }.count == 1)

                return firstDesc
            }

            // Build again using the cached build description, and check results.
            let secondDesc = try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .inMemoryCache)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 1)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 1)

                // Check that its signature is the same as the first one above (since we restored it from the cache), but different from the second one above.
                #expect(results.buildDescription.signature == firstDesc.signature)

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Compare the tasks and make sure the cached tasks ran.
                let secondDesc = results.buildDescription
                #expect(firstDesc.tasks.count == secondDesc.tasks.count)
                if firstDesc.tasks.count == secondDesc.tasks.count {
                    for i in 0..<firstDesc.tasks.count {
                        try compareRunTasks(firstDesc.tasks[i], secondDesc.tasks[i], tasksShouldBeTheSameObject: true, results)
                    }
                }

                // Compare the task action maps.
                #expect(firstDesc.taskActionMap.count == secondDesc.taskActionMap.count)
                if firstDesc.taskActionMap.count == secondDesc.taskActionMap.count {
                    for (tool, oldAction) in firstDesc.taskActionMap {
                        if let newAction = secondDesc.taskActionMap[tool] {
                            #expect(oldAction == newAction)
                        } else {
                            Issue.record("new description's taskActionMap does not have a TaskAction for tool: \(tool)")
                        }
                    }
                }

                // TODO: Compare errors and warnings.

                // Make sure there were only 2 configured targets deserialized among all the tasks, and that all of the configured targets in the build request are contained in the deserialized description.
                var targets = Set<ConfiguredTarget>()
                var targetRefs = Set<Ref<ConfiguredTarget>>()
                for task in secondDesc.tasks {
                    if let target = task.forTarget, !task.isGate {
                        targets.insert(target)
                        targetRefs.insert(Ref(target))
                    }
                }
                // This check uses Refs because it is verifying that only 2 discrete objects were deserialized.
                #expect(targetRefs.count == 2)

                return secondDesc
            }

            // Blow away the build manifest file and rebuild.
            try localFS.remove(secondDesc.manifestPath)
            try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .new)

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Generate a `BuildDescription` from our test workspace, build it, and check results.  Then try doing it again to make sure we can use the cached build system object
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func buildDescriptionUseInBuildSystemCaching() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await getTestWorkspace(in: tmpDirPath)

            // Use an in-memory cache.
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info-Foo.plist"), .plDict(["key": .plString("value")]))
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Bar.h"))  { $0 <<< "#include \"Baz.h\"\n" }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Bar.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Baz.h"))  { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Baz.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Quux.swift")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Crux.swift")) { _ in }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info-Bar.plist"), .plDict(["key": .plString("value")]))

            // This test is explicitly testing cached build system objects, so enable caching
            tester.userPreferences = tester.userPreferences.with(enableBuildSystemCaching: true)

            // Create a new build description, build from it, and check results.
            let firstDesc = try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .new)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 1)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 1)

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Save the build description for later use.
                let firstDesc = results.buildDescription

                // FIXME: We should be running swift-stdlib-tool for the app here, since the framework contains Swift, but presently it breaks due to <rdar://problem/28343103> [Swift Build] Build failure when building a Swift app (swift-stdlib-tool issue?)

                // Do some checking of the results to make sure we got the commands we expect.
                #expect(results.checkTasks(.matchRuleType("MkDir")) { $0 }.count == 9)
                #expect(results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { $0 }.count == 31)
                #expect(results.checkTasks(.matchRuleType("SymLink")) { $0 }.count == 6)
                #expect(results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("CompileC")) { $0 }.count == 5)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver Compilation Requirements")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftCompile")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("SwiftEmitModule")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("SwiftMergeGeneratedHeaders")) { $0 }.count == 1)
                #expect(results.checkTasks(.matchRuleType("Ld")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("CpHeader")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("Copy")) { $0 }.count == 6)
                #expect(results.checkTasks(.matchRuleType("Touch")) { $0 }.count == 2)
                #expect(results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { $0 }.count == 1)

                return firstDesc
            }

            // Build again using the cached build description, and check results.
            let secondDesc = try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .inMemoryCache)
                #expect(results.buildDescriptionInfo.inMemoryCacheSize == 1)
                #expect(results.buildDescriptionInfo.onDiskCacheSize(fs: tester.fs) == 1)

                // Check that its signature is the same as the first one above (since we restored it from the cache), but different from the second one above.
                let secondDesc = results.buildDescription
                #expect(secondDesc.signature == firstDesc.signature)

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()


                // Make sure there were only 2 configured targets deserialized among all the tasks, and that all of the configured targets in the build request are contained in the deserialized description.
                var targets = Set<ConfiguredTarget>()
                var targetRefs = Set<Ref<ConfiguredTarget>>()
                for task in secondDesc.tasks {
                    if let target = task.forTarget, !task.isGate {
                        targets.insert(target)
                        targetRefs.insert(Ref(target))
                    }
                }
                // This check uses Refs because it is verifying that only 2 discrete objects were deserialized.
                #expect(targetRefs.count == 2)

                return secondDesc
            }

            // Blow away the build manifest file and rebuild.
            try localFS.remove(secondDesc.manifestPath)
            try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that we got the BuildDescription in the expected way.
                #expect(results.buildDescriptionInfo.source == .new)

                // Check that there were no errors or warnings.
                results.checkNoDiagnostics()
            }
        }
    }
}

