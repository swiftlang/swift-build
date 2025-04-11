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

import struct Foundation.Data

import Testing
import SWBProtocol
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import SWBCore

@Suite
fileprivate struct OnDemandResourcesTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.iOS))
    func onDemandResourcesBasics() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    // We have a mix of resources which just get copied, vs. get processed.
                    TestFile("A.dat"),
                    TestFile("B.png"),
                    TestFile("de.lproj/C.png", regionVariantName: "de"),
                    TestFile("Assets.xcassets"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "INFOPLIST_FILE": "Sources/Info.plist",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "CODE_SIGN_IDENTITY": "-",
                        "ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS": "foo",
                        "ON_DEMAND_RESOURCES_PREFETCH_ORDER": "baz",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            TestBuildFile("A.dat", assetTags: Set(["foo"])),
                            TestBuildFile("B.png", assetTags: Set(["foo"])),
                            TestBuildFile("de.lproj/C.png", assetTags: Set(["foo", "bar"])),
                            "Assets.xcassets",
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        final class ClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first.map(Path.init)?.basename == "actool", commandLine.dropFirst().first != "--version" {
                    return .result(status: .exit(0), stdout: Data("{}".utf8), stderr: Data())
                }
                return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
            }
        }

        await tester.checkBuild(runDestination: .iOS, clientDelegate: ClientDelegate()) { results in
            // For debugging convenience, consume all task types we're not interested in checking.
            results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "RegisterExecutionPolicyException", "Touch", "Validate"])

            // Check that results for the framework target were generated, but they're not what we're testing here.
            results.checkTarget("App") { target in
                // Tasks to copy the resources.
                results.checkTask(.matchTarget(target), .matchRule(["CpResource", "\(SRCROOT)/build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack/A.dat", "\(SRCROOT)/Sources/A.dat"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyPNGFile", "\(SRCROOT)/build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack/B.png", "\(SRCROOT)/Sources/B.png"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyPNGFile", "\(SRCROOT)/build/Debug-iphoneos/OnDemandResources/com.company.App.bar+foo-8856328b99ee7881e9bf7205296e056d.assetpack/de.lproj/C.png", "\(SRCROOT)/Sources/de.lproj/C.png"])) { _ in }

                // There should be a CompileAssetCatalog task, but there isn't anything we can meaningfully check about it at the task construction level.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkAssetCatalog")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature")) { _ in }

                // Task to create the asset pack manifest.
                results.checkTask(.matchTarget(target), .matchRuleType("CreateAssetPackManifest")) { task in
                    task.checkCommandLineMatches([
                        "\(SRCROOT)/build/Debug-iphoneos/OnDemandResources/com.company.App.bar+foo-8856328b99ee7881e9bf7205296e056d.assetpack",
                        "\(SRCROOT)/build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack",
                    ])
                }

                // Tasks to create ODR Info.plist files.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/Debug-iphoneos/App.app/OnDemandResources.plist"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/Debug-iphoneos/OnDemandResources/com.company.App.bar+foo-8856328b99ee7881e9bf7205296e056d.assetpack/Info.plist"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack/Info.plist"])) { _ in }

                // Consume other tasks we presently don't want to examine.
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemBasename("App.app.xcent")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemBasename("App.app.xcent")) { _ in }

                // Check that there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }
        }
    }

}
