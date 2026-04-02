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
import struct Foundation.Date
import struct Foundation.URL
import struct Foundation.URLResourceValues

import Testing

import SWBCore
import SWBTestSupport
import SWBUtil

import SWBTaskExecution
import SWBProtocol
import SwiftBuildTestSupport

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

    @Test(.requireSDKs(.macOS), .requireXcode26dot4())
    func switchingBetweenSanitizerModesNew() async throws {
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
                "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER",
                "ENABLE_MEMORY_TAGGING_ADDRESS_SANITIZER"
            ].combinationsWithoutRepetition

            var previousBuildParameters = [BuildParameters]()

            for combination in sanitizerCombinations {
                // Skip combinations with (asan + tsan) or (asan + mtsan), since they're invalid to the compiler.
                if (combination.contains("ENABLE_ADDRESS_SANITIZER") && combination.contains("ENABLE_THREAD_SANITIZER")) ||
                   (combination.contains("ENABLE_ADDRESS_SANITIZER") && combination.contains("ENABLE_MEMORY_TAGGING_ADDRESS_SANITIZER"))
                {
                    continue
                }

                var overrides = combination.reduce(into: [String:String]()) { $0[$1] = "YES" }
                // Only build for the active architecture (arm64) to avoid trying to enable
                // memory-tagging address sanitizer on x86_64, which doesn't support it.
                overrides["ONLY_ACTIVE_ARCH"] = "YES"
                let parameters = BuildParameters(configuration: "Debug", overrides: overrides)

                // Try build with new combination of sanitizers. Note that memory-tagging address sanitizer is only
                // available on Apple Silicon, so this is hardcoded.
                try await tester.checkBuild(parameters: parameters, runDestination: .macOSAppleSilicon, persistent: true) { results in
                    results.checkTask(.matchRuleType("CompileC")) { _ in }
                    results.checkTask(.matchRuleType("Libtool")) { _ in }
                    results.consumeTasksMatchingRuleTypes(excludingTypes)
                    results.checkNoTask()
                }

                // Check that we get a null build when using same parameters
                try await tester.checkNullBuild(parameters: parameters, runDestination: .macOSAppleSilicon, persistent: true)

                for previousParameters in previousBuildParameters {
                    // Try build with all previous parameters to ensure that compilation doesn't happen again for them
                    try await tester.checkBuild(parameters: previousParameters, runDestination: .macOSAppleSilicon, persistent: true) { results in
                        results.checkTask(.matchRuleType("Libtool")) { _ in }
                        results.consumeTasksMatchingRuleTypes(excludingTypes)
                        results.checkNoTask()
                    }
                }

                previousBuildParameters.append(parameters)
            }
        }
    }

    /// Test that stale EagerLinkingTBDs are removed when switching between workspaces
    /// that share the same build output directory. rdar://109491531
    @Test(.requireSDKs(.macOS))
    func crossWorkspaceStaleEagerLinkingTBDRemoval() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let sharedBuildDir = tmpDirPath.join("SharedBuild")

            let projectA = TestProject(
                "ProjectA",
                sourceRoot: tmpDirPath.join("ProjectA"),
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Fwk.c"),
                        TestFile("App.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "OBJROOT": sharedBuildDir.join("Intermediates.noindex").str,
                        "SYMROOT": sharedBuildDir.join("Products").str,
                        "DSTROOT": sharedBuildDir.join("Products").str,
                    ])],
                targets: [
                    TestStandardTarget(
                        "Fwk",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["Fwk.c"]),
                        ]
                    ),
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["App.c"]),
                            TestFrameworksBuildPhase(["Fwk.framework"]),
                        ],
                        dependencies: ["Fwk"]
                    ),
                ])

            let wsA = TestWorkspace(
                "WorkspaceA",
                sourceRoot: tmpDirPath.join("wsA"),
                projects: [projectA])
            let testerA = try await BuildOperationTester(getCore(), wsA, simulated: false)

            try await testerA.fs.writeFileContents(tmpDirPath.join("ProjectA/Fwk.c")) { contents in
                contents <<< "void fwk_func(void) {}\n"
            }
            try await testerA.fs.writeFileContents(tmpDirPath.join("ProjectA/App.c")) { contents in
                contents <<< "extern void fwk_func(void);\nint main() { fwk_func(); return 0; }\n"
            }

            let eagerTBDDir = sharedBuildDir.join("Intermediates.noindex/EagerLinkingTBDs")
            try await testerA.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            #expect(localFS.isDirectory(eagerTBDDir), "EagerLinkingTBDs directory should exist after workspace A build")
            let tbdFilesAfterA = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) { return path }
                return nil
            }
            #expect(!tbdFilesAfterA.isEmpty, "EagerLinkingTBDs should contain TBD files after workspace A build")

            // Workspace B: static library, same build dir, different workspace.
            // The workspace SFR key is stable across workspace switches, so
            // llbuild's delta detects workspace A's TBDs as stale and removes them.
            let projectB = TestProject(
                "ProjectB",
                sourceRoot: tmpDirPath.join("ProjectB"),
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Bar.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "OBJROOT": sharedBuildDir.join("Intermediates.noindex").str,
                        "SYMROOT": sharedBuildDir.join("Products").str,
                        "DSTROOT": sharedBuildDir.join("Products").str,
                    ])],
                targets: [
                    TestStandardTarget(
                        "Bar",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["Bar.c"]),
                        ]
                    ),
                ])

            let wsB = TestWorkspace(
                "WorkspaceB",
                sourceRoot: tmpDirPath.join("wsB"),
                projects: [projectB])
            let testerB = try await BuildOperationTester(getCore(), wsB, simulated: false)

            try await testerB.fs.writeFileContents(tmpDirPath.join("ProjectB/Bar.c")) { contents in
                contents <<< "int bar(void) { return 0; }\n"
            }

            try await testerB.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Verify that stale EagerLinkingTBDs from workspace A were removed.
            let tbdFilesAfterB = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) { return path }
                return nil
            }
            #expect(tbdFilesAfterB.isEmpty, "Stale EagerLinkingTBDs from workspace A should be removed after workspace B build, but found: \(tbdFilesAfterB)")
        }
    }

    /// Test that rebuilding the same workspace preserves its own EagerLinkingTBDs. rdar://109491531
    @Test(.requireSDKs(.macOS))
    func sameWorkspaceRebuildPreservesEagerLinkingTBDs() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let sharedBuildDir = tmpDirPath.join("SharedBuild")

            let project = TestProject(
                "ProjectA",
                sourceRoot: tmpDirPath.join("ProjectA"),
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Fwk.c"),
                        TestFile("App.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "OBJROOT": sharedBuildDir.join("Intermediates.noindex").str,
                        "SYMROOT": sharedBuildDir.join("Products").str,
                        "DSTROOT": sharedBuildDir.join("Products").str,
                    ])],
                targets: [
                    TestStandardTarget(
                        "Fwk",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["Fwk.c"]),
                        ]
                    ),
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["App.c"]),
                            TestFrameworksBuildPhase(["Fwk.framework"]),
                        ],
                        dependencies: ["Fwk"]
                    ),
                ])

            let ws = TestWorkspace(
                "WorkspaceA",
                sourceRoot: tmpDirPath.join("wsA"),
                projects: [project])
            let tester = try await BuildOperationTester(getCore(), ws, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("ProjectA/Fwk.c")) { contents in
                contents <<< "void fwk_func(void) {}\n"
            }
            try await tester.fs.writeFileContents(tmpDirPath.join("ProjectA/App.c")) { contents in
                contents <<< "extern void fwk_func(void);\nint main() { fwk_func(); return 0; }\n"
            }

            let eagerTBDDir = sharedBuildDir.join("Intermediates.noindex/EagerLinkingTBDs")
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            let tbdFilesAfterBuild1 = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) { return path }
                return nil
            }
            #expect(!tbdFilesAfterBuild1.isEmpty, "EagerLinkingTBDs should exist after first build")

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            let tbdFilesAfterBuild2 = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) { return path }
                return nil
            }
            #expect(tbdFilesAfterBuild1 == tbdFilesAfterBuild2, "EagerLinkingTBDs should be preserved after rebuilding the same workspace")
        }
    }

    /// Test that stale EagerLinkingTBDs from a dynamic framework are removed when
    /// switching to a workspace where the same framework is static. rdar://165932649
    @Test(.requireSDKs(.macOS))
    func staleTBDRemovedWhenFrameworkSwitchesDynamicToStatic() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let sharedBuildDir = tmpDirPath.join("SharedBuild")

            // Workspace A: SharedLib as dynamic framework (generates TBD).
            let projectA = TestProject(
                "ProjectA",
                sourceRoot: tmpDirPath.join("ProjectA"),
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("SharedLib.c"),
                        TestFile("App.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "OBJROOT": sharedBuildDir.join("Intermediates.noindex").str,
                        "SYMROOT": sharedBuildDir.join("Products").str,
                        "DSTROOT": sharedBuildDir.join("Products").str,
                    ])],
                targets: [
                    TestStandardTarget(
                        "SharedLib",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["SharedLib.c"]),
                        ]
                    ),
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["App.c"]),
                            TestFrameworksBuildPhase(["SharedLib.framework"]),
                        ],
                        dependencies: ["SharedLib"]
                    ),
                ])

            let wsA = TestWorkspace(
                "WorkspaceA",
                sourceRoot: tmpDirPath.join("wsA"),
                projects: [projectA])
            let testerA = try await BuildOperationTester(getCore(), wsA, simulated: false)

            try await testerA.fs.writeFileContents(tmpDirPath.join("ProjectA/SharedLib.c")) { contents in
                contents <<< "void shared_func(void) {}\n"
            }
            try await testerA.fs.writeFileContents(tmpDirPath.join("ProjectA/App.c")) { contents in
                contents <<< "extern void shared_func(void);\nint main() { shared_func(); return 0; }\n"
            }

            let eagerTBDDir = sharedBuildDir.join("Intermediates.noindex/EagerLinkingTBDs")
            try await testerA.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            let tbdFilesAfterA = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) && path.str.contains("SharedLib") { return path }
                return nil
            }
            #expect(!tbdFilesAfterA.isEmpty, "SharedLib TBD should exist in EagerLinkingTBDs after workspace A (dynamic) build")

            // Workspace B: SharedLib as static library, same build dir, different build.db.
            // Stale TBD from workspace A should be removed.
            let projectB = TestProject(
                "ProjectB",
                sourceRoot: tmpDirPath.join("ProjectB"),
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("SharedLib.c"),
                        TestFile("App.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "OBJROOT": sharedBuildDir.join("Intermediates.noindex").str,
                        "SYMROOT": sharedBuildDir.join("Products").str,
                        "DSTROOT": sharedBuildDir.join("Products").str,
                    ])],
                targets: [
                    TestStandardTarget(
                        "SharedLib",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["SharedLib.c"]),
                        ]
                    ),
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["App.c"]),
                        ],
                        dependencies: ["SharedLib"]
                    ),
                ])

            let wsB = TestWorkspace(
                "WorkspaceB",
                sourceRoot: tmpDirPath.join("wsB"),
                projects: [projectB])
            let testerB = try await BuildOperationTester(getCore(), wsB, simulated: false)

            try await testerB.fs.writeFileContents(tmpDirPath.join("ProjectB/SharedLib.c")) { contents in
                contents <<< "int shared_func(void) { return 0; }\n"
            }
            try await testerB.fs.writeFileContents(tmpDirPath.join("ProjectB/App.c")) { contents in
                contents <<< "extern int shared_func(void);\nint main() { return shared_func(); }\n"
            }

            try await testerB.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Verify the stale SharedLib TBD was removed.
            let tbdFilesAfterB = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) && path.str.contains("SharedLib") { return path }
                return nil
            }
            #expect(tbdFilesAfterB.isEmpty, "Stale SharedLib TBD from dynamic framework should be removed after switching to static library (rdar://165932649), but found: \(tbdFilesAfterB)")
        }
    }

    /// Test that workspace SFR does not delete TBDs from other configurations.
    @Test(.requireSDKs(.macOS))
    func workspaceSFRDoesNotDeleteOtherConfigurations() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let sharedBuildDir = tmpDirPath.join("SharedBuild")

            func sharedSettings() -> [String: String] {
                return [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "OBJROOT": sharedBuildDir.join("Intermediates.noindex").str,
                    "SYMROOT": sharedBuildDir.join("Products").str,
                    "DSTROOT": sharedBuildDir.join("Products").str,
                ]
            }

            let fwkSource = tmpDirPath.join("SharedSrc/Fwk.c")
            let appSource = tmpDirPath.join("SharedSrc/App.c")
            try localFS.createDirectory(fwkSource.dirname, recursive: true)
            try localFS.write(fwkSource, contents: ByteString(encodingAsUTF8: "void fwk_func(void) {}\n"))
            try localFS.write(appSource, contents: ByteString(encodingAsUTF8: "extern void fwk_func(void);\nint main() { fwk_func(); return 0; }\n"))

            // Workspace A: builds Debug configuration.
            let projectA = TestProject(
                "ProjectA",
                sourceRoot: tmpDirPath.join("SharedSrc"),
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Fwk.c"),
                        TestFile("App.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: sharedSettings())],
                targets: [
                    TestStandardTarget(
                        "Fwk", type: .framework,
                        buildPhases: [TestSourcesBuildPhase(["Fwk.c"])]
                    ),
                    TestStandardTarget(
                        "App", type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["App.c"]),
                            TestFrameworksBuildPhase(["Fwk.framework"]),
                        ],
                        dependencies: ["Fwk"]
                    ),
                ])

            let wsA = TestWorkspace("WorkspaceA", sourceRoot: tmpDirPath.join("wsA"), projects: [projectA])
            let testerA = try await BuildOperationTester(getCore(), wsA, simulated: false)

            try await testerA.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            let eagerTBDDir = sharedBuildDir.join("Intermediates.noindex/EagerLinkingTBDs")
            let debugTBDs = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) && path.str.contains("/Debug/") { return path }
                return nil
            }
            #expect(!debugTBDs.isEmpty, "Debug EagerLinkingTBDs should exist after workspace A build")

            // Workspace B: builds Release, same shared build dir, different build.db.
            // Workspace SFR key includes the configuration, so Release SFR
            // won't touch Debug TBDs.
            let projectB = TestProject(
                "ProjectB",
                sourceRoot: tmpDirPath.join("SharedSrc"),
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Fwk.c"),
                        TestFile("App.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration("Release", buildSettings: sharedSettings())],
                targets: [
                    TestStandardTarget(
                        "Fwk", type: .framework,
                        buildPhases: [TestSourcesBuildPhase(["Fwk.c"])]
                    ),
                    TestStandardTarget(
                        "App", type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["App.c"]),
                            TestFrameworksBuildPhase(["Fwk.framework"]),
                        ],
                        dependencies: ["Fwk"]
                    ),
                ])

            let wsB = TestWorkspace("WorkspaceB", sourceRoot: tmpDirPath.join("wsB"), projects: [projectB])
            let testerB = try await BuildOperationTester(getCore(), wsB, simulated: false)

            try await testerB.checkBuild(parameters: BuildParameters(configuration: "Release"), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Debug TBDs should survive — workspace B's SFR key is for Release.
            let debugTBDsAfterRelease = try localFS.traverse(eagerTBDDir) { path -> Path? in
                if !localFS.isDirectory(path) && path.str.contains("/Debug/") { return path }
                return nil
            }
            #expect(!debugTBDsAfterRelease.isEmpty, "Debug EagerLinkingTBDs should survive after workspace B's Release build because workspace SFR key is configuration-specific")
        }
    }

    /// Test that stale pcm files in ExplicitPrecompiledModules directories are pruned after a build.
    @Test(.requireSDKs(.macOS), .requireModuleCachePruning)
    func pruneStaleExplicitPrecompiledModules() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let buildDir = tmpDirPath.join("build")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "CLANG_MODULES_PRUNE_AFTER": "345600",
                                "CLANG_MODULES_PRUNE_INTERVAL": "1",
                                "OBJROOT": buildDir.str,
                                "SYMROOT": buildDir.str,
                                "DSTROOT": buildDir.str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            let explicitModulesDir = buildDir.join("ExplicitPrecompiledModules")
            let swiftExplicitModulesDir = buildDir.join("SwiftExplicitPrecompiledModules")

            let staleDate = Date().addingTimeInterval(-500000) // ~5.8 days ago
            let freshDate = Date().addingTimeInterval(-100000) // ~1.2 days ago

            let stalePcm = explicitModulesDir.join("stale_module-DEADBEEF.pcm")
            let freshPcm = explicitModulesDir.join("fresh_module-CAFEBABE.pcm")

            try localFS.createDirectory(explicitModulesDir, recursive: true)
            try localFS.write(stalePcm, contents: ByteString(encodingAsUTF8: "stale"))
            try localFS.write(freshPcm, contents: ByteString(encodingAsUTF8: "fresh"))
            try setAccessTime(stalePcm, to: staleDate)
            try setAccessTime(freshPcm, to: freshDate)

            let staleSwiftPcm = swiftExplicitModulesDir.join("stale_swift-DEADBEEF.pcm")
            try localFS.createDirectory(swiftExplicitModulesDir, recursive: true)
            try localFS.write(staleSwiftPcm, contents: ByteString(encodingAsUTF8: "stale_swift"))
            try setAccessTime(staleSwiftPcm, to: staleDate)

            // Backdate the modules.timestamp files so the prune interval check passes.
            let oldTimestamp = Int(Date().addingTimeInterval(-100).timeIntervalSince1970)
            for dir in [explicitModulesDir, swiftExplicitModulesDir] {
                let timestampPath = dir.join("modules.timestamp")
                if localFS.exists(timestampPath) {
                    try localFS.setFileTimestamp(timestampPath, timestamp: oldTimestamp)
                }
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            #expect(!localFS.exists(stalePcm), "Stale pcm in ExplicitPrecompiledModules should be pruned")
            #expect(!localFS.exists(staleSwiftPcm), "Stale pcm in SwiftExplicitPrecompiledModules should be pruned")
            #expect(localFS.exists(freshPcm), "Fresh pcm should survive pruning")
        }
    }

    /// Test that pruning is throttled by CLANG_MODULES_PRUNE_INTERVAL.
    @Test(.requireSDKs(.macOS), .requireModuleCachePruning)
    func pruneExplicitPrecompiledModulesIntervalThrottling() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let buildDir = tmpDirPath.join("build")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "CLANG_MODULES_PRUNE_AFTER": "345600",
                                "CLANG_MODULES_PRUNE_INTERVAL": "999999",
                                "OBJROOT": buildDir.str,
                                "SYMROOT": buildDir.str,
                                "DSTROOT": buildDir.str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            let explicitModulesDir = buildDir.join("ExplicitPrecompiledModules")
            let lastPrunedPath = explicitModulesDir.join("modules.timestamp")
            #expect(localFS.exists(lastPrunedPath), "modules.timestamp should exist after first build")

            let staleDate = Date().addingTimeInterval(-500000)
            let stalePcm = explicitModulesDir.join("stale_module-DEADBEEF.pcm")
            try localFS.write(stalePcm, contents: ByteString(encodingAsUTF8: "stale"))
            try setAccessTime(stalePcm, to: staleDate)

            // modules.timestamp is recent and interval is large, so pruning should be skipped.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            #expect(localFS.exists(stalePcm), "Stale pcm should survive when pruning is throttled by interval")

            // Backdate modules.timestamp so the interval has elapsed.
            let oldTimestamp = Int(Date().addingTimeInterval(-1_000_001).timeIntervalSince1970)
            try localFS.setFileTimestamp(lastPrunedPath, timestamp: oldTimestamp)

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            #expect(!localFS.exists(stalePcm), "Stale pcm should be pruned after interval elapses")
        }
    }

    /// Test that deleting an explicit precompiled module triggers a rebuild on the next build.
    @Test(.requireSDKs(.macOS), .requireModuleCachePruning)
    func rebuildDeletedExplicitPrecompiledModule() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let buildDir = tmpDirPath.join("build")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "OBJROOT": buildDir.str,
                                "SYMROOT": buildDir.str,
                                "DSTROOT": buildDir.str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            let explicitModulesDir = buildDir.join("ExplicitPrecompiledModules")

            let pcmFiles = try localFS.traverse(explicitModulesDir) { (path: Path) -> Path? in
                if path.fileExtension == "pcm" { return path }
                return nil
            }
            #expect(!pcmFiles.isEmpty, "Build should have produced at least one PCM")

            for pcm in pcmFiles {
                try localFS.remove(pcm)
            }

            // Should detect missing PCM outputs and rebuild them.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            let pcmFilesAfterRebuild = try localFS.traverse(explicitModulesDir) { (path: Path) -> Path? in
                if path.fileExtension == "pcm" { return path }
                return nil
            }
            #expect(!pcmFilesAfterRebuild.isEmpty, "PCMs should be rebuilt after deletion")
        }
    }

    /// Test that deleting a Swift explicit precompiled module and then modifying a source file
    /// results in a successful build. The Swift driver should rescan and rebuild the missing PCMs.
    @Test(.requireSDKs(.macOS), .requireDependencyScanner)
    func rebuildDeletedSwiftPCMAfterSourceChange() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let buildDir = tmpDirPath.join("build")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": "5",
                                "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "OBJROOT": buildDir.str,
                                "SYMROOT": buildDir.str,
                                "DSTROOT": buildDir.str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.swift"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let sourceFile = testWorkspace.sourceRoot.join("aProject/file.swift")

            try await tester.fs.writeFileContents(sourceFile) { stream in
                stream <<<
                """
                import Foundation
                public let something = 1
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            let swiftExplicitModulesDir = buildDir.join("SwiftExplicitPrecompiledModules")

            let pcmFiles = try localFS.traverse(swiftExplicitModulesDir) { (path: Path) -> Path? in
                if path.fileExtension == "pcm" { return path }
                return nil
            }
            #expect(!pcmFiles.isEmpty, "Build should have produced at least one Swift explicit PCM")

            // Delete all PCMs to simulate pruning.
            for pcm in pcmFiles {
                try localFS.remove(pcm)
            }

            try await tester.fs.writeFileContents(sourceFile) { stream in
                stream <<<
                """
                import Foundation
                public let something = 2
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            let pcmFilesAfterRebuild = try localFS.traverse(swiftExplicitModulesDir) { (path: Path) -> Path? in
                if path.fileExtension == "pcm" { return path }
                return nil
            }
            #expect(!pcmFilesAfterRebuild.isEmpty, "Swift explicit PCMs should be rebuilt after source change triggers recompile")
        }
    }
}

/// Set the access time (and modification time) of a file.
private func setAccessTime(_ path: Path, to date: Date) throws {
    var url = URL(fileURLWithPath: path.str)
    var values = URLResourceValues()
    values.contentAccessDate = date
    values.contentModificationDate = date
    try url.setResourceValues(values)
}

fileprivate extension Array {
    var combinationsWithoutRepetition: [[Element]] {
        guard !isEmpty else { return [[]] }
        return Array(self[1...]).combinationsWithoutRepetition.flatMap { [$0, [self[0]] + $0] }
    }
}
