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

import class Foundation.ProcessInfo

import Testing

import SWBCore
import SWBTestSupport
import SWBUtil

import SWBTaskExecution
import SWBProtocol

@Suite
fileprivate struct StaleFileRemovalTests: CoreBasedTests {
    /// Test that macOS and DriverKit stale file removal tasks don't stomp on each other, since they use the same "platform".
    @Test(.requireSDKs(.driverKit))
    func macOSDriverKitConflict() async throws {

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
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                contents <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDKROOT": "macosx"]), runDestination: .macOS, persistent: true) { results in
                #expect(tester.fs.exists(SRCROOT.join("build/Debug/Framework.framework/Framework")))
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDKROOT": "driverkit"]), runDestination: .macOS, persistent: true) { results in
                #expect(tester.fs.exists(SRCROOT.join("build/Debug/Framework.framework/Framework")))
                #expect(tester.fs.exists(SRCROOT.join("build/Debug-driverkit/Framework.framework/Framework")))
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDKROOT": "macosx"]), runDestination: .macOS, persistent: true) { results in
                #expect(tester.fs.exists(SRCROOT.join("build/Debug/Framework.framework/Framework")))
                #expect(tester.fs.exists(SRCROOT.join("build/Debug-driverkit/Framework.framework/Framework")))
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS), .requireClangFeatures(.vfsstatcache), .enabled(if: ProcessInfo.processInfo.isRunningUnderFilesystemCaseSensitivityIOPolicy, "Requires running under case-sensitive I/O policy"), .requireLocalFileSystem(.macOS, .iOS))
    func statCachesExcludedFromStaleFileRemoval() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let cacheDir = tmpDirPath.join("SDKStatCaches")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "auto",
                                    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                contents <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDK_STAT_CACHE_DIR": cacheDir.str]), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                try #expect(localFS.listdir(cacheDir.join("SDKStatCaches.noindex")).count == 1)
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDK_STAT_CACHE_DIR": cacheDir.str]), runDestination: .iOS, persistent: true) { results in
                results.checkNoDiagnostics()
                try #expect(localFS.listdir(cacheDir.join("SDKStatCaches.noindex")).count == 2)
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDK_STAT_CACHE_DIR": cacheDir.str]), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                try #expect(localFS.listdir(cacheDir.join("SDKStatCaches.noindex")).count == 2)
            }
        }
    }

    /// Ensure that different build actions do not trigger stale file removal.
    @Test(.requireSDKs(.macOS))
    func installHeadersStaleFileRemoval() async throws {
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
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "macosx",
                                    "DSTROOT": tmpDirPath.join("dstroot").str,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                contents <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                #expect(tester.fs.exists(SRCROOT.join("build/Debug/Framework.framework/Framework")))
            }

            try await tester.checkBuild(parameters: BuildParameters(action: .installHeaders, configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoStaleFileRemovalNotes()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func switchingBetweenSanitizerModes() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "shared", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["shared.m"]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/shared.m")) { contents in
                contents <<< "int number = 1;\n"
            }

            let excludingTypes = Set([
                "Copy", "Touch", "Gate", "MkDir", "WriteAuxiliaryFile", "SymLink", "CreateBuildDirectory",
                "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "ClangStatCache"
            ])

            let sanitizerCombinations = [
                "ENABLE_ADDRESS_SANITIZER",
                "ENABLE_THREAD_SANITIZER",
                "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER"
            ].combinationsWithoutRepetition

            var previousBuildParameters = [BuildParameters]()

            for combination in sanitizerCombinations {
                // Skip combinations with asan and tsan, since they're invalid to the compiler.
                if combination.contains("ENABLE_ADDRESS_SANITIZER") && combination.contains("ENABLE_THREAD_SANITIZER") {
                    continue
                }

                let overrides = combination.reduce(into: [String:String]()) { $0[$1] = "YES" }
                let parameters = BuildParameters(configuration: "Debug", overrides: overrides)

                // Try build with new combination of sanitizers
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("CompileC")) { _ in }
                    results.checkTask(.matchRuleType("Libtool")) { _ in }
                    results.consumeTasksMatchingRuleTypes(excludingTypes)
                    results.checkNoTask()
                }

                // Check that we get a null build when using same parameters
                try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true)

                for previousParameters in previousBuildParameters {
                    // Try build with all previous parameters to ensure that compilation doesn't happen again for them
                    try await tester.checkBuild(parameters: previousParameters, runDestination: .macOS, persistent: true) { results in
                        results.checkTask(.matchRuleType("Libtool")) { _ in }
                        results.consumeTasksMatchingRuleTypes(excludingTypes)
                        results.checkNoTask()
                    }
                }

                previousBuildParameters.append(parameters)
            }
        }
    }
}

fileprivate extension Array {
    var combinationsWithoutRepetition: [[Element]] {
        guard !isEmpty else { return [[]] }
        return Array(self[1...]).combinationsWithoutRepetition.flatMap { [$0, [self[0]] + $0] }
    }
}
