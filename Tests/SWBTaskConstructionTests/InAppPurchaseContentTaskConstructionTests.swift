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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import SWBCore

@Suite
fileprivate struct InAppPurchaseContentTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func inAppPurchaseContent() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("resource.dat"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "INSTALL_PATH": "$(LOCAL_LIBRARY_DIR)/InAppPurchaseContent",
                        "INFOPLIST_FILE": "MyIAP/ContentInfo.plist",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "MyIAP",
                    type: .inAppPurchaseContent,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx"
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "resource.dat",
                        ]),
                    ],
                    dependencies: ["MyIAPEmbedded"]
                ),
                TestStandardTarget(
                    "MyIAPEmbedded",
                    type: .inAppPurchaseContent,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos"
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "resource.dat",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let srcRoot = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try await fs.writePlist(srcRoot.join("MyIAP/ContentInfo.plist"), .plDict([:]))

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.consumeTasksMatchingRuleTypes(["CpResource", "CreateBuildDirectory", "Gate", "MkDir", "RegisterExecutionPolicyException", "ProcessInfoPlistFile", "ProcessProductPackaging", "Touch", "WriteAuxiliaryFile"])

            // Notably, should not be codesigned.

            results.checkTarget("MyIAP") { target in
                results.checkNoTask(.matchTarget(target))
            }

            results.checkTarget("MyIAPEmbedded") { target in
                results.checkNoTask(.matchTarget(target))
            }

            results.checkNoTask()

            results.checkError(.equal("deprecated product type 'com.apple.product-type.in-app-purchase-content' for platform 'macOS'. Uploading non-consumable in-app purchase content for Apple to host is no longer supported. Existing content that's hosted by Apple isn't affected. To enable smaller app bundles, faster downloads, and richer app content, use on-demand resources to host your content on the App Store, separately from the app bundle. For details, see: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/On_Demand_Resources_Guide/index.html (in target 'MyIAP' from project 'aProject')"))
            results.checkError(.equal("deprecated product type 'com.apple.product-type.in-app-purchase-content' for platform 'iOS'. Uploading non-consumable in-app purchase content for Apple to host is no longer supported. Existing content that's hosted by Apple isn't affected. To enable smaller app bundles, faster downloads, and richer app content, use on-demand resources to host your content on the App Store, separately from the app bundle. For details, see: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/On_Demand_Resources_Guide/index.html (in target 'MyIAPEmbedded' from project 'aProject')"))

            // Check there are no more diagnostics.
            results.checkNoDiagnostics()
        }
    }
}
