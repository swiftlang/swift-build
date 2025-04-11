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

import SWBTaskConstruction
import SWBProtocol

@Suite
fileprivate struct InstallLocTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func installLocBasics() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("foo.xib", children: [
                        TestFile("Base.lproj/foo.xib", regionVariantName: "Base"),
                        TestFile("en.lproj/foo.strings", regionVariantName: "en"),
                        TestFile("de.lproj/foo.strings", regionVariantName: "de"),
                    ]),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Localizable.strings", regionVariantName: "de"),
                        TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                    ]),
                    TestVariantGroup("Main.storyboard", children: [
                        TestFile("Base.lproj/Main.storyboard", regionVariantName: "Base"),
                        TestFile("en.lproj/Main.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Main.strings", regionVariantName: "de"),
                        TestFile("ja.lproj/Main.strings", regionVariantName: "ja"),
                    ]),
                    TestVariantGroup("Intents.intentdefinition", children: [
                        TestFile("Base.lproj/Intents.intentdefinition", regionVariantName: "Base"),
                        TestFile("de.lproj/Intents.strings", regionVariantName: "de"),
                        TestFile("ja.lproj/Intents.strings", regionVariantName: "ja"),
                    ])
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "IBC_EXEC": ibtoolPath.str,
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xib",
                            "Localizable.strings",
                            "Main.storyboard"
                        ]),
                        TestSourcesBuildPhase([
                            // Intent definition files appear in the "Compile Sources" phase
                            "Intents.intentdefinition"
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .macOS) { results in
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/App.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/App.app/Contents"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/App.app/Contents/Resources"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/Debug/App.app", "../../../../aProject.dst/Applications/App.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "/tmp/Test/aProject/Sources/Base.lproj/foo.xib"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/en.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Intents.strings", "/tmp/Test/aProject/Sources/de.lproj/Intents.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ja.lproj/Intents.strings", "/tmp/Test/aProject/Sources/ja.lproj/Intents.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileStoryboard", "/tmp/Test/aProject/Sources/Base.lproj/Main.storyboard"])) { _ in }
                if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                    results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/empty.plist"])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/aProject.dst/Applications/App.app/Contents/Info.plist", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/empty.plist"])) { _ in }
                }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // INSTALLLOC_LANGUAGE set to "de" should only have de.lproj/foo.strings and not Base.lproj/foo.xib in the output.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "de"]), runDestination: .macOS) { results in
            // Ignore all Gate, build directory, MkDir, and SymLink tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/foo.strings", "/tmp/Test/aProject/Sources/de.lproj/foo.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Main.strings", "/tmp/Test/aProject/Sources/de.lproj/Main.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Intents.strings", "/tmp/Test/aProject/Sources/de.lproj/Intents.strings"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // INSTALLLOC_LANGUAGE can also be set to a string list of language codes
        // These would generally contain all languages other than English, but could differ.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "de ja"]), runDestination: .macOS) { results in
            // Ignore all Gate, build directory, MkDir, and SymLink tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/foo.strings", "/tmp/Test/aProject/Sources/de.lproj/foo.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Main.strings", "/tmp/Test/aProject/Sources/de.lproj/Main.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ja.lproj/Main.strings", "/tmp/Test/aProject/Sources/ja.lproj/Main.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/de.lproj/Intents.strings", "/tmp/Test/aProject/Sources/de.lproj/Intents.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ja.lproj/Intents.strings", "/tmp/Test/aProject/Sources/ja.lproj/Intents.strings"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Check that we don't generate any tasks for any resources that don't exist in an lproj.
    @Test(.requireSDKs(.macOS))
    func installLocIgnoreUnlocalizedResources() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.png"),
                    TestFile("com.apple.Foo.plist"),
                    TestFile("AFolderIncorrectlyNamed.lproj/Path/To/Something/NotLocalizable.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "DONT_GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .application,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Foo.png",
                        ]),
                        TestCopyFilesBuildPhase([
                            "com.apple.Foo.plist",
                        ], destinationSubfolder: .resources, onlyForDeployment: false
                                               ),
                        TestCopyFilesBuildPhase([
                            "AFolderIncorrectlyNamed.lproj/Path/To/Something/NotLocalizable.plist",
                        ], destinationSubfolder: .resources, onlyForDeployment: false
                                               ),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .macOS) { results in
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            // Ignore any SymLink tasks
            results.checkTasks(.matchRuleType("SymLink")) { _ in }

            // Ignore intent dependency
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test an App that has an embedded bundle (.appex in this case)
    @Test(.requireSDKs(.iOS, .watchOS))
    func embeddedBundles() async throws {

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // iOS app files
                    TestFile("iosApp/main.m"),
                    TestFile("iosApp/Main.storyboard"),
                    TestFile("iosApp/Assets.xcassets"),
                    TestFile("iosApp/Info.plist"),

                    // watchOS app files
                    TestFile("watchosApp/Interface.storyboard"),
                    TestFile("watchosApp/Info.plist"),

                    // watchOS extension files
                    TestFile("watchosExtension/Controller.m"),
                    TestFile("watchosExtension/Info.plist"),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("watchOSExtension/en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("watchOSExtension/zh_TW.lproj/Localizable.strings", regionVariantName: "zh_TW"),
                        TestFile("watchOSExtension/fr.lproj/Localizable.strings", regionVariantName: "fr"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Release",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Watchable",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Release",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "Sources/iosApp/Info.plist",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
                                                "SDKROOT": "iphoneos"
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                        TestResourcesBuildPhase([
                            "Main.storyboard",
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
                        TestBuildConfiguration("Release",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "Sources/watchosApp/Info.plist",
                                                "SDKROOT": "watchos",
                                                "SKIP_INSTALL": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Interface.storyboard",
                        ]),
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
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                                                "INFOPLIST_FILE": "Sources/watchosExtension/Info.plist",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                                                "SDKROOT": "watchos",
                                                "SKIP_INSTALL": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Controller.m",
                        ]),
                        TestResourcesBuildPhase([
                            "Interface.storyboard",
                            "Localizable.strings",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["DSTROOT": "/tmp/Root"]), runDestination: .macOS) { results in
            // Ignore all Gate, build directory, SymLink, MkDir, and WriteAuxiliaryFile tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("Watchable WatchKit Extension") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex/en.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/watchOSExtension/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/watchOSExtension/zh_TW.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex/fr.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/watchOSExtension/fr.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex/Info.plist", "/tmp/Test/aProject/Sources/watchosExtension/Info.plist"])) { _ in }
            }

            results.checkTarget("Watchable WatchKit App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit App.app/PlugIns/Watchable WatchKit Extension.appex", "/tmp/Test/aProject/build/Release-watchos/Watchable WatchKit Extension.appex"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit App.app/Info.plist", "/tmp/Test/aProject/Sources/watchosApp/Info.plist"])) { _ in }
            }

            results.checkTarget("Watchable") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/Test/aProject/build/Release-iphoneos/Watchable.app/Watch/Watchable WatchKit App.app", "/tmp/Test/aProject/build/Release-watchos/Watchable WatchKit App.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/Root/Applications/Watchable.app/Info.plist", "/tmp/Test/aProject/Sources/iosApp/Info.plist"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // We shouldn't process any InfoPlist files if INSTALLLOC_LANGUAGE is set.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["DSTROOT": "/tmp/Root", "INSTALLLOC_LANGUAGE": "zh_TW"]), runDestination: .macOS) { results in
            // Ignore all Gate, build directory, SymLink, MkDir, and WriteAuxiliaryFile tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("Watchable WatchKit Extension") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/watchOSExtension/zh_TW.lproj/Localizable.strings"])) { _ in }
            }
            results.checkTarget("Watchable WatchKit App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit App.app/PlugIns/Watchable WatchKit Extension.appex", "/tmp/Test/aProject/build/Release-watchos/Watchable WatchKit Extension.appex"])) { task in
                    task.checkCommandLineContains(["-ignore-missing-inputs"])
                }
            }
            results.checkTarget("Watchable") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/Test/aProject/build/Release-iphoneos/Watchable.app/Watch/Watchable WatchKit App.app", "/tmp/Test/aProject/build/Release-watchos/Watchable WatchKit App.app"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // And check when INSTALLLOC_LANGUAGE is set to multiple languages.
        // Still shouldn't process any InfoPlist files.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["DSTROOT": "/tmp/Root", "INSTALLLOC_LANGUAGE": "zh_TW fr"]), runDestination: .macOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("Watchable WatchKit Extension") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/watchOSExtension/zh_TW.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit Extension.appex/fr.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/watchOSExtension/fr.lproj/Localizable.strings"])) { _ in }
            }
            results.checkTarget("Watchable WatchKit App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/Test/aProject/build/UninstalledProducts/watchos/Watchable WatchKit App.app/PlugIns/Watchable WatchKit Extension.appex", "/tmp/Test/aProject/build/Release-watchos/Watchable WatchKit Extension.appex"])) { task in
                    task.checkCommandLineContains(["-ignore-missing-inputs"])
                }
            }
            results.checkTarget("Watchable") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/Test/aProject/build/Release-iphoneos/Watchable.app/Watch/Watchable WatchKit App.app", "/tmp/Test/aProject/build/Release-watchos/Watchable WatchKit App.app"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test an App that has a bundle in copy resources phase
    @Test(.requireSDKs(.iOS))
    func resourceBundles() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // iOS app files
                    TestFile("iosApp/main.m"),
                    TestFile("iosApp/Main.storyboard"),
                    TestFile("iosApp/Assets.xcassets"),
                    TestFile("iosApp/Info.plist"),

                    // bundle files
                    TestFile("myBundle/Controller.m"),
                    TestFile("myBundle/Info.plist"),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("myBundle/en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("myBundle/zh_TW.lproj/Localizable.strings", regionVariantName: "zh_TW"),
                        TestFile("myBundle/fr.lproj/Localizable.strings", regionVariantName: "fr"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Release",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Bundlable",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Release",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "Sources/iosApp/Info.plist",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
                                                "SDKROOT": "iphoneos"
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                        TestResourcesBuildPhase([
                            "Main.storyboard",
                            "iosApp/Assets.xcassets",
                            "MyBundle.bundle"
                        ]),
                    ],
                    dependencies: ["MyBundle"]
                ),
                TestStandardTarget(
                    "MyBundle",
                    type: .bundle,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "Sources/myBundle/Info.plist",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                                                "SDKROOT": "iphoneos",
                                                "SKIP_INSTALL": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Controller.m",
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.strings",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["DSTROOT": "/tmp/Root"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("MyBundle") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/MyBundle.bundle/en.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/myBundle/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/MyBundle.bundle/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/myBundle/zh_TW.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/MyBundle.bundle/fr.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/myBundle/fr.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/MyBundle.bundle/Info.plist", "/tmp/Test/aProject/Sources/myBundle/Info.plist"])) { _ in }
            }

            results.checkTarget("Bundlable") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/Root/Applications/Bundlable.app/MyBundle.bundle", "/tmp/Test/aProject/build/Release-iphoneos/MyBundle.bundle"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/Root/Applications/Bundlable.app/Info.plist", "/tmp/Test/aProject/Sources/iosApp/Info.plist"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // We shouldn't process any InfoPlist files if INSTALLLOC_LANGUAGE is set.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["DSTROOT": "/tmp/Root", "INSTALLLOC_LANGUAGE": "zh_TW"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("MyBundle") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/MyBundle.bundle/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/myBundle/zh_TW.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("Bundlable") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/Root/Applications/Bundlable.app/MyBundle.bundle", "/tmp/Test/aProject/build/Release-iphoneos/MyBundle.bundle"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // And same for multiple specified languages.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["DSTROOT": "/tmp/Root", "INSTALLLOC_LANGUAGE": "zh_TW fr"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("MyBundle") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/MyBundle.bundle/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/myBundle/zh_TW.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/MyBundle.bundle/fr.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/myBundle/fr.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("Bundlable") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/Root/Applications/Bundlable.app/MyBundle.bundle", "/tmp/Test/aProject/build/Release-iphoneos/MyBundle.bundle"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test an App that has a bundle (not the product of a target) in copy files phase
    @Test(.requireSDKs(.iOS))
    func embeddedExternalBundles() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("CoreFoo.framework"),
                        TestVariantGroup("Localizable.strings", children: [
                            TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                            TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                            TestFile("zh_TW.lproj/Localizable.strings", regionVariantName: "zh_TW"),
                        ]),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT" : "iphoneos",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestCopyFilesBuildPhase([
                                "CoreFoo.framework",
                            ], destinationSubfolder: .frameworks, onlyForDeployment: false
                                                   ),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let fs = PseudoFS()
            var languageLprojPathPairs: [(String, Path)] = []
            for lang in ["en", "ja", "zh_TW"] {
                let path = srcRoot.join("Sources/CoreFoo.framework/\(lang).lproj", preserveRoot: true, normalize: true)
                try fs.createDirectory(path, recursive: true)
                try fs.write(path.join("Localizable.strings"), contents: "LocTest")
                languageLprojPathPairs += [(lang, path)]
            }

            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .iOS, fs: fs) { results in
                // Ignore all Gate, build directory, SymLink, and MkDir tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs {
                        results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework/\(language).lproj", path.str])) { _ in }
                    }
                }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja"
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .iOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs where language == "ja" {
                        results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework/\(language).lproj", path.str])) { _ in }
                    }
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja"
            let specificLangs = ["zh_TW", "ja"]
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": specificLangs.joined(separator: " ")]), runDestination: .iOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs where specificLangs.contains(language) {
                        results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework/\(language).lproj", path.str])) { _ in }
                    }
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test an App that has a bundle (not the product of a target) in copy files phase
    @Test(.requireSDKs(.iOS))
    func warningForMissingExternalBundles() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("CoreFoo.framework"),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT" : "iphoneos",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "CoreFoo.framework",
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false
                                               ),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkNoTask()
            results.checkWarning("Unable to find localized content for bundle at \'/tmp/Test/aProject/Sources/CoreFoo.framework\' because the directory contents could not be traversed: \'not a directory: /tmp/Test/aProject/Sources/CoreFoo.framework\' (in target \'App\' from project \'aProject\')")
        }
    }

    @Test(.requireSDKs(.iOS))
    func copyFilesForLocalizableFiles() async throws {
        // This test case ensures the INSTALLLOC_LANGUAGE setting is respected
        // when using a Copy Files phase to copy an individual file. See <rdar://problem/46735865>.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                        TestFile("zh_TW.lproj/Localizable.strings", regionVariantName: "zh_TW"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT" : "iphoneos",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "Localizable.strings",
                        ], destinationSubfolder: .resources, onlyForDeployment: false),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // When installing Japanese, we should only get Japanese content.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // When a language is not specified, we should get all localizable content.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/en.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // Or with multiple languages
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja zh_TW"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func installLocForFramework() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                        TestFile("zh_TW.lproj/Localizable.strings", regionVariantName: "zh_TW"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT" : "iphoneos",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "CoreFoo.framework",
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false
                                               ),
                    ],
                    dependencies: ["CoreFoo"]
                ),
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Localizable.strings"
                        ]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/en.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja zh_TW"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func installLocForAppAndEmbeddedProductsInWorkspace() async throws {
        let testWorkspace = TestWorkspace("aWorkspace", projects: [
            TestProject(
                "aProject",
                groupTree: TestGroup(
                    "Frameworks",
                    children: [
                        TestFile("CoreFoo.framework", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR")),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT" : "iphoneos",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestCopyFilesBuildPhase([
                                "CoreFoo.framework",
                            ], destinationSubfolder: .frameworks, onlyForDeployment: false
                                                   ),
                        ]
                    )
                ]),
            TestProject(
                "bProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestVariantGroup("Localizable.strings", children: [
                            TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                            TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                            TestFile("zh_TW.lproj/Localizable.strings", regionVariantName: "zh_TW"),
                        ]),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT" : "iphoneos",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "CoreFoo", type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SKIP_INSTALL": "YES",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([
                                "Localizable.strings"
                            ]),
                        ]
                    )
                ]
            )
        ])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let buildParameters = BuildParameters(action: .installLoc, configuration: "Debug")
        let target = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: buildParameters, target: $0) })
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: target, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

        await tester.checkBuild(buildParameters, runDestination: .iOS, buildRequest: buildRequest) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/bProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/en.lproj/Localizable.strings", "/tmp/aWorkspace/bProject/Sources/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/bProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/aWorkspace/bProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/bProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/aWorkspace/bProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/aWorkspace/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        let japaneseBuildParameters = BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"])
        let japaneseTarget = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: japaneseBuildParameters, target: $0) })
        let japaneseBuildRequest = BuildRequest(parameters: japaneseBuildParameters, buildTargets: japaneseTarget, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

        await tester.checkBuild(japaneseBuildParameters, runDestination: .iOS, buildRequest: japaneseBuildRequest) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/bProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/aWorkspace/bProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/aWorkspace/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        let multiLangBuildParameters = BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja zh_TW"])
        let multiLangTarget = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: multiLangBuildParameters, target: $0) })
        let multiLangBuildRequest = BuildRequest(parameters: multiLangBuildParameters, buildTargets: multiLangTarget, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

        await tester.checkBuild(multiLangBuildParameters, runDestination: .iOS, buildRequest: multiLangBuildRequest) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/bProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/aWorkspace/bProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/bProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/aWorkspace/bProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/aWorkspace/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test an App that has a Settings.bundle
    @Test(.requireSDKs(.macOS))
    func installLocForSettingsBundle() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("Settings.bundle")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                "Settings.bundle"
                            ]),
                        ])
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let fs = PseudoFS()
            var languageLprojPathPairs: [(String, Path)] = []
            for lang in ["en", "ja", "fr"] {
                let path = srcRoot.join("Sources/Settings.bundle/\(lang).lproj", preserveRoot: true, normalize: true)
                try fs.createDirectory(path, recursive: true)
                try fs.write(path.join("Root.strings"), contents: "LocTest")
                languageLprojPathPairs += [(lang, path)]
            }

            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, SymLink, and MkDir tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs {
                        results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/Settings.bundle/\(language).lproj", path.str])) { _ in }
                    }
                }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja"
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs where language == "ja" {
                        results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/Settings.bundle/\(language).lproj", path.str])) { _ in }
                    }
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja fr"
            let langs = ["ja", "fr"]
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": langs.joined(separator: " ")]), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs where langs.contains(language) {
                        results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/Settings.bundle/\(language).lproj", path.str])) { _ in }
                    }
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test an App that has a Settings.bundle in the Copy Files build phase
    @Test(.requireSDKs(.macOS))
    func installLocForSettingsBundleInCopyFiles() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("Settings.bundle")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestCopyFilesBuildPhase(["Settings.bundle"], destinationSubfolder: .resources, onlyForDeployment: false),
                        ])
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let fs = PseudoFS()
            var languageLprojPathPairs: [(String, Path)] = []
            for lang in ["en", "ja", "de"] {
                let path = srcRoot.join("Sources/Settings.bundle/\(lang).lproj", preserveRoot: true, normalize: true)
                try fs.createDirectory(path, recursive: true)
                try fs.write(path.join("Root.strings"), contents: "LocTest")
                languageLprojPathPairs += [(lang, path)]
            }

            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, SymLink, and MkDir tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs {
                        results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/Settings.bundle/\(language).lproj", path.str])) { _ in }
                    }
                }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja"
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs where language == "ja" {
                        results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/Settings.bundle/\(language).lproj", path.str])) { _ in }
                    }
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja"
            let langs = ["ja", "de"]
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": langs.joined(separator: " ")]), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                results.checkTarget("App") { target in
                    for (language, path) in languageLprojPathPairs where langs.contains(language) {
                        results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/Settings.bundle/\(language).lproj", path.str])) { _ in }
                    }
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test an App with an unlocalized ReleaseSettings.bundle, does not put en.lproj content into the localization root
    @Test(.requireSDKs(.macOS))
    func installLocForUnlocalizedSettingsBundle() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ReleaseSettings.bundle")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                "ReleaseSettings.bundle"
                            ]),
                        ])
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let fs = PseudoFS()
            let path = srcRoot.join("Sources/ReleaseSettings.bundle/en.lproj", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("Root.strings"), contents: "LocTest")

            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, SymLink, and MkDir tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }

                results.checkTarget("App") { target in
                    results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ReleaseSettings.bundle/en.lproj", path.str])) { _ in }
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja"
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                // We should not be copying en.lproj content into to localization root
                results.checkTarget("App") { target in
                    results.checkNoTask(.matchTarget(target), .matchRule(["CpResource", path.str, "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ReleaseSettings.bundle/en.lproj"]))
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // INSTALLLOC_LANGUAGE set to "ja fr"
            await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja fr"]), runDestination: .macOS, fs: fs) { results in
                // Ignore all Gate, build directory, MkDir, and SymLink tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                // We should not be copying en.lproj content into to localization root
                results.checkTarget("App") { target in
                    results.checkNoTask(.matchTarget(target), .matchRule(["CpResource", path.str, "/tmp/aProject.dst/Applications/App.app/Contents/Resources/ReleaseSettings.bundle/en.lproj"]))
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func installLocWithShellScriptPhase() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", path: "Sources"),
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestShellScriptBuildPhase(name: "", shellPath: "/bin/bash", originalObjectID: "abc", contents: "env | sort", onlyForDeployment: false, emitEnvironment: true, alwaysOutOfDate: true)
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("App") { target in
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // Shell Script tasks should be generated for an installloc build only if INSTALLLOC_SCRIPT_PHASE is enabled.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_SCRIPT_PHASE": "YES"]), runDestination: .macOS) { results in
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("App") { target in
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/Script-abc.sh"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["PhaseScriptExecution", "Run Script", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/Script-abc.sh"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func overlappingSymlinksForFrameworks() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                        TestFile("it.lproj/Localizable.strings", regionVariantName: "it"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)"
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Localizable.strings"
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // For localization builds, we expect all the necessary directories and localizable files to be created.
        // However, we should not generate the expected SymLink tasks for a FrameworkProductTypeSpec.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .macOS) { results in

            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("FrameworkTarget") { target in
                results.checkTasks(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/Release/FrameworkTarget.framework", "../../../../aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }

                // For localization builds, we expect all the necessary directories and localizable files to be created, but we should skip creating the Framework SymLinks.
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources/ja.lproj/Localizable.strings", "/tmp/Test/aProject/ja.lproj/Localizable.strings"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // Same if multiple languages are specified as in _Loc_All builds.
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["INSTALLLOC_LANGUAGE": "ja it"]), runDestination: .macOS) { results in

            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("FrameworkTarget") { target in
                results.checkTasks(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/Release/FrameworkTarget.framework", "../../../../aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }

                // For localization builds, we expect all the necessary directories and localizable files to be created, but we should skip creating the Framework SymLinks.
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources/ja.lproj/Localizable.strings", "/tmp/Test/aProject/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources/it.lproj/Localizable.strings", "/tmp/Test/aProject/it.lproj/Localizable.strings"])) { _ in }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // Verify that an install build still creates the SymLinks we want to ignore in the installloc build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                results.checkTasks(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/Release/FrameworkTarget.framework", "../../../../aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/Current", "A"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Resources", "Versions/Current/Resources"])) { _ in }
            }

            // We shouldn't have any other SymLink tasks.
            results.checkNoTask(.matchRuleType("SymLink"))
        }
    }

    @Test(.requireSDKs(.iOS))
    func installLocSkipVerifyModules() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("MyFramework.h"),
                    TestFile("PublicHeader.h"),
                    TestFile("PrivateHeader.h"),
                    TestFile("SourceFile.m"),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                        TestFile("zh_TW.lproj/Localizable.strings", regionVariantName: "zh_TW"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT" : "iphoneos",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "CoreFoo.framework",
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false
                                               ),
                    ],
                    dependencies: ["CoreFoo"]
                ),
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "DEFINES_MODULE": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("MyFramework.h", headerVisibility: .public),
                            TestBuildFile("PublicHeader.h", headerVisibility: .public),
                            TestBuildFile("PrivateHeader.h", headerVisibility: .private),
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.strings"
                        ]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            results.checkNoTask(.matchRuleType("VerifyModule"))

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/en.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkNoTask(.matchRuleType("VerifyModule"))
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja zh_TW"]), runDestination: .iOS) { results in
            // Ignore all Gate, build directory, SymLink, and MkDir tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkNoTask(.matchRuleType("VerifyModule"))
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/UninstalledProducts/iphoneos/CoreFoo.framework/zh_TW.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/zh_TW.lproj/Localizable.strings"])) { _ in }
            }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/App.app/Frameworks/CoreFoo.framework", "/tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func installLocSkipCopyBaselinesTasksOnTestsTargets() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // Framework sources
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("TestTwo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "macosx",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.0",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UnitTestTarget-Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                            "TestTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "FrameworkTarget.framework",
                        ])
                    ],
                    dependencies: ["FrameworkTarget"]
                ),
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "FrameworkTarget-Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ]
                ),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Write the test baseline files.
        guard let baselineDir = (tester.workspace.projects.first?.targets.first as? SWBCore.StandardTarget)?.performanceTestsBaselinesPath else {
            Issue.record("Could not get path to performance test baselines.")
            return
        }

        let fs = PseudoFS()
        try fs.createDirectory(baselineDir, recursive: true)
        try await fs.writePlist(baselineDir.join("Info.plist"), .plDict([:]))
        try await fs.writePlist(baselineDir.join("Some-Test-Data.plist"), .plDict([:]))

        // Run installLoc on project
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .macOS, fs: fs) { results in

            // Ignore all Gate, SymLink and CreateBuildDirectory tasks, as they are not relevant for this case
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            // Check the unit test target.
            results.checkTarget("UnitTestTarget") { target in

                // There should not be a task to copy the testing baselines
                results.checkNoTask(.matchTarget(target), .matchRule(["Copy", baselineDir.str, "/tmp/Test/aProject/build/UninstalledProducts/macosx/UnitTestTarget.xctest/Contents/Resources/xcbaselines"]))
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test an App that has an embedded bundle from a Swift package project
    @Test(.requireSDKs(.macOS))
    func packageResourceBundleEmbedding() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                    TestFile("app.swift"),
                    TestFile("appex.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                    "MACOSX_DEPLOYMENT_TARGET": "10.15",
                    "IPHONEOS_DEPLOYMENT_TARGET": "13.0",
                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    "SUPPORTS_MACCATALYST": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "app", type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["app.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("SwiftyJSON"))
                        ]),
                    ],
                    dependencies: [
                        "appex",
                        "SwiftyJSON",
                    ]),

                TestStandardTarget(
                    "appex", type: .applicationExtension,
                    buildPhases: [
                        TestSourcesBuildPhase(["appex.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("SwiftyJSON"))
                        ]),
                    ],
                    dependencies: [
                        "SwiftyJSON",
                    ]),

                TestStandardTarget(
                    "SwiftyJSON", type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", impartedBuildProperties: TestImpartedBuildProperties(buildSettings: [
                            "EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES": "FOO",
                        ]))
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"]),
                    ],
                    dependencies: [
                        "FOO",
                    ]),

                TestStandardTarget(
                    "FOO", type: .bundle
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "ja"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("app") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FOO.bundle")) { task in
                    task.checkCommandLineContains(["-ignore-missing-inputs", "/tmp/Test/aProject/build/Debug/FOO.bundle", "/tmp/Test/aProject/build/UninstalledProducts/macosx/app.app/Contents/Resources"])
                }
            }
            results.checkTarget("appex") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FOO.bundle")) { task in
                    task.checkCommandLineContains(["-ignore-missing-inputs", "/tmp/Test/aProject/build/Debug/FOO.bundle", "/tmp/Test/aProject/build/UninstalledProducts/macosx/appex.appex/Contents/Resources"])
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS), .requireXcode16())
    func installLocSSUAppIntents() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("AppShortcuts.strings", children: [
                        TestFile("en.lproj/AppShortcuts.strings", regionVariantName: "en"),
                        TestFile("de.lproj/AppShortcuts.strings", regionVariantName: "de"),
                        TestFile("ja.lproj/AppShortcuts.strings", regionVariantName: "ja"),
                    ]),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Localizable.strings", regionVariantName: "de"),
                        TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                    ]),
                    TestVariantGroup("InfoPlist.strings", children: [
                        TestFile("en.lproj/InfoPlist.strings", regionVariantName: "en"),
                        TestFile("de.lproj/InfoPlist.strings", regionVariantName: "de"),
                        TestFile("ja.lproj/InfoPlist.strings", regionVariantName: "ja"),
                    ])
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "APP_INTENTS_METADATA_PATH": "path_to_metadata_appintents",
                        "LM_ENABLE_LINK_GENERATION": "NO",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "AppShortcuts.strings",
                            "Localizable.strings",
                            "InfoPlist.strings"
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug"), runDestination: nil) { results in
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/App.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/Debug-iphoneos/App.app", "../../../../aProject.dst/Applications/App.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/en.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/en.lproj/AppShortcuts.strings", "/tmp/Test/aProject/Sources/en.lproj/AppShortcuts.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/ja.lproj/AppShortcuts.strings", "/tmp/Test/aProject/Sources/ja.lproj/AppShortcuts.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/AppShortcuts.strings", "/tmp/Test/aProject/Sources/de.lproj/AppShortcuts.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/en.lproj/InfoPlist.strings", "/tmp/Test/aProject/Sources/en.lproj/InfoPlist.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/ja.lproj/InfoPlist.strings", "/tmp/Test/aProject/Sources/ja.lproj/InfoPlist.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/InfoPlist.strings", "/tmp/Test/aProject/Sources/de.lproj/InfoPlist.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateAppShortcutStringsMetadata")) { task in
                    task.checkCommandLineContains(["appshortcutstringsprocessor",
                                                   "--source-file",
                                                   "/tmp/Test/aProject/Sources/en.lproj/AppShortcuts.strings",
                                                   "--input-data-path",
                                                   "path_to_metadata_appintents"])
                }
                results.checkTask(.matchRuleType("AppIntentsSSUTraining")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsnltrainingprocessor" {
                        task.checkCommandLine([executableName.asString,
                                               "--infoplist-path",
                                               "/tmp/Test/aProject/Sources/en.lproj/InfoPlist.strings",
                                               "--temp-dir-path",
                                               "/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/App.build/ssu",
                                               "--bundle-id",
                                               "com.foo.bar",
                                               "--product-path",
                                               "/tmp/aProject.dst/Applications/App.app",
                                               "--extracted-metadata-path",
                                               "path_to_metadata_appintents",
                                               "--deployment-postprocessing",
                                               "--metadata-file-list",
                                               "/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/App.build/App.DependencyMetadataFileList",
                                               "--archive-ssu-assets"
                                              ])
                    }

                    task.checkInputs([
                        .path("/tmp/Test/aProject/Sources/en.lproj/InfoPlist.strings"),
                        .path("/tmp/Test/aProject/Sources/en.lproj/AppShortcuts.strings"),
                        .namePattern(.and(.prefix("ValidateAppShortcutStringsMetadata target-App-T-App-"), .suffix(" /tmp/Test/aProject/Sources/en.lproj/AppShortcuts.strings"))),
                        .namePattern(.suffix("App.DependencyMetadataFileList")),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-copy-bundle-resources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ])

                    task.checkOutputs([
                        .path("/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/App.build/ssu/root.ssu.yaml"),
                    ])

                    results.checkNoDiagnostics()
                }
                if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                    results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/empty.plist"])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/aProject.dst/Applications/App.app/Contents/Info.plist", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/empty.plist"])) { _ in }
                }

            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "de"]), runDestination: nil) { results in
            // Ignore all Gate, build directory, MkDir, and SymLink tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/AppShortcuts.strings", "/tmp/Test/aProject/Sources/de.lproj/AppShortcuts.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/InfoPlist.strings", "/tmp/Test/aProject/Sources/de.lproj/InfoPlist.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateAppShortcutStringsMetadata")) { task in
                    task.checkCommandLineContains(["appshortcutstringsprocessor",
                                                   "--source-file",
                                                   "/tmp/Test/aProject/Sources/en.lproj/AppShortcuts.strings",
                                                   "--input-data-path",
                                                   "path_to_metadata_appintents"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("AppIntentsSSUTraining")) { task in
                    task.checkCommandLineContains(["appintentsnltrainingprocessor",
                                                   "--infoplist-path",
                                                   "/tmp/Test/aProject/Sources/en.lproj/InfoPlist.strings",
                                                   "--temp-dir-path",
                                                   "/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/App.build/ssu",
                                                   "--extracted-metadata-path",
                                                   "path_to_metadata_appintents",
                                                   "--archive-ssu-assets"])
                }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Debug", overrides: ["INSTALLLOC_LANGUAGE": "de ja"]), runDestination: nil) { results in
            // Ignore all Gate, build directory, MkDir, and SymLink tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("LinkStoryboards")) { _ in }
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/ja.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/AppShortcuts.strings", "/tmp/Test/aProject/Sources/de.lproj/AppShortcuts.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/ja.lproj/AppShortcuts.strings", "/tmp/Test/aProject/Sources/ja.lproj/AppShortcuts.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/de.lproj/InfoPlist.strings", "/tmp/Test/aProject/Sources/de.lproj/InfoPlist.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/App.app/ja.lproj/InfoPlist.strings", "/tmp/Test/aProject/Sources/ja.lproj/InfoPlist.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/App.build/App.DependencyMetadataFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/App.build/App.DependencyStaticMetadataFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ValidateAppShortcutStringsMetadata")) { task in
                    task.checkCommandLineContains(["appshortcutstringsprocessor",
                                                   "--source-file",
                                                   "/tmp/Test/aProject/Sources/en.lproj/AppShortcuts.strings",
                                                   "--input-data-path",
                                                   "path_to_metadata_appintents"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("AppIntentsSSUTraining")) { task in
                    task.checkCommandLineContains(["appintentsnltrainingprocessor",
                                                   "--infoplist-path",
                                                   "/tmp/Test/aProject/Sources/en.lproj/InfoPlist.strings",
                                                   "--temp-dir-path",
                                                   "/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/App.build/ssu",
                                                   "--extracted-metadata-path",
                                                   "path_to_metadata_appintents",
                                                   "--archive-ssu-assets"])
                }
            }
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }
}
