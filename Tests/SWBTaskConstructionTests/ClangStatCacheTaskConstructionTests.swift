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

import SWBTestSupport

import SWBCore
@_spi(Testing) import SWBUtil

@Suite(.requireClangFeatures(.vfsstatcache), .requireLocalFileSystem(.macOS), .disabled(if: ProcessInfo.processInfo.isRunningUnderFilesystemCaseSensitivityIOPolicy, "Running under case sensitive IO policy"))
fileprivate struct ClangStatCacheTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS), .requireSwiftFeatures(.vfsstatcache))
    func statCacheTaskConstruction() async throws {
        let testWorkspace = try await TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("file.swift"),
                            TestFile("file2.swift"),
                            TestFile("file3.c"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "CODE_SIGNING_ALLOWED": "NO",
                        ])],
                    targets: [
                        TestStandardTarget(
                            "Framework",
                            type: .framework,
                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT":"iphoneos"])],
                            buildPhases: [
                                TestSourcesBuildPhase(["file.swift"]),
                            ], dependencies: ["Tool", "Framework2"]),
                        TestStandardTarget(
                            "Framework2",
                            type: .framework,
                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT":"iphoneos"])],
                            buildPhases: [
                                TestSourcesBuildPhase(["file3.c"]),
                            ]),
                        TestStandardTarget(
                            "Tool",
                            type: .commandLineTool,
                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT":"macosx"])],
                            buildPhases: [
                                TestSourcesBuildPhase(["file2.swift"]),
                            ]),
                    ])])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testWorkspace)
        await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.macOS).path.str)])) { task in
                task.checkCommandLineMatches([.suffix("clang-stat-cache"), .equal(core.loadSDK(.macOS).path.str), .equal("-o"), .suffix(".sdkstatcache")])
                task.checkInputs([])
                task.checkOutputs([.namePattern(.suffix(".sdkstatcache")), .namePattern(.suffix(".sdkstatcache"))])
            }

            results.checkTask(.matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.iOS).path.str)])) { task in
                task.checkCommandLineMatches([.suffix("clang-stat-cache"), .equal(core.loadSDK(.iOS).path.str), .equal("-o"), .suffix(".sdkstatcache")])
                task.checkInputs([])
                task.checkOutputs([.namePattern(.suffix(".sdkstatcache")), .namePattern(.suffix(".sdkstatcache"))])
            }

            // Even though there are 3 targets, 2 share an SDK so there should only be 2 cache tasks.
            results.checkNoTask(.matchRuleType("ClangStatCache"))

            results.checkTask([.matchRuleType("SwiftDriver Compilation"), .matchTargetName("Tool")]) { task in
                results.checkTaskFollows(task, .matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.macOS).path.str)]))
                results.checkTaskDoesNotFollow(task, .matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.iOS).path.str)]))
                task.checkCommandLineMatches([.anySequence, .equal("-Xcc"), .equal("-ivfsstatcache"), .equal("-Xcc"), .suffix(".sdkstatcache"), .anySequence])
                task.checkInputs(contain: [.namePattern(.suffix(".sdkstatcache"))])
            }

            results.checkTask([.matchRuleType("SwiftDriver Compilation"), .matchTargetName("Framework")]) { task in
                results.checkTaskFollows(task, .matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.iOS).path.str)]))
                task.checkCommandLineMatches([.anySequence, .equal("-Xcc"), .equal("-ivfsstatcache"), .equal("-Xcc"), .suffix(".sdkstatcache"), .anySequence])
                task.checkInputs(contain: [.namePattern(.suffix(".sdkstatcache"))])
            }

            results.checkTask([.matchRuleType("CompileC"), .matchTargetName("Framework2")]) { task in
                results.checkTaskFollows(task, .matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.iOS).path.str)]))
                results.checkTaskDoesNotFollow(task, .matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.macOS).path.str)]))
                task.checkCommandLineMatches([.anySequence, .equal("-ivfsstatcache"), .suffix(".sdkstatcache"), .anySequence])
                task.checkInputs(contain: [.namePattern(.suffix(".sdkstatcache"))])
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireSwiftFeatures(.vfsstatcache))
    func verbosityMismatchNoDuplicateTasks() async throws {
        let testWorkspace = try await TestWorkspace(
            "Test",
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
                            "CODE_SIGNING_ALLOWED": "NO",
                        ])],
                    targets: [
                        TestStandardTarget(
                            "Framework",
                            type: .framework,
                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDK_STAT_CACHE_VERBOSE_LOGGING": "YES"])],
                            buildPhases: [
                                TestSourcesBuildPhase(["file.swift"]),
                            ], dependencies: ["Framework2"]),
                        TestStandardTarget(
                            "Framework2",
                            type: .framework,
                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDK_STAT_CACHE_VERBOSE_LOGGING": "NO"])],
                            buildPhases: [
                                TestSourcesBuildPhase(["file2.swift"]),
                            ]),
                    ])])

        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
            // There should be no duplicate tasks error, and exactly one stat cache task.
            results.checkNoDiagnostics()
            results.checkTasks(.matchRulePattern(["ClangStatCache", .any, .any])) { tasks in
                #expect(tasks.count == 1)
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireSwiftFeatures(.vfsstatcache))
    func verboseLogging() async throws {
        let testWorkspace = try await TestWorkspace(
            "Test",
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
                            "SWIFT_VERSION": swiftVersion,
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SDK_STAT_CACHE_VERBOSE_LOGGING": "YES"
                        ])],
                    targets: [
                        TestStandardTarget(
                            "Framework",
                            type: .framework,
                            buildPhases: [
                                TestSourcesBuildPhase(["file.swift"]),
                            ]),
                    ])])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testWorkspace)
        await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.macOS).path.str)])) { task in
                task.checkCommandLineMatches([.suffix("clang-stat-cache"), .equal(core.loadSDK(.macOS).path.str), .equal("-v"), .equal("-o"), .suffix(".sdkstatcache")])
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func statCacheEligibility() async throws {
        let testWorkspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("file.m"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ])],
                    targets: [
                        TestStandardTarget(
                            "Framework",
                            type: .framework,
                            buildPhases: [
                                TestSourcesBuildPhase(["file.m"]),
                            ]),
                    ])])

        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
            results.checkTaskExists(.matchRuleType("ClangStatCache"))
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SDK_STAT_CACHE_ENABLE": "NO"]), runDestination: .macOS, fs: localFS) { results in
            results.checkNoTask(.matchRuleType("ClangStatCache"))
        }

        await UserDefaults.withEnvironment(["EnableSDKStatCaching": "0"]) {
            await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
                results.checkNoTask(.matchRuleType("ClangStatCache"))
            }
        }
    }
}
