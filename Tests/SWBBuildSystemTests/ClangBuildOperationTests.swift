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
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct ClangBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func headerDependenciesOnSystemModuleOutsideSysroot() async throws {

        // This is a regression test for an implicit modules-only issue, but we want to primarily verify explicit modules work correctly going forward.
        for enableExplicitModules in [true, false] {
            try await withTemporaryDirectory { tmpDirPath in
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                children: [
                                    TestFile("Framework.h"),
                                    TestFile("Shared.h"),
                                    TestFile("Shared.m"),
                                    TestFile("Framework2.h"),
                                    TestFile("Shared2.h"),
                                    TestFile("Shared2.m"),
                                ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "CLANG_ENABLE_EXPLICIT_MODULES": enableExplicitModules ? "YES" : "NO",
                                    "RECORD_SYSTEM_HEADER_DEPENDENCIES_OUTSIDE_SYSROOT": "YES",
                                ])],
                            targets: [
                                TestStandardTarget(
                                    "Framework",
                                    type: .framework,
                                    buildConfigurations: [TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "DEFINES_MODULE": "YES",
                                        ])],
                                    buildPhases: [
                                        TestSourcesBuildPhase(["Shared.m"]),
                                        TestHeadersBuildPhase([
                                            TestBuildFile("Framework.h", headerVisibility: .public),
                                            TestBuildFile("Shared.h", headerVisibility: .public),
                                        ]),
                                        TestFrameworksBuildPhase(["Framework2.framework"]),
                                    ], dependencies: ["Framework2"]),
                                TestStandardTarget(
                                    "Framework2",
                                    type: .framework,
                                    buildConfigurations: [TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "DEFINES_MODULE": "YES",
                                            "MODULEMAP_FILE_CONTENTS": """
                                        framework module Framework2 [system] {
                                            umbrella header \"Framework2.h\"
                                            export *
                                        }
                                        """
                                        ])],
                                    buildPhases: [
                                        TestSourcesBuildPhase(["Shared2.m"]),
                                        TestHeadersBuildPhase([
                                            TestBuildFile("Framework2.h", headerVisibility: .public),
                                            TestBuildFile("Shared2.h", headerVisibility: .public),
                                        ]),
                                    ]),
                            ])])

                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                    stream <<<
            """
            #include <Framework/Framework.h>

            void test() {
                NSLog(@"%@", [[Shared alloc] init]);
            }

            """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                    stream <<<
            """
            #include <Framework/Shared.h>
            """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                    stream <<<
            """
            #include <Foundation/Foundation.h>
            #include <Framework2/Framework2.h>
            @interface Shared: Shared2 {}
            @end

            """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                    stream <<<
            """
            #include "Shared.h"
            @implementation Shared {}
            @end
            """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework2.h")) { stream in
                    stream <<<
            """
            #include <Framework2/Shared2.h>
            """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared2.h")) { stream in
                    stream <<<
            """
            #include <Foundation/Foundation.h>
            @interface Shared2: NSObject {}
            @end

            """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared2.m")) { stream in
                    stream <<<
            """
            #include "Shared2.h"
            @implementation Shared2 {}
            @end
            """
                }

                // Clean build
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    results.checkNoDiagnostics()
                }

                // Change the header in the system module
                try tester.fs.touch(testWorkspace.sourceRoot.join("aProject/Shared2.h"))

                // The dependency of the system module outside the sysroot should recompile.
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    results.checkNoDiagnostics()
                    results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("Shared.m")))
                }
            }
        }
    }
}
