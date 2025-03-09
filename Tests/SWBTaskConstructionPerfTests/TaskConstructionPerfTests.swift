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

import class Foundation.Bundle

import Testing

import SWBCore
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite(.performance)
fileprivate struct TaskConstructionPerfTests: CoreBasedTests, PerfTests {
    /// Regression test for rdar://83518445
    /// Test the performance of generating CreateBuildDirectory tasks
    @Test(.requireSDKs(.macOS))
    func createBuildDirectoryTaskGenerationWith500Targets() async throws {
        try await withTemporaryDirectory { tmpDir in
            let targets: [TestStandardTarget] = (0..<500).map {
                let buildPath = tmpDir.join("build/\($0)")
                return TestStandardTarget(
                    "CoreFoo\($0)", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["OBJROOT": buildPath.str, "SYMROOT": buildPath.str, "DSTROOT": buildPath.str])],
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])], dependencies: ["OtherFramework"])
            }

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("foo.c")]),
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                              "GENERATE_INFOPLIST_FILE": "YES",
                                                                                              "USE_HEADERMAP": "NO"])],
                        targets: [TestAggregateTarget("all", dependencies: targets.map(\.name))] + targets)
                ]
            )
            let tester = try await TaskConstructionTester(self.getCore(), testWorkspace)
            await measure {
                await tester.checkBuild(runDestination: .macOS, checkTaskGraphIntegrity: false) { tester in
                    tester.checkTasks(.matchRuleType("CreateBuildDirectory")) { tasks in
                        #expect(tasks.count == 1503)
                    }
                }
            }
        }
    }
}
