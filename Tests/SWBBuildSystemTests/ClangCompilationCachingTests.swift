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
import SWBMacro
import SWBProtocol
import SWBTaskExecution
import SWBTestSupport
import SWBUtil

@Suite(.skipHostOS(.windows, "Windows platform has no CAS support yet"),
       .requireDependencyScannerPlusCaching, .requireXcode26())
fileprivate struct ClangCompilationCachingTests: CoreBasedTests {
    let canUseCASPlugin: Bool
    let canUseCASPruning: Bool
    let canCheckCASUpToDate: Bool

    init() async throws {
        let options = try await casOptions()
        canUseCASPlugin = options.canUseCASPlugin
        canUseCASPruning = options.canUseCASPruning
        canCheckCASUpToDate = options.canCheckCASUpToDate
    }

    @Test(.requireSDKs(.macOS))
    func assembly() async throws {
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
                                TestFile("file.s"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.s"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.s")) { stream in
                stream <<<
                """
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"))
                results.checkedWarnings = true
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingCppModules() async throws {
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
                                TestFile("t.cpp"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "Aggregate",
                                dependencies: [
                                    "Textual",
                                    "TextualWithFMod",
                                    "CppModules",
                                ]),
                            TestStandardTarget(
                                "Textual",
                                type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "CLANG_ENABLE_MODULES": "NO",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["t.cpp"]),
                                ]),
                            TestStandardTarget(
                                "TextualWithFMod",
                                type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "CLANG_ENABLE_MODULES": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["t.cpp"]),
                                ]),
                            TestStandardTarget(
                                "CppModules",
                                type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "CLANG_ENABLE_MODULES": "YES",
                                        "OTHER_CFLAGS": "$(inherited) -fcxx-modules",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["t.cpp"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/t.cpp")) { stream in
                stream <<<
                """
                void foo(void) {}
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                _ = results.checkTask(.matchTargetName("Textual"), .matchRuleType("ScanDependencies")) { $0 }
                _ = results.checkTask(.matchTargetName("TextualWithFMod"), .matchRuleType("ScanDependencies")) { $0 }
                results.checkNoTask(.matchTargetName("CppModules"), .matchRuleType("ScanDependencies"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingBasic() async throws {
        try await testCachingBasic(usePlugin: false, runDestination: .macOS)
    }

    @Test(.requireSDKs(.macOS), .requireCASPlugin)
    func cachingBasicPlugin() async throws {
        try await testCachingBasic(usePlugin: true, runDestination: .macOS)
    }

    @Test(.requireSDKs(.iOS), .requireCASPlugin)
    func cachingPluginOniOSPlatform() async throws {
        try await testCachingBasic(usePlugin: true, runDestination: .iOS)
    }

    func testCachingBasic(usePlugin: Bool, runDestination: SWBProtocol.RunDestinationInfo) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            var buildSettings: [String: String] = [
                "SDKROOT": runDestination.sdk,
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                "CLANG_ENABLE_MODULES": "NO",
                "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
            ]
            if usePlugin {
                buildSettings["COMPILATION_CACHE_ENABLE_PLUGIN"] = "YES"
            }
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
                            buildSettings: buildSettings)],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let rawUserInfo = tester.userInfo

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            let metricsEnv = { (suffix: String) in ["SWIFTBUILD_METRICS_PATH": tmpDirPath.join("Test/aProject/build/XCBuildData/metrics-\(suffix).json").str] }

            tester.userInfo = rawUserInfo.withAdditionalEnvironment(environment: metricsEnv("one"))
            try await tester.checkBuild(
                runDestination: runDestination,
                persistent: true
            ) { results in
                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }

                // Make sure scanning happens before compilation...
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                results.checkNote("0 hits / 1 cacheable task (0%)")
                results.checkCompileCacheMiss(compileTask)
                results.checkNoDiagnostics()
            }

            func readMetrics(_ suffix: String) throws -> String {
                try tester.fs.read(tmpDirPath.join("Test/aProject/build/XCBuildData/metrics-\(suffix).json")).asString
            }
            #expect(try readMetrics("one") == #"{"global":{"clangCacheHits":0,"clangCacheMisses":1,"swiftCacheHits":0,"swiftCacheMisses":0},"tasks":{"CompileC":{"cacheMisses":1,"headerDependenciesNotValidatedTasks":1,"moduleDependenciesNotValidatedTasks":1}}}"#)

            let CASConfigPath = tmpDirPath.join("Test/aProject/build/aProject.build/Debug\(runDestination == .macOS ? "": "-" + runDestination.platform)/Library.build/.cas-config")

            if usePlugin {
                let content = try Regex("\"CASPath\":.*\"PluginPath\"")
                #expect(try tester.fs.read(CASConfigPath).asString.contains(content))
            } else {
                #expect(try tester.fs.read(CASConfigPath).asString.contains("\"CASPath\":"))
            }

            // Touch the source file to trigger a new scan.
            try await tester.fs.updateTimestamp(testWorkspace.sourceRoot.join("aProject/file.c"))

            tester.userInfo = rawUserInfo.withAdditionalEnvironment(environment: metricsEnv("two"))
            try await tester.checkBuild(
                runDestination: runDestination,
                persistent: true
            ) { results in
                if tester.fs.fileSystemMode == .checksumOnly  {
                    // Updating timestamp of aProject/file.c will not re-trigger a "ScanDependencies" task
                } else {
                    let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }

                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }

                    // Make sure scanning happens before compilation.
                    results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                    results.checkNote("1 hit / 1 cacheable task (100%)")
                    results.checkCompileCacheHit(compileTask)
                }
                results.checkNoDiagnostics()
            }
            #expect(try readMetrics("two") == #"{"global":{"clangCacheHits":1,"clangCacheMisses":0,"swiftCacheHits":0,"swiftCacheMisses":0},"tasks":{"CompileC":{"cacheHits":1,"headerDependenciesNotValidatedTasks":1,"moduleDependenciesNotValidatedTasks":1}}}"#)

            // Modify the source file to trigger a cache miss.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1000;
                """
            }

            tester.userInfo = rawUserInfo.withAdditionalEnvironment(environment: metricsEnv("three"))
            try await tester.checkBuild(
                runDestination: runDestination,
                persistent: true
            ) { results in
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                results.checkCompileCacheMiss(compileTask)
                results.checkNoDiagnostics()
            }
            #expect(try readMetrics("three") == #"{"global":{"clangCacheHits":0,"clangCacheMisses":1,"swiftCacheHits":0,"swiftCacheMisses":0},"tasks":{"CompileC":{"cacheMisses":1,"headerDependenciesNotValidatedTasks":1,"moduleDependenciesNotValidatedTasks":1}}}"#)

            // Return to the original source -> should still be a hit.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            tester.userInfo = rawUserInfo.withAdditionalEnvironment(environment: metricsEnv("four"))
            try await tester.checkBuild(
                runDestination: runDestination,
                persistent: true
            ) { results in
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                results.checkCompileCacheHit(compileTask)
                results.checkNoDiagnostics()
            }
            #expect(try readMetrics("four") == #"{"global":{"clangCacheHits":1,"clangCacheMisses":0,"swiftCacheHits":0,"swiftCacheMisses":0},"tasks":{"CompileC":{"cacheHits":1,"headerDependenciesNotValidatedTasks":1,"moduleDependenciesNotValidatedTasks":1}}}"#)

            // The cache should normally persist after the build.
            #expect(tester.fs.exists(tmpDirPath.join("CompilationCache")))
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachePath() async throws {

        try await withTemporaryDirectory { tmpDirPath in
            let derivedDataPath = tmpDirPath.join("derived-data")
            let cchrootPath = tmpDirPath.join("cchroot")

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
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "CCHROOT": cchrootPath.str,
                                "CLANG_ENABLE_MODULES": "NO",
                                "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
                                "EMIT_FRONTEND_COMMAND_LINES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            do {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                let arena = ArenaInfo.buildArena(derivedDataRoot: derivedDataPath)
                let parameters = BuildParameters(action: .build, configuration: "Debug", arena: arena)

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: false) { results in
                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                    results.checkTaskOutput(compileTask) { compileOutput in
                        XCTAssertMatch(compileOutput.stringValue, .contains("-fcas-path \(derivedDataPath.str)/"))
                    }
                }
            }

            do {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                try await tester.checkBuild(runDestination: .macOS) { results in
                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                    results.checkTaskOutput(compileTask) { compileOutput in
                        XCTAssertMatch(compileOutput.stringValue, .contains("-fcas-path \(cchrootPath.str)/"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingFineGrainedOutputsDisabled() async throws {
        let buildSettings = [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CLANG_ENABLE_COMPILE_CACHE": "YES",
            "CLANG_CACHE_FINE_GRAINED_OUTPUTS": "NO",
            "CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION": "NO",
            "EMIT_FRONTEND_COMMAND_LINES": "YES",
        ]

        try await testCachingFineGrainedOutputsBasicNoMatch(buildSettings: buildSettings)
    }

    @Test(.requireSDKs(.macOS))
    func cachingFineGrainedOutputsCompileCacheDisabled() async throws {
        let buildSettings = [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CLANG_ENABLE_COMPILE_CACHE": "NO",
            "CLANG_CACHE_FINE_GRAINED_OUTPUTS": "YES",
            "CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION": "YES",
            "EMIT_FRONTEND_COMMAND_LINES": "YES",
        ]

        try await testCachingFineGrainedOutputsBasicNoMatch(buildSettings: buildSettings)
    }

    func testCachingFineGrainedOutputsBasicNoMatch(buildSettings: [String: String]) async throws {

        try await withTemporaryDirectory { tmpDirPath in
            let derivedDataPath = tmpDirPath.join("derived-data")

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
                            buildSettings: buildSettings)],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            do {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                let arena = ArenaInfo.buildArena(derivedDataRoot: derivedDataPath)
                let parameters = BuildParameters(action: .build, configuration: "Debug", arena: arena)

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: false) { results in
                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                    results.checkTaskOutput(compileTask) { compileOutput in
                        XCTAssertNoMatch(compileOutput.stringValue, .contains("-fcas-backend"))
                        XCTAssertNoMatch(compileOutput.stringValue, .contains("-cas-friendly-debug-info"))
                        XCTAssertNoMatch(compileOutput.stringValue, .contains("-fcas-backend-mode\\=verify"))
                    }
                }
            }

            do {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                try await tester.checkBuild(runDestination: .macOS) { results in
                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                    results.checkTaskOutput(compileTask) { compileOutput in
                        XCTAssertNoMatch(compileOutput.stringValue, .contains("-fcas-backend"))
                        XCTAssertNoMatch(compileOutput.stringValue, .contains("-cas-friendly-debug-info"))
                        XCTAssertNoMatch(compileOutput.stringValue, .contains("-fcas-backend-mode\\=verify"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingFineGrainedOutputsNotSet() async throws {
        let buildSettings = [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CLANG_ENABLE_COMPILE_CACHE": "YES",
            "EMIT_FRONTEND_COMMAND_LINES": "YES",
        ]

        try await testCachingFineGrainedOutputsBasicMatch(buildSettings: buildSettings, checkVerification: false)
    }

    @Test(.requireSDKs(.macOS))
    func cachingFineGrainedOutputsSet() async throws {
        let buildSettings = [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CLANG_ENABLE_COMPILE_CACHE": "YES",
            "CLANG_CACHE_FINE_GRAINED_OUTPUTS": "YES",
            "EMIT_FRONTEND_COMMAND_LINES": "YES",
        ]

        try await testCachingFineGrainedOutputsBasicMatch(buildSettings: buildSettings, checkVerification: false)
    }

    @Test(.requireSDKs(.macOS))
    func cachingFineGrainedOutputsVerifySet() async throws {
        let buildSettings = [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CLANG_ENABLE_COMPILE_CACHE": "YES",
            "CLANG_CACHE_FINE_GRAINED_OUTPUTS": "YES",
            "CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION": "YES",
            "EMIT_FRONTEND_COMMAND_LINES": "YES",
        ]

        try await testCachingFineGrainedOutputsBasicMatch(buildSettings: buildSettings, checkVerification: true)
    }

    func testCachingFineGrainedOutputsBasicMatch(buildSettings: [String: String], checkVerification: Bool) async throws {

        try await withTemporaryDirectory { tmpDirPath in
            let derivedDataPath = tmpDirPath.join("derived-data")

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
                            buildSettings: buildSettings)],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            do {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                let arena = ArenaInfo.buildArena(derivedDataRoot: derivedDataPath)
                let parameters = BuildParameters(action: .build, configuration: "Debug", arena: arena)

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: false) { results in
                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                    results.checkTaskOutput(compileTask) { compileOutput in
                        XCTAssertMatch(compileOutput.stringValue, .contains("-fcas-backend"))
                        XCTAssertMatch(compileOutput.stringValue, .contains("-cas-friendly-debug-info"))
                        if checkVerification {
                            XCTAssertMatch(compileOutput.stringValue, .contains("-fcas-backend-mode\\=verify"))
                        }
                    }
                }
            }

            do {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                try await tester.checkBuild(runDestination: .macOS) { results in
                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                    results.checkTaskOutput(compileTask) { compileOutput in
                        XCTAssertMatch(compileOutput.stringValue, .contains("-fcas-backend"))
                        XCTAssertMatch(compileOutput.stringValue, .contains("-cas-friendly-debug-info"))
                        if checkVerification {
                            XCTAssertMatch(compileOutput.stringValue, .contains("-fcas-backend-mode\\=verify"))
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingBlockList() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        try await withTemporaryDirectory { tmpDirPath in
            let blockListFilePath = tmpDirPath.join("clang-caching.json")
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
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                "BLOCKLISTS_PATH": tmpDirPath.str,
                                "CLANG_ENABLE_MODULES": "NO",
                                "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
                                "EMIT_FRONTEND_COMMAND_LINES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            do {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                try await tester.fs.writeFileContents(blockListFilePath) { file in
                    file <<<
                            """
                            {
                                "KnownFailures": []
                            }
                            """
                }

                try await tester.checkBuild(runDestination: .macOS) { results in
                    results.checkTaskExists(.matchRuleType("ScanDependencies"))
                    results.checkTask(.matchRuleType("CompileC")) { compileTask in
                        results.checkTaskOutput(compileTask) { output in
                            XCTAssertMatch(output.stringValue, .contains("-fcas-path"))
                        }
                    }
                    results.checkNoErrors()
                }
            }

            do {
                // Construct a custom core to test project identity based matching
                let core = try await Self.makeCore(registerExtraPlugins: { pluginManager in
                    struct TestSettingsBuilderExtension: SettingsBuilderExtension {
                        func matchesAnyProjectIdentities(scope: MacroEvaluationScope, projectIdentities: Set<String>) -> Bool {
                            projectIdentities.contains(scope.evaluate(BuiltinMacros.PROJECT_NAME))
                        }
                    }
                    pluginManager.register(TestSettingsBuilderExtension(), type: SettingsBuilderExtensionPoint.self)
                })

                let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<< "void foo(void) {}"
                }

                try await tester.fs.writeFileContents(blockListFilePath) { file in
                    file <<<
                            """
                            {
                                "KnownFailures": ["aProject"]
                            }
                            """
                }

                let buildParameters = BuildParameters(configuration: "Debug",
                                                      // Hack to reset the build system's cache of the `CommandLineToolSpecInfo`,
                                                      // which caches the `ClangCachingBlockListInfo`
                                                      overrides: ["CC": clangCompilerPath.dirname.join("../bin/clang").str])
                let buildRequest = BuildRequest(parameters: buildParameters,
                                                buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: buildParameters, target: $0) }),
                                                continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

                try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest) { results in
                    results.checkNoTask(.matchRuleType("ScanDependencies"))
                    results.checkTask(.matchRuleType("CompileC")) { compileTask in
                        results.checkTaskOutput(compileTask) { output in
                            XCTAssertMatch(output.stringValue, .not(.contains("-fcas")))
                        }
                    }
                    results.checkNoErrors()
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingModulesBasic() async throws {
        try await testCachingModulesBasic(usePlugin: false)
    }

    @Test(.requireSDKs(.macOS), .requireCASPlugin)
    func cachingModulesBasicPlugin() async throws {
        try await testCachingModulesBasic(usePlugin: true)
    }

    func testCachingModulesBasic(usePlugin: Bool) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            var buildSettings: [String: String] = [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                "CLANG_ENABLE_MODULES": "YES",
                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                "DSTROOT": tmpDirPath.join("dstroot").str,
            ]
            if usePlugin {
                buildSettings["COMPILATION_CACHE_ENABLE_PLUGIN"] = "YES"
            }
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
                            buildSettings: buildSettings)],
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
                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }

                // Make sure scanning happens before compilation...
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                // ... and make sure pcms also get precompiled before compilation.
                results.checkTasks(.matchRuleType("PrecompileModule")) { pcmTasks in
                    #expect(pcmTasks.count >= 1)
                    for pcmTask in pcmTasks {
                        results.check(event: .taskHadEvent(pcmTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))
                        results.checkCompileCacheMiss(pcmTask)
                    }
                }

                results.checkCompileCacheMiss(compileTask)
                results.checkNoDiagnostics()
            }

            // Touch the source file to trigger a new scan.
            try await tester.fs.updateTimestamp(testWorkspace.sourceRoot.join("aProject/file.c"))

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                if tester.fs.fileSystemMode == .checksumOnly {
                    // Updating timestamp of aProject/file.c will not trigger "ScanDependencies" or "CompileC" tasks
                } else {
                    let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }

                    let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }

                    // Make sure scanning happens before compilation.
                    results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                    results.checkCompileCacheHit(compileTask)
                }
                // None of the pcm inputs changed, so we should not be precompiling pcms again.
                results.checkNoTask(.matchRuleType("PrecompileModule"))

                results.checkNoDiagnostics()
            }

            // Clean the build to trigger a cached build.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }

                // Make sure scanning happens before compilation...
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                // ... and make sure pcms also get precompiled before compilation.
                results.checkTasks(.matchRuleType("PrecompileModule")) { pcmTasks in
                    #expect(pcmTasks.count >= 1)
                    for pcmTask in pcmTasks {
                        results.check(event: .taskHadEvent(pcmTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))
                        results.checkCompileCacheHit(pcmTask)
                    }
                }

                results.checkCompileCacheHit(compileTask)
                results.checkNoDiagnostics()
            }

            // Modify the source file to trigger a cache miss.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1000;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                results.checkCompileCacheMiss(compileTask)
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireCASUpToDate)
    func incrementalDatabasePruningWithPrecompiledHeader() async throws {
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
                                TestFile("file1.c"),
                                TestFile("header.h"),
                                TestFile("file2.c"),
                                TestFile("file3.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                    "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                    "COMPILATION_CACHE_LIMIT_SIZE": "1",
                                    "DSTROOT": tmpDirPath.join("dstroot").str])],
                        targets: [
                            TestStandardTarget(
                                "Library1",
                                type: .staticLibrary,
                                buildPhases: [TestSourcesBuildPhase(["file1.c"])],
                                dependencies: ["Library2"]),
                            TestStandardTarget(
                                "Library2",
                                type: .staticLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "GCC_PREFIX_HEADER": "header.h",
                                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES"])],
                                buildPhases: [TestSourcesBuildPhase(["file2.c", "file3.c"])])])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file1.c")) { stream in
                stream <<< "int something = 1;"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/header.h")) { stream in
                stream <<< "typedef int my_int;"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<< "my_int something = 1;"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file3.c")) { stream in
                stream <<< "my_int something = 1;"
            }

            // Clean build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 4)
                }
                results.checkTasks(.matchRuleType("ProcessPCH")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 3)
                }
            }

            // Incremental build of a file that does not depend on the prefix header.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file1.c")) { stream in
                stream <<< "int something = 2;"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 1)
                }
            }

            // Incremental build of a file that does depend on the prefix header.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<< "my_int something = 2;"
            }
            // Despite the low CAS size limit the PCH include-tree should not get garbage collected.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 1)
                }
            }

            // Incremental build of a file that does depend on the prefix header after the CAS disappeared (or got pruned by another project build).
            #expect(tester.fs.exists(tmpDirPath.join("CompilationCache")))
            #expect(throws: Never.self) {
                try tester.fs.removeDirectory(tmpDirPath.join("CompilationCache"))
            }
            #expect(!tester.fs.exists(tmpDirPath.join("CompilationCache")))
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<< "my_int something = 3;"
            }
            // The PCH and TU include-trees got removed so the scanner needs to run again.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    // FIXME: Since file1.c and file3.c did not change, no need to compile or scan them.
                    // XCTAssertEqual(tasks.count, 2)
                    #expect(tasks.count == 4)
                }
                // FIXME: Since header.h did not change, we only need to scan it to get the include-tree. No need to actually recompile it.
                // results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkTasks(.matchRuleType("ProcessPCH")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    // FIXME: If the PCH does not get recompiled, no need to recompile file1.c or file3.c either.
                    // XCTAssertEqual(tasks.count, 1)
                    #expect(tasks.count == 3)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireCASUpToDate)
    func incrementalDatabasePruningWithModules() async throws {
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
                                TestFile("file1.c"),
                                TestFile("module.modulemap"),
                                TestFile("header.h"),
                                TestFile("file2.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                    "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                    "COMPILATION_CACHE_LIMIT_SIZE": "1",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                    "DSTROOT": tmpDirPath.join("dstroot").str])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [TestSourcesBuildPhase(["file1.c", "file2.c"])])])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file1.c")) { stream in
                stream <<< "int something = 1;"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
                """
                module M { header "header.h" }
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/header.h")) { stream in
                stream <<< "typedef int my_int;"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<<
                """
                #include "header.h"
                my_int something = 1;
                """
            }

            // Clean build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 2)
                }
                results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 2)
                }
            }

            // Incremental build of a file that does not depend on the module.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file1.c")) { stream in
                stream <<< "int something = 2;"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkNoTask(.matchRuleType("PrecompileModule"))
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 1)
                }
            }

            // Incremental build of a file that does depend on the module.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<<
                """
                #include "header.h"
                my_int something = 2;
                """
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 1)
                }
                // FIXME: It's unclear whether we're happy for the previous build to prune the results of the PrecompileModule task and re-run it again now, or whether we'd prefer for the results to never get pruned out.
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 1)
                }
            }

            // Incremental build of a file that does depend on the module after the CAS disappeared (or got pruned by another project build).
            #expect(tester.fs.exists(tmpDirPath.join("CompilationCache")))
            #expect(throws: Never.self) {
                try tester.fs.removeDirectory(tmpDirPath.join("CompilationCache"))
            }
            #expect(!tester.fs.exists(tmpDirPath.join("CompilationCache")))
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<<
                """
                #include "header.h"
                my_int something = 3;
                """
            }
            // The module include-tree, PCM and diagnostics got removed; the TU include-tree got removed too.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkNoDiagnostics()
                // FIXME: No need to scan for file1.c, its inputs and outputs are still up-to-date.
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 2)
                }
                results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in
                    #expect(tasks.count == 1)
                }
                // FIXME: No need to build file1.c, its inputs and outputs are still up-to-date.
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 2)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireCASUpToDate)
    func incrementalDatabasePruningWithPrecompiledHeaderAndModules() async throws {
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
                                TestFile("file1.c"),
                                TestFile("module.modulemap"),
                                TestFile("M.h"),
                                TestFile("header.h"),
                                TestFile("file2.c"),
                                TestFile("file3.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                    "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                    "COMPILATION_CACHE_LIMIT_SIZE": "1",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                    "DSTROOT": tmpDirPath.join("dstroot").str])],
                        targets: [
                            TestStandardTarget(
                                "Library1",
                                type: .staticLibrary,
                                buildPhases: [TestSourcesBuildPhase(["file1.c"])],
                                dependencies: ["Library2"]),
                            TestStandardTarget(
                                "Library2",
                                type: .staticLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "GCC_PREFIX_HEADER": "header.h",
                                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES"])],
                                buildPhases: [TestSourcesBuildPhase(["file2.c", "file3.c"])])])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file1.c")) { stream in
                stream <<<
                """
                int something = 1;
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
                """
                module M { header "M.h" }
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/M.h")) { stream in
                stream <<<
                """
                typedef int my_int;
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/header.h")) { stream in
                stream <<<
                """
                #include "M.h"
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<<
                """
                my_int something = 1;
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file3.c")) { stream in
                stream <<<
                """
                my_int something = 1;
                """
            }

            // Clean build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 4)
                }
                results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRuleType("ProcessPCH")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 3)
                }
            }

            // Incremental build of a file that does not depend on the prefix header.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file1.c")) { stream in
                stream <<<
                """
                int something = 2;
                """
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkNoTask(.matchRuleType("PrecompileModule"))
                results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 1)
                }
            }

            // Incremental build of a file that does depend on the prefix header.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<<
                """
                my_int something = 2;
                """
            }
            // Despite the low CAS size limit the PCH include-tree should not get garbage collected.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkNoTask(.matchRuleType("PrecompileModule"))
                results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 1)
                }
            }

            // Incremental build of a file that does depend on the prefix header after the CAS disappeared (or got pruned by another project build).
            #expect(tester.fs.exists(tmpDirPath.join("CompilationCache")))
            #expect(throws: Never.self) {
                try tester.fs.removeDirectory(tmpDirPath.join("CompilationCache"))
            }
            #expect(!tester.fs.exists(tmpDirPath.join("CompilationCache")))
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<<
                """
                my_int something = 3;
                """
            }
            // The module, PCH and TU include-trees got removed so the scanner needs to run again.
            // The module PCM got removed so the compiler needs to run again.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    // FIXME: Since file1.c and file3.c did not change, no need to compile or scan them.
                    // XCTAssertEqual(tasks.count, 2)
                    #expect(tasks.count == 4)
                }
                results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in
                    #expect(tasks.count == 1)
                }
                // FIXME: Since header.h did not change, we only need to scan it to get the include-tree. No need to actually recompile it.
                // results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkTasks(.matchRuleType("ProcessPCH")) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    // FIXME: If the PCH does not get recompiled, no need to recompile file1.c or file3.c either.
                    // XCTAssertEqual(tasks.count, 1)
                    #expect(tasks.count == 3)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingMixedModulesAndNonModules() async throws {
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
                                TestFile("file1.c"),
                                TestFile("file2.cpp"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file1.c", "file2.cpp"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file1.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.cpp")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int otherthing = 2;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 2)
                }
                let compileTaskWithModule: Task = try results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("file1.o")) { $0 }
                let compileTaskNoModule: Task = try results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("file2.o")) { $0 }

                // ... and make sure pcms also get precompiled before compilation.
                results.checkTasks(.matchRuleType("PrecompileModule")) { pcmTasks in
                    #expect(pcmTasks.count >= 1)
                    for pcmTask in pcmTasks {
                        results.check(event: .taskHadEvent(pcmTask, event: .completed), precedes: .taskHadEvent(compileTaskWithModule, event: .started))
                        results.checkCompileCacheMiss(pcmTask)
                    }
                }

                results.checkCompileCacheMiss(compileTaskWithModule)
                results.checkCompileCacheMiss(compileTaskNoModule)
                results.checkNoDiagnostics()
            }

            // Touch the source file to trigger a new scan.
            try await tester.fs.updateTimestamp(testWorkspace.sourceRoot.join("aProject/file1.c"))
            try await tester.fs.updateTimestamp(testWorkspace.sourceRoot.join("aProject/file2.cpp"))

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                if tester.fs.fileSystemMode == .checksumOnly {
                    // Updating timestamp will not trigger "ScanDependencies" and "CompileC" under .checksumOnly
                } else {
                    results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                        #expect(tasks.count == 2)
                    }
                    let compileTaskWithModule: Task = try results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("file1.o")) { $0 }
                    let compileTaskNoModule: Task = try results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("file2.o")) { $0 }

                    results.checkCompileCacheHit(compileTaskWithModule)
                    results.checkCompileCacheHit(compileTaskNoModule)
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cachingModulesWithPrecompiledHeader() async throws {
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
                                TestFile("file.c"),
                                TestFile("pch.h"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                "DSTROOT": tmpDirPath.join("dstroot").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["GCC_PREFIX_HEADER": "pch.h"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<< "int something = 1;"
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/pch.h")) { stream in
                stream <<< "#include <stdio.h>"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }
                results.checkTasks(.matchRuleType("PrecompileModule")) { pcmTasks in
                    #expect(pcmTasks.count >= 1)
                    for pcmTask in pcmTasks {
                        results.checkCompileCacheMiss(pcmTask)
                    }
                }
                results.checkTask(.matchRuleType("ProcessPCH")) { pchTask in
                    results.checkCompileCacheMiss(pchTask)
                }
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    results.checkCompileCacheMiss(compileTask)
                }
                results.checkNoDiagnostics()
            }

            // Clean the build to trigger a cached build.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("PrecompileModule")) { pcmTasks in
                    #expect(pcmTasks.count >= 1)
                    for pcmTask in pcmTasks {
                        results.checkCompileCacheHit(pcmTask)
                    }
                }
                results.checkTask(.matchRuleType("ProcessPCH")) { pchTask in
                    results.checkCompileCacheHit(pchTask)
                }
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    results.checkCompileCacheHit(compileTask)
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func implicitModules() async throws {
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
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
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
                results.checkNoTask(.matchRuleType("ScanDependencies"))
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    results.checkTaskOutput(compileTask) { output in
                        XCTAssertMatch(output.stringValue, .not(.contains("-fcas")))
                    }
                }
                results.checkWarning(.contains("Compile caching is not supported with implicit modules"))
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.depscanPrefixMap), .skipDeveloperDirectoryWithEqualSign)
    func prefixMapping() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            func buildTestWorkspace(sourceDir: Path, moduleDir: Path, _ body: (BuildOperationTester.BuildResults) async throws -> Void) async throws {
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: sourceDir,
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
                                    "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                    "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                    "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                    "HEADER_SEARCH_PATHS": "\(moduleDir.str) $DERIVED_FILE_DIR",
                                    "CLANG_ENABLE_PREFIX_MAPPING": "YES",
                                    "CLANG_OTHER_PREFIX_MAPPINGS": "\(moduleDir.str)=/^mod",
                                    "DSTROOT": tmpDirPath.join("dstroot").str,
                                    "EMIT_FRONTEND_COMMAND_LINES": "YES",
                                ])],
                            targets: [
                                TestStandardTarget(
                                    "Library",
                                    type: .staticLibrary,
                                    buildPhases: [
                                        TestShellScriptBuildPhase(name: "WriteFile", shellPath: "/bin/bash", originalObjectID: "WriteEmptyHeaderFile", contents: #"touch "${SCRIPT_OUTPUT_FILE_0}""#, inputs: [], outputs: ["$DERIVED_FILE_DIR/empty.h"]),

                                        TestSourcesBuildPhase(["file.c"]),
                                    ]),
                            ])])

                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<<
                    """
                    #include "other.h"
                    #include "empty.h"
                    void foo(void) {}
                    """
                }
                try await tester.fs.writeFileContents(moduleDir.join("other.h")) { stream in
                    stream <<<
                    """
                    int other;
                    """
                }
                try await tester.fs.writeFileContents(moduleDir.join("module.modulemap")) { stream in
                    stream <<<
                    """
                    module Other { header "other.h" }
                    """
                }

                try await tester.checkBuild(runDestination: .macOS, persistent: true, body: body)

                // Clean.
                try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            }

            func checkCommandLineCommon(output: ByteString) {
                // fails if DEVELOPER_DIR contains "=" (rdar://129434789)
                XCTAssertMatch(output.stringValue, .contains(#"-isysroot /\^sdk"#))
                XCTAssertMatch(output.stringValue, .contains(#"-resource-dir /\^toolchain/usr/lib/clang/"#))
            }
            func checkModuleCommandLine(task: Task, results: BuildOperationTester.BuildResults, name: String) {
                // The final command-line is only known to the dynamic task, but it's printed to output so we can check that.
                results.checkTaskOutput(task) { output in
                    XCTAssertMatch(output.stringValue, .or(.contains(#"\#(name)\=/\^mod"#), .contains(#"\#(name) /\^mod"#)))
                    checkCommandLineCommon(output: output)
                }
            }
            func checkTUCommandLine(task: Task, results: BuildOperationTester.BuildResults) {
                // The final command-line is only known to the dynamic task, but it's printed to output so we can check that.
                results.checkTaskOutput(task) { output in
                    checkCommandLineCommon(output: output)
                }
            }
            func checkCachingConfigFiles(_ results: BuildOperationTester.BuildResults) throws {
                try results.checkTask(.matchRuleType("WriteCASConfig")) {
                    let output = try #require($0.outputPaths.first)
                    #expect(try results.fs.read(output).asString.contains("\"CASPath\":"))
                }
                try results.checkTask(.matchRuleType("WriteCompilePrefixMap")) {
                    let output = try #require($0.outputPaths.first)
                    let matchRegex = try Regex("\"/\\^built\":.*\"/\\^mod\":.*\"/\\^sdk\":.*")
                    #expect(try results.fs.read(output).asString.contains(matchRegex))
                }
            }

            try await buildTestWorkspace(sourceDir: tmpDirPath.join("Test1"), moduleDir: tmpDirPath.join("Mod1")) { results in
                let moduleTask: Task = try results.checkTask(.matchRuleType("PrecompileModule")) { $0 }
                let tuTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                results.checkCompileCacheMiss(moduleTask)
                results.checkCompileCacheMiss(tuTask)
                results.checkNoDiagnostics()
                checkModuleCommandLine(task: moduleTask, results: results, name: "Mod1")
                checkTUCommandLine(task: tuTask, results: results)
                try checkCachingConfigFiles(results)
            }

            try await buildTestWorkspace(sourceDir: tmpDirPath.join("Test2"), moduleDir: tmpDirPath.join("Mod2")) { results in
                let moduleTask: Task = try results.checkTask(.matchRuleType("PrecompileModule")) { $0 }
                let tuTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                // Module is in a different directory, but it's canonicalized.
                results.checkCompileCacheHit(moduleTask)
                results.checkCompileCacheHit(tuTask)
                results.checkNoDiagnostics()
                checkModuleCommandLine(task: moduleTask, results: results, name: "Mod2")
                checkTUCommandLine(task: tuTask, results: results)
                try checkCachingConfigFiles(results)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cacheCleanup() async throws {
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
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                                "DSTROOT": tmpDirPath.join("dstroot").str,
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

            let parameters =  BuildParameters(configuration: "Debug", overrides: ["CCHROOT": "\(tmpDirPath.join("CCHROOT").str)"])
            let parametersCustom =  BuildParameters(configuration: "Debug", overrides:[
                "COMPILATION_CACHE_CAS_PATH": "\(tmpDirPath.join("Custom").str)",
                "COMPILATION_CACHE_LIMIT_SIZE": "100K",
            ])

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Normal build, cache persists.
                let path = tmpDirPath.join("CCHROOT/CompilationCache.noindex")
                #expect(tester.fs.exists(path))
                results.check(notContains: .activityStarted(ruleInfo: "CleanupCompileCache \(path.str)"))
                results.check(notContains: .activityEnded(ruleInfo: "CleanupCompileCache \(path.str)", status: .succeeded))

                let libClangPath = try await self.libClangPath

                results.check(contains: .activityStarted(ruleInfo: "ClangCachingPruneData \(path.str)/builtin \(libClangPath.str)"))
                results.check(contains: .activityEnded(ruleInfo: "ClangCachingPruneData \(path.str)/builtin \(libClangPath.str)", status: .succeeded))
                results.checkNote(.contains("cache miss: "))
                results.checkNoRemarks()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(parameters: parametersCustom, runDestination: .macOS, persistent: true) { results in
                // Normal build, cache persists.
                let path = tmpDirPath.join("Custom")
                #expect(tester.fs.exists(path))
                results.check(notContains: .activityStarted(ruleInfo: "CleanupCompileCache \(path.str)"))
                results.check(notContains: .activityEnded(ruleInfo: "CleanupCompileCache \(path.str)", status: .succeeded))

                if canUseCASPruning {
                    results.checkNote(.regex(try Regex("cache size \\(.*\\) larger than size limit")))
                }
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            let arena = ArenaInfo.buildArena(derivedDataRoot: tmpDirPath.join("derived-data"))
            let parametersWithDerivedData =  BuildParameters(configuration: "Debug", overrides:[
                "COMPILATION_CACHE_LIMIT_SIZE": "0",
            ], arena: arena)

            try await tester.checkBuild(parameters: parametersWithDerivedData, runDestination: .macOS, persistent: true) { results in
                // Normal build, cache persists.
                let path = tmpDirPath.join("derived-data/CompilationCache.noindex")
                #expect(tester.fs.exists(path))
                results.check(notContains: .activityStarted(ruleInfo: "CleanupCompileCache \(path.str)"))
                results.check(notContains: .activityEnded(ruleInfo: "CleanupCompileCache \(path.str)", status: .succeeded))

                let libClangPath = try await self.libClangPath

                results.check(contains: .activityStarted(ruleInfo: "ClangCachingPruneData \(path.str)/builtin \(libClangPath.str)"))
                results.check(contains: .activityEnded(ruleInfo: "ClangCachingPruneData \(path.str)/builtin \(libClangPath.str)", status: .succeeded))
                results.checkNote(.contains("cache miss: "))
                results.checkNoRemarks()
            }
        }
    }

    /// Check that scripts disable CAS directory cleanup.
    @Test(.requireSDKs(.macOS))
    func noCacheCleanupInScript() async throws {
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
                                TestFile("file.c"),
                                TestFile("generated1.c.fake-customrule"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "Script", originalObjectID: "Script", contents: "echo", inputs: [], outputs: []),
                                    TestSourcesBuildPhase([
                                        "file.c",
                                        "generated1.c.fake-customrule",
                                    ]),
                                ],
                                buildRules: [
                                    TestBuildRule(filePattern: "*.fake-customrule", script: "cp \"$INPUT_FILE_PATH\" \"${DERIVED_FILE_DIR}/${INPUT_FILE_BASE}\"", outputs: ["$(DERIVED_FILE_DIR)/$(INPUT_FILE_BASE)"])
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/generated1.c.fake-customrule")) { stream in
                stream <<< "void foo(void) {}"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                    #expect(task.environment.bindings.contains(where: { $0 == ("COMPILATION_CACHE_KEEP_CAS_DIRECTORY", "YES") }))
                    #expect(task.environment.bindings.contains(where: { $0 == ("COMPILATION_CACHE_LIMIT_SIZE", "0") }))
                }
                results.checkTask(.matchRuleType("RuleScriptExecution")) { task in
                    #expect(task.environment.bindings.contains(where: { $0 == ("COMPILATION_CACHE_KEEP_CAS_DIRECTORY", "YES") }))
                    #expect(task.environment.bindings.contains(where: { $0 == ("COMPILATION_CACHE_LIMIT_SIZE", "0") }))
                }
                results.checkWarning(.prefix("Run script build phase 'Script' will be run during every build"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func rebuildAfterEnablingCaching() async throws {
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
                                TestFile("t.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "CLANG_ENABLE_EXPLICIT_MODULES": "YES",
                                "CLANG_COMPILE_CACHE_PATH": tmpDirPath.join("CompilationCache").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Lib",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["t.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/t.c")) { stream in
                stream <<<
                """
                void foo(void) {}
                """
            }

            // Build with explicit modules scanning but without caching.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                _ = results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                _ = results.checkTask(.matchRuleType("CompileC")) { $0 }
                results.checkNoErrors()
            }

            // Re-build with caching enabled, make sure compilation tasks re-run.
            let parameters = BuildParameters(configuration: "Debug", overrides: ["CLANG_ENABLE_COMPILE_CACHE": "YES"])
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                _ = results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                _ = results.checkTask(.matchRuleType("CompileC")) { $0 }
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireCASValidation, .requireSDKs(.macOS), arguments: [
        (true, true, false),   // plugin
        (true, true, true),    // + post build
        (false, true, false),  // builtin
        (false, true, true),   // + post build
        (false, false, false), // disabled
        (false, false, true),  // + post build
    ])
    func validateCAS(usePlugin: Bool, enableCaching: Bool, includePostBuild: Bool) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let casPath = tmpDirPath.join("CompilationCache")
            var buildSettings: [String: String] = [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_ENABLE_COMPILE_CACHE": enableCaching ? "YES" : "NO",
                "CLANG_ENABLE_MODULES": "NO",
                "COMPILATION_CACHE_CAS_PATH": casPath.str,
                "DSTROOT": tmpDirPath.join("dstroot").str,
                "COMPILATION_CACHE_VALIDATE_POST_BUILD": includePostBuild ? "YES" : "NO",
            ]
            if usePlugin {
                buildSettings["COMPILATION_CACHE_ENABLE_PLUGIN"] = "YES"
            }
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
                            buildSettings: buildSettings)],
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

            let specificCAS = casPath.join(usePlugin ? "plugin" : "builtin")
            let ruleInfo = "ValidateCAS \(specificCAS.str) \(try await ConditionTraitContext.shared.llvmCasToolPath.str)"
            let ruleInfoPostBuild = "ValidateCASPostBuild \(specificCAS.str) \(try await ConditionTraitContext.shared.llvmCasToolPath.str)"

            let checkBuild = { (expectedOutput: ByteString?, expectedPostBuildOutput: ByteString?) in
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in

                    if enableCaching {
                        results.check(contains: .activityStarted(ruleInfo: ruleInfo))
                        if let expectedOutput {
                            results.check(contains: .activityEmittedData(ruleInfo: ruleInfo, expectedOutput.bytes))
                        }
                        results.check(contains: .activityEnded(ruleInfo: ruleInfo, status: .succeeded))

                        if includePostBuild {
                            results.check(contains: .activityStarted(ruleInfo: ruleInfoPostBuild))
                            if let expectedPostBuildOutput {
                                results.check(contains: .activityEmittedData(ruleInfo: ruleInfoPostBuild, expectedPostBuildOutput.bytes))
                            }
                            results.check(contains: .activityEnded(ruleInfo: ruleInfoPostBuild, status: .succeeded))
                        } else {
                            results.check(notContains: .activityStarted(ruleInfo: ruleInfoPostBuild))
                        }
                    } else {
                        results.check(notContains: .activityStarted(ruleInfo: ruleInfo))
                        results.check(notContains: .activityStarted(ruleInfo: ruleInfoPostBuild))
                    }
                    results.checkNoDiagnostics()
                }
            }

            // Ignore output for plugin CAS since it may not yet support validation.
            let validatedSuccessfully = usePlugin ? nil : ByteString("validated successfully\n")
            try await checkBuild(validatedSuccessfully, validatedSuccessfully)
            // The second build should not require validation.
            try await checkBuild("validation skipped\n", validatedSuccessfully)
            // Including clean builds.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await checkBuild("validation skipped\n", validatedSuccessfully)
        }
    }

    @Test(.requireCASValidation, .requireSDKs(.macOS))
    func validateCASRecovery() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let casPath = tmpDirPath.join("CompilationCache")
            let buildSettings: [String: String] = [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                "CLANG_ENABLE_MODULES": "NO",
                "COMPILATION_CACHE_CAS_PATH": casPath.str,
            ]
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
                            buildSettings: buildSettings)],
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

            let specificCAS = casPath.join("builtin")
            let ruleInfo = "ValidateCAS \(specificCAS.str) \(try await ConditionTraitContext.shared.llvmCasToolPath.str)"

            let checkBuild = { (expectedOutput: ByteString?) in
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    results.check(contains: .activityStarted(ruleInfo: ruleInfo))
                    if let expectedOutput {
                        results.check(contains: .activityEmittedData(ruleInfo: ruleInfo, expectedOutput.bytes))
                    }
                    results.check(contains: .activityEnded(ruleInfo: ruleInfo, status: .succeeded))
                    results.checkNoDiagnostics()
                }
            }

            // Ignore output for plugin CAS since it may not yet support validation.
            try await checkBuild("validated successfully\n")
            // Create an error and trigger revalidation by messing with the validation data.
            let dataDir = casPath.join("builtin").join("v1.1")
            let dataFile = try #require(tester.fs.listdir(dataDir).first {
                $0.hasSuffix(".data") && $0.hasPrefix("v")
            })
            try tester.fs.move(dataDir.join(dataFile), to: dataDir.join("moved"))
            try await tester.fs.writeFileContents(casPath.join("builtin/v1.validation")) { stream in
                stream <<< "0"
            }
            try await checkBuild("recovered from invalid data\n")
        }
    }

    @Test(.requireCASValidation, .requireSDKs(.macOS))
    func validateCASMultipleExec() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            let casPath = tmpDirPath.join("CompilationCache")
            let buildSettings: [String: String] = [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                "CLANG_ENABLE_MODULES": "NO",
                "COMPILATION_CACHE_CAS_PATH": casPath.str,
            ]
            let llvmCasExec = try await ConditionTraitContext.shared.llvmCasToolPath
            // Create a trivially different path. If we ever canonicalize the path it will be harder to test this.
            let llvmCasExec2 = Path("\(llvmCasExec.dirname.str)\(Path.pathSeparator)\(Path.pathSeparator)\(llvmCasExec.basename)")
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
                            buildSettings: buildSettings)],
                        targets: [
                            TestStandardTarget(
                                "Library1",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                            TestStandardTarget(
                                "Library2",
                                type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "VALIDATE_CAS_EXEC": llvmCasExec2.str,
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                            TestStandardTarget(
                                "Library3",
                                type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "VALIDATE_CAS_EXEC": llvmCasExec2.str,
                                        "COMPILATION_CACHE_VALIDATE_POST_BUILD": "YES",
                                    ])],
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

            let specificCAS = casPath.join("builtin")
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: .macOS)
            let targets = tester.workspace.allTargets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })

            try await tester.checkBuild(runDestination: .macOS, buildRequest: BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false), persistent: true) { results in
                for ruleInfo in ["ValidateCAS \(specificCAS.str) \(llvmCasExec.str)", "ValidateCAS \(specificCAS.str) \(llvmCasExec2.str)"] {
                    results.check(contains: .activityStarted(ruleInfo: ruleInfo), count: 1)
                    results.check(contains: .activityEnded(ruleInfo: ruleInfo, status: .succeeded), count: 1)
                }
                // Only second CAS has post-build validation enabled.
                let postBuildRuleInfo1 = "ValidateCASPostBuild \(specificCAS.str) \(llvmCasExec.str)"
                let postBuildRuleInfo2 = "ValidateCASPostBuild \(specificCAS.str) \(llvmCasExec2.str)"
                results.check(notContains: .activityStarted(ruleInfo: postBuildRuleInfo1))
                results.check(contains: .activityStarted(ruleInfo: postBuildRuleInfo2), count: 1)
                results.check(contains: .activityEnded(ruleInfo: postBuildRuleInfo2, status: .succeeded), count: 1)

            }
        }
    }

    @Test(.requireCASValidation, .requireSDKs(.macOS))
    func validateCASPostBuildError() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let casPath = tmpDirPath.join("CompilationCache")
            let buildSettings: [String: String] = [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                "CLANG_ENABLE_MODULES": "NO",
                "COMPILATION_CACHE_CAS_PATH": casPath.str,
                "COMPILATION_CACHE_VALIDATE_POST_BUILD": "YES",
            ]
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
                            buildSettings: buildSettings)],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                    TestShellScriptBuildPhase(name: "Script", originalObjectID: "X", contents: """
                                                              if [ -f \(tmpDirPath.join("test_file").str) ]; then
                                                                rm \(casPath.join("builtin").join("v1.1").str)/v*.data
                                                              else
                                                                touch \(tmpDirPath.join("test_file").str)
                                                              fi
                                                              """,
                                                              alwaysOutOfDate: true),
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

            let specificCAS = casPath.join("builtin")
            let ruleInfoPre = "ValidateCAS \(specificCAS.str) \(try await ConditionTraitContext.shared.llvmCasToolPath.str)"
            let ruleInfo = "ValidateCASPostBuild \(specificCAS.str) \(try await ConditionTraitContext.shared.llvmCasToolPath.str)"

            let checkBuild = { (succeeded: Bool, expectedOutput: ByteString?) in
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    // The pre-build check should succeed both times.
                    results.check(contains: .activityStarted(ruleInfo: ruleInfoPre))
                    results.check(contains: .activityEnded(ruleInfo: ruleInfoPre, status: .succeeded))

                    results.check(contains: .activityStarted(ruleInfo: ruleInfo))
                    if let expectedOutput {
                        #expect(results.events.contains(where: { event in
                            if case .activityEmittedData(ruleInfo, let data) = event {
                                return ByteString(data).contains(expectedOutput)
                            }
                            return false
                        }), "missing activity output \(expectedOutput.stringValue!)")
                    }
                    results.check(contains: .activityEnded(ruleInfo: ruleInfo, status: succeeded ? .succeeded : .failed))
                    results.checkNoDiagnostics()
                }
            }

            // First build does not corrupt the CAS, the second one does in the script phase.
            try await checkBuild(true, "validated successfully\n")
            try await checkBuild(false, "llvm-cas: validate: bad record")
        }
    }
}

extension BuildOperationTester.BuildResults {
    fileprivate func checkCompileCacheMiss(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        let found = (getDiagnosticMessageForTask(.contains("cache miss: "), kind: .note, task: task) != nil)
        guard found else {
            Issue.record("Unable to find cache miss diagnostic for task \(task)", sourceLocation: sourceLocation)
            return
        }
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache miss\n")), sourceLocation: sourceLocation)
    }

    fileprivate func checkCompileCacheHit(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        let found = (getDiagnosticMessageForTask(.contains("cache hit: "), kind: .note, task: task) != nil)
        guard found else {
            Issue.record("Unable to find cache hit diagnostic for task \(task)", sourceLocation: sourceLocation)
            return
        }
        while getDiagnosticMessageForTask(.contains("using CAS output"), kind: .note, task: task) != nil {}
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache hit\n")), sourceLocation: sourceLocation)
    }
}
