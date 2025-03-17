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

import Foundation
import Testing

@_spi(Testing) import SwiftBuild
import SwiftBuildTestSupport
import SWBBuildService

import SWBCore
import SWBUtil
import SWBTestSupport
import SWBProtocol

@Suite
fileprivate struct BuildOperationTests: CoreBasedTests {
    /// Check the basic behavior of an empty build.
    @Test
    func emptyBuild() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                XCTAssertLastBuildEvent(events)
            }
        }
    }

    /// Check the basic behavior of an empty build.
    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func emptyBuildInProcess() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(connectionMode: .inProcess, temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                XCTAssertLastBuildEvent(events)
            }
        }
    }

    @Test
    func emptyBuildInProcessStatic() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(connectionMode: .inProcessStatic(swiftbuildServiceEntryPoint), temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                XCTAssertLastBuildEvent(events)
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func multiFileAssembleBuild() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [TestFile("Test.c")]),
                    targets: [
                        TestAggregateTarget("All", dependencies: ["aFramework", "bFramework"]),
                        TestStandardTarget("aFramework", type: .application, buildPhases: [TestSourcesBuildPhase([TestBuildFile("Test.c")])]),
                        TestStandardTarget("bFramework", type: .application, buildPhases: [TestSourcesBuildPhase([TestBuildFile("Test.c")])]),
                    ])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.configuredTargets = testProject.targets.dropFirst().map { SWBConfiguredTarget(guid: $0.guid) }
                request.buildCommand = .buildFiles(paths: [srcroot.join("Test.c").str], action: .assemble)

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                let pathMap = try #require(events.compactMap({ msg in
                    switch msg {
                    case let .reportPathMap(msg):
                        return msg.generatedFilesPathMap
                    default:
                        return nil
                    }
                }).only)
                #expect(pathMap.count == 4)
                for arch in ["arm64", "x86_64"] {
                    for target in ["aFramework", "bFramework"] {
                        #expect(try pathMap[AbsolutePath(validating: "\(srcroot.str)/aProject/build/aProject.build/Debug/\(target).build/Objects-normal/\(arch)/Test.s")] == AbsolutePath(validating: "\(srcroot.str)/Test.c"))
                    }
                }

                XCTAssertLastBuildEvent(events)
            }
        }
    }

    /// Check the basic behavior of a build operation's messages.
    @Test(.requireSDKs(.macOS), .skipHostOS(.windows)) // relies on UNIX shell, consider adding Windows command shell support for script phases?
    func basics() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestAggregateTarget("A",
                                                     buildPhases: [
                                                        TestShellScriptBuildPhase(
                                                            name: "A.Script", originalObjectID: "A.Script", contents: (OutputByteStream()
                                                                                                                       <<< "/usr/bin/touch ${SCRIPT_OUTPUT_FILE_0}"
                                                                                                                      ).bytes.asString, inputs: [], outputs: ["$(DERIVED_FILE_DIR)/stamp"])
                                                     ],
                                                     dependencies: ["B"]
                )
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [testTarget,
                              TestAggregateTarget("B",
                                                  buildPhases: [
                                                    // This task will be up-to-date after the first build
                                                    TestShellScriptBuildPhase(
                                                        name: "B.Once", originalObjectID: "B.Once",
                                                        contents: "/usr/bin/touch ${SCRIPT_OUTPUT_FILE_0}",
                                                        inputs: [], outputs: ["$(DERIVED_FILE_DIR)/stamp"]),
                                                    // This task will always run.
                                                    TestShellScriptBuildPhase(
                                                        name: "B.Always", originalObjectID: "B.Always",
                                                        contents: "true",
                                                        inputs: [], outputs: [])
                                                  ]
                                                 )
                             ])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    XCTAssertLastBuildEvent(events)
                }

                // Check that a null build reports the target is up-to-date, and reports task up-to-date messages appropriately.
                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    // FIXME: We should check these events much more carefully.
                    var targetStarted = false
                    var targetUpToDate = false
                    var targetComplete = false
                    var taskUpToDate = false
                    for event in events {
                        switch event {
                        case .targetStarted:
                            targetStarted = true
                        case .targetUpToDate:
                            targetUpToDate = true
                        case .targetComplete:
                            targetComplete = true
                        case .taskUpToDate:
                            taskUpToDate = true
                        default:
                            break
                        }
                    }
                    #expect(targetStarted, "unexpected events: \(events)")
                    #expect(targetUpToDate, "unexpected events: \(events)")
                    #expect(targetComplete, "unexpected events: \(events)")
                    #expect(taskUpToDate, "unexpected events: \(events)")
                    XCTAssertLastBuildEvent(events)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory) // version info discovery isn't working on Windows
    func onlyCreateBuildDescription() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTarget = TestStandardTarget(
                    "Foo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let otherTargetWithHeader = TestStandardTarget(
                    "Bar", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("foo.c"), TestFile("foo.h")]),
                    targets: [testTarget, otherTargetWithHeader])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                // Run a test build.
                let request = {
                    var request = SWBBuildRequest()
                    request.parameters = SWBBuildParameters()
                    request.parameters.action = "build"
                    request.parameters.configurationName = "Debug"
                    request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))
                    return request
                }()

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }

                // Check that we get a build description but nothing is built.
                do {
                    let (events, _) = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events, { results in
                        results.checkTask(.matchRule(["ComputeTargetDependencyGraph"])) { task in
                            #expect(task.executionDescription == "Compute target dependency graph")
                        }
                        results.checkTask(.matchRule(["GatherProvisioningInputs"])) { task in
                            #expect(task.executionDescription == "Gather provisioning inputs")
                        }
                        results.checkTask(.matchRule(["CreateBuildDescription"])) { task in
                            #expect(task.executionDescription == "Create build description")

                            // FIXME: Check the hierarchical relationship when we have infrastructure to do so.
                            results.checkTasks(.matchRuleType("ExecuteExternalTool")) { tasks in
                                XCTAssertEqualSequences(Set(tasks.map(\.executionDescription)).sorted(), [
                                    "Discovering version info for clang",
                                    "Discovering version info for ld"
                                ])
                            }
                        }
                        results.checkNoTask()

                        results.checkNoDiagnostics()
                        results.checkNoFailedTasks()
                    })
                }

                // Check that we can invoke build description creation operation concurrently while a normal build is in progress.

                // First normal build, then build description.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                        try await tester.checkResults(events: events, { results in
                            results.checkTasks { tasks in
                                #expect(!tasks.isEmpty)
                            }
                        })
                    }

                    group.addTask {
                        let (events, _) = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: TestBuildOperationDelegate())
                        try await tester.checkResults(events: events, { results in
                            results.checkTask(.matchRule(["ComputeTargetDependencyGraph"])) { task in
                                #expect(task.executionDescription == "Compute target dependency graph")
                            }
                            results.checkTask(.matchRule(["GatherProvisioningInputs"])) { task in
                                #expect(task.executionDescription == "Gather provisioning inputs")
                            }
                            results.checkNoTask()
                        })
                    }

                    try await group.waitForAll()
                }

                // First build description, then normal build.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let (events, _) = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: TestBuildOperationDelegate())
                        try await tester.checkResults(events: events, { results in
                            results.checkTask(.matchRule(["ComputeTargetDependencyGraph"])) { task in
                                #expect(task.executionDescription == "Compute target dependency graph")
                            }
                            results.checkTask(.matchRule(["GatherProvisioningInputs"])) { task in
                                #expect(task.executionDescription == "Gather provisioning inputs")
                            }
                            results.checkNoTask()
                        })
                    }

                    group.addTask {
                        try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    }

                    try await group.waitForAll()
                }
            }
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory) // version info discovery isn't working on Windows
    func explicitBuildDescriptionID() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTarget = TestStandardTarget(
                    "Foo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let otherTargetWithHeader = TestStandardTarget(
                    "Bar", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("foo.c"), TestFile("foo.h")]),
                    targets: [testTarget, otherTargetWithHeader])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }

                // Check that we get a build description but nothing is built.
                let buildDescriptionID: String
                do {
                    let (events, id) = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: TestBuildOperationDelegate())
                    buildDescriptionID = id.buildDescriptionID

                    try await tester.checkResults(events: events) { results in
                        results.checkTask(.matchRule(["ComputeTargetDependencyGraph"])) { task in
                            #expect(task.executionDescription == "Compute target dependency graph")
                        }
                        results.checkTask(.matchRule(["GatherProvisioningInputs"])) { task in
                            #expect(task.executionDescription == "Gather provisioning inputs")
                        }
                        results.checkTask(.matchRule(["CreateBuildDescription"])) { task in
                            #expect(task.executionDescription == "Create build description")

                            // FIXME: Check the hierarchical relationship when we have infrastructure to do so.
                            results.checkTasks(.matchRuleType("ExecuteExternalTool")) { tasks in
                                XCTAssertEqualSequences(Set(tasks.map(\.executionDescription)).sorted(), [
                                    "Discovering version info for clang",
                                    "Discovering version info for ld"
                                ])
                            }
                        }
                        results.checkNoTask()
                    }

                    #expect(events.contains { event in
                        switch event {
                        case .planningOperationStarted, .planningOperationCompleted:
                            return true
                        default:
                            return false
                        }
                    }, "unexpected events: \(events)")
                }

                // Check that passing a `buildDescriptionID` will avoid planning.
                do {
                    request.buildDescriptionID = buildDescriptionID
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events) { results in
                        results.checkTasks { tasks in
                            #expect(!tasks.isEmpty)
                        }
                        results.checkNoTask()
                    }

                    #expect(!events.contains { event in
                        switch event {
                        case .planningOperationStarted, .planningOperationCompleted:
                            return true
                        default:
                            return false
                        }
                    }, "unexpected events: \(events)")
                    #expect(events.reportBuildDescriptionMessage?.buildDescriptionID == buildDescriptionID)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func concurrentPrepareAndNormalBuild() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTarget = TestStandardTarget(
                    "Foo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let otherTargetWithHeader = TestStandardTarget(
                    "Bar", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("foo.c"), TestFile("foo.h")]),
                    targets: [testTarget, otherTargetWithHeader])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }

                let buildRequest = {
                    var buildRequest = SWBBuildRequest()
                    buildRequest.parameters = SWBBuildParameters(action: "build", configuration: "Debug")
                    buildRequest.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))
                    return buildRequest
                }()

                let buildDescriptionID = try await createIndexBuildDescription(testWorkspace, session: testSession)
                let prepareRequest = {
                    var prepareRequest = SWBBuildRequest()
                    prepareRequest.parameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug")
                    prepareRequest.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [testTarget.guid], enableIndexBuildArena: true)
                    prepareRequest.buildDescriptionID = buildDescriptionID
                    return prepareRequest
                }()

                // Check that we can invoke prepare-for-index operation concurrently while a normal build is in progress.

                // First normal build, then prepare.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let events = try await testSession.runBuildOperation(request: buildRequest, delegate: TestBuildOperationDelegate())
                        try await tester.checkResults(events: events) { results in
                            results.checkTasks { tasks in
                                #expect(!tasks.isEmpty)
                            }
                            results.checkNoTask()
                        }
                    }

                    group.addTask {
                        try await testSession.runBuildOperation(request: prepareRequest, delegate: TestBuildOperationDelegate())
                    }

                    try await group.waitForAll()
                }

                // First prepare, then normal build.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await testSession.runBuildOperation(request: prepareRequest, delegate: TestBuildOperationDelegate())
                    }

                    group.addTask {
                        try await testSession.runBuildOperation(request: buildRequest, delegate: TestBuildOperationDelegate())
                    }

                    try await group.waitForAll()
                }
            }
        }
    }

    @Test
    func multipleConcurrentNormalBuilds() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [TestProject(
                        "aProject",
                        defaultConfigurationName: "Release",
                        groupTree: TestGroup("Foo", children: [
                            TestFile("foo.c"), TestFile("foo.h")]),
                        targets: [TestExternalTarget("Sleeper", toolPath: "/bin/sleep", arguments: "10")])])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                try await testSession.sendPIF(testWorkspace)

                // Write the test sources.
                try await localFS.writeFileContents(SRCROOT.join("foo.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }

                var buildRequest = SWBBuildRequest()
                buildRequest.parameters = SWBBuildParameters(action: "build", configuration: "Debug")
                buildRequest.add(target: SWBConfiguredTarget(guid: testWorkspace.projects[0].targets[0].guid, parameters: nil))

                do {
                    let operation = try await testSession.session.createBuildOperation(request: buildRequest, delegate: TestBuildOperationDelegate())
                    _ = try await operation.start()

                    // Starting a second build operation concurrently with the first should fail.
                    await #expect(performing: {
                        try await testSession.session.createBuildOperation(request: buildRequest, delegate: TestBuildOperationDelegate())
                    }, throws: { error in
                        (error as (any Error)).localizedDescription == "unexpected attempt to have multiple concurrent normal build operations"
                    })

                    operation.cancel()

                    await operation.waitForCompletion()
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func prepareForIndexResultInfo() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let frameTarget = TestStandardTarget(
                    "Frame", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("frame.swift")]),
                    ])
                let toolTarget = TestStandardTarget(
                    "Tool", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("tool.swift")]),
                        TestFrameworksBuildPhase(["Frame.framework"]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    groupTree: TestGroup("Files", children: [
                        TestFile("frame.swift"),
                        TestFile("tool.swift")
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "macosx",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": "5",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    targets: [frameTarget, toolTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("frame.swift")) { contents in
                    contents <<< "public func getTheValue() -> Int { return 0 }\n"
                }
                try await fs.writeFileContents(SRCROOT.join("tool.swift")) { contents in
                    contents <<< "import Frame\n_ = getTheValue()\n"
                }

                let buildDescriptionID = try await createIndexBuildDescription(testWorkspace, session: testSession)
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug")
                request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [toolTarget.guid], enableIndexBuildArena: true)
                request.buildDescriptionID = buildDescriptionID

                var currentPrepareResult: SwiftBuildMessage.PreparedForIndexInfo
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start()
                    var preparedForIndexInfos: [SwiftBuildMessage.PreparedForIndexInfo] = []
                    for await event in events {
                        if case let .preparedForIndex(message) = event {
                            preparedForIndexInfos.append(message)
                        }
                    }
                    currentPrepareResult = try #require(preparedForIndexInfos.only)
                    #expect(currentPrepareResult.targetGUID == toolTarget.guid)
                    await operation.waitForCompletion()
                }

                // Update source file changing the source location of the function. The existing module file will be untouched but the `*.swiftsourceinfo` file will be updated.
                // The prepare result will be updated.
                try await localFS.writeFileContents(SRCROOT.join("frame.swift")) { contents in
                    contents <<< "\npublic func getTheValue() -> Int { return 0 }\n"
                }
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start().collect()
                    var preparedForIndexInfos: [SwiftBuildMessage.PreparedForIndexInfo] = []
                    for event in events {
                        if case let .preparedForIndex(message) = event {
                            preparedForIndexInfos.append(message)
                        }
                    }
                    await operation.waitForCompletion()

                    try await tester.checkResults(events: events) { results in
                        results.checkTasks(.matchRuleType("SwiftDriver GenerateModule")) { tasks in
                            #expect(!tasks.isEmpty)
                        }

                        results.checkTasks { tasks in
                            #expect(!tasks.isEmpty)
                        }
                        results.checkNoTask()
                    }

                    let resultInfo = try #require(preparedForIndexInfos.only)
                    currentPrepareResult = resultInfo
                }

                // Change the function signature. The swift module will get updated.
                // The prepare result should have new update.
                try await localFS.writeFileContents(SRCROOT.join("frame.swift")) { contents in
                    contents <<< "public func getTheValue() -> Float { return 1 }\n"
                }
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start().collect()
                    var preparedForIndexInfos: [SwiftBuildMessage.PreparedForIndexInfo] = []
                    for event in events {
                        if case let .preparedForIndex(message) = event {
                            preparedForIndexInfos.append(message)
                        }
                    }
                    await operation.waitForCompletion()

                    try await tester.checkResults(events: events) { results in
                        results.checkTasks(.matchRuleType("SwiftDriver GenerateModule")) { tasks in
                            #expect(!tasks.isEmpty)
                        }
                    }

                    _ = try #require(preparedForIndexInfos.only)
                }
            }
        }
    }

    /// Check that a prebuild doesn't cause any unnecessary rebuilding.
    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func prebuildInterference() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTarget = TestStandardTarget(
                    "Foo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let otherTargetWithHeader = TestStandardTarget(
                    "Bar", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("foo.c"), TestFile("foo.h")]),
                    targets: [testTarget, otherTargetWithHeader])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }

                // Run the initial build.
                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    XCTAssertLastBuildEvent(events)

                    try await tester.checkResults(events: events) { results in
                        results.checkTasks { tasks in
                            #expect(!tasks.isEmpty)
                        }
                        results.checkNoTask()

                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }

                    let reportedBuildDescriptionID = try #require(events.reportBuildDescriptionMessage?.buildDescriptionID)
                    #expect(events.allOutput().bytes.unsafeStringValue.hasPrefix(
                """
                Build description signature: \(reportedBuildDescriptionID)
                Build description path: \(tmpDir.str)/Test/aProject/build/XCBuildData/\(reportedBuildDescriptionID).xcbuilddata
                """))
                }

                // Check that we get a null build.
                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()
                        results.consumeTasksMatchingRuleTypes(["ComputeTargetDependencyGraph", "GatherProvisioningInputs"])
                        results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }
                        results.checkNoTask()

                        results.checkNoFailedTasks()
                    }
                }

                // Run a prebuild.
                do {
                    // This request is intentionally crafted to cause the VFS to change (by adding an extra target); that will cause the VFS to be rewritten in both targets, but that should *not* cause anything to recompile.
                    var request = SWBBuildRequest()
                    request.parameters = SWBBuildParameters()
                    request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: false)
                    request.parameters.action = "build"
                    request.parameters.configurationName = "Debug"
                    request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))
                    request.add(target: SWBConfiguredTarget(guid: otherTargetWithHeader.guid, parameters: nil))

                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events) { results in
                        results.consumeTasksMatchingRuleTypes(["WriteAuxiliaryFile", "MkDir", "SymLink", "CreateBuildDirectory", "ClangStatCache"])
                        results.checkTask(.matchRule(["ComputeTargetDependencyGraph"])) { task in
                            #expect(task.executionDescription == "Compute target dependency graph")
                        }
                        results.checkTask(.matchRule(["GatherProvisioningInputs"])) { task in
                            #expect(task.executionDescription == "Gather provisioning inputs")
                        }
                        results.checkTask(.matchRule(["CreateBuildDescription"])) { task in
                            #expect(task.executionDescription == "Create build description")
                        }
                        results.checkNoTask()

                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }
                }

                // Check that we get a null-(ish) build.
                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events) { results in
                        results.consumeTasksMatchingRuleTypes(["ComputeTargetDependencyGraph", "GatherProvisioningInputs", "WriteAuxiliaryFile", "ClangStatCache", "ProcessInfoPlistFile", "CodeSign"])
                        results.checkNoTask()

                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }
                }
            }
        }
    }

    @Test(.skipHostOS(.windows)) // Windows: $PRODUCT_NAME-preparedForIndex-target node is missing?
    func prepareForIndexAvoidsProvisioning() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTarget = TestStandardTarget(
                    "Foo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                               ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                        TestHeadersBuildPhase([TestBuildFile("foo.h")]),
                    ],
                    provisioningSourceData: [
                        ProvisioningSourceData(configurationName: "Debug", provisioningStyle: .automatic, bundleIdentifierFromInfoPlist: "AppTarget"),
                    ]
                )
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("foo.c"), TestFile("foo.h")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                try await fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }

                do {
                    var request = SWBBuildRequest()
                    request.parameters = SWBBuildParameters()
                    request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [testTarget.guid], enableIndexBuildArena: true)
                    request.parameters.action = "indexbuild"
                    request.parameters.configurationName = "Debug"
                    request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                    let delegate = TestBuildOperationDelegate()
                    let events = try await testSession.runBuildOperation(request: request, delegate: delegate)
                    #expect(delegate.numProvisioningTaskInputRequests.withLock { $0 } == 0)

                    try await tester.checkResults(events: events) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }
                }
            }
        }
    }

    /// Check the behavior of an invalid request (basically that it doesn't crash).
    @Test
    func invalidBuildRequest() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestExternalTarget("ExternalTarget")
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: "INVALID-GUID", parameters: nil))

                await #expect(throws: (any Error).self) {
                    try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                }
            }
        }
    }

    /// Check the basic behavior of a clean build.
    @Test
    func cleanBuild() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Run a clean build.
                var request = SWBBuildRequest()
                request.buildCommand = .cleanBuildFolder(style: .regular)
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                XCTAssertLastBuildEvent(events)
            }
        }
    }

    /// Test that we don't assert or corrupt session state if the service terminates from underneath us after session creation.
    @Test(.requireHostOS(.macOS))
    func serviceCrashRecovery() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            let tmpDir = temporaryDirectory.path
            let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)

            let srcroot = tmpDir.join("Test")
            let testTarget = TestExternalTarget("ExternalTarget")
            let testProject = TestProject(
                "aProject",
                defaultConfigurationName: "Release",
                groupTree: TestGroup("Foo"),
                targets: [testTarget])
            let testWorkspace = TestWorkspace("aWorkspace",
                                              sourceRoot: srcroot,
                                              projects: [testProject])

            try await testSession.sendPIF(testWorkspace)

            do {
                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: "INVALID-GUID", parameters: nil))

                await #expect(throws: (any Error).self) {
                    try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                }
            }

            await testSession.service.terminate()

            await #expect(performing: {
                try await testSession.close()
            }, throws: { error in
                error.localizedDescription == "The Xcode build system has crashed. Build again to continue."
            })
        }
    }

    /// Check some cancellation related semantics.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "requires /usr/bin/yes"), .skipHostOS(.linux, "test occasionally hangs on Linux"))
    func cancellationBeforeStarting() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestStandardTarget(
                    "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                // We run a task which will never finish.
                                "CC": "/usr/bin/yes",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [testProject])

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test file.
                try fs.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try fs.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                // Check cancellation before starting the operation.
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    // Cancel immediately and wait.
                    operation.cancel()
                    await operation.waitForCompletion()

                    // The operation should report itself as cancelled.
                    #expect(operation.state == .cancelled)

                    try await tester.checkResults(events: []) { results in
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }

    /// Check some cancellation related semantics.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "requires /usr/bin/yes"), .skipHostOS(.linux, "test occasionally hangs on Linux"))
    func cancellationImmediatelyAfterStart() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestStandardTarget(
                    "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                // We run a task which will never finish.
                                "CC": "/usr/bin/yes",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [testProject])

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test file.
                try fs.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try fs.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                // Check immediate cancellation after starting the operation.
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start()

                    // Cancel immediately and wait.
                    operation.cancel()
                    await operation.waitForCompletion()

                    // The operation should report itself as cancelled.
                    #expect(operation.state == .cancelled)

                    try await tester.checkResults(events: events.collect()) { results in
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }

    /// Check some cancellation related semantics.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "requires /usr/bin/yes"), .skipHostOS(.linux, "test occasionally hangs on Linux"))
    func cancellationAfterStart() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestStandardTarget(
                    "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                // We run a task which will never finish.
                                "CC": "/usr/bin/yes",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [testProject])

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test file.
                try fs.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try fs.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                // Check cancellation after the build has started.
                //
                // FIXME: This isn't yet reliable.
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let eventStream = try await operation.start()

                    // Cancel after the build starts.
                    var events: [SwiftBuildMessage] = []
                    for await event in eventStream {
                        if case .buildStarted = event {
                            operation.cancel()
                        }
                        events.append(event)
                    }

                    // Wait for the build to finish.
                    await operation.waitForCompletion()

                    // The operation should report itself as cancelled.
                    #expect(operation.state == .cancelled)

                    try await tester.checkResults(events: events) { results in
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }

    /// Check some cancellation related semantics.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "requires /usr/bin/yes"), .skipHostOS(.linux, "test occasionally hangs on Linux"))
    func cancellationAfterTaskStart() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestStandardTarget(
                    "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                // We run a task which will never finish.
                                "CC": "/usr/bin/yes",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [testProject])

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test file.
                try fs.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try fs.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                // Check cancellation after a task has started.
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let eventStream = try await operation.start()

                    // Cancel after the build starts.
                    var events: [SwiftBuildMessage] = []
                    for await event in eventStream {
                        if case .taskStarted = event {
                            operation.cancel()
                        }
                        events.append(event)
                    }

                    // Wait for the build to finish.
                    await operation.waitForCompletion()

                    // The operation should report itself as cancelled.
                    #expect(operation.state == .cancelled)

                    try await tester.checkResults(events: events) { results in
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }

    /// Check some cancellation related semantics.
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "requires /usr/bin/yes"), .skipHostOS(.linux, "test occasionally hangs on Linux"))
    func repeatedCancellation() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestStandardTarget(
                    "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                // We run a task which will never finish.
                                "CC": "/usr/bin/yes",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [testProject])

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test file.
                try fs.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try fs.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                // The original issue was depending on timing so try a few times to make sure.
                for _ in 0..<5 {
                    let operation = try await testSession.session.createBuildOperationForBuildDescriptionOnly(request: request, delegate: TestBuildOperationDelegate())
                    let eventStream = try await operation.start()
                    var events: [SwiftBuildMessage] = []
                    for await event in eventStream {
                        if case .preparationComplete = event {
                            operation.cancel()
                        }
                        events.append(event)
                    }
                    await operation.waitForCompletion()
                    XCTAssertLastBuildEvent(events)

                    try await tester.checkResults(events: events) { results in
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }

    /// Test that starting a build operation actually cancels indexing operations.
    @Test(.requireSDKs(.host), .requireHostOS(.macOS))
    func indexingCancellation() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestStandardTarget(
                    "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [testProject])

                try await testSession.sendPIF(testWorkspace)

                // Write the test file.
                try localFS.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try localFS.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                let request = {
                    var request = SWBBuildRequest()
                    request.parameters = SWBBuildParameters()
                    request.parameters.action = "build"
                    request.parameters.configurationName = "Debug"
                    request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))
                    return request
                }()

                while true {
                    // Trigger indexing and immediately start the build operation.
                    let indexingInfo = Task { try await testSession.session.generateIndexingFileSettings(for: request, targetID: testTarget.guid, delegate: TestBuildOperationDelegate()) }
                    let operation = Task {
                        let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                        _ = try await operation.start()
                        return operation
                    }

                    do {
                        _ = try await indexingInfo.value
                        let operation = try await operation.value
                        operation.cancel()
                        await operation.waitForCompletion()
                    } catch let result {
                        // The indexing should get automatically cancelled by the build operation.
                        #expect(String(describing: result).contains("The indexing operation was cancelled"), Comment(rawValue: String(describing: result)))
                        return
                    }
                }
            }
        }
    }

    /// Test session destruction
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "requires /usr/bin/yes"), .skipHostOS(.linux, "test occasionally hangs on Linux"))
    func sessionDestructionCancellation() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path

                let service: SWBBuildService? = try await SWBBuildService()
                await deferrable.addBlock { [weak service] in
                    await service?.close()
                    service = nil
                }

                func start() async throws -> (SWBBuildOperation, AsyncStream<SwiftBuildMessage>) {
                    let (sessionResult, _) = try await #require(service).createSession(name: #function, cachePath: tmpDir.str)
                    let session: SWBBuildServiceSession? = try sessionResult.get()
                    await deferrable.addBlock { [weak session] in
                        await #expect(throws: Never.self) {
                            try await session?.close()
                        }
                        session = nil
                    }

                    let testTarget: TestStandardTarget
                    do {
                        let srcroot = tmpDir.join("Test")
                        testTarget = TestStandardTarget(
                            "Foo", type: .staticLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "USE_HEADERMAP": "NO",
                                        // We run a task which will never finish.
                                        "CC": "/usr/bin/yes",
                                    ])],
                            buildPhases: [
                                TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                            ])
                        let testProject = TestProject(
                            "aProject",
                            defaultConfigurationName: "Release",
                            groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                            targets: [testTarget])
                        let testWorkspace = TestWorkspace(
                            "aWorkspace",
                            sourceRoot: srcroot,
                            projects: [testProject])

                        // Write the test file.
                        try localFS.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                        try localFS.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                        try await session?.sendPIF(.init(testWorkspace.toObjects().propertyListItem))
                    }

                    let request = {
                        var request = SWBBuildRequest()
                        request.parameters = SWBBuildParameters()
                        request.parameters.action = "build"
                        request.parameters.configurationName = "Debug"
                        request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))
                        return request
                    }()

                    let operation = try await #require(session).createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start()

                    if operation.state != .cancelled {
                        operation.cancel()
                    }

                    try await session?.close()

                    return (operation, events)
                }

                let (_, events) = try await start()
                _ = await events.collect()
            }
        }
    }

    /// Check scraped build issues.
    @Test(.requireSDKs(.macOS), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory) // relies on UNIX shell, consider adding Windows command shell support for script phases?
    func buildScriptIssues() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testTarget = TestAggregateTarget(
                    "Target",
                    buildPhases: [
                        TestShellScriptBuildPhase(
                            name: "Script1", originalObjectID: "Script1", contents: (OutputByteStream()
                                                                                     <<< "echo 'foo:1:1: error: bar'\n"
                                                                                     <<< "echo 'foo:1:1: warning: bar'\n"
                                                                                     <<< "echo 'foo:1:1: note: bar'\n"
                                                                                     <<< "echo 'foo: error: bar'\n"
                                                                                     <<< "echo 'foo: warning: bar'\n"
                                                                                     <<< "echo 'foo: note: bar'\n"
                                                                                    ).bytes.asString, inputs: [], outputs: [], alwaysOutOfDate: true)
                    ]
                )
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])

                let tester = try await CoreQualificationTester(testWorkspace, testSession)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                XCTAssertLastBuildEvent(events)

                try await tester.checkResults(events: events) { results in
                    results.checkNote(.equal("Building targets in dependency order"))
                    results.checkNote(.equal("Run script build phase \'Script1\' will be run during every build because the option to run the script phase \"Based on dependency analysis\" is unchecked."))

                    results.checkError(.equal("bar"))
                    results.checkWarning(.equal("bar"))
                    results.checkNote(.equal("bar"))

                    results.checkError(.equal("bar"))
                    results.checkWarning(.equal("bar"))
                    results.checkNote(.equal("bar"))

                    results.checkNoDiagnostics()
                }

                let reportedBuildDescriptionID = try #require(events.reportBuildDescriptionMessage?.buildDescriptionID)
                #expect(events.allOutput().bytes.unsafeStringValue == """
            Build description signature: \(reportedBuildDescriptionID)
            Build description path: \(tmpDir.str)/Test/aProject/build/XCBuildData/\(reportedBuildDescriptionID).xcbuilddata
            foo:1:1: error: bar
            foo:1:1: warning: bar
            foo:1:1: note: bar
            foo: error: bar
            foo: warning: bar
            foo: note: bar

            """)
            }
        }
    }

    /// Check situations involving incremental project changes with task construction.
    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func incrementalPIFTaskConstruction() async throws {
        // This specific case is a regression test for:
        //   <rdar://problem/32110353> unexpected missing header info for SWBCore.Project
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTargetA = TestStandardTarget(
                    "aTarget", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])])
                let testProject1 = TestProject(
                    "aProject",
                    groupTree: TestGroup("Sources", children: [TestFile("foo.c")]),
                    targets: [testTargetA])
                let testWorkspace1 = TestWorkspace("aWorkspace",
                                                   sourceRoot: tmpDir.join("Test"),
                                                   projects: [testProject1])
                let SRCROOT = testWorkspace1.sourceRoot.join("aProject")

                let fs = localFS

                // Write the source file.
                try await fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }

                let transferred1 = try await testSession.sendPIFIncrementally(testWorkspace1)
                #expect(transferred1 == [
                    testWorkspace1.signature, testProject1.signature, testTargetA.signature])

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTargetA.guid, parameters: nil))
                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    let tester = try await CoreQualificationTester(testWorkspace1, testSession, sendPIF: false, fs: fs)
                    try await tester.checkResults(events: events) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }
                }

                // Build again with a new project but shared targetA.
                let testProject2 = TestProject(
                    "aProject",
                    groupTree: TestGroup("Sources", children: [TestFile("foo.c"), TestFile("baz.c")]),
                    targets: [testTargetA])
                let testWorkspace2 = TestWorkspace("aWorkspace",
                                                   sourceRoot: tmpDir.join("Test"),
                                                   projects: [testProject2])

                let transferred2 = try await testSession.sendPIFIncrementally(testWorkspace2)
                #expect(transferred2 == [
                    testWorkspace2.signature, testProject2.signature])
                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    let tester = try await CoreQualificationTester(testWorkspace2, testSession, sendPIF: false, fs: fs)
                    try await tester.checkResults(events: events) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }
                }

                // Build once again with a new workspace but shared project, but a new build request (to force task reconstruction).
                let testWorkspace3 = TestWorkspace("aWorkspace",
                                                   sourceRoot: tmpDir.join("Test"),
                                                   projects: [testProject1])
                let transferred3 = try await testSession.sendPIFIncrementally(testWorkspace3)
                #expect(transferred3 == [
                    testWorkspace3.signature])
                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    let tester = try await CoreQualificationTester(testWorkspace3, testSession, sendPIF: false, fs: fs)
                    try await tester.checkResults(events: events) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }
                }
            }
        }
    }

    /// Test that an implicit dependency which results in an ambiguity, emits a diagnostic.
    /// This provides additional coverage over the variant in `SWBCoreTests`, because it tests with a real target dependency resolver delegate which sends diagnostics back from the build service.
    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func ambiguousImplicitDependency() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testWorkspace = TestWorkspace(
                    "Workspace",
                    sourceRoot: tmpDirPath,
                    projects: [
                        TestProject(
                            "P1",
                            groupTree: TestGroup(
                                "G1",
                                children: [
                                    TestFile("aFramework.framework"),
                                    TestFile("bFramework", path: "bFramework.framework/Versions/A/bFramework", fileType: "compiled.mach-o.executable", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR"))
                                ]
                            ),
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [:]),
                            ],
                            targets: [
                                TestStandardTarget(
                                    "anApp",
                                    guid: "Foo",
                                    type: .application,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                                    ],
                                    buildPhases: [
                                        TestFrameworksBuildPhase([
                                            "aFramework.framework",
                                            "bFramework",
                                        ]),
                                    ]
                                )
                            ]
                        ),
                        TestProject(
                            "P2",
                            groupTree: TestGroup(
                                "G2",
                                children:[
                                ]
                            ),
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [:]),
                            ],
                            targets: [
                                TestStandardTarget(
                                    "aFramework1",
                                    type: .framework,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                                    ]
                                ),
                                TestStandardTarget(
                                    "aFramework2",
                                    type: .framework,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                                    ]
                                ),
                                TestStandardTarget(
                                    "bFramework1",
                                    type: .framework,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "bFramework"]),
                                    ]
                                ),
                                TestStandardTarget(
                                    "bFramework2",
                                    type: .framework,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "bFramework"]),
                                    ]
                                ),
                            ]
                        ),
                    ]
                )

                let tester = try await CoreQualificationTester(testWorkspace, testSession)

                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                var table = SWBSettingsTable()
                table.set(value: "NO", for: "USE_HEADERMAP")
                table.set(value: "YES", for: "GENERATE_INFOPLIST_FILE")
                request.parameters.overrides.commandLine = table
                request.useImplicitDependencies = true
                request.add(target: SWBConfiguredTarget(guid: "Foo", parameters: nil))

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                try await tester.checkResults(events: events) { results in
                    results.checkNote(.equal("Building targets in dependency order"))
                    results.checkWarning(.equal("Multiple targets match implicit dependency for product reference 'aFramework.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity."))
                    results.checkWarning(.equal("Multiple targets match implicit dependency for product bundle executable reference 'bFramework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity."))
                    results.checkNoDiagnostics()

                    results.checkNoFailedTasks()
                }
            }
        }
    }

    @Test
    func buildSystemCachePurging() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")

                let testTarget = TestAggregateTarget(
                    "aTarget",
                    guid: "T1",
                    buildPhases: [
                        TestShellScriptBuildPhase(
                            name: "A.Script",
                            guid: "BS1",
                            originalObjectID: "A.Script",
                            contents: (OutputByteStream()
                                       <<< "echo test"
                                      ).bytes.asString,
                            inputs: [],
                            outputs: [])
                    ]
                )

                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    guid: "W1",
                    sourceRoot: srcroot,
                    projects: [TestProject(
                        "aProject",
                        guid: "P1",
                        defaultConfigurationName: "Debug",
                        groupTree: TestGroup(
                            "Foo",
                            guid: "G1"
                        ),
                        targets: [
                            testTarget,
                        ]
                    )])

                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                for _ in 0..<10 {
                    try await testSession.sendPIF(testWorkspace)

                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    XCTAssertLastBuildEvent(events)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func missingInputFailsBuilds() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(connectionMode: .inProcess, temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTarget = TestStandardTarget(
                    "TargetA",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "file1.swift",
                            "file2.swift",
                        ]),
                    ])

                let testWorkspace = try await TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                path: "Sources",
                                children: [
                                    TestFile("file1.swift"),
                                    TestFile("file2.swift"),
                                ]),
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SWIFT_VERSION": swiftVersion,
                                        "BUILD_VARIANTS": "normal",
                                        "ARCHS": "arm64e",

                                        // This file does not exist and should fail the build
                                        "SWIFT_OBJC_BRIDGING_HEADER": "foo.h"
                                    ])
                            ],
                            targets: [ testTarget ])
                    ])

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                try await fs.writeFileContents(tmpDirPath.join("Test/aProject/Sources/file1.swift")) { contents in
                    contents <<< "struct A {}\n"
                }

                try await fs.writeFileContents(tmpDirPath.join("Test/aProject/Sources/file2.swift")) { contents in
                    contents <<< "struct B {}\n"
                }

                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events) { results in
                        results.checkedErrors = true
                        let compilationTask = results.getTask(.matchRule(["SwiftDriver Compilation", "TargetA", "normal", "arm64e", "com.apple.xcode.tools.swift.compiler"]))
                        let compilationRequirementsTask = results.getTask(.matchRule(["SwiftDriver Compilation Requirements", "TargetA", "normal", "arm64e", "com.apple.xcode.tools.swift.compiler"]))
                        results.checkSomeTasksFailed([compilationTask, compilationRequirementsTask].compactMap { $0 })
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func swiftPerFileBatchedTaskSignaturesAreStable() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDirPath.join("Test")
                let testTarget = TestStandardTarget(
                    "Tool", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                // FIXME: There should be a way to automatically populate the version here, but since these tests are not CoreBasedTests, there isn't a good way to do so right now.
                                "SWIFT_VERSION": "5.0",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "USE_HEADERMAP": "NO",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "SWIFT_ENABLE_EXPLICIT_MODULES": "NO"
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                            TestBuildFile("File2.swift")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("File1.swift"),
                        TestFile("File2.swift")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await tester.invalidate()
                    }
                }

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("File1.swift")) { contents in
                    contents <<< "struct A {}\n"
                }
                try await fs.writeFileContents(SRCROOT.join("File2.swift")) { contents in
                    contents <<< "struct B {}\n"
                }

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                let taskStartedMessages = events.taskStartedMessages
                let file1x86Task = try #require(taskStartedMessages.filter({ $0.ruleInfo == "SwiftCompile normal x86_64 \(SRCROOT.join("File1.swift").str)" }).only)
                let file1arm64Task = try #require(taskStartedMessages.filter({ $0.ruleInfo == "SwiftCompile normal arm64 \(SRCROOT.join("File1.swift").str)" }).only)

                try fs.append(SRCROOT.join("File2.swift"), contents: "struct C {}\n")

                let delegate2 = TestBuildOperationDelegate()
                let operation = try await testSession.session.createBuildOperation(request: request, delegate: delegate2)
                let events2 = try await operation.start()
                var taskUpToDateMessages: [SwiftBuildMessage.TaskUpToDateInfo] = []
                for await event in events2 {
                    if case let .taskUpToDate(message) = event {
                        taskUpToDateMessages.append(message)
                    }
                }
                await operation.waitForCompletion()

                XCTAssertMatch(taskUpToDateMessages.map(\.taskSignature), [.contains(file1x86Task.taskSignature)])
                XCTAssertMatch(taskUpToDateMessages.map(\.taskSignature), [.contains(file1arm64Task.taskSignature)])
            }
        }
    }
}
