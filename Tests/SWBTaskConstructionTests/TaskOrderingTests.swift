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
import SWBTaskConstruction

import SWBTestSupport
import SWBProtocol

@Suite
fileprivate struct TaskOrderingTests: CoreBasedTests {
    /// Check the basic ordering among tasks.
    @Test(.requireSDKs(.macOS))
    func basicOrdering() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [TestFile("SourceFile.m")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "SKIP_INSTALL": "NO",
                    "DEFINES_MODULE": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "RETAIN_RAW_BINARIES": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("Ld")) { task in
                results.checkTaskFollows(task, .matchRuleType("CompileC"))
            }
            results.checkTask(.matchRuleType("Strip")) { task in
                results.checkTaskFollows(task, .matchRuleType("Ld"))
            }
            results.checkTask(.matchRuleType("SetMode")) { task in
                results.checkTaskFollows(task, .matchRuleType("Strip"))
            }
            results.checkTask(.matchRuleType("CodeSign")) { task in
                results.checkTaskFollows(task, .matchRuleType("SetMode"))
            }
        }
    }
}

