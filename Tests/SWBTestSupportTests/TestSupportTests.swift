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
import SWBTestSupport
import SWBUtil

@Suite fileprivate struct AssertionTests {
    @Test func assertMatchStringLists() {
        XCTAssertMatch([], [])
        XCTAssertMatch(["a"], [])

        XCTAssertMatch([], [.anySequence])
        XCTAssertMatch(["a"], [.anySequence])
        XCTAssertMatch(["a", "b"], [.anySequence])

        XCTAssertMatch([], [.start])
        XCTAssertMatch([], [.start, .end])
        XCTAssertMatch([], [.end])
        XCTAssertNoMatch([], [.end, "a"])

        XCTAssertMatch(["a"], [.start, "a", .end])
        XCTAssertMatch(["a"], [.start, .anySequence, .end])
        XCTAssertNoMatch(["a"], [.start, "b", .end])
        XCTAssertNoMatch(["a"], ["a", .start])

        XCTAssertMatch(["a", "c"], ["a", .anySequence, "c"])
        XCTAssertMatch(["a", "b", "c"], ["a", .anySequence, "c"])
        XCTAssertMatch(["a", "b", "b", "c"], ["a", .anySequence, "c"])
    }
}

@Suite fileprivate struct TaskCheckingTests: CoreBasedTests {
    @Test(.requireSDKs(.host)) 
    func ensureTaskBelongToCorrectBuild() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace("TestWorkspace", sourceRoot: tmpDir, projects: [
                TestProject("TestProject",
                    groupTree: TestGroup("Root", children: [TestFile("test.c")]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CODE_SIGN_IDENTITY": "-",
                            ]),
                    ],
                    targets: [
                        TestStandardTarget("TestTarget", type: .commandLineTool, buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("test.c")
                            ])
                        ])
                    ])
                ])

            let core = try await getCore()
            let buildA = try TaskConstructionTester(core, testWorkspace)
            try await buildA.checkBuild(runDestination: .host) { outerResults in
                let tasks = outerResults.getTasks(.matchRuleItem("CompileC"))
                let buildB = try TaskConstructionTester(core, testWorkspace)
                await buildB.checkBuild(runDestination: .host) { results in
                    // This is not a not a known issue but rather an expected failure
                    withKnownIssue("Task does not belong to the current build") {
                        try results.checkTaskFollows(#require(tasks.only), .matchRuleItem("CompileC"))
                    }
                }
            }
        }
    }
}
