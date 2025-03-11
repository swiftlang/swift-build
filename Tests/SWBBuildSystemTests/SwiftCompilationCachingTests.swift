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

@Suite(.requireSwiftFeatures(.compilationCaching), .requireCompilationCaching, .flaky("A handful of Swift Build CAS tests fail when running the entire test suite"), .bug("rdar://137717929"))
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
                results.consumeTasksMatchingRuleTypes(["CopySwiftLibs", "GenerateDSYMFile", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "Touch", "Validate", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "SwiftDriver Compilation Requirements", "Copy", "Ld", "CompileC", "SwiftMergeGeneratedHeaders"])

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

                results.checkNoTask()
            }
            #expect(try readMetrics("one") == "{\"clangCacheHits\":0,\"clangCacheMisses\":0,\"swiftCacheHits\":0,\"swiftCacheMisses\":\(numCompile)}")

            // touch a file, clean build folder, and rebuild.
            try await tester.fs.updateTimestamp(testWorkspace.sourceRoot.join("aProject/App.swift"))
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            tester.userInfo = rawUserInfo.withAdditionalEnvironment(environment: metricsEnv("two"))
            try await tester.checkBuild(runDestination: .anyiOSDevice, persistent: true) { _ in }
            #expect(try readMetrics("two") == "{\"clangCacheHits\":0,\"clangCacheMisses\":0,\"swiftCacheHits\":\(numCompile),\"swiftCacheMisses\":0}")
        }
    }
}

extension BuildOperationTester.BuildResults {
    fileprivate func checkKeyQueryCacheMiss(_ task: Task, file: StaticString = #file, line: UInt = #line) {
        checkRemark(.contains("cache key query miss"))
    }

    fileprivate func checkKeyQueryCacheHit(_ task: Task, file: StaticString = #file, line: UInt = #line) {
        checkRemark(.contains("cache key query hit"))
    }
}
