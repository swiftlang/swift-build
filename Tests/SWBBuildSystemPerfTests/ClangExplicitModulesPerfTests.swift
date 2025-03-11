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
import SWBProtocol
import SWBUtil
import SWBTestSupport

@Suite(.performance)
fileprivate struct ClangExplicitModulesPerfTests: CoreBasedTests, PerfTests {
    @Test(.requireSDKs(.macOS))
    func testDynamicTaskScaling() async throws {
        let numSources = getEnvironmentVariable("CI") != nil ? 10 : 500
        try await withTemporaryDirectory { (tmpDirPath: Path) -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: (0..<numSources).map { TestFile("file-\($0).m") } + [
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "DSTROOT": tmpDirPath.join("dstroot").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase((0..<numSources).map { TestBuildFile("file-\($0).m") }),
                                ], dependencies: ["Framework"]),
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
                                ])
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            for i in 0..<numSources {
                try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/file-\(i).m")) { stream in stream <<< """
                    #include <Framework/Framework.h>

                    void test\(i)() {
                        NSLog(@"%@", [[Shared alloc] init]);
                        }
                    """
                }
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>
                """
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            try await measure {
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    results.checkNoDiagnostics()
                }
                try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func testScanningIncrementalPerformance() async throws {
        let numSources = getEnvironmentVariable("CI") != nil ? 10 : 500
        try await withTemporaryDirectory { (tmpDirPath: Path) -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: (0..<numSources).map { TestFile("file-\($0).m") } + [
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "DSTROOT": tmpDirPath.join("dstroot").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase((0..<numSources).map { TestBuildFile("file-\($0).m") }),
                                ], dependencies: ["Framework"]),
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
                                ])
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            for i in 0..<numSources {
                try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/file-\(i).m")) { stream in stream <<< """
                    #include <Framework/Framework.h>

                    void test\(i)() {
                        NSLog(@"%@", [[Shared alloc] init]);
                        }
                    """
                }
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>
                """
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            try await measure {
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    results.checkNoDiagnostics()
                }
                try tester.fs.touch(tmpDirPath.join("Test/aProject/file-\((0..<numSources).randomElement()!).m"))
            }
        }
    }
}
