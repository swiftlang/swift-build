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

import SWBTaskExecution
import SWBProtocol

@Suite(.requireSwiftFeatures(.compilationCaching),
       .skipInXcodeCloud("flaky tests"))
fileprivate struct SwiftCompilationCachingTests: CoreBasedTests {
    @Test(.requireSDKs(.iOS))
    func swiftCachingSimple() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("App.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "arm64",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "iphoneos",
                                    "SWIFT_VERSION": swiftVersion,
                                    "DEBUG_INFORMATION_FORMAT": "dwarf",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    "SWIFT_ENABLE_COMPILE_CACHE": "YES",
                                    "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                                    "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                    "DSTROOT": tmpDirPath.join("dstroot").str,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Application",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "App.swift",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/App.swift")) {
                $0 <<< "@main struct Main { static func main() { } }\n"
            }

            let metricsEnv = { (suffix: String) in ["SWIFTBUILD_METRICS_PATH": tmpDirPath.join("Test/aProject/build/XCBuildData/metrics-\(suffix).json").str] }

            func readMetrics(_ suffix: String) throws -> String {
                try tester.fs.read(tmpDirPath.join("Test/aProject/build/XCBuildData/metrics-\(suffix).json")).asString
            }

            let rawUserInfo = tester.userInfo
            tester.userInfo = rawUserInfo.withAdditionalEnvironment(environment: metricsEnv("one"))

            var numCompile = 0
            try await tester.checkBuild(runDestination: .anyiOSDevice, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes()
                results.consumeTasksMatchingRuleTypes(["CopySwiftLibs", "GenerateDSYMFile", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "Touch", "Validate", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "SwiftDriver Compilation Requirements", "Copy", "Ld", "CompileC", "SwiftMergeGeneratedHeaders", "ProcessSDKImports"])

                results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftDriver", "Application", "normal", "arm64", "com.apple.xcode.tools.swift.compiler"])) { task in
                    task.checkCommandLineMatches([.suffix("swiftc"), .anySequence, "-cache-compile-job", .anySequence])
                }

                results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftDriver Compilation", "Application", "normal", "arm64", "com.apple.xcode.tools.swift.compiler"])) { task in
                    task.checkCommandLineMatches([.suffix("swiftc"), .anySequence, "-cache-compile-job", .anySequence])
                    numCompile += 1
                }

                results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftCompile", "normal", "arm64", "Compiling App.swift", "\(tmpDirPath.str)/Test/aProject/App.swift"])) { task in
                    task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-cache-compile-job", .anySequence])
                    numCompile += 1
                    results.checkKeyQueryCacheMiss(task)
                }
                results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftEmitModule", "normal", "arm64", "Emitting module for Application"])) { _ in }

                results.checkNoTask(.matchTargetName("Application"))

                // Check the dynamic module tasks.
                results.checkTasks(.matchRuleType("SwiftExplicitDependencyGeneratePcm")) { tasks in
                    numCompile += tasks.count
                }
                results.checkTasks(.matchRuleType("SwiftExplicitDependencyCompileModuleFromInterface")) { tasks in
                    numCompile += tasks.count
                }

                results.checkNote("0 hits / 4 cacheable tasks (0%)")

                results.checkNoTask()
            }
            #expect(try readMetrics("one").contains("\"swiftCacheHits\":0,\"swiftCacheMisses\":\(numCompile)"))

            // touch a file, clean build folder, and rebuild.
            try await tester.fs.updateTimestamp(testWorkspace.sourceRoot.join("aProject/App.swift"))
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            tester.userInfo = rawUserInfo.withAdditionalEnvironment(environment: metricsEnv("two"))
            try await tester.checkBuild(runDestination: .anyiOSDevice, persistent: true) { results in
                results.checkTask(.matchRule(["SwiftCompile", "normal", "arm64", "Compiling App.swift", "\(tmpDirPath.str)/Test/aProject/App.swift"])) { task in
                    results.checkKeyQueryCacheHit(task)
                }

                results.checkNote("4 hits / 4 cacheable tasks (100%)")
            }
            #expect(try readMetrics("two").contains("\"swiftCacheHits\":\(numCompile),\"swiftCacheMisses\":0"))
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftCachingSwiftPM() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let commonBuildSettings = try await [
                "SDKROOT": "auto",
                "SDK_VARIANT": "auto",
                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                "SWIFT_VERSION": swiftVersion,
                "CODE_SIGNING_ALLOWED": "NO",
            ]

            let leafPackage = TestPackageProject(
                "aPackageLeaf",
                groupTree: TestGroup("Sources", children: [TestFile("Bar.swift")]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: commonBuildSettings)],
                targets: [
                    TestPackageProductTarget(
                        "BarProduct",
                        frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("Bar"))]),
                        dependencies: ["Bar"]),
                    TestStandardTarget(
                        "Bar",
                        type: .dynamicLibrary,
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Bar", "EXECUTABLE_PREFIX": "lib"])],
                        buildPhases: [TestSourcesBuildPhase(["Bar.swift"])])])

            let package = TestPackageProject(
                "aPackage",
                groupTree: TestGroup("Sources", children: [TestFile("Foo.swift")]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: commonBuildSettings.addingContents(of: [
                    "SWIFT_INCLUDE_PATHS": "$(TARGET_BUILD_DIR)/../../../aPackageLeaf/build/Debug",
                ]))],
                targets: [
                    TestPackageProductTarget(
                        "FooProduct",
                        frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("Foo"))]),
                        dependencies: ["Foo"]),
                    TestStandardTarget(
                        "Foo",
                        type: .dynamicLibrary,
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Foo", "EXECUTABLE_PREFIX": "lib"])],
                        buildPhases: [
                            TestSourcesBuildPhase(["Foo.swift"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("BarProduct"))])],
                        dependencies: ["BarProduct"])])

            let project = TestProject(
                "aProject",
                groupTree: TestGroup("Sources", children: [TestFile("App1.swift"), TestFile("App2.swift")]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: commonBuildSettings.addingContents(of: [
                    "SWIFT_INCLUDE_PATHS": "$(TARGET_BUILD_DIR)/../../../aPackage/build/Debug $(TARGET_BUILD_DIR)/../../../aPackageLeaf/build/Debug"]))],
                targets: [
                    TestStandardTarget(
                        "App1",
                        type: .framework,
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_ENABLE_COMPILE_CACHE": "YES",
                            "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                            "COMPILATION_CACHE_CAS_PATH": "$(DSTROOT)/CompilationCache"])],
                        buildPhases: [
                            TestSourcesBuildPhase(["App1.swift"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("FooProduct"))])],
                        dependencies: ["FooProduct"]),
                    TestStandardTarget(
                        "App2",
                        type: .framework,
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)"])],
                        buildPhases: [
                            TestSourcesBuildPhase(["App2.swift"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("FooProduct"))])],
                        dependencies: ["FooProduct"])])

            let workspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [project, package, leafPackage])

            let tester = try await BuildOperationTester(getCore(), workspace, simulated: false)

            try await tester.fs.writeFileContents(workspace.sourceRoot.join("aPackageLeaf/Bar.swift")) { stream in
                stream <<<
                """
                public func baz() {}
                """
            }

            try await tester.fs.writeFileContents(workspace.sourceRoot.join("aPackage/Foo.swift")) { stream in
                stream <<<
                """
                import Bar
                public func foo() { baz() }
                """
            }

            try await tester.fs.writeFileContents(workspace.sourceRoot.join("aProject/App1.swift")) { stream in
                stream <<<
                """
                import Foo
                func app() { foo() }
                """
            }

            try await tester.fs.writeFileContents(workspace.sourceRoot.join("aProject/App2.swift")) { stream in
                stream <<<
                """
                import Foo
                func app() { foo() }
                """
            }

            let parameters = BuildParameters(configuration: "Debug", overrides: ["ARCHS": "arm64"])
            let buildApp1Target = BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])
            let buildApp2Target = BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[1])
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: [buildApp2Target, buildApp1Target], continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()

                results.checkTasks(.matchRule(["SwiftCompile", "normal", "arm64", "Compiling Bar.swift", tmpDirPath.join("Test/aPackageLeaf/Bar.swift").str])) { tasks in
                    #expect(tasks.count == 1)
                    for task in tasks {
                        results.checkKeyQueryCacheMiss(task)
                    }
                }

                results.checkTask(.matchRule(["SwiftCompile", "normal", "arm64", "Compiling Foo.swift", tmpDirPath.join("Test/aPackage/Foo.swift").str])) { task in
                    results.checkKeyQueryCacheMiss(task)
                }

                results.checkTask(.matchRule(["SwiftCompile", "normal", "arm64", "Compiling App1.swift", tmpDirPath.join("Test/aProject/App1.swift").str])) { task in
                    results.checkKeyQueryCacheMiss(task)
                }

                results.checkTask(.matchRule(["SwiftCompile", "normal", "arm64", "Compiling App2.swift", "\(tmpDirPath.str)/Test/aProject/App2.swift"])) { task in
                    results.checkNotCached(task)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftCASLimiting() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "macosx",
                                    "SWIFT_VERSION": swiftVersion,
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    "SWIFT_ENABLE_COMPILE_CACHE": "YES",
                                    "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                                    "COMPILATION_CACHE_LIMIT_SIZE": "1",
                                    "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                    "DSTROOT": tmpDirPath.join("dstroot").str,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.swift",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/main.swift")) {
                $0 <<< "let x = 1\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("SwiftCompile")) { results.checkKeyQueryCacheMiss($0) }
            }
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            // Update the source file and rebuild.
            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/main.swift")) {
                $0 <<< "let x = 2\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("SwiftCompile")) { results.checkKeyQueryCacheMiss($0) }
            }
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            // Revert the source change and rebuild. It should still be a cache miss because of CAS size limiting.
            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/main.swift")) {
                $0 <<< "let x = 1\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("SwiftCompile")) { results.checkKeyQueryCacheMiss($0) }
            }
        }
    }

    @Test(.requireCASValidation, .requireSDKs(.macOS))
    func validateCAS() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let casPath = tmpDirPath.join("CompilationCache")
            let buildSettings: [String: String] = [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "SWIFT_VERSION": try await swiftVersion,
                "SWIFT_ENABLE_COMPILE_CACHE": "YES",
                "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                "COMPILATION_CACHE_CAS_PATH": casPath.str,
                "DSTROOT": tmpDirPath.join("dstroot").str,
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
                                TestFile("file.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: buildSettings)],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.swift"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.swift")) { stream in
                stream <<<
                """
                public func libFunc() {}
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
            // The second build should not require validation.
            try await checkBuild("validation skipped\n")
            // Including clean builds.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await checkBuild("validation skipped\n")
        }
    }
}

extension BuildOperationTester.BuildResults {
    fileprivate func checkNotCached(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        check(notContains: .taskHadEvent(task, event: .hadOutput(contents: "Cache miss\n")), sourceLocation: sourceLocation)
        check(notContains: .taskHadEvent(task, event: .hadOutput(contents: "Cache hit\n")), sourceLocation: sourceLocation)
    }

    fileprivate func checkKeyQueryCacheMiss(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        // FIXME: This doesn't work as expected (at least for Swift package targets).
        // let found = (getDiagnosticMessageForTask(.contains("cache miss"), kind: .note, task: task) != nil)
        // guard found else {
        //     Issue.record("Unable to find cache miss diagnostic for task \(task)", sourceLocation: sourceLocation)
        //     return
        // }
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache miss\n")), sourceLocation: sourceLocation)
    }

    fileprivate func checkKeyQueryCacheHit(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        // FIXME: This doesn't work as expected (at least for Swift package targets).
        // let found = (getDiagnosticMessageForTask(.contains("cache found for key"), kind: .note, task: task) != nil)
        // guard found else {
        //     Issue.record("Unable to find cache hit diagnostic for task \(task)", sourceLocation: sourceLocation)
        //     return
        // }
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache hit\n")), sourceLocation: sourceLocation)
    }
}
