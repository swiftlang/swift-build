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
import SWBMacro
import SWBProtocol

@Suite
fileprivate struct DsymGenerationBuildOperationTests: CoreBasedTests {
    /// Test that dsymutil task doesn't run on second (null) build.
    @Test(.requireSDKs(.macOS))
    func dSYMNullBuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles", path: "Sources",
                            children: [
                                TestFile("main.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "DEBUG_INFORMATION_FORMAT" : "dwarf-with-dsym",
                                    "DEPLOYMENT_POSTPROCESSING": "YES",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.c"])]),
                        ])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/main.c")) { stream in
                stream <<< "int a = 5;"
            }

            let debug = BuildParameters(configuration: "Debug")

            // Check the initial build.
            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { _ in }

            // Check that the next build is null.
            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }
                results.checkNoTask()
            }

            // Make a change and expect dsym task to be re-run.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/main.c"), waitForNewTimestamp: true) { stream in
                stream <<< "int a = 6;"
            }

            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkTask(.matchRuleType("Ld")) { _ in }
                results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                results.checkTask(.matchRuleType("GenerateDSYMFile")) { _ in }
                results.checkTask(.matchRuleType("Strip")) { _ in }
                let sdkImportsEnabled = results.buildRequestContext.getCachedSettings(debug, target: try #require(tester.workspace.projects.first?.targets.first)).globalScope.evaluate(BuiltinMacros.ENABLE_SDK_IMPORTS)
                if try await supportsSDKImports, sdkImportsEnabled {
                    results.checkTask(.matchRuleType("ProcessSDKImports")) { _ in }
                }
                results.checkNoTask()
            }

            // Check that the next build is null.
            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }
                results.checkNoTask()
            }
        }
    }

    /// Test that when the target is configured for the dSYM to accompany the product on an install build, that if the dSYM gets regenerated then it also gets copied to the accompanying location.
    @Test(.requireSDKs(.macOS))
    func dSYMAccompaniesProductRebuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles", path: "Sources",
                            children: [
                                TestFile("main.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "DEBUG_INFORMATION_FORMAT" : "dwarf-with-dsym",
                                    "DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT": "YES",
                                    "DEPLOYMENT_POSTPROCESSING": "YES",
                                    // Disable the SetOwnerAndGroup action by setting them to empty values.
                                    "INSTALL_GROUP": "",
                                    "INSTALL_OWNER": "",
                                    "DSTROOT": tmpDirPath.join("dstroot").str,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.c"])]),
                        ])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/main.c")) { stream in
                stream <<< "int a = 5;"
            }

            // Perform an initial build and check that tasks we expected to run did.
            let debug = BuildParameters(action: .install, configuration: "Debug")
            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("GenerateDSYMFile")) { _ in }
                results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("CoreFoo.framework.dSYM")) { _ in }

                results.checkNoErrors()
            }

            // Make a change to the source file and check that the dSYM was regenerated and re-copied.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/main.c"), waitForNewTimestamp: true) { stream in
                stream <<< "int a = 6;"
            }

            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("GenerateDSYMFile")) { _ in }
                results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("CoreFoo.framework.dSYM")) { _ in }

                results.checkNoErrors()
            }

            // Finally perform a build with no changes and check that no tasks were run (null build).
            try await tester.checkNullBuild(parameters: debug, runDestination: .macOS, persistent: true)
        }
    }

    /// Check that dsym waits for all its dependencies
    @Test(.requireSDKs(.macOS))
    func dSYMSwiftDependencies() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles", path: "Sources",
                            children: [
                                TestFile("foo.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "DEBUG_INFORMATION_FORMAT" : "dwarf-with-dsym",
                                    "DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT": "YES",
                                    "DEPLOYMENT_POSTPROCESSING": "YES",
                                    "SWIFT_VERSION": swiftVersion,
                                    // Don't generate bridging header to ensure eager compilation
                                    "SWIFT_OBJC_INTERFACE_HEADER_NAME": "",
                                    // Disable the SetOwnerAndGroup action by setting them to empty values.
                                    "INSTALL_GROUP": "",
                                    "INSTALL_OWNER": "",
                                    "DSTROOT": tmpDirPath.join("dstroot").str,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["foo.swift"])]),
                        ])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/foo.swift")) { stream in
                stream <<< "public struct A {}"
            }

            let debug = BuildParameters(action: .install, configuration: "Debug")
            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()

                try results.checkTask(.matchRuleType("GenerateDSYMFile")) { generateDSYMTask in
                    for rule in ["SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftEmitModule", "SwiftCompile", "Ld"] {
                        try results.checkTaskFollows(generateDSYMTask, .matchRuleType(rule))
                    }
                }

                results.checkNoErrors()
            }
        }
    }

}
