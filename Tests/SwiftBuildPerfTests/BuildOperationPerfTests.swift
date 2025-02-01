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

import SwiftBuild
import SwiftBuildTestSupport

import SWBProtocol
import SWBUtil
import SWBTestSupport

import Testing

@Suite(.performance, .requireThreadSafeWorkingDirectory)
fileprivate struct BuildOperationPerfTests: PerfTests {
    /// Run a test of a synthetic project with a given number of targets and files.
    ///
    /// - Parameters:
    ///   - numTargets: The number of targets to generate.
    ///   - numFiles: The number of files to generate in each target.
    ///   - numHeaders: The number of headers to be included (transitively) in each target.
    ///   - separateHeaders: Whether the headers are shared by all files, or separate for all files.
    func checkNullBuild(numTargets: Int, numFiles: Int, numHeaders: Int = 0, separateHeaders: Bool = false, iterations: Int) async throws {
        let fs = localFS
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let targets = (0 ..< numTargets).map { i in
                    return TestStandardTarget(
                        "Tool-\(i)", type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase((0 ..< numFiles).map{ TestBuildFile("File-\($0).c") }),
                            TestFrameworksBuildPhase()
                        ],
                        provisioningSourceData: [
                            SWBProtocol.ProvisioningSourceData(
                                configurationName: "Debug",
                                provisioningStyle: .manual,
                                bundleIdentifierFromInfoPlist: "$(PRODUCT_BUNDLE_IDENTIFIER)")])
                }
                let allTarget = TestAggregateTarget("ALL", dependencies: targets.map{ $0.name })
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Debug",
                    groupTree: TestGroup("Root", children: (0 ..< numFiles).map{ TestFile("File-\($0).c") }),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "USE_HEADERMAP": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ])],
                    targets: [allTarget] + targets)
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: tmpDir.join("Test"),
                                                  projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                // Write the header files.
                if !separateHeaders {
                    for i in 0 ..< numHeaders {
                        try await localFS.writeFileContents(SRCROOT.join("Header-\(i).h")) { contents in
                            if i + 1 < numHeaders {
                                contents <<< "#include \"Header-\(i + 1).h\"\n"
                            }
                        }
                    }
                }

                // Write the source files.
                for i in 0 ..< numFiles {
                    if separateHeaders {
                        for j in 0 ..< numHeaders {
                            try await localFS.writeFileContents(SRCROOT.join("File-\(i)-\(j).h")) { contents in
                                if j + 1 < numHeaders {
                                    contents <<< "#include \"File-\(i)-\(j + 1).h\"\n"
                                }
                            }
                        }
                    }

                    try await localFS.writeFileContents(SRCROOT.join("File-\(i).c")) { contents in
                        if numHeaders != 0 {
                            if separateHeaders {
                                contents <<< "#include \"File-\(i)-0.h\"\n\n"
                            } else {
                                contents <<< "#include \"Header-0.h\"\n\n"
                            }
                        }

                        if i == 0 {
                            contents <<< "int main() { return 0; }\n"
                        } else {
                            contents <<< "void f\(i)(void) {}\n"
                        }
                    }
                }

                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await tester.invalidate()
                    }
                }

                // Run a test build.
                let request = {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = true
                    request.parameters = SWBBuildParameters()
                    request.parameters.action = "build"
                    request.parameters.configurationName = "Debug"
                    request.add(target: SWBConfiguredTarget(guid: allTarget.guid, parameters: nil))
                    return request
                }()

                // Suppress a linker warning.
                try fs.createDirectory(SRCROOT.join("build/Debug"), recursive: true)

                do {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let reportedBuildDescriptionID = try #require(events.reportBuildDescriptionMessage?.buildDescriptionID)
                    #expect(events.allOutput().bytes.unsafeStringValue.hasPrefix(
                """
                Build description signature: \(reportedBuildDescriptionID)
                Build description path: \(SRCROOT.str)/build/XCBuildData/\(reportedBuildDescriptionID).xcbuilddata

                """))

                    try await tester.checkResults(events: events) { results in
                        results.checkTasks { tasks in
                            #expect(tasks.count > numTargets * numFiles)
                        }

                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }

                    #expect(events.filter { event in
                        switch event {
                        case .targetUpToDate:
                            return true
                        default:
                            return false
                        }
                    }.count == 0)
                }

                // Check the performance of the null build.
                try await measure {
                    for _ in 0 ..< (getEnvironmentVariable("CI")?.boolValue == true ? 1 : iterations) {
                        let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                        try await tester.checkResults(events: events) { results in
                            results.consumeTasksMatchingRuleTypes(["CreateBuildDescription", "ComputeTargetDependencyGraph", "GatherProvisioningInputs", "ClangStatCache"])
                            results.checkNoTask()

                            results.checkNote(.equal("Building targets in dependency order"))
                            results.checkNoDiagnostics()

                            results.checkNoFailedTasks()
                        }

                        #expect(events.allOutput().bytes == "")
                        #expect(events.filter { event in
                            switch event {
                            case .targetUpToDate:
                                return true
                            default:
                                return false
                            }
                        }.count == numTargets)
                    }
                }
            }
        }
    }

    // MARK: One target builds with varying file counts.

    @Test
    func synthetic_NoHeaders_T1F10_X100() async throws {
        try await checkNullBuild(numTargets: 1, numFiles: 10, iterations: 100)
    }

    @Test
    func synthetic_NoHeaders_T1F100_X100() async throws {
        try await checkNullBuild(numTargets: 1, numFiles: 100, iterations: 100)
    }

    @Test
    func synthetic_NoHeaders_T1F1000_X10() async throws {
        try await checkNullBuild(numTargets: 1, numFiles: 1000, iterations: 10)
    }

    // MARK: Multi-target builds with a constant total file count.

    @Test
    func synthetic_NoHeaders_T10F100_X10() async throws {
        try await checkNullBuild(numTargets: 10, numFiles: 100, iterations: 10)
    }

    @Test
    func synthetic_NoHeaders_T100F10_X10() async throws {
        try await checkNullBuild(numTargets: 100, numFiles: 10, iterations: 10)
    }

    @Test
    func synthetic_NoHeaders_T1000F1() async throws {
        try await checkNullBuild(numTargets: 1000, numFiles: 1, iterations: 1)
    }

    // MARK: One-target builds, with shared headers of varying counts.

    @Test
    func synthetic_SharedHeaders_T1F1000H1_X10() async throws {
        try await checkNullBuild(numTargets: 1, numFiles: 1000, numHeaders: 1, iterations: 10)
    }

    @Test
    func synthetic_SharedHeaders_T1F1000H10_X10() async throws {
        try await checkNullBuild(numTargets: 1, numFiles: 1000, numHeaders: 10, iterations: 10)
    }

    @Test
    func synthetic_SharedHeaders_T1F1000H100_X10() async throws {
        try await checkNullBuild(numTargets: 1, numFiles: 1000, numHeaders: 100, iterations: 10)
    }

    // MARK: One-target builds, with separate headers of varying counts.

    @Test
    func synthetic_SeparateHeaders_T1F1000H10_X10() async throws {
        try await checkNullBuild(numTargets: 1, numFiles: 1000, numHeaders: 10, separateHeaders: true, iterations: 10)
    }
}
