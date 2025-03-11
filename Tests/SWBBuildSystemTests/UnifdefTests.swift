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
import SWBUtil
import SWBTestSupport

@Suite(.requireXcode16())
fileprivate struct UnifdefTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func unifdefActionSignatureChange() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("A.h"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                            "COPY_HEADERS_RUN_UNIFDEF": "YES"])],
                        targets: [
                            TestStandardTarget(
                                "Empty", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try tester.fs.createDirectory(SRCROOT, recursive: true)
            try tester.fs.write(SRCROOT.join("A.h"), contents: """
            #if FOO
            void f(void);
            #endif

            #if BAR
            void g(void);
            #endif
            """)

            // Check the initial build.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["COPY_HEADERS_UNIFDEF_FLAGS": "-DFOO"]), runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("Unifdef")) { _ in }
            }

            // The second build should be null.
            try await tester.checkNullBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["COPY_HEADERS_UNIFDEF_FLAGS": "-DFOO"]), runDestination: .macOS, persistent: true)

            // Changing unifdef's flags should cause it to rerun.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["COPY_HEADERS_UNIFDEF_FLAGS": "-DBAR"]), runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("Unifdef")) { _ in }
            }
        }
    }
}
