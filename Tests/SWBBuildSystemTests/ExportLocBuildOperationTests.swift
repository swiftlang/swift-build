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
fileprivate struct ExportLocBuildOperationTests: CoreBasedTests {
    // Regression test for rdar://108867135 (SEED: Exporting localizations fails when a framework depends on another one)
    @Test(.requireSDKs(.macOS))
    func locExportBuildsHeaders() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.h"),
                                TestFile("file.c"),
                                TestFile("file.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "DependentFramework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.swift"]),
                                    TestFrameworksBuildPhase(["Framework.framework"])
                                ], dependencies: ["Framework"]),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                        "MODULEMAP_FILE_CONTENTS": "framework module Framework { header \"file.h\" }"
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                    TestHeadersBuildPhase([TestBuildFile("file.h", headerVisibility: .public)])
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                void foo(void) {};
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.h")) { stream in
                stream <<<
                """
                void foo(void);
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.swift")) { stream in
                stream <<<
                """
                import Framework
                func bar() {
                    foo()
                }
                """
            }

            let stringsDir = tmpDirPath.join("strings")
            try tester.fs.createDirectory(stringsDir, recursive: true)

            // Ensure we build the headers component in a localization export build.
            try await tester.checkBuild(parameters: BuildParameters(action: .exportLoc, configuration: "Debug", overrides: ["SWIFT_EMIT_LOC_STRINGS": "YES", "STRINGSDATA_DIR": stringsDir.str]), runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("CpHeader"), .matchRuleItemPattern(.suffix("file.h")))
                results.checkNoDiagnostics()
            }
        }
    }

    // Regression test for rdar://108867135 (SEED: Exporting localizations fails when a framework depends on another one)
    @Test(.requireSDKs(.macOS))
    func locExportGeneratesIntermediateStubs() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "DependentFramework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.swift"]),
                                    TestFrameworksBuildPhase(["Framework.framework"])
                                ], dependencies: ["Framework"]),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file2.swift"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.swift")) { stream in
                stream <<<
                """
                public func foo() {}
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.swift")) { stream in
                stream <<<
                """
                import Framework
                func bar() {
                    foo()
                }
                """
            }

            let stringsDir = tmpDirPath.join("strings")
            try tester.fs.createDirectory(stringsDir, recursive: true)

            // Perform a regular debug build for the active arch, then an exportLoc build which will build for all archs. Unless the export log build rebuilds the intermediate TBD, the dependent framework will fail to link.
            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ONLY_ACTIVE_ARCH": "YES"]), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try await tester.checkBuild(parameters: BuildParameters(action: .exportLoc, configuration: "Debug", overrides: ["SWIFT_EMIT_LOC_STRINGS": "YES", "ONLY_ACTIVE_ARCH": "NO"]), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
