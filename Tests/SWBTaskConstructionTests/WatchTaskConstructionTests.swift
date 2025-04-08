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
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct WatchTaskConstructionTests: CoreBasedTests {
    /// Test a basic iOS+watchOS app.
    @Test(.requireSDKs(.iOS, .watchOS))
    func watchOSAppBasics() async throws {

        let core = try await getCore()
        let archs = ["arm64", "arm64e"]
        let swiftCompilerPath = try await self.swiftCompilerPath
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // iOS app files
                    TestFile("iosApp/main.m"),
                    TestFile("iosApp/CompanionClass.swift"),
                    TestFile("iosApp/Base.lproj/Main.storyboard"),
                    TestFile("iosApp/Assets.xcassets"),
                    TestFile("iosApp/Info.plist"),

                    // watchOS app files
                    TestFile("watchosApp/Base.lproj/Interface.storyboard"),
                    TestFile("watchosApp/Assets.xcassets"),
                    TestFile("watchosApp/Info.plist"),

                    // watchOS extension files
                    TestFile("watchosExtension/Controller.m"),
                    TestFile("watchosExtension/WatchClass.swift"),
                    TestFile("watchosExtension/Assets.xcassets"),
                    TestFile("watchosExtension/Info.plist"),
                    TestFile("watchosExtension/PrivacyInfo.xcprivacy"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ARCHS[sdk=iphoneos*]": archs.joined(separator: " "),
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "IBC_EXEC": ibtoolPath.str,
                        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "ENABLE_ON_DEMAND_RESOURCES": "NO",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": swiftVersion,
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.test.aProject",
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Watchable",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
                                                "INFOPLIST_FILE": "Sources/iosApp/Info.plist",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
                                                "TARGETED_DEVICE_FAMILY": "1,2",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                            "iosApp/CompanionClass.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "Base.lproj/Main.storyboard",
                            "iosApp/Assets.xcassets",
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
                                                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
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
                            "watchosExtension/Assets.xcassets",
                            "watchosExtension/PrivacyInfo.xcprivacy",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "Watchable WatchKit Extension (old)",
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
                                                "WATCHOS_DEPLOYMENT_TARGET": "4.0",
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
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let IPHONEOS_DEPLOYMENT_TARGET = core.loadSDK(.iOS).defaultDeploymentTarget
        let WATCHOS_DEPLOYMENT_TARGET = core.loadSDK(.watchOS).defaultDeploymentTarget

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        try fs.createDirectory(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
        try fs.createDirectory(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")

        let actoolPath = try await self.actoolPath

        // Check the debug build, for the device.
        try await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // Ignore certain classes of tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("CreateUniversalBinary")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check the watchOS extension
            try results.checkTarget("Watchable WatchKit Extension") { target in
                // There should be one clang and one swiftc task.
                let arch = "arm64_32"
                let variant = "normal"

                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("Controller.m")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Controller.o"), .suffix("Controller.m"), .equal(variant), .equal(arch), .equal("objective-c"), .any])
                    let expectedCommandLine: [String] = [
                        ["clang"],
                        ["-target", "arm64_32-apple-watchos\(WATCHOS_DEPLOYMENT_TARGET)"],
                        ["-isysroot", core.loadSDK(.watchOS).path.str],
                        ["-o", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(target.target.name).build/Objects-\(variant)/\(arch)/Controller.o"]
                    ].reduce([], +)
                    task.checkCommandLineContains(expectedCommandLine)
                    #expect(!task.commandLine.contains("-fasm-blocks"))
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "Watchable WatchKit Extension", .equal(variant), .equal(arch), .equal("com.apple.xcode.tools.swift.compiler")])
                    let responseFilePath = "@\(SRCROOT)/build/aProject.build/Debug-watchos/\(target.target.name).build/Objects-\(variant)/\(arch)/\(target.target.name).SwiftFileList"
                    task.checkCommandLineContains([swiftCompilerPath.str, responseFilePath, "-sdk", core.loadSDK(.watchOS).path.str, "-target", "\(arch)-apple-watchos\(core.loadSDK(.watchOS).defaultDeploymentTarget)"])
                }

                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))

                // There should be one link task
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let expectedCommandLine: [String] = [
                        ["clang"],
                        ["-target", "\(arch)-apple-watchos\(WATCHOS_DEPLOYMENT_TARGET)"],
                        ["-isysroot", core.loadSDK(.watchOS).path.str, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks"],
                        ["-fapplication-extension", "\(SRCROOT)/build/Debug-watchos/\(target.target.name).appex/\(target.target.name)"]
                    ].reduce([], +)
                    task.checkCommandLineContains(expectedCommandLine)
                    if try Version(WATCHOS_DEPLOYMENT_TARGET) >= Version(6) {
                        task.checkCommandLineContainsUninterrupted(["-e", "_WKExtensionMain"])
                        task.checkCommandLineContainsUninterrupted(["-framework", "WatchKit"])
                    }
                }

                // There should be tasks to copy the associated Swift files.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftdoc"), .matchRuleItemBasename("\(arch)-apple-watchos.swiftdoc")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Watchable_WatchKit_Extension-Swift.h"), .matchRuleItemBasename("Watchable_WatchKit_Extension-Swift.h")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftmodule"), .matchRuleItemBasename("\(arch)-apple-watchos.swiftmodule")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.abi.json"), .matchRuleItemBasename("\(arch)-apple-watchos.abi.json")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftsourceinfo"), .matchRuleItemBasename("\(arch)-apple-watchos.swiftsourceinfo")) { _ in }

                // There should be two actool tasks
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/watchosExtension/Assets.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(target.target.name).build/assetcatalog_output/\(variant)", "--target-device", "watch", "--complication", "Complication", "--minimum-deployment-target", WATCHOS_DEPLOYMENT_TARGET, "--platform", "watchos"])
                    }
                }
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/watchosExtension/Assets.xcassets", "--compile", "\(SRCROOT)/build/Debug-watchos/\(target.target.name).appex", "--target-device", "watch", "--complication", "Complication", "--minimum-deployment-target", WATCHOS_DEPLOYMENT_TARGET, "--platform", "watchos", "--bundle-identifier", "com.test.aProject", "--generate-swift-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-watchos/Watchable WatchKit Extension.build/DerivedSources/GeneratedAssetSymbols.swift", "--generate-objc-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-watchos/Watchable WatchKit Extension.build/DerivedSources/GeneratedAssetSymbols.h"])
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                // Ensure the privacy file is copied.
                results.checkTask(.matchTarget(target), .matchRuleType("CopyPlistFile")) { task in
                    task.checkInputs(contain: [.name("PrivacyInfo.xcprivacy")])
                    task.checkOutputs(contain: [.name("PrivacyInfo.xcprivacy")])
                }

                // There should be a process Info.plist task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }

                // There should be a product packaging task for the entitlements file, and one for the provisioning profile.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemBasename("embedded.mobileprovision")) { _ in }

                // There should be one GenerateDSYMFile task.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { _ in }

                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    #expect(task.ruleInfo[1] == "\(SRCROOT)/build/Debug-watchos/Watchable WatchKit Extension.appex")
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(target.target.name).build/\(target.target.name).appex.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug-watchos/\(target.target.name).appex"])
                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE": .equal("codesign_allocate"),
                    ], exact: true)
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            results.checkTarget("Watchable WatchKit Extension (old)") { target in
                // There should be one link task
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let expectedCommandLine: [String] = [
                        ["clang"],
                        ["-target", "arm64_32-apple-watchos4.0"],
                        ["-isysroot", core.loadSDK(.watchOS).path.str, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks"],
                        ["-fapplication-extension", "\(SRCROOT)/build/Debug-watchos/Watchable WatchKit Extension (old).appex/Watchable WatchKit Extension (old)"]
                    ].reduce([], +)
                    task.checkCommandLineContains(expectedCommandLine)
                    task.checkCommandLineContainsUninterrupted(["-e", "_WKExtensionMain"])
                    task.checkCommandLineContainsUninterrupted(["-lWKExtensionMainLegacy"])
                    task.checkCommandLineContainsUninterrupted(["-framework", "WatchKit"])
                }
            }

            // Check the watchOS app
            results.checkTarget("Watchable WatchKit App") { target in
                let builtWatchAppPath = "\(SRCROOT)/build/Debug-watchos/Watchable WatchKit App.app"

                // There should be one actool task
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/watchosApp/Assets.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug-watchos/Watchable WatchKit App.build/assetcatalog_output/\(variant)", "--target-device", "watch", "--minimum-deployment-target", WATCHOS_DEPLOYMENT_TARGET, "--platform", "watchos"])
                    }
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                // There should be a compile storyboard and a link storyboards task.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkOutputs([
                        .path("\(builtWatchAppPath)/Base.lproj/Interface.plist"),
                        .path("\(builtWatchAppPath)/Base.lproj/Interface-glance.plist"),
                        .path("\(builtWatchAppPath)/Base.lproj/Interface-notification.plist"),
                    ])

                }

                // There should be a process Info.plist task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    // Ensure the appx is being inspected for the privacy manifest.
                    task.checkInputs(contain: [.name("Watchable WatchKit Extension.appex")])
                }

                // There should be build directory creation tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be a product packaging task for the entitlements file, and one for the provisioning profile.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemBasename("embedded.mobileprovision")) { _ in }

                // There should be tasks to copy the watchOS stub into the app as its binary, and into the sidecar directory.
                results.checkTask(.matchTarget(target), .matchRuleType("CopyAndPreserveArchs"), .matchRuleItem("\(builtWatchAppPath)/Watchable WatchKit App")) { task in
                    task.checkCommandLine(["lipo", "\(core.loadSDK(.watchOS).path.str)/Library/Application Support/WatchKit/WK", "-output", "\(builtWatchAppPath)/Watchable WatchKit App", "-extract", "arm64_32"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CopyAndPreserveArchs"), .matchRuleItem("\(builtWatchAppPath)/_WatchKitStub/WK")) { task in
                    task.checkCommandLine(["lipo", "\(core.loadSDK(.watchOS).path.str)/Library/Application Support/WatchKit/WK", "-output", "\(builtWatchAppPath)/_WatchKitStub/WK", "-extract", "arm64_32"])
                }

                // There should be a task to embed the watchOS extension and another to validate it.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable WatchKit Extension.appex")) { task in
                    task.checkCommandLineContains(["builtin-copy", "\(SRCROOT)/build/Debug-watchos/Watchable WatchKit Extension.appex", "\(builtWatchAppPath)/PlugIns"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItemBasename("Watchable WatchKit Extension.appex")) { task in
                    task.checkCommandLineContains(["embeddedBinaryValidationUtility", "\(builtWatchAppPath)/PlugIns/Watchable WatchKit Extension.appex", "-signing-cert", "105DE4E702E4", "-info-plist-path", "\(builtWatchAppPath)/Info.plist"])
                }

                // There should be a task to embed the Swift standard libraries.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLineContains(["builtin-swiftStdLibTool", "--scan-executable", "\(builtWatchAppPath)/Watchable WatchKit App", "--scan-folder", "\(builtWatchAppPath)/Frameworks", "--scan-folder", "\(builtWatchAppPath)/PlugIns", "--platform", "watchos", "--destination",  "\(builtWatchAppPath)/Frameworks"])
                }

                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    #expect(task.ruleInfo[1] == builtWatchAppPath)
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-watchos/Watchable WatchKit App.build/Watchable WatchKit App.app.xcent", "--timestamp=none", "--generate-entitlement-der", builtWatchAppPath])
                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE": .equal("codesign_allocate"),
                    ], exact: true)
                }

                // There should be one product validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Validate"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLine(["builtin-validationUtility", builtWatchAppPath, "-shallow-bundle", "-infoplist-subpath", "Info.plist"])
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the iOS app
            results.checkTarget("Watchable") { target in
                let builtHostIOSAppPath = "\(SRCROOT)/build/Debug-iphoneos/Watchable.app"


                // We should have one clang, one swiftc, and link task per arch.
                for arch in archs {
                    // CompileC
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("main.m"), .matchRuleItem(arch)) { task in
                        task.checkRuleInfo([.equal("CompileC"), .suffix("main.o"), .suffix("main.m"), .equal("normal"), .equal(arch), .equal("objective-c"), .any])
                        let expectedCommandLine: [String] = [
                            ["clang"],
                            ["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"],
                            ["-isysroot", core.loadSDK(.iOS).path.str],
                            ["-o", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/Watchable.build/Objects-normal/\(arch)/main.o"]
                        ].reduce([], +)
                        task.checkCommandLineContains(expectedCommandLine)
                        #expect(!task.commandLine.contains("-fasm-blocks"))
                    }
                    // SwiftDriver
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"), .matchRuleItem(arch)) { task in
                        task.checkRuleInfo(["SwiftDriver Compilation", "Watchable", .equal("normal"), .equal(arch), .equal("com.apple.xcode.tools.swift.compiler")])
                        let responseFilePath = "@\(SRCROOT)/build/aProject.build/Debug-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name).SwiftFileList"
                        task.checkCommandLineContains([swiftCompilerPath.str, responseFilePath, "-sdk", core.loadSDK(.iOS).path.str, "-target", "\(arch)-apple-ios\(core.loadSDK(.iOS).defaultDeploymentTarget)"])
                    }

                    results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"), .matchRuleItem(arch))

                    // Ld
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem(arch)) { task in
                        #expect(!task.commandLine.contains("__entitlements"))
                    }
                }

                // There should be two actool tasks
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/iosApp/Assets.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/Watchable.build/assetcatalog_output/\(variant)", "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", IPHONEOS_DEPLOYMENT_TARGET, "--platform", "iphoneos"])
                    }
                }
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/iosApp/Assets.xcassets", "--compile", "\(SRCROOT)/build/Debug-iphoneos/Watchable.app", "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", IPHONEOS_DEPLOYMENT_TARGET, "--platform", "iphoneos", "--bundle-identifier", "com.test.aProject",  "--generate-swift-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/Watchable.build/DerivedSources/GeneratedAssetSymbols.swift", "--generate-objc-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/Watchable.build/DerivedSources/GeneratedAssetSymbols.h"])
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                // There should be a compile storyboard and a link storyboards task (host iOS app)
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkOutputs([
                        .path("\(builtHostIOSAppPath)/Base.lproj/Main.storyboardc"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Watchable-Swift.h"), .matchRuleItemBasename("Watchable-Swift.h")) { _ in }

                for arch in archs {
                    // There should be tasks to copy the associated Swift files.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftdoc"), .matchRuleItemBasename("\(arch)-apple-ios.swiftdoc")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftmodule"), .matchRuleItemBasename("\(arch)-apple-ios.swiftmodule")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftsourceinfo"), .matchRuleItemBasename("\(arch)-apple-ios.swiftsourceinfo")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.abi.json"), .matchRuleItemBasename("\(arch)-apple-ios.abi.json")) { _ in }
                }

                // There should be a process Info.plist task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }

                // There should be a product packaging task for the entitlements file, and one for the provisioning profile.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemBasename("embedded.mobileprovision")) { _ in }

                // There should be one GenerateDSYMFile task.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { _ in }

                // There should be a task to embed the watchOS app and another to validate it.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLineContains(["builtin-copy", "\(SRCROOT)/build/Debug-watchos/Watchable WatchKit App.app", "\(builtHostIOSAppPath)/Watch"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLineContains(["embeddedBinaryValidationUtility", "\(builtHostIOSAppPath)/Watch/Watchable WatchKit App.app", "-signing-cert", "105DE4E702E4", "-info-plist-path", "\(builtHostIOSAppPath)/Info.plist"])
                }

                // There should be a task to embed the Swift standard libraries.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs"), .matchRuleItemBasename("Watchable.app")) { task in
                    task.checkCommandLineContains(["builtin-swiftStdLibTool", "--scan-executable", "\(builtHostIOSAppPath)/Watchable", "--scan-folder", "\(builtHostIOSAppPath)/Frameworks", "--scan-folder", "\(builtHostIOSAppPath)/PlugIns", "--platform", "iphoneos", "--destination",  "\(builtHostIOSAppPath)/Frameworks"])
                }

                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    #expect(task.ruleInfo[1] == builtHostIOSAppPath)
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/Watchable.build/Watchable.app.xcent", "--timestamp=none", "--generate-entitlement-der", builtHostIOSAppPath])
                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE": .equal("codesign_allocate"),
                    ], exact: true)
                }

                // There should be one product validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Validate"), .matchRuleItemBasename("Watchable.app")) { task in
                    task.checkCommandLine(["builtin-validationUtility", builtHostIOSAppPath, "-shallow-bundle", "-infoplist-subpath", "Info.plist"])
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check the debug build, for the simulator.
        await tester.checkBuild(runDestination: .iOSSimulator, fs: fs) { results in
            // Ignore certain classes of tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check the watchOS extension
            results.checkTarget("Watchable WatchKit Extension") { target in
                let arch = "x86_64"
                let variant = "normal"

                // There should be one clang and one swiftc task.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("Controller.m")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Controller.o"), .suffix("Controller.m"), .equal(variant), .equal(arch), .equal("objective-c"), .any])
                    let expectedCommandLine: [String] = [
                        ["clang"],
                        ["-target", "\(arch)-apple-watchos\(WATCHOS_DEPLOYMENT_TARGET)-simulator"],
                        ["-isysroot", core.loadSDK(.watchOSSimulator).path.str],
                        ["-o", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Objects-\(variant)/\(arch)/Controller.o"]
                    ].reduce([], +)
                    task.checkCommandLineContains(expectedCommandLine)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "Watchable WatchKit Extension", .equal(variant), .equal(arch), .equal("com.apple.xcode.tools.swift.compiler")])
                    let responseFilePath = "@\(SRCROOT)/build/aProject.build/Debug-watchsimulator/\(target.target.name).build/Objects-\(variant)/\(arch)/\(target.target.name).SwiftFileList"
                    task.checkCommandLineContains([swiftCompilerPath.str, responseFilePath, "-sdk", core.loadSDK(.watchOSSimulator).path.str, "-target", "x86_64-apple-watchos\(core.loadSDK(.watchOS).defaultDeploymentTarget)-simulator"])
                }

                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))

                // There should be one link task
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let expectedCommandLine: [String] = [
                        ["clang"],
                        ["-target", "x86_64-apple-watchos\(WATCHOS_DEPLOYMENT_TARGET)-simulator"],
                        ["-isysroot", core.loadSDK(.watchOSSimulator).path.str, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks"],
                        ["-fapplication-extension", "\(SRCROOT)/build/Debug-watchsimulator/Watchable WatchKit Extension.appex/Watchable WatchKit Extension"]
                    ].reduce([], +)
                    task.checkCommandLineContains(expectedCommandLine)
                }

                // There should be tasks to copy the associated Swift files.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftdoc"), .matchRuleItemBasename("x86_64-apple-watchos-simulator.swiftdoc")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Watchable_WatchKit_Extension-Swift.h"), .matchRuleItemBasename("Watchable_WatchKit_Extension-Swift.h")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftmodule"), .matchRuleItemBasename("x86_64-apple-watchos-simulator.swiftmodule")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftsourceinfo"), .matchRuleItemBasename("x86_64-apple-watchos-simulator.swiftsourceinfo")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.abi.json"), .matchRuleItemBasename("x86_64-apple-watchos-simulator.abi.json")) { _ in }

                // There should be two actool tasks
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/watchosExtension/Assets.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/assetcatalog_output/\(variant)", "--target-device", "watch", "--complication", "Complication", "--minimum-deployment-target", WATCHOS_DEPLOYMENT_TARGET, "--platform", "watchsimulator"])
                    }
                }
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/watchosExtension/Assets.xcassets", "--compile", "\(SRCROOT)/build/Debug-watchsimulator/Watchable WatchKit Extension.appex", "--target-device", "watch", "--complication", "Complication", "--minimum-deployment-target", WATCHOS_DEPLOYMENT_TARGET, "--platform", "watchsimulator", "--bundle-identifier", "com.test.aProject", "--generate-swift-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/DerivedSources/GeneratedAssetSymbols.swift", "--generate-objc-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/DerivedSources/GeneratedAssetSymbols.h"])
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                // Ensure the privacy file is copied.
                results.checkTask(.matchTarget(target), .matchRuleType("CopyPlistFile")) { task in
                    task.checkInputs(contain: [.name("PrivacyInfo.xcprivacy")])
                    task.checkOutputs(contain: [.name("PrivacyInfo.xcprivacy")])
                }

                // There should be a process Info.plist task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }

                // There should be one GenerateDSYMFile task.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { _ in }

                // There should be a task to generate the entitlements file.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Watchable WatchKit Extension.appex.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Watchable WatchKit Extension.appex.xcent", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Watchable WatchKit Extension.appex.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Watchable WatchKit Extension.appex-Simulated.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Watchable WatchKit Extension.appex-Simulated.xcent", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Watchable WatchKit Extension.appex-Simulated.xcent.der"])) { _ in }

                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    #expect(task.ruleInfo[1] == "\(SRCROOT)/build/Debug-watchsimulator/Watchable WatchKit Extension.appex")
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit Extension.build/Watchable WatchKit Extension.appex.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug-watchsimulator/Watchable WatchKit Extension.appex"])
                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE": .equal("codesign_allocate"),
                    ], exact: true)
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            results.checkTarget("Watchable WatchKit Extension (old)") { target in
            }

            // Check the watchOS app
            let builtWatchAppPath = "\(SRCROOT)/build/Debug-watchsimulator/Watchable WatchKit App.app"
            results.checkTarget("Watchable WatchKit App") { target in
                // There should be one actool task
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/watchosApp/Assets.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/assetcatalog_output/\(variant)", "--target-device", "watch", "--minimum-deployment-target", WATCHOS_DEPLOYMENT_TARGET,  "--platform", "watchsimulator"])
                    }
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                // There should be a compile storyboard and a link storyboards task.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkOutputs([
                        .path("\(builtWatchAppPath)/Base.lproj/Interface.plist"),
                        .path("\(builtWatchAppPath)/Base.lproj/Interface-glance.plist"),
                        .path("\(builtWatchAppPath)/Base.lproj/Interface-notification.plist"),
                    ])
                }

                // There should be a process Info.plist task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }

                // There should be tasks to copy the watchOS stub into the app as its binary, and into the sidecar directory.
                results.checkTask(.matchTarget(target), .matchRuleType("CopyAndPreserveArchs"), .matchRuleItem("\(builtWatchAppPath)/Watchable WatchKit App")) { task in
                    task.checkCommandLine(["lipo", "\(core.loadSDK(.watchOSSimulator).path.str)/Library/Application Support/WatchKit/WK", "-output", "\(builtWatchAppPath)/Watchable WatchKit App", "-extract", "x86_64"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CopyAndPreserveArchs"), .matchRuleItem("\(builtWatchAppPath)/_WatchKitStub/WK")) { task in
                    task.checkCommandLine(["lipo", "\(core.loadSDK(.watchOSSimulator).path.str)/Library/Application Support/WatchKit/WK", "-output", "\(builtWatchAppPath)/_WatchKitStub/WK", "-extract", "x86_64"])
                }

                // There should be a task to embed the watchOS extension and another to validate it.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable WatchKit Extension.appex")) { task in
                    task.checkCommandLineContains(["builtin-copy", "\(SRCROOT)/build/Debug-watchsimulator/Watchable WatchKit Extension.appex", "\(builtWatchAppPath)/PlugIns"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItemBasename("Watchable WatchKit Extension.appex")) { task in
                    task.checkCommandLineContains(["embeddedBinaryValidationUtility", "\(builtWatchAppPath)/PlugIns/Watchable WatchKit Extension.appex", "-signing-cert", "105DE4E702E4", "-info-plist-path", "\(builtWatchAppPath)/Info.plist"])
                }

                // There should be a task to embed the Swift standard libraries.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLineContains(["builtin-swiftStdLibTool", "--scan-executable", "\(builtWatchAppPath)/Watchable WatchKit App", "--scan-folder", "\(builtWatchAppPath)/Frameworks", "--scan-folder", "\(builtWatchAppPath)/PlugIns", "--platform", "watchsimulator", "--destination",  "\(builtWatchAppPath)/Frameworks"])
                }

                // There should be a task to generate the entitlements file.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/Watchable WatchKit App.app.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/Watchable WatchKit App.app.xcent", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/Watchable WatchKit App.app.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/Watchable WatchKit App.app-Simulated.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/Watchable WatchKit App.app-Simulated.xcent", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/Watchable WatchKit App.app-Simulated.xcent.der"])) { _ in }

                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    #expect(task.ruleInfo[1] == builtWatchAppPath)
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/Watchable WatchKit App.build/Watchable WatchKit App.app.xcent", "--timestamp=none", "--generate-entitlement-der", builtWatchAppPath])
                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE": .equal("codesign_allocate"),
                    ], exact: true)
                }

                // There should be one product validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Validate"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLine(["builtin-validationUtility", builtWatchAppPath, "-shallow-bundle", "-infoplist-subpath", "Info.plist"])
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the iOS app
            results.checkTarget("Watchable") { target in
                let builtHostIOSAppPath = "\(SRCROOT)/build/Debug-iphonesimulator/Watchable.app"

                // We should have one clang, one swiftc, and link task per arch.
                for arch in ["x86_64"] {
                    // CompileC
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("main.m"), .matchRuleItem(arch)) { task in
                        task.checkRuleInfo([.equal("CompileC"), .suffix("main.o"), .suffix("main.m"), .equal("normal"), .equal(arch), .equal("objective-c"), .any])
                        let expectedCommandLine: [String] = [
                            ["clang"],
                            ["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)-simulator"],
                            ["-isysroot", core.loadSDK(.iOSSimulator).path.str, "-fasm-blocks"],
                            ["-o", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Objects-normal/\(arch)/main.o"]
                        ].reduce([], +)
                        task.checkCommandLineContains(expectedCommandLine)
                    }
                    // SwiftDriver
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkRuleInfo(["SwiftDriver Compilation", "Watchable", .equal("normal"), .equal(arch), .equal("com.apple.xcode.tools.swift.compiler")])
                        let responseFilePath = "@\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name).SwiftFileList"
                        task.checkCommandLineContains([swiftCompilerPath.str, responseFilePath, "-sdk", core.loadSDK(.iOSSimulator).path.str, "-target", "\(arch)-apple-ios\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)-simulator"])
                    }

                    results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))

                    // Ld
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    }
                }

                // There should be two actool tasks
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/iosApp/Assets.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/assetcatalog_output/\(variant)", "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", IPHONEOS_DEPLOYMENT_TARGET, "--platform", "iphonesimulator"])
                    }
                }
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkCommandLineContains([actoolPath.str, "\(SRCROOT)/Sources/iosApp/Assets.xcassets", "--compile", builtHostIOSAppPath, "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", IPHONEOS_DEPLOYMENT_TARGET, "--platform", "iphonesimulator", "--bundle-identifier", "com.test.aProject", "--generate-swift-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/DerivedSources/GeneratedAssetSymbols.swift", "--generate-objc-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/DerivedSources/GeneratedAssetSymbols.h"])
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                // There should be a compile storyboard and a link storyboards task.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkOutputs([
                        .path("\(builtHostIOSAppPath)/Base.lproj/Main.storyboardc"),
                    ])
                }

                // There should be tasks to copy the associated Swift files.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftdoc"), .matchRuleItemBasename("x86_64-apple-ios-simulator.swiftdoc")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Watchable-Swift.h"), .matchRuleItemBasename("Watchable-Swift.h")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftmodule"), .matchRuleItemBasename("x86_64-apple-ios-simulator.swiftmodule")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftsourceinfo"), .matchRuleItemBasename("x86_64-apple-ios-simulator.swiftsourceinfo")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.abi.json"), .matchRuleItemBasename("x86_64-apple-ios-simulator.abi.json")) { _ in }

                // There should be a process Info.plist task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }

                // There should be one GenerateDSYMFile task.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { _ in }

                // There should be a task to embed the watchOS app and another to validate it.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLineContains(["builtin-copy", builtWatchAppPath, "\(builtHostIOSAppPath)/Watch"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItemBasename("Watchable WatchKit App.app")) { task in
                    task.checkCommandLineContains(["embeddedBinaryValidationUtility", "\(builtHostIOSAppPath)/Watch/Watchable WatchKit App.app", "-signing-cert", "105DE4E702E4", "-info-plist-path", "\(builtHostIOSAppPath)/Info.plist"])
                }

                // There should be a task to embed the Swift standard libraries.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs"), .matchRuleItemBasename("Watchable.app")) { task in
                    task.checkCommandLineContains(["builtin-swiftStdLibTool", "--scan-executable", "\(builtHostIOSAppPath)/Watchable", "--scan-folder", "\(builtHostIOSAppPath)/Frameworks", "--scan-folder", "\(builtHostIOSAppPath)/PlugIns", "--platform", "iphonesimulator", "--destination",  "\(builtHostIOSAppPath)/Frameworks"])
                }

                // There should be a task to generate the entitlements file.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Watchable.app.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Watchable.app.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Watchable.app.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Watchable.app-Simulated.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Watchable.app-Simulated.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Watchable.app-Simulated.xcent.der"])) { _ in }

                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    #expect(task.ruleInfo[1] == builtHostIOSAppPath)
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/Watchable.build/Watchable.app.xcent", "--timestamp=none", "--generate-entitlement-der", builtHostIOSAppPath])
                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE": .equal("codesign_allocate"),
                    ], exact: true)
                }

                // There should be one product validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Validate"), .matchRuleItemBasename("Watchable.app")) { task in
                    task.checkCommandLine(["builtin-validationUtility", builtHostIOSAppPath, "-shallow-bundle", "-infoplist-subpath", "Info.plist"])
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build for the device.
        let installParameters = BuildParameters(action: .install, configuration: "Debug")
        await tester.checkBuild(installParameters, runDestination: .macOS, fs: fs) { results in
            // Ignore certain classes of tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check the watchOS extension
            results.checkTarget("Watchable WatchKit Extension") { target in
                let relBuiltWatchExtensionPath = "../UninstalledProducts/watchos/Watchable WatchKit Extension.appex"
                let builtWatchExtensionPath = "\(SRCROOT)/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex"

                // Consume all the tasks which also exist for the non-install build.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftdoc"), .matchRuleItemBasename("arm64_32-apple-watchos.swiftdoc"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Watchable_WatchKit_Extension-Swift.h"), .matchRuleItemBasename("Watchable_WatchKit_Extension-Swift.h"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable_WatchKit_Extension.swiftmodule"), .matchRuleItemBasename("arm64_32-apple-watchos.swiftmodule"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Copy"),   .matchRuleItemBasename("Watchable_WatchKit_Extension.abi.json"), .matchRuleItemBasename("arm64_32-apple-watchos.abi.json"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("GenerateAssetSymbols"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent")))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent")))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("GenerateDSYMFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CodeSign"))
                results.checkTasks(.matchTarget(target), .matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileC"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))

                // Ensure the privacy file is copied.
                results.checkTask(.matchTarget(target), .matchRuleType("CopyPlistFile")) { task in
                    task.checkInputs(contain: [.name("PrivacyInfo.xcprivacy")])
                    task.checkOutputs(contain: [.name("PrivacyInfo.xcprivacy")])
                }

                // There should be a task to generate the provisioning file.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".mobileprovision"))) { task in
                    task.checkRuleInfo([.equal("ProcessProductPackaging"), .suffix(".mobileprovision"), .equal("\(builtWatchExtensionPath)/embedded.mobileprovision")])
                }

                // There should be SetOwnerAndGroup, SetMode and Strip tasks.
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { task in
                    task.checkRuleInfo([.equal("SetOwnerAndGroup"), .equal("exampleUser:exampleGroup"), .equal(builtWatchExtensionPath)])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { task in
                    task.checkRuleInfo([.equal("SetMode"), .equal("u+w,go-w,a+rX"), .equal(builtWatchExtensionPath)])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { task in
                    task.checkRuleInfo([.equal("Strip"), .equal("\(builtWatchExtensionPath)/Watchable WatchKit Extension")])
                }

                // There should be a Symlink task to the BUILT_PRODUCTS_DIR.
                results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                    task.checkRuleInfo([.equal("SymLink"), .equal("\(SRCROOT)/build/Debug-watchos/Watchable WatchKit Extension.appex"), .equal(relBuiltWatchExtensionPath)])
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            results.checkTarget("Watchable WatchKit Extension (old)") { target in
            }

            // Check the watchOS app
            results.checkTarget("Watchable WatchKit App") { target in
                let relBuiltWatchAppPath = "../UninstalledProducts/watchos/Watchable WatchKit App.app"
                let builtWatchAppPath = "\(SRCROOT)/build/UninstalledProducts/watchos/Watchable WatchKit App.app"

                // Consume all the tasks which also exist for the non-install build.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkOutputs([
                        .path("\(builtWatchAppPath)/Base.lproj/Interface.plist"),
                        .path("\(builtWatchAppPath)/Base.lproj/Interface-glance.plist"),
                        .path("\(builtWatchAppPath)/Base.lproj/Interface-notification.plist"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent.der"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopyAndPreserveArchs"), .matchRuleItem("\(builtWatchAppPath)/Watchable WatchKit App")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopyAndPreserveArchs"), .matchRuleItem("\(builtWatchAppPath)/_WatchKitStub/WK")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable WatchKit Extension.appex")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { _ in }

                // There should be a task to generate the provisioning file.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".mobileprovision"))) { task in
                    task.checkRuleInfo([.equal("ProcessProductPackaging"), .suffix(".mobileprovision"), .equal("\(builtWatchAppPath)/embedded.mobileprovision")])
                }

                // There should be SetOwnerAndGroup, SetMode and Validate tasks.  But no Strip task, since the watchOS stub doesn't get stripped.
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { task in
                    task.checkRuleInfo([.equal("SetOwnerAndGroup"), .equal("exampleUser:exampleGroup"), .equal(builtWatchAppPath)])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { task in
                    task.checkRuleInfo([.equal("SetMode"), .equal("u+w,go-w,a+rX"), .equal(builtWatchAppPath)])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Validate")) { task in
                    task.checkRuleInfo([.equal("Validate"), .equal(builtWatchAppPath)])
                }

                // There should be a Symlink task to the BUILT_PRODUCTS_DIR.
                results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                    task.checkRuleInfo([.equal("SymLink"), .equal("\(SRCROOT)/build/Debug-watchos/Watchable WatchKit App.app"), .equal(relBuiltWatchAppPath)])
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the iOS app
            results.checkTarget("Watchable") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateAssetSymbols")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { _ in }

                for arch in archs {
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftdoc"), .matchRuleItemBasename("\(arch)-apple-ios.swiftdoc")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.swiftmodule"), .matchRuleItemBasename("\(arch)-apple-ios.swiftmodule")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable.abi.json"), .matchRuleItemBasename("\(arch)-apple-ios.abi.json")) { _ in }
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Watchable-Swift.h"), .matchRuleItemBasename("Watchable-Swift.h")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent.der"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Watchable WatchKit App.app")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItemBasename("Watchable WatchKit App.app")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs"), .matchRuleItemBasename("Watchable.app")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { _ in }

                for arch in archs {
                    results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem(arch))
                    results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"), .matchRuleItem(arch))
                    results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"), .matchRuleItem(arch))
                    results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem(arch))
                }

                // There should be a task to generate the provisioning file.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".mobileprovision"))) { task in
                    task.checkRuleInfo([.equal("ProcessProductPackaging"), .suffix(".mobileprovision"), .equal("/tmp/aProject.dst/Applications/Watchable.app/embedded.mobileprovision")])
                }

                // There should be SetOwnerAndGroup, SetMode, Strip and Validate tasks.
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { task in
                    task.checkRuleInfo([.equal("SetOwnerAndGroup"), .equal("exampleUser:exampleGroup"), .equal("/tmp/aProject.dst/Applications/Watchable.app")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { task in
                    task.checkRuleInfo([.equal("SetMode"), .equal("u+w,go-w,a+rX"), .equal("/tmp/aProject.dst/Applications/Watchable.app")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { task in
                    task.checkRuleInfo([.equal("Strip"), .equal("/tmp/aProject.dst/Applications/Watchable.app/Watchable")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Validate")) { task in
                    task.checkRuleInfo([.equal("Validate"), .equal("/tmp/aProject.dst/Applications/Watchable.app")])
                }

                // There should be a Symlink task to the BUILT_PRODUCTS_DIR.
                results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                    task.checkRuleInfo([.equal("SymLink"), .equal("\(SRCROOT)/build/Debug-iphoneos/Watchable.app"), .equal("../../../../aProject.dst/Applications/Watchable.app")])
                }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test a watch-only app.
    @Test(.requireSDKs(.iOS, .watchOS))
    func watchOnlyApp() async throws {

        let core = try await getCore()
        let testProject = try await TestProject(
            "aProject",
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
                    TestFile("watchosExtension/PrivacyInfo.xcprivacy"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "IBC_EXEC": ibtoolPath.str,
                        "ENABLE_ON_DEMAND_RESOURCES": "NO",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "SDKROOT": "iphoneos",
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
                            // The target must at least HAVE an empty phase for the automatic asset catalog to work
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
                            "watchosExtension/PrivacyInfo.xcprivacy",
                        ]),
                    ]
                ),
            ])
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let IPHONEOS_DEPLOYMENT_TARGET = "13.0" // watch-only app stub containers are hardcoded to 13.0 by default

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        try fs.createDirectory(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
        try fs.createDirectory(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
        try fs.createDirectory(core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub"), recursive: true)
        try await fs.writeAssetCatalog(core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub.xcassets"), .appIcon("MessagesApplicationStub"))
        try fs.write(core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub"), contents: "stub")

        let actoolPath = try await self.actoolPath

        // Check the debug build, for the device.
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // Ignore certain classes of tasks.
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "MkDir", "ProcessProductPackaging", "ProcessProductPackagingDER", "Copy", "RegisterExecutionPolicyException", "Touch", "Validate", "ValidateEmbeddedBinary", "WriteAuxiliaryFile"])

            // Check the shim app
            results.checkTarget("Watchable") { target in
                // There should be one actool task
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub.xcassets").normalize().str, "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/Watchable.build/assetcatalog_output/\(variant)", "--target-device", "iphone", "--minimum-deployment-target", IPHONEOS_DEPLOYMENT_TARGET, "--platform", "iphoneos"])
                    }
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyAndPreserveArchs", "\(SRCROOT)/build/Debug-iphoneos/Watchable.app/Watchable"])) { _ in }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            results.checkNoDiagnostics()
        }
    }

    /// Test a watch-only app when trying to thin all architectures out of the stub.
    @Test(.requireSDKs(.iOS, .watchOS))
    func watchOnlyAppStubThinning() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "IBC_EXEC": ibtoolPath.str,
                        "ENABLE_ON_DEMAND_RESOURCES": "NO",
                        "EXCLUDED_ARCHS": "$(VALID_ARCHS)",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "SDKROOT": "iphoneos",
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
                            // The target must at least HAVE an empty phase for the automatic asset catalog to work
                        ]),
                    ],
                    dependencies: ["Watchable WatchKit App"]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let IPHONEOS_DEPLOYMENT_TARGET = "13.0" // watch-only app stub containers are hardcoded to 13.0 by default

        let actoolPath = try await self.actoolPath

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        try fs.createDirectory(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
        try fs.createDirectory(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
        try fs.createDirectory(core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub"), recursive: true)
        try await fs.writeAssetCatalog(core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub.xcassets"), .appIcon("MessagesApplicationStub"))
        try fs.write(core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub"), contents: "stub")

        // Check the debug build, for the device.
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // Ignore certain classes of tasks.
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "MkDir", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "Touch", "Validate", "ValidateEmbeddedBinary", "WriteAuxiliaryFile"])

            // Check the shim app
            results.checkTarget("Watchable") { target in
                // There should be one actool task
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains([actoolPath.str, core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub.xcassets").normalize().str, "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/Watchable.build/assetcatalog_output/\(variant)", "--target-device", "iphone", "--minimum-deployment-target", IPHONEOS_DEPLOYMENT_TARGET, "--platform", "iphoneos"])
                    }
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))

                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/Watchable.app/Watchable", core.loadSDK(.iOS).path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub").normalize().str])) { _ in }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func archivingMultipleWatchSidecars() async throws {

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // iOS app files
                    TestFile("iosApp/main.m"),
                    TestFile("iosApp/Info.plist"),

                    // watchOS app files
                    TestFile("watchosApp/Info.plist"),

                    // watchOS extension files
                    TestFile("watchosExtension/Controller.m"),
                    TestFile("watchosExtension/Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "SDKROOT": "iphoneos",
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Watchable",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INFOPLIST_FILE": "Sources/iosApp/Info.plist",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                        TestCopyFilesBuildPhase([
                            "Watchable WatchKit App.app",
                            "Watchable WatchKit App 2.app",
                        ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                               ),
                    ],
                    dependencies: ["Watchable WatchKit App", "Watchable WatchKit App 2"]
                ),
                TestStandardTarget(
                    "Watchable WatchKit App",
                    type: .watchKitApp,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INFOPLIST_FILE": "Sources/watchosApp/Info.plist",
                                "SDKROOT": "watchos",
                                "SKIP_INSTALL": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "Watchable WatchKit Extension.appex",
                        ], destinationSubfolder: .plugins, onlyForDeployment: false
                                               ),
                    ],
                    dependencies: ["Watchable WatchKit Extension"]
                ),
                TestStandardTarget(
                    "Watchable WatchKit App 2",
                    type: .watchKitApp,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INFOPLIST_FILE": "Sources/watchosApp/Info.plist",
                                "SDKROOT": "watchos",
                                "SKIP_INSTALL": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "Watchable WatchKit Extension.appex",
                        ], destinationSubfolder: .plugins, onlyForDeployment: false
                                               ),
                    ],
                    dependencies: ["Watchable WatchKit Extension"]
                ),
                TestStandardTarget(
                    "Watchable WatchKit Extension",
                    type: .watchKitExtension,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INFOPLIST_FILE": "Sources/watchosExtension/Info.plist",
                                "SDKROOT": "watchos",
                                "SKIP_INSTALL": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Controller.m",
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        let fs = PseudoFS()
        try fs.createDirectory(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")

        let params = BuildParameters(action: .archive, configuration: "Debug", overrides: ["WATCHKIT_2_SUPPORT_FOLDER_PATH": "/tmp/SideCars"])
        await tester.checkBuild(params, runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRule(["CopyAndPreserveArchs", "/tmp/SideCars/WK"])) { task in
                // This is a target-independent task because multiple apps may exist in the same project but share a single stub
                #expect(task.forTarget == nil)

                // Stub thinning is enabled by default for the app targets, and so that should propagate to copying the shared stub using lipo instead of a plain copy
                task.checkCommandLine(["lipo", core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit/WK").str, "-output", "/tmp/SideCars/WK", "-extract", "arm64", "-extract", "arm64_32"])
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func watchKitSettingsBundleDeprecation() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("Settings-Watch.bundle"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Watchable",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Settings-Watch.bundle"
                        ]),
                    ],
                    dependencies: []
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Expect a warning when deploying to iOS 13 or later.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["IPHONEOS_DEPLOYMENT_TARGET": "13.0"]), runDestination: .iOS) { results in
            results.checkWarning(.equal("WatchKit Settings bundles in iOS apps are deprecated. (in target 'Watchable' from project 'aProject')"))
            results.checkNoDiagnostics()
        }

        // Expect no warning for earlier deployment targets.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["IPHONEOS_DEPLOYMENT_TARGET": "12.0"]), runDestination: .iOS) { results in
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.watchOS))
    func swiftModulesForArm64AndArm64_32() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                    TestFile("CoreFoo.h"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "watchos",
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "CODE_SIGNING_ALLOWED": "NO",
                                                "SWIFT_VERSION": swiftVersion,
                                                "TAPI_EXEC": tapiToolPath.str,
                                                "ARCHS": "arm64 arm64_32",
                                                "INFOPLIST_FILE": "Sources/Info.plist"
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.swift"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("CoreFoo.h", headerVisibility: .public),
                        ]),
                    ])
            ])

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .anywatchOSDevice) { results in
            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"), .matchRuleItemPattern("arm64")) { task in
                    task.checkCommandLineContains(["\(SRCROOT)/build/aProject.build/Debug-watchos/CoreFoo.build/Objects-normal/arm64/CoreFoo.swiftmodule"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"), .matchRuleItemPattern("arm64_32")) { task in
                    task.checkCommandLineContains(["\(SRCROOT)/build/aProject.build/Debug-watchos/CoreFoo.build/Objects-normal/arm64_32/CoreFoo.swiftmodule"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug-watchos/CoreFoo.framework/Modules/CoreFoo.swiftmodule/arm64-apple-watchos.swiftmodule")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug-watchos/CoreFoo.framework/Modules/CoreFoo.swiftmodule/arm64_32-apple-watchos.swiftmodule")) { _ in }
            }
        }
    }
}
