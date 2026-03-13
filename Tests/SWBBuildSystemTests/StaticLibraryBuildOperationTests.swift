//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing

import SWBCore
import SWBTestSupport
import SwiftBuildTestSupport
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct StaticLibraryBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func staticLibraryLinkingStaticLibrary() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "ConsumerProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("lib.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    // FIXME: Find a way to make these default
                                    "EXECUTABLE_PREFIX": "lib",
                                    "EXECUTABLE_PREFIX[sdk=windows*]": "",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Consumer",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["lib.c"]),
                                    TestFrameworksBuildPhase([
                                        TestBuildFile(.target("Dependency")),
                                    ]),
                                ],
                                dependencies: ["Dependency"],
                                productReferenceName: "$(EXECUTABLE_NAME)",
                            ),
                        ]
                    ),
                    TestProject(
                        "DependencyProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("dep.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    // FIXME: Find a way to make these default
                                    "EXECUTABLE_PREFIX": "lib",
                                    "EXECUTABLE_PREFIX[sdk=windows*]": "",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Dependency",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["dep.c"]),
                                ],
                                productReferenceName: "$(EXECUTABLE_NAME)",
                            ),
                        ]
                    ),
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/DependencyProject/dep.c")) {
                $0 <<< "int dep_func(void) { return 42; }\n"
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/ConsumerProject/lib.c")) {
                $0 <<< "int dep_func(void);\n"
                $0 <<< "int lib_func(void) { return dep_func(); }\n"
            }

            try await tester.checkBuild(runDestination: .host) { results in
                results.checkNoDiagnostics()
                results.checkTaskExists(.matchTargetName("Dependency"), .matchRuleType("Libtool"))
                results.checkTaskExists(.matchTargetName("Consumer"), .matchRuleType("Libtool"))
            }
        }
    }
}
