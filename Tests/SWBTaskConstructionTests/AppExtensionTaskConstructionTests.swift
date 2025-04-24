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
import SWBTestSupport

import SWBCore
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct AppExtensionTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func appExtensionEmbedding() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", children: [
                    TestFile("Source.c"),
                    TestFile("Legacy.appex", fileType: "wrapper.app-extension", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR")),
                    TestFile("Modern.appex", fileType: "wrapper.extensionkit-extension", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR")),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTED_PLATFORMS": "macosx iphoneos",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.c"]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile(.target("Legacy"))], destinationSubfolder: .plugins, onlyForDeployment: false),
                        TestCopyFilesBuildPhase([
                            TestBuildFile(.target("Modern"))], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(EXTENSIONS_FOLDER_PATH)", onlyForDeployment: false),
                    ],
                    dependencies: ["Legacy", "Modern"]),
                TestStandardTarget(
                    "Legacy",
                    type: .applicationExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.c"]),
                    ]),
                TestStandardTarget(
                    "Modern",
                    type: .extensionKitExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.c"]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchTargetName("Foo"), .matchRule(["Copy", "/tmp/Test/aProject/build/Debug/Foo.app/Contents/Extensions/Modern.appex", "/tmp/Test/aProject/build/Debug/Modern.appex"])) { task in }
            results.checkTask(.matchTargetName("Foo"), .matchRule(["Copy", "/tmp/Test/aProject/build/Debug/Foo.app/Contents/PlugIns/Legacy.appex", "/tmp/Test/aProject/build/Debug/Legacy.appex"])) { task in }
        }

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchTargetName("Foo"), .matchRule(["Copy", "/tmp/Test/aProject/build/Debug-iphoneos/Foo.app/Extensions/Modern.appex", "/tmp/Test/aProject/build/Debug-iphoneos/Modern.appex"])) { task in }
            results.checkTask(.matchTargetName("Foo"), .matchRule(["Copy", "/tmp/Test/aProject/build/Debug-iphoneos/Foo.app/PlugIns/Legacy.appex", "/tmp/Test/aProject/build/Debug-iphoneos/Legacy.appex"])) { task in }
        }
    }
}
