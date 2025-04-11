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

import SWBTestSupport
import SWBUtil
import Testing
import SWBCore

@Suite
fileprivate struct WatchBuildOperationTests: CoreBasedTests {
    /// Test that a watch-only app's stub app is restricted to iOS.
    @Test(.requireSDKs(.watchOS))
    func watchOnlyAppPlatformConstraints() async throws {

        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        // watchOS app files
                        TestFile("watchosApp/Base.lproj/Interface.storyboard"),
                        TestFile("watchosApp/Assets.xcassets"),
                        TestFile("watchosApp/Info.plist"),

                        // watchOS extension files
                        TestFile("watchosExtension/Controller.m"),
                        TestFile("watchosExtension/WatchClass.swift"),
                        TestFile("watchosExtension/Assets.xcassets"),
                        TestFile("watchosExtension/Info.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "ENABLE_ON_DEMAND_RESOURCES": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "Apple Development",
                            "SDKROOT": "watchos",
                            "SWIFT_VERSION": swiftVersion,
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Watchable",
                        type: .watchKitAppContainer,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([
                                // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                            ]),
                            TestCopyFilesBuildPhase([
                                "Watchable WatchKit App.app",
                            ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                                   ),
                        ],
                        dependencies: ["Watchable WatchKit App"]
                    ),
                    TestStandardTarget(
                        "Watchable WatchKit App",
                        type: .watchKitApp,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "ARCHS[sdk=watchos*]": "arm64_32",
                                                    "ARCHS[sdk=watchsimulator*]": "x86_64",
                                                    "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                                                    "INFOPLIST_FILE": "Sources/watchosApp/Info.plist",
                                                    "SDKROOT": "watchos",
                                                    "SKIP_INSTALL": "YES",
                                                    "TARGETED_DEVICE_FAMILY": "4",
                                                    "WATCHOS_DEPLOYMENT_TARGET": core.loadSDK(.watchOS).defaultDeploymentTarget,
                                                   ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([
                                "Base.lproj/Interface.storyboard",
                                "watchosApp/Assets.xcassets",
                            ]),
                            TestCopyFilesBuildPhase([
                                "Watchable WatchKit Extension.appex",
                            ], destinationSubfolder: .plugins, onlyForDeployment: false
                                                   ),
                        ],
                        dependencies: ["Watchable WatchKit Extension", "Watchable WatchKit Extension (old)"]
                    ),
                    TestStandardTarget(
                        "Watchable WatchKit Extension",
                        type: .watchKitExtension,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "ARCHS[sdk=watchos*]": "arm64_32",
                                                    "ARCHS[sdk=watchsimulator*]": "x86_64",
                                                    "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                                                    "INFOPLIST_FILE": "Sources/watchosExtension/Info.plist",
                                                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                                                    "SDKROOT": "watchos",
                                                    "SKIP_INSTALL": "YES",
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "TARGETED_DEVICE_FAMILY": "4",
                                                    "WATCHOS_DEPLOYMENT_TARGET": core.loadSDK(.watchOS).defaultDeploymentTarget,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "Controller.m",
                                "watchosExtension/WatchClass.swift",
                            ]),
                            TestResourcesBuildPhase([
                                "Base.lproj/Interface.storyboard",
                                "watchosExtension/Assets.xcassets",
                            ]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: true)

            // Create files in the filesystem so they're known to exist.
            let fs = tester.fs
            try fs.createDirectory(core.developerPath.path.join("usr/bin"), recursive: true)
            try await fs.writeFileContents(core.developerPath.path.join("usr/bin/actool")) { $0 <<< "binary" }
            try await fs.writeFileContents(core.developerPath.path.join("usr/bin/ibtool")) { $0 <<< "binary" }

            try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
            try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
            try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
            try fs.createDirectory(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit"), recursive: true)
            try fs.write(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
            try fs.createDirectory(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit"), recursive: true)
            try fs.write(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")

            // Create the iOS stub assets in the wrong SDK so the build doesn't fail early due to missing inputs.
            try fs.createDirectory(core.loadSDK(.watchOS).path.join("../../../Library/Application Support/MessagesApplicationStub"), recursive: true)
            try await fs.writeAssetCatalog(core.loadSDK(.watchOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub.xcassets"), .appIcon("MessagesApplicationStub"))
            try fs.write(core.loadSDK(.watchOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub"), contents: "stub")

            // Check the debug build, for the device.
            try await tester.checkBuild(runDestination: .watchOS) { results in
                for _ in 0..<4 {
                    results.checkError(.prefix("unable to open dependencies file"))
                }
                results.checkWarning(.contains("Could not read serialized diagnostics file"))
                results.checkError(.equal("[targetIntegrity] Watch-Only Application Stubs are not available when building for watchOS. (in target 'Watchable' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }
    }
}
