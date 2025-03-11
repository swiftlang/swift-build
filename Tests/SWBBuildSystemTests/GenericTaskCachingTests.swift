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
import Foundation

@_spi(Testing) import SWBUtil
import SWBBuildSystem
import SWBCore
import SWBTestSupport

@Suite(.disabled(if: getEnvironmentVariable("CI")?.isEmpty == false, "tests run too slowly in CI"), .requireXcode16())
fileprivate struct GenericTaskCachingTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func realityToolCachingBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Reality.rkassets"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "macosx",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "VERSIONING_SYSTEM": "apple-generic",
                            "DSTROOT": tmpDir.join("dstroot").str,
                            "ENABLE_GENERIC_TASK_CACHING": "YES",
                            "GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "FrameworkTarget",
                        type: .framework,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("Reality.rkassets"),
                            ]),
                        ]
                    ),
                ])

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot
            try localFS.createDirectory(SRCROOT.join("Reality.rkassets"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    task.checkCommandLineContainsUninterrupted(["compile", "--platform", "macosx", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget, "-o", "\(SRCROOT.str)/build/Debug/FrameworkTarget.framework/Versions/A/Resources/Reality.reality", "\(SRCROOT.str)/Reality.rkassets"])
                }
                results.checkNoTask(.matchRuleType("RealityAssetsSchemaGen"))
                results.checkRemark(.prefix("caching result"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    task.checkCommandLineContainsUninterrupted(["compile", "--platform", "macosx", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget, "-o", "\(SRCROOT.str)/build/Debug/FrameworkTarget.framework/Versions/A/Resources/Reality.reality", "\(SRCROOT.str)/Reality.rkassets"])
                }
                results.checkNoTask(.matchRuleType("RealityAssetsSchemaGen"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try localFS.write(SRCROOT.join("Reality.rkassets/foo.txt"), contents: "Foo")

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    task.checkCommandLineContainsUninterrupted(["compile", "--platform", "macosx", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget, "-o", "\(SRCROOT.str)/build/Debug/FrameworkTarget.framework/Versions/A/Resources/Reality.reality", "\(SRCROOT.str)/Reality.rkassets"])
                }
                results.checkNoTask(.matchRuleType("RealityAssetsSchemaGen"))
                results.checkRemark(.prefix("caching result"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try localFS.remove(SRCROOT.join("Reality.rkassets/foo.txt"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    task.checkCommandLineContainsUninterrupted(["compile", "--platform", "macosx", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget, "-o", "\(SRCROOT.str)/build/Debug/FrameworkTarget.framework/Versions/A/Resources/Reality.reality", "\(SRCROOT.str)/Reality.rkassets"])
                }
                results.checkNoTask(.matchRuleType("RealityAssetsSchemaGen"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.iOS), .requireHostOS(.macOS))
    func ibtoolCachingBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Main.storyboard"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "iphoneos",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "VERSIONING_SYSTEM": "apple-generic",
                            "DSTROOT": tmpDir.join("dstroot").str,
                            "ENABLE_GENERIC_TASK_CACHING": "YES",
                            "GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "FrameworkTarget",
                        type: .framework,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("Main.storyboard"),
                            ]),
                        ]
                    ),
                ])

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeStoryboard(SRCROOT.join("Main.storyboard"), .iOS)

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileStoryboard"))
                results.checkRemark(.prefix("caching result"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileStoryboard"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try localFS.append(SRCROOT.join("Main.storyboard"), contents: " ")

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileStoryboard"))
                results.checkRemark(.prefix("caching result"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.fs.writeStoryboard(SRCROOT.join("Main.storyboard"), .iOS)

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileStoryboard"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func assetCatalogCachingBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Assets.xcassets"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "macosx",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "VERSIONING_SYSTEM": "apple-generic",
                            "DSTROOT": tmpDir.join("dstroot").str,
                            "ENABLE_GENERIC_TASK_CACHING": "YES",
                            "GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "FrameworkTarget",
                        type: .framework,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("Assets.xcassets"),
                            ]),
                        ]
                    ),
                ])

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot
            try await localFS.writeAssetCatalog(SRCROOT.join("Assets.xcassets"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileAssetCatalogVariant"))
                results.checkRemark(.prefix("caching result"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileAssetCatalogVariant"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try localFS.write(SRCROOT.join("Assets.xcassets/foo.txt"), contents: "Foo")

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileAssetCatalogVariant"))
                results.checkRemark(.prefix("caching result"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })

            try localFS.remove(SRCROOT.join("Assets.xcassets/foo.txt"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileAssetCatalogVariant"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS))
    func repeatedReplay() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Assets.xcassets"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "macosx",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "VERSIONING_SYSTEM": "apple-generic",
                            "DSTROOT": tmpDir.join("dstroot").str,
                            "ENABLE_GENERIC_TASK_CACHING": "YES",
                            "GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                            "COMPILATION_CACHE_LIMIT_SIZE": "1"
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "FrameworkTarget",
                        type: .framework,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("Assets.xcassets"),
                            ]),
                        ]
                    ),
                ])

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot
            try await localFS.writeAssetCatalog(SRCROOT.join("Assets.xcassets"))

            // Repeated replay of the task in incremental builds should successfully place outputs
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileAssetCatalogVariant"))
                results.checkRemark(.prefix("caching result"))
                results.checkNoErrors()
            }

            try tester.fs.touch(SRCROOT.join("Assets.xcassets"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileAssetCatalogVariant"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }

            try tester.fs.touch(SRCROOT.join("Assets.xcassets"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CCHROOT": tmpDir.join("cchroot").str]), runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("CompileAssetCatalogVariant"))
                results.checkRemark(.prefix("replaying cache hit"))
                results.checkNoErrors()
            }
        }
    }
}
