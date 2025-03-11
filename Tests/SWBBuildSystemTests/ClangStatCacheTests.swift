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
import SWBUtil
import SWBTestSupport

@Suite(.requireClangFeatures(.vfsstatcache), .disabled(if: ProcessInfo.processInfo.isRunningUnderFilesystemCaseSensitivityIOPolicy, "Running under case sensitive IO policy"), .requireLocalFileSystem(.macOS))
fileprivate struct ClangStatCacheTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func clangStatCacheBasics() async throws {
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
                                TestFile("file.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                ]),
                        ])])

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                @import Foundation;
                int foo() {}
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("ClangStatCache")) { task in
                    task.checkCommandLineMatches([.suffix("clang-stat-cache"), .equal(core.loadSDK(.macOS).path.str), .equal("-o"), .suffix(".sdkstatcache")])
                }

                try results.checkTask(.matchRuleType("CompileC")) { task in
                    try results.checkTaskFollows(task, .matchRuleType("ClangStatCache"))
                    task.checkCommandLineMatches([.anySequence, .equal("-ivfsstatcache"), .suffix(".sdkstatcache"), .anySequence])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireSwiftFeatures(.vfsstatcache))
    func clangStatCacheUsageBySwift() async throws {
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
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
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
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.swift")) { stream in
                stream <<<
                """
                import Foundation;
                func foo() {}
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("ClangStatCache")) { task in
                    task.checkCommandLineMatches([.suffix("clang-stat-cache"), .equal(core.loadSDK(.macOS).path.str), .equal("-o"), .suffix(".sdkstatcache")])
                }

                try results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    try results.checkTaskFollows(task, .matchRuleType("ClangStatCache"))
                    task.checkCommandLineMatches([.anySequence, .equal("-Xcc"), .equal("-ivfsstatcache"), .equal("-Xcc"), .suffix(".sdkstatcache"), .anySequence])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS), .requireSwiftFeatures(.vfsstatcache))
    func multiStatCacheBuild() async throws {
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
                                "CODE_SIGNING_ALLOWED": "NO",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT":"iphoneos"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.swift"]),
                                ], dependencies: ["Tool"]),
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT":"macosx"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["file2.swift"]),
                                ]),
                        ])])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.swift")) { stream in
                stream <<<
                """
                import Foundation;
                func foo() {}
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.swift")) { stream in
                stream <<<
                """
                import Foundation;
                @main struct Entry {
                    static func main() {}
                }
                """
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.macOS).path.str)])) { task in
                    task.checkCommandLineMatches([.suffix("clang-stat-cache"), .equal(core.loadSDK(.macOS).path.str), .equal("-o"), .suffix(".sdkstatcache")])
                }

                try results.checkTask([.matchRuleType("SwiftDriver Compilation"), .matchTargetName("Tool")]) { task in
                    try results.checkTaskFollows(task, .matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.macOS).path.str)]))
                    try results.checkTaskDoesNotFollow(task, .matchRule(["ClangStatCache", core.loadSDK(.iOS).path.str]))
                    task.checkCommandLineMatches([.anySequence, .equal("-Xcc"), .equal("-ivfsstatcache"), .equal("-Xcc"), .suffix(".sdkstatcache"), .anySequence])
                }

                results.checkTask(.matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.iOS).path.str)])) { task in
                    task.checkCommandLineMatches([.suffix("clang-stat-cache"), .equal(core.loadSDK(.iOS).path.str), .equal("-o"), .suffix(".sdkstatcache")])
                }

                try results.checkTask([.matchRuleType("SwiftDriver Compilation"), .matchTargetName("Framework")]) { task in
                    try results.checkTaskFollows(task, .matchRulePattern(["ClangStatCache", .any, .equal(core.loadSDK(.iOS).path.str)]))
                    task.checkCommandLineMatches([.anySequence, .equal("-Xcc"), .equal("-ivfsstatcache"), .equal("-Xcc"), .suffix(".sdkstatcache"), .anySequence])
                }
            }
        }
    }
}

