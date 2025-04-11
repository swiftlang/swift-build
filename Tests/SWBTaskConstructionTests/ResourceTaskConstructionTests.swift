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

/// Task construction tests related to resource processing.
@Suite
fileprivate struct ResourcesTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func rezPhase() async throws {
        // Test the Rez phase.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Foo.r"),
                    TestFile("Bar.r"),
                    TestFile("RezPrefixFile.r"),
                    TestFile("de.lproj/Baz.r", regionVariantName: "de"),
                    TestFile("en.lproj/Baz.r", regionVariantName: "en")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "OTHER_REZFLAGS": "other_rez_flags",
                    "REZ_SEARCH_PATHS": "rez_search_paths",
                    "FRAMEWORK_SEARCH_PATHS": "framework_search_paths",
                    "SYSTEM_FRAMEWORK_SEARCH_PATHS": "system_framework_search_paths1 system_framework_search_paths2",
                    "HEADER_SEARCH_PATHS": "header_search_paths",
                    "SYSTEM_HEADER_SEARCH_PATHS": "system_header_search_paths1 system_header_search_paths1",
                    "REZ_PREFIX_FILE": "a/b/../../RezPrefixFile.r",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestRezBuildPhase(["Foo.r", "Bar.r", "de.lproj/Baz.r", "en.lproj/Baz.r"]),
                    ]
                )
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        let rezPath = core.developerPath.path.join("usr/bin/Rez")
        try fs.createDirectory(rezPath.dirname, recursive: true)
        try await fs.writeFileContents(rezPath) { _ in }

        let configuration = "Release"

        await tester.checkBuild(BuildParameters(action: .installHeaders, configuration: configuration), runDestination: .macOS) { results in
            results.checkTarget("App") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("Rez"))
            }
        }

        await tester.checkBuild(BuildParameters(configuration: configuration), runDestination: .macOS, fs: fs) { results -> Void in
            results.checkWarning(.equal("Build Carbon Resources build phases are no longer supported.  Rez source files should be moved to the Copy Bundle Resources build phase. (in target 'App' from project 'aProject')"))

            results.checkTarget("App") { target -> Void in
                // Processing Bar.r
                results.checkTask(.matchRule(["Rez", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Bar.rsrc", "\(SRCROOT)/Bar.r"])) { task in
                    task.checkCommandLine([rezPath.str, "-o", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Bar.rsrc", "-d", "SystemSevenOrLater=1", "-useDF", "-script", "Roman", "other_rez_flags", "-arch", "x86_64", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "rez_search_paths", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "framework_search_paths", "-F", "system_framework_search_paths1", "-F", "system_framework_search_paths2", "-i", "\(SRCROOT)/build/\(configuration)/include", "-i", "header_search_paths", "-i", "system_header_search_paths1", "-i", "system_header_search_paths1", "\(SRCROOT)/RezPrefixFile.r", "-isysroot", core.loadSDK(.macOS).path.str, "\(SRCROOT)/Bar.r"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Bar.r"),
                        .path("\(SRCROOT)/RezPrefixFile.r"),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Bar.rsrc"),])
                }

                // Processing Foo.r
                results.checkTask(.matchRule(["Rez", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Foo.rsrc", "\(SRCROOT)/Foo.r"])) { task in
                    task.checkCommandLine([rezPath.str, "-o", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Foo.rsrc", "-d", "SystemSevenOrLater=1", "-useDF", "-script", "Roman", "other_rez_flags", "-arch", "x86_64", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "rez_search_paths", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "framework_search_paths", "-F", "system_framework_search_paths1", "-F", "system_framework_search_paths2", "-i", "\(SRCROOT)/build/\(configuration)/include", "-i", "header_search_paths", "-i", "system_header_search_paths1", "-i", "system_header_search_paths1", "\(SRCROOT)/RezPrefixFile.r", "-isysroot", core.loadSDK(.macOS).path.str, "\(SRCROOT)/Foo.r"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Foo.r"),
                        .path("\(SRCROOT)/RezPrefixFile.r"),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Foo.rsrc"),])
                }

                // Processing Baz.r (de)
                results.checkTask(.matchRule(["Rez", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/de.lproj/Baz.rsrc", "\(SRCROOT)/de.lproj/Baz.r"])) { task in
                    task.checkCommandLine([rezPath.str, "-o", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/de.lproj/Baz.rsrc", "-d", "SystemSevenOrLater=1", "-useDF", "-script", "Roman", "other_rez_flags", "-arch", "x86_64", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "rez_search_paths", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "framework_search_paths", "-F", "system_framework_search_paths1", "-F", "system_framework_search_paths2", "-i", "\(SRCROOT)/build/\(configuration)/include", "-i", "header_search_paths", "-i", "system_header_search_paths1", "-i", "system_header_search_paths1", "\(SRCROOT)/RezPrefixFile.r", "-isysroot", core.loadSDK(.macOS).path.str, "\(SRCROOT)/de.lproj/Baz.r"])
                    task.checkInputs([
                        .path("\(SRCROOT)/de.lproj/Baz.r"),
                        .path("\(SRCROOT)/RezPrefixFile.r"),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/de.lproj/Baz.rsrc"),])
                }

                // Processing Baz.r (en)
                results.checkTask(.matchRule(["Rez", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/en.lproj/Baz.rsrc", "\(SRCROOT)/en.lproj/Baz.r"])) { task in
                    task.checkCommandLine([rezPath.str, "-o", "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/en.lproj/Baz.rsrc", "-d", "SystemSevenOrLater=1", "-useDF", "-script", "Roman", "other_rez_flags", "-arch", "x86_64", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "rez_search_paths", "-i", "\(SRCROOT)/build/\(configuration)", "-i", "framework_search_paths", "-F", "system_framework_search_paths1", "-F", "system_framework_search_paths2", "-i", "\(SRCROOT)/build/\(configuration)/include", "-i", "header_search_paths", "-i", "system_header_search_paths1", "-i", "system_header_search_paths1", "\(SRCROOT)/RezPrefixFile.r", "-isysroot", core.loadSDK(.macOS).path.str, "\(SRCROOT)/en.lproj/Baz.r"])
                    task.checkInputs([
                        .path("\(SRCROOT)/en.lproj/Baz.r"),
                        .path("\(SRCROOT)/RezPrefixFile.r"),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/en.lproj/Baz.rsrc"),])
                }

                // There should only be four Rez tasks.
                results.checkNoTask(.matchRuleType("Rez"))

                // There should be one collector and one merger task per region ("unlocalized" is a pseudo-region).
                results.checkTasks(.matchTarget(target), .matchRuleType("ResMergerCollector")) { tasks in
                    #expect(tasks.count == 3)
                    zip(["", "de", "en"], tasks.sorted { $0.inputs[0].path < $1.inputs[0].path }).forEach { (region: String, task: PlannedTask) -> Void in
                        let rsrcName = !region.isEmpty ? "\(region).lproj/Baz.rsrc" : "App.rsrc"
                        let output = "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/\(!region.isEmpty ? "\(region)" : "App.rsrc")"
                        let inputs: [String]
                        if !region.isEmpty {
                            inputs = [
                                "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/\(rsrcName)",
                            ]
                        } else {
                            inputs = [
                                "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Foo.rsrc",
                                "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/Objects/Bar.rsrc"
                            ]
                        }

                        task.checkRuleInfo(["ResMergerCollector", output])
                        task.checkCommandLine(["ResMerger", "-dstIs", "DF"] + inputs + ["-o", output])

                        task.checkInputs(inputs.map { .path($0) } + [
                            .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path(output),])
                    }
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("ResMergerProduct")) { tasks in
                    #expect(tasks.count == 3)
                    zip(["", "de", "en"], tasks.sorted { $0.inputs[0].path < $1.inputs[0].path }).forEach { region, task in
                        let rsrcName = !region.isEmpty ? "\(region).lproj/Localized.rsrc" : "App.rsrc"
                        let input = "\(SRCROOT)/build/aProject.build/\(configuration)/App.build/ResourceManagerResources/\(!region.isEmpty ? "\(region)" : "App.rsrc")"

                        task.checkRuleInfo(["ResMergerProduct", "\(SRCROOT)/build/\(configuration)/App.app/Contents/Resources/\(rsrcName)"])
                        // FIXME: Check the ResMergerProduct command line
                        task.checkCommandLine(["ResMerger", input, "-dstIs", "DF", "-o", "\(SRCROOT)/build/\(configuration)/App.app/Contents/Resources/\(rsrcName)"])

                        task.checkInputs([
                            .path(input),
                            .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/\(configuration)/App.app/Contents/Resources/\(rsrcName)"),])
                    }
                }
            }

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the asset catalog tool.
    @Test(.requireSDKs(.macOS))
    func assetCatalogTool() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Info.plist"),
                    TestFile("foo.xcassets"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ASSETCATALOG_EXEC": actoolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "INFOPLIST_FILE": "Sources/Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xcassets",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let actoolPath = try await self.actoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory related tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                // Check the sole asset catalog compilation step.
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkRuleInfo(["CompileAssetCatalogVariant", variant, "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "\(SRCROOT)/Sources/foo.xcassets"])
                        task.checkCommandLine([actoolPath.str, "\(SRCROOT)/Sources/foo.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/\(variant)", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_dependencies_\(variant)", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist_\(variant)", "--enable-on-demand-resources", "NO", "--development-region", "English", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--platform", "macosx"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/foo.xcassets"),
                            .name("MkDir \(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/\(variant)"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/\(variant)"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        // Check that we treat the generated Info.plist file as an output.
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/\(variant)"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_dependencies_\(variant)"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist_\(variant)"),
                        ])
                    }
                }

                results.checkTask(.matchTarget(target), .matchRuleType("LinkAssetCatalog")) { task in
                    task.checkCommandLine(["builtin-linkAssetCatalog", "--thinned", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/thinned", "--thinned-dependencies", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_dependencies_thinned", "--thinned-info-plist-content", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist_thinned", "--unthinned", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/unthinned", "--unthinned-dependencies", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_dependencies_unthinned", "--unthinned-info-plist-content", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist_unthinned", "--output", "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "--plist-output", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/foo.xcassets"),
                        .name("MkDir \(SRCROOT)/build/Debug/App.app/Contents/Resources"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/thinned"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/unthinned"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_signature"),
                        .namePattern(.suffix("ModuleVerifierTaskProducer")),
                        .namePattern(.suffix("-entry"))
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Assets.car"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature")) { task in
                    task.checkCommandLine(["builtin-linkAssetCatalogSignature", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_signature"])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_signature")
                    ])
                }

                // Check that the info plist task includes additional input
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist"])
                }
            }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the asset catalog tool for tvOS (which has unique args)
    @Test(.requireSDKs(.tvOS))
    func assetCatalogTool_tvOS() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Info.plist"),
                    TestFile("foo.xcassets"),
                    TestFile("SourceFile.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
                        "ENABLE_ON_DEMAND_RESOURCES": "NO",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.test.aProject",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "appletvos",
                                                "INFOPLIST_FILE": "Sources/Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                        ]),
                        TestResourcesBuildPhase([
                            "foo.xcassets",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let actoolPath = try await self.actoolPath

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")

        await tester.checkBuild(runDestination: .tvOS, fs: fs) { results in
            // Ignore
            for r in ["WriteAuxiliaryFile", "MkDir", "CompileC", "Ld", "GenerateDSYMFile", "Touch", "Gate", "RegisterExecutionPolicyException", "RegisterWithLaunchServices", "CodeSign", "ProcessProductPackaging", "ProcessProductPackagingDER", "Validate", "ProcessInfoPlistFile", "CreateBuildDirectory", "CreateUniversalBinary"] {
                results.checkTasks(.matchRuleType(r)) { _ in }
            }

            results.checkTarget("App") { target in
                // Check the sole asset catalog compilation step.
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkRuleInfo(["CompileAssetCatalogVariant", variant, "\(SRCROOT)/build/Debug-appletvos/App.app", "\(SRCROOT)/Sources/foo.xcassets"])

                        task.checkCommandLine([actoolPath.str, "\(SRCROOT)/Sources/foo.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug-appletvos/App.build/assetcatalog_output/\(variant)", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-appletvos/App.build/assetcatalog_dependencies_\(variant)", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-appletvos/App.build/assetcatalog_generated_info.plist_\(variant)", "--compress-pngs", "--enable-on-demand-resources", "NO", "--development-region", "English", "--leaderboard-identifier-prefix", "App.game-center.leaderboard.", "--leaderboard-set-identifier-prefix", "App.game-center.leaderboard-set.", "--target-device", "tv", "--minimum-deployment-target", "\(results.runDestinationSDK.defaultDeploymentTarget)", "--platform", "appletvos"])
                    }
                }

                results.checkTask(.matchTarget(target), .matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkRuleInfo(["GenerateAssetSymbols", "\(SRCROOT)/Sources/foo.xcassets"])

                    task.checkCommandLine([actoolPath.str, "\(SRCROOT)/Sources/foo.xcassets", "--compile", "\(SRCROOT)/build/Debug-appletvos/App.app", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-appletvos/App.build/assetcatalog_dependencies", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-appletvos/App.build/assetcatalog_generated_info.plist", "--compress-pngs", "--enable-on-demand-resources", "NO", "--development-region", "English", "--leaderboard-identifier-prefix", "App.game-center.leaderboard.", "--leaderboard-set-identifier-prefix", "App.game-center.leaderboard-set.", "--target-device", "tv", "--minimum-deployment-target", "\(results.runDestinationSDK.defaultDeploymentTarget)", "--platform", "appletvos", "--bundle-identifier", "com.test.aProject", "--generate-objc-asset-symbols", "\(SRCROOT)/build/aProject.build/Debug-appletvos/App.build/DerivedSources/GeneratedAssetSymbols.h", "--generate-asset-symbol-index", "\(SRCROOT)/build/aProject.build/Debug-appletvos/App.build/DerivedSources/GeneratedAssetSymbols-Index.plist"])
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))
            }


            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Check that the resource-specific overrides work for the asset catalog tool.
    @Test(.requireSDKs(.macOS))
    func assetCatalogToolResourceOverrides() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Info.plist"),
                    TestFile("foo.xcassets"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "RESOURCES_PLATFORM_NAME": "toastOS",
                        "RESOURCES_MINIMUM_DEPLOYMENT_TARGET": "999.9",
                        "RESOURCES_TARGETED_DEVICE_FAMILY": "toastpad",
                        "ASSETCATALOG_EXEC": actoolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "INFOPLIST_FILE": "Sources/Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xcassets",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let actoolPath = try await self.actoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                // Check the sole asset catalog compilation step.
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkRuleInfo(["CompileAssetCatalogVariant", variant, "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "\(SRCROOT)/Sources/foo.xcassets"])
                        task.checkCommandLine([actoolPath.str, "\(SRCROOT)/Sources/foo.xcassets", "--compile", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/\(variant)", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_dependencies_\(variant)", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist_\(variant)", "--target-device", "toastpad", "--enable-on-demand-resources", "NO", "--development-region", "English", "--minimum-deployment-target", "999.9", "--platform", "toastOS"])

                        // Check that we treat the generated Info.plist file as an output.
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_output/\(variant)"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_dependencies_\(variant)"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist_\(variant)"),])
                    }

                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalog"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("LinkAssetCatalogSignature"))
                // Check that the info plist task includes additional input
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/assetcatalog_generated_info.plist"])
                }
            }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the IB compile tools when processing unlocalized files.
    @Test(.requireSDKs(.macOS))
    func interfaceBuilderCompilers() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Info.plist"),
                    TestFile("foo.xib"),
                    TestFile("bar.storyboard"),
                    TestFile("baz.storyboard"),
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
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "CODE_SIGN_IDENTITY": "",
                                                "SDKROOT": "macosx",
                                                "IBC_EXEC": ibtoolPath.str,
                                                "INFOPLIST_FILE": "Sources/Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xib",
                            "bar.storyboard",
                            "baz.storyboard",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let ibtoolPath = try await self.ibtoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                // Check the xib compile.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileXIB"), .matchRuleItemBasename("foo.xib")) { task in
                    task.checkRuleInfo(["CompileXIB", "\(SRCROOT)/Sources/foo.xib"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo.nib", "\(SRCROOT)/Sources/foo.xib"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/foo.xib"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~iphone.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist"),])

                    task.checkEnvironment([
                        "XCODE_DEVELOPER_USR_PATH": .equal("\(core.developerPath.path.str)/usr/bin/.."),
                    ], exact: true)
                }

                // Check the storyboard compiles.
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileStoryboard")) { tasks in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    for (i, base) in ["bar", "baz"].enumerated() {
                        let task = sortedTasks[i]
                        task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/\(base).storyboard"])
                        task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text",  "\(SRCROOT)/Sources/\(base).storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build",])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/\(base).storyboard"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base).storyboardc"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist"),])
                    }
                }

                // Check the storyboard link.
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkRuleInfo(["LinkStoryboards"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--link", "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz.storyboardc"),
                    ])
                }

                // Check that the info plist task includes additional input
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist"])
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar-SBPartialInfo.plist"])
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz-SBPartialInfo.plist"])
                }
            }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the IB compile tools when building with multiple variants.
    @Test(.requireSDKs(.macOS))
    func interfaceBuilderCompilers_MultiVariant() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Info.plist"),
                    TestFile("foo.xib"),
                    TestFile("bar.storyboard"),
                    TestFile("baz.storyboard"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "BUILD_VARIANTS": "normal debug",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "CODE_SIGN_IDENTITY": "",
                                                "SDKROOT": "macosx",
                                                "IBC_EXEC": ibtoolPath.str,
                                                "INFOPLIST_FILE": "Sources/Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo.xib",
                            "bar.storyboard",
                            "baz.storyboard",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let ibtoolPath = try await self.ibtoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                // Check the xib compile.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileXIB"), .matchRuleItemBasename("foo.xib")) { task in
                    task.checkRuleInfo(["CompileXIB", "\(SRCROOT)/Sources/foo.xib"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo.nib", "\(SRCROOT)/Sources/foo.xib"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/foo.xib"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~iphone.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist"),])

                    task.checkEnvironment([
                        "XCODE_DEVELOPER_USR_PATH": .equal("\(core.developerPath.path.str)/usr/bin/.."),
                    ], exact: true)
                }

                // Check the storyboard compiles.
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileStoryboard")) { tasks in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    for (i, base) in ["bar", "baz"].enumerated() {
                        let task = sortedTasks[i]
                        task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/\(base).storyboard"])
                        task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "\(SRCROOT)/Sources/\(base).storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/\(base).storyboard"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-")),
                            .name("WorkspaceHeaderMapVFSFilesWritten")])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base).storyboardc"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist"),])
                    }
                }

                // Check the storyboard link.
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkRuleInfo(["LinkStoryboards"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--link", "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz.storyboardc"),
                    ])
                }

                // Check that the info plist task includes additional input
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist"])
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar-SBPartialInfo.plist"])
                    task.checkCommandLineContainsUninterrupted(["-additionalcontentfile", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz-SBPartialInfo.plist"])
                }
            }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the IB compile tools when processing files which are only base-localized.
    @Test(.requireSDKs(.macOS))
    func interfaceBuilderCompilers_BaseLocalization() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("foo.xib", children: [TestFile("Base.lproj/foo.xib", regionVariantName: "Base")]),
                    TestVariantGroup("bar.storyboard", children: [TestFile("Base.lproj/bar.storyboard", regionVariantName: "Base")]),
                    TestVariantGroup("baz.storyboard", children: [TestFile("Base.lproj/baz.storyboard", regionVariantName: "Base")]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "CODE_SIGN_IDENTITY": "",
                                                "IBC_EXEC": ibtoolPath.str,
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xib",
                            "bar.storyboard",
                            "baz.storyboard",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let ibtoolPath = try await self.ibtoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory related tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                // Check the xib compile.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileXIB"), .matchRuleItemBasename("foo.xib")) { task in
                    task.checkRuleInfo(["CompileXIB", "\(SRCROOT)/Sources/Base.lproj/foo.xib"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/foo-PartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo.nib", "\(SRCROOT)/Sources/Base.lproj/foo.xib"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/Base.lproj/foo.xib"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])

                    // The .nib files are localized, but the -PartialInfo.plist file is not.
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo~iphone.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/foo-PartialInfo.plist"),])

                    task.checkEnvironment([
                        "XCODE_DEVELOPER_USR_PATH": .equal("\(core.developerPath.path.str)/usr/bin/.."),
                    ], exact: true)
                }

                // Check the storyboard compiles.
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileStoryboard")) { tasks in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    for (i, basename) in ["bar", "baz"].enumerated() {
                        let task = sortedTasks[i]
                        task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/Base.lproj/\(basename).storyboard"])
                        task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/\(basename)-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "\(SRCROOT)/Sources/Base.lproj/\(basename).storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/Base.lproj/\(basename).storyboard"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/\(basename).storyboardc"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/\(basename)-SBPartialInfo.plist"),])
                    }
                }

                // Check the storyboard link.
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkRuleInfo(["LinkStoryboards"])
                    // The --link option does *not* contain Base.lproj - the tool handles localizing its outputs.
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--link", "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/bar.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/baz.storyboardc"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/bar.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/baz.storyboardc"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/bar.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/baz.storyboardc"),
                    ])
                }

                if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                    // There should be a process Info.plist task.
                    results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
                }
            }

            // Skip the plist and validate tasks.
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { task in }
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the IB compile tools when processing localized files using the base-localized-xib-and-localized-strings-files model.
    @Test(.requireSDKs(.macOS))
    func interfaceBuilderCompilers_FullLocalization() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("foo.xib",
                                     children: [
                                        TestFile("Base.lproj/foo.xib", regionVariantName: "Base"),
                                        // The French localized xib will be processed by a separate ibtool command from the other files.
                                        TestFile("fr.lproj/foo.xib", regionVariantName: "fr"),
                                        TestFile("en.lproj/foo.strings", regionVariantName: "en"),
                                        TestFile("de.lproj/foo.strings", regionVariantName: "de"),
                                     ]
                                    ),
                    TestVariantGroup("Main.storyboard",
                                     children: [
                                        TestFile("Base.lproj/Main.storyboard", regionVariantName: "Base"),
                                        // The French localized storyboard will be processed by a separate ibtool command from the other files.
                                        TestFile("fr.lproj/Main.storyboard", regionVariantName: "fr"),
                                        TestFile("en.lproj/Main.strings", regionVariantName: "en"),
                                        TestFile("de.lproj/Main.strings", regionVariantName: "de"),
                                     ]
                                    ),
                    TestFile("bar.storyboard"),
                    TestFile("baz.storyboard"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "IBC_EXEC": ibtoolPath.str,
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xib",
                            "Main.storyboard",
                            "bar.storyboard",
                            "baz.storyboard",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let ibtoolPath = try await self.ibtoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory related tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                // Check compiling the base-localized xib with the strings files.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileXIB"), .matchRuleItem("\(SRCROOT)/Sources/Base.lproj/foo.xib")) { task in
                    task.checkRuleInfo(["CompileXIB", "\(SRCROOT)/Sources/Base.lproj/foo.xib"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--companion-strings-file", "en:\(SRCROOT)/Sources/en.lproj/foo.strings", "--companion-strings-file", "de:\(SRCROOT)/Sources/de.lproj/foo.strings", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/foo-PartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo.nib", "\(SRCROOT)/Sources/Base.lproj/foo.xib"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/Base.lproj/foo.xib"),
                        .path("\(SRCROOT)/Sources/en.lproj/foo.strings"),
                        .path("\(SRCROOT)/Sources/de.lproj/foo.strings"),
                        .any,
                        .any,
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo~iphone.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/foo~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/foo-PartialInfo.plist"),
                    ])

                    task.checkEnvironment([
                        "XCODE_DEVELOPER_USR_PATH": .equal("\(core.developerPath.path.str)/usr/bin/.."),
                    ], exact: true)
                }

                // Check compiling the French-localized xib.  This xib would be slightly different from the Base-localized xib in ways that can't be captured in a .strings file.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileXIB"), .matchRuleItem("\(SRCROOT)/Sources/fr.lproj/foo.xib")) { task in
                    task.checkRuleInfo(["CompileXIB", "\(SRCROOT)/Sources/fr.lproj/foo.xib"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/foo-PartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/fr.lproj/foo.nib", "\(SRCROOT)/Sources/fr.lproj/foo.xib"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/fr.lproj/foo.xib"),
                        .any,
                        .any,
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/fr.lproj/foo.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/fr.lproj/foo~iphone.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/fr.lproj/foo~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/foo-PartialInfo.plist"),
                    ])

                    task.checkEnvironment([
                        "XCODE_DEVELOPER_USR_PATH": .equal("\(core.developerPath.path.str)/usr/bin/.."),
                    ], exact: true)
                }

                // Check compiling the base-localized Main storyboard with the strings files.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard"), .matchRuleItem("\(SRCROOT)/Sources/Base.lproj/Main.storyboard")) { task in
                    task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/Base.lproj/Main.storyboard"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--companion-strings-file", "en:\(SRCROOT)/Sources/en.lproj/Main.strings", "--companion-strings-file", "de:\(SRCROOT)/Sources/de.lproj/Main.strings", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/Main-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "\(SRCROOT)/Sources/Base.lproj/Main.storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj",])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/Base.lproj/Main.storyboard"),
                        .path("\(SRCROOT)/Sources/en.lproj/Main.strings"),
                        .path("\(SRCROOT)/Sources/de.lproj/Main.strings"),
                        .any,
                        .any,
                    ])

                    // The .storyboardc gets placed in the intermediates dir so it can be linked later, but the .strings files get placed directly into the product.
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/Main-SBPartialInfo.plist"),
                    ])
                }

                // Check compiling the French-localized storyboard.  This storyboard would be slightly different from the Base-localized storyboard in ways that can't be captured in a .strings file.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard"), .matchRuleItem("\(SRCROOT)/Sources/fr.lproj/Main.storyboard")) { task in
                    task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/fr.lproj/Main.storyboard"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/Main-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "\(SRCROOT)/Sources/fr.lproj/Main.storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/fr.lproj/Main.storyboard"),
                        .any,
                        .any,
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/Main-SBPartialInfo.plist"),
                    ])

                    task.checkEnvironment([
                        "XCODE_DEVELOPER_USR_PATH": .equal("\(core.developerPath.path.str)/usr/bin/.."),
                    ], exact: true)
                }

                // Check compiling the unlocalized storyboards.
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileStoryboard")) { tasks in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    for (i, base) in ["bar", "baz"].enumerated() {
                        let task = sortedTasks[i]
                        task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/\(base).storyboard"])
                        task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "\(SRCROOT)/Sources/\(base).storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/\(base).storyboard"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-")),
                        ])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base).storyboardc"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist"),
                        ])
                    }
                }

                // Check the storyboard link.
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkRuleInfo(["LinkStoryboards"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--link", "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/Main.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/Main.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Base.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Base.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/fr.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz.storyboardc"),
                    ])
                }

                results.checkTasks(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
            }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the IB compile tools when processing localized files in the "legacy" style variant groups
    /// (duplicated XIBs per region versus the modern-style single Base-localization XIB + companion strings files).
    @Test(.requireSDKs(.macOS))
    func interfaceBuilderCompilers_LegacyLocalization() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("foo.xib",
                                     children: [
                                        TestFile("en.lproj/foo.xib", regionVariantName: "en"),
                                        TestFile("de.lproj/foo.xib", regionVariantName: "de"),
                                     ]
                                    ),
                    TestVariantGroup("Main.storyboard",
                                     children: [
                                        TestFile("en.lproj/Main.storyboard", regionVariantName: "en"),
                                        TestFile("fr.lproj/Main.storyboard", regionVariantName: "fr"),
                                     ]
                                    ),
                    TestFile("bar.storyboard"),
                    TestFile("baz.storyboard"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "IBC_EXEC": ibtoolPath.str,
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "CODE_SIGN_IDENTITY": "",
                                                // Disable InterfaceBuilder source code generation, which makes the command lines differ on Xcode 7.x and 8.x.
                                                "IBC_SOURCE_CODE_OUTPUT": "",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xib",
                            "Main.storyboard",
                            "bar.storyboard",
                            "baz.storyboard",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let ibtoolPath = try await self.ibtoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory related tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                // Check the xib compiles.
                for region in ["en", "de"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileXIB"), .matchRuleItemPattern(.suffix("\(region).lproj/foo.xib"))) { task in
                        task.checkRuleInfo(["CompileXIB", "\(SRCROOT)/Sources/\(region).lproj/foo.xib"])
                        task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/\(region).lproj/foo-PartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/foo.nib", "\(SRCROOT)/Sources/\(region).lproj/foo.xib"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/\(region).lproj/foo.xib"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/foo.nib"),
                            .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/foo~iphone.nib"),
                            .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/foo~ipad.nib"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(region).lproj/foo-PartialInfo.plist"),])

                        task.checkEnvironment([
                            "XCODE_DEVELOPER_USR_PATH": .equal("\(core.developerPath.path.str)/usr/bin/.."),
                        ], exact: true)
                    }
                }

                // Check the storyboard compiles.
                for region in ["en", "fr"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard"), .matchRuleItemPattern(.suffix("\(region).lproj/Main.storyboard"))) { task in
                        task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/\(region).lproj/Main.storyboard"])
                        task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/\(region).lproj/Main-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "\(SRCROOT)/Sources/\(region).lproj/Main.storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build/\(region).lproj"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/\(region).lproj/Main.storyboard"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        // The .storyboardc gets placed in the intermediates dir so it can be linked later, but the .strings files get placed directly into the product.
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(region).lproj/Main.storyboardc"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(region).lproj/Main-SBPartialInfo.plist"),])
                    }
                }

                // Check the unlocalized storyboard compiles.
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileStoryboard")) { tasks in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    for (i, base) in ["bar", "baz"].enumerated() {
                        let task = sortedTasks[i]
                        task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/\(base).storyboard"])
                        task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist", "--auto-activate-custom-fonts", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "\(SRCROOT)/Sources/\(base).storyboard", "--compilation-directory", "\(SRCROOT)/build/aProject.build/Debug/App.build"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/\(base).storyboard"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base).storyboardc"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/\(base)-SBPartialInfo.plist"),])
                    }
                }

                // Check the storyboard link.
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkRuleInfo(["LinkStoryboards"])
                    task.checkCommandLine([ibtoolPath.str, "--errors", "--warnings", "--notices", "--module", "App", "--target-device", "mac", "--minimum-deployment-target", "\(core.loadSDK(.macOS).defaultDeploymentTarget)", "--output-format", "human-readable-text", "--link", "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "\(SRCROOT)/build/aProject.build/Debug/App.build/en.lproj/Main.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/Main.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/en.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/fr.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/bar.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/en.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/fr.lproj/Main.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar.storyboardc"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz.storyboardc"),
                    ])
                }

                results.checkTasks(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
            }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func preprocessedLocalizedStringsFiles() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("InfoPlist.stringspreprocess",
                                     children: [
                                        TestFile("Base.lproj/InfoPlist.stringspreprocess", fileType: "file", regionVariantName: "Base"),
                                        TestFile("en.lproj/InfoPlist.stringspreprocess", fileType: "file", regionVariantName: "en"),
                                        TestFile("de.lproj/InfoPlist.stringspreprocess", fileType: "file", regionVariantName: "de"),
                                     ]
                                    ),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "InfoPlist.stringspreprocess",
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(
                            filePattern: "*InfoPlist.stringspreprocess",
                            script: "",
                            outputs: ["${DERIVED_FILE_DIR}/${INPUT_FILE_REGION_PATH_COMPONENT}InfoPlist.strings"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all build directory related tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("App") { target in
                for region in ["Base", "de", "en"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemPattern(.suffix("\(region).lproj/InfoPlist.stringspreprocess"))) { task in
                        task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/\(region).lproj/InfoPlist.strings", "\(SRCROOT)/Sources/\(region).lproj/InfoPlist.stringspreprocess", "normal", "undefined_arch"])
                        task.checkCommandLine(["/bin/sh", "-c", ""])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/\(region).lproj/InfoPlist.stringspreprocess"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/\(region).lproj/InfoPlist.strings"),])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("CopyStringsFile"), .matchRuleItemPattern(.suffix("\(region).lproj/InfoPlist.strings"))) { task in
                        task.checkRuleInfo(["CopyStringsFile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/InfoPlist.strings", "\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/\(region).lproj/InfoPlist.strings"])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/\(region).lproj/InfoPlist.strings"),
                            .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/InfoPlist.strings"),])
                    }
                }

                results.checkTasks(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { _ in }
            }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test that there are no output file collisions when there are multiple xib files with the same base name, but with different ~device components.
    @Test(.requireSDKs(.macOS))
    func interfaceBuilderDeviceSpecificProcessing() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Info.plist"),
                    TestFile("foo.xib"),
                    TestFile("foo~iphone.xib"),
                    TestFile("foo~ipad.xib"),
                    TestFile("bar~iphone.xib"),
                    TestFile("bar~ipad.xib"),
                    TestFile("baz.xib"),
                    TestFile("baz~ipad.xib"),
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
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                // Disable InterfaceBuilder source code generation, which makes the command lines differ on Xcode 7.x and 8.x.
                                                "IBC_SOURCE_CODE_OUTPUT": "",
                                                "INFOPLIST_FILE": "Sources/Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "foo.xib",
                            "foo~iphone.xib",
                            "foo~ipad.xib",
                            "bar~iphone.xib",
                            "bar~ipad.xib",
                            "baz.xib",
                            "baz~ipad.xib",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let ibtoolPath = try await self.ibtoolPath

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("App") { target in
                // Check the xib compiles, in particular the output files.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "\(SRCROOT)/Sources/foo.xib"])) { task in
                    task.checkCommandLineContains([ibtoolPath.str, "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo.nib", "\(SRCROOT)/Sources/foo.xib"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/foo.xib"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/foo-PartialInfo.plist"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "\(SRCROOT)/Sources/foo~iphone.xib"])) { task in
                    task.checkCommandLineContains([ibtoolPath.str, "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/foo~iphone-PartialInfo.plist", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~iphone.nib", "\(SRCROOT)/Sources/foo~iphone.xib"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/foo~iphone.xib"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~iphone.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/foo~iphone-PartialInfo.plist"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "\(SRCROOT)/Sources/foo~ipad.xib"])) { task in
                    task.checkCommandLineContains([ibtoolPath.str, "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/foo~ipad-PartialInfo.plist", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~ipad.nib", "\(SRCROOT)/Sources/foo~ipad.xib"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/foo~ipad.xib"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/foo~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/foo~ipad-PartialInfo.plist"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "\(SRCROOT)/Sources/bar~iphone.xib"])) { task in
                    task.checkCommandLineContains([ibtoolPath.str, "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar~iphone-PartialInfo.plist", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar~iphone.nib", "\(SRCROOT)/Sources/bar~iphone.xib"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/bar~iphone.xib"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar~iphone.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/bar~iphone-PartialInfo.plist"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "\(SRCROOT)/Sources/bar~ipad.xib"])) { task in
                    task.checkCommandLineContains([ibtoolPath.str, "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/bar~ipad-PartialInfo.plist", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar~ipad.nib", "\(SRCROOT)/Sources/bar~ipad.xib"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/bar~ipad.xib"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/bar~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/bar~ipad-PartialInfo.plist"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "\(SRCROOT)/Sources/baz.xib"])) { task in
                    task.checkCommandLineContains([ibtoolPath.str, "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz-PartialInfo.plist", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz.nib", "\(SRCROOT)/Sources/baz.xib"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/baz.xib"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz.nib"),
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz~iphone.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz-PartialInfo.plist"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "\(SRCROOT)/Sources/baz~ipad.xib"])) { task in
                    task.checkCommandLineContains([ibtoolPath.str, "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/App.build/baz~ipad-PartialInfo.plist", "--compile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz~ipad.nib", "\(SRCROOT)/Sources/baz~ipad.xib"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/baz~ipad.xib"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/baz~ipad.nib"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz~ipad-PartialInfo.plist"),
                    ])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of reprocessing of resource script outputs.
    @Test(.requireSDKs(.macOS))
    func resourceProcessing() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.fake-xcspec-direct"),
                    TestFile("Bar.fake-xcspec-twostep"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Foo.fake-xcspec-direct",
                            "Bar.fake-xcspec-twostep",
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*/*.fake-xcspec-direct", script: "ProcessDirect", outputs: [
                            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/$(INPUT_FILE_BASE).fake-xcspec-direct"
                        ]),
                        TestBuildRule(filePattern: "*/*.fake-xcspec-twostep", script: "ProcessTwoStep", outputs: [
                            "$(DERIVED_FILES_DIR)/$(INPUT_FILE_BASE).fake-xcspec-twostep"
                        ]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("CoreFoo") { target in
                // We should have a RuleScriptExecution task to process directly into the Resources directory.
                results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("Foo.fake-xcspec-direct")) { task in
                    task.checkRuleInfo(["RuleScriptExecution", "/tmp/Test/aProject/build/Debug/CoreFoo.framework/Versions/A/Resources/Foo.fake-xcspec-direct", "/tmp/Test/aProject/Sources/Foo.fake-xcspec-direct", "normal", "undefined_arch"])
                }

                // We should have tasks to process into the DERIVED_FILES_DIR and then copy from there into the Resources directory.
                results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("Bar.fake-xcspec-twostep")) { task in
                    task.checkRuleInfo(["RuleScriptExecution", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources/Bar.fake-xcspec-twostep", "/tmp/Test/aProject/Sources/Bar.fake-xcspec-twostep", "normal", "undefined_arch"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CpResource"), .matchRuleItemBasename("Bar.fake-xcspec-twostep")) { task in
                    task.checkRuleInfo(["CpResource", "/tmp/Test/aProject/build/Debug/CoreFoo.framework/Versions/A/Resources/Bar.fake-xcspec-twostep", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources/Bar.fake-xcspec-twostep"])
                }

                // We should not have any other CpResource or RuleScriptExecution tasks.
                results.checkNoTask(.matchRuleType("RuleScriptExecution"))
                results.checkNoTask(.matchRuleType("CpResource"))
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of copy files build phases when processing resources.
    @Test(.requireSDKs(.macOS))
    func copyFilesProcessing() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.png"),
                    TestFile("Bar.fake-twostep"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "APPLY_RULES_IN_COPY_FILES": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "Foo.png",
                        ], destinationSubfolder: .resources, onlyForDeployment: false),
                        TestCopyFilesBuildPhase([
                            "Bar.fake-twostep",
                        ], destinationSubfolder: .resources, onlyForDeployment: false),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*/*.fake-twostep", script: "ProcessTwoStep", outputs: [
                            "$(DERIVED_FILES_DIR)/$(INPUT_FILE_BASE).fake-twostep"
                        ]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("CoreFoo") { target in
                // We should have a Debug task to process directly into framework.
                results.checkTask(.matchTarget(target), .matchRuleType("CopyPNGFile"), .matchRuleItemBasename("Foo.png")) { task in
                    task.checkRuleInfo(["CopyPNGFile", "\(SRCROOT)/build/Debug/CoreFoo.framework/Versions/A/Resources/Foo.png", "\(SRCROOT)/Sources/Foo.png"])
                }

                // We should have tasks to process the .fake-twostep source into the DERIVED_FILES_DIR and then copy from there into the Resources directory.
                results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("Bar.fake-twostep")) { task in
                    task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/DerivedSources/Bar.fake-twostep", "\(SRCROOT)/Sources/Bar.fake-twostep", "normal", "undefined_arch"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Bar.fake-twostep")) { task in
                    task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug/CoreFoo.framework/Versions/A/Resources/Bar.fake-twostep", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/DerivedSources/Bar.fake-twostep"])
                }

                // We should not have any other CpResource or RuleScriptExecution tasks.
                results.checkNoTask(.matchRuleType("RuleScriptExecution"))
                results.checkNoTask(.matchRuleType("CpResource"))
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func copyLocalizedFilesProcessing() async throws {
        // This tests a weird case where the strings file is referenced without
        // a variant group but Xcode does create a variant group for these references.
        //
        // A sample project is available in <rdar://problem/37618285>.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("English.lproj/Localizable.strings", regionVariantName: "English"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
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

        await tester.checkBuild(runDestination: .iOS) { results in
            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("Localizable.strings")) { task in
                    task.checkRuleInfo(["Copy", "/tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework/English.lproj/Localizable.strings", "/tmp/Test/aProject/Sources/English.lproj/Localizable.strings"])
                }
            }
            results.checkNoDiagnostics()
        }
    }

    /// Test permutations of the versioning stub file.
    @Test(.requireSDKs(.macOS))
    func versioningStub() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "VERSIONING_SYSTEM": "apple-generic",
                        "CURRENT_PROJECT_VERSION": "3.1",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check that setting VERSION_INFO_EXPORT_DECL to 'export' generates the expected file contents.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["VERSION_INFO_EXPORT_DECL": "export"]), runDestination: .macOS) { results in
            // There should be a WriteAuxiliaryFile task to create the versioning file.
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"])) { task, contents in
                task.checkInputs([
                    .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                task.checkOutputs([
                    .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"),])

                #expect(contents == "export extern const unsigned char AppTargetVersionString[];\nexport extern const double AppTargetVersionNumber;\n\nexport const unsigned char AppTargetVersionString[] __attribute__ ((used)) = \"@(#)PROGRAM:AppTarget  PROJECT:aProject-3.1\" \"\\n\";\nexport const double AppTargetVersionNumber __attribute__ ((used)) = (double)3.1;\n")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check that setting VERSION_INFO_EXPORT_DECL to 'static' generates the expected file contents, omitting the 'extern' lines.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["VERSION_INFO_EXPORT_DECL": "static"]), runDestination: .macOS) { results in
            // There should be a WriteAuxiliaryFile task to create the versioning file.
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"])) { task, contents in
                task.checkInputs([
                    .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                task.checkOutputs([
                    .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"),])

                #expect(contents == "static const unsigned char AppTargetVersionString[] __attribute__ ((used)) = \"@(#)PROGRAM:AppTarget  PROJECT:aProject-3.1\" \"\\n\";\nstatic const double AppTargetVersionNumber __attribute__ ((used)) = (double)3.1;\n")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check that setting apple-generic-hidden generates the expected file contents.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["VERSIONING_SYSTEM": "apple-generic-hidden"]), runDestination: .macOS) { results in
            // There should be a WriteAuxiliaryFile task to create the versioning file.
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"])) { task, contents in
                task.checkInputs([
                    .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                task.checkOutputs([
                    .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"),])

                #expect(contents == "__attribute__ ((__visibility__(\"hidden\")))  extern const unsigned char AppTargetVersionString[];\n__attribute__ ((__visibility__(\"hidden\")))  extern const double AppTargetVersionNumber;\n\n__attribute__ ((__visibility__(\"hidden\")))  const unsigned char AppTargetVersionString[] __attribute__ ((used)) = \"@(#)PROGRAM:AppTarget  PROJECT:aProject-3.1\" \"\\n\";\n__attribute__ ((__visibility__(\"hidden\")))  const double AppTargetVersionNumber __attribute__ ((used)) = (double)3.1;\n")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check that setting apple-generic-hidden works with VERSION_INFO_EXPORT_DECL and generates the expected file contents.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["VERSIONING_SYSTEM": "apple-generic-hidden",
                                                                                    "VERSION_INFO_EXPORT_DECL": "somedeclattr"]), runDestination: .macOS) { results in
            // There should be a WriteAuxiliaryFile task to create the versioning file.
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"])) { task, contents in
                task.checkInputs([
                    .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                task.checkOutputs([
                    .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"),])

                #expect(contents == "__attribute__ ((__visibility__(\"hidden\"))) somedeclattr extern const unsigned char AppTargetVersionString[];\n__attribute__ ((__visibility__(\"hidden\"))) somedeclattr extern const double AppTargetVersionNumber;\n\n__attribute__ ((__visibility__(\"hidden\"))) somedeclattr const unsigned char AppTargetVersionString[] __attribute__ ((used)) = \"@(#)PROGRAM:AppTarget  PROJECT:aProject-3.1\" \"\\n\";\n__attribute__ ((__visibility__(\"hidden\"))) somedeclattr const double AppTargetVersionNumber __attribute__ ((used)) = (double)3.1;\n")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check that we only generate dSYMs when appropriate.
    @Test(.requireSDKs(.macOS))
    func dSYMGeneration() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check behavior with dSYMs disabled.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["DEBUG_INFORMATION_FORMAT": "dwarf"]), runDestination: .macOS) { results in
            // There shouldn't be a dSYM task.
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"))

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check behavior with dSYMs enabled.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"]), runDestination: .macOS) { results in
            // Check the expected dSYM task.
            results.checkTask(.matchRuleType("GenerateDSYMFile")) { task in
                task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/Test/aProject/build/Debug/CoreFoo.framework/Versions/A/CoreFoo"])
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check that we honor the appropriate header stripping overrides.
    @Test(.requireSDKs(.macOS))
    func copyHeaderRemoval() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Thing-1.txt"),
                    TestFile("Thing-2.txt"),
                ]),
            targets: [
                TestAggregateTarget("All", buildPhases: [
                    TestCopyFilesBuildPhase([
                        TestBuildFile("Thing-1.txt", removeHeadersOnCopy: true),
                        TestBuildFile("Thing-2.txt", removeHeadersOnCopy: false)], destinationSubfolder: .frameworks,
                                            onlyForDeployment: false),
                ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check default behavior (should honor the flag).
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("Thing-1.txt")) { task in
                task.checkRuleInfo(["Copy", "/tmp/Test/aProject/build/Debug/Thing-1.txt", "/tmp/Test/aProject/Sources/Thing-1.txt"])
                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-exclude", "Headers", "-exclude", "PrivateHeaders", "-exclude", "Modules", "-exclude", "*.tbd", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "-remove-static-executable", "/tmp/Test/aProject/Sources/Thing-1.txt", "/tmp/Test/aProject/build/Debug"])
            }
            results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("Thing-2.txt")) { task in
                task.checkRuleInfo(["Copy", "/tmp/Test/aProject/build/Debug/Thing-2.txt", "/tmp/Test/aProject/Sources/Thing-2.txt"])
                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "-remove-static-executable", "/tmp/Test/aProject/Sources/Thing-2.txt", "/tmp/Test/aProject/build/Debug"])
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check global disabling override.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES": "NO"]), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("Thing-1.txt")) { task in
                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "-remove-static-executable", "/tmp/Test/aProject/Sources/Thing-1.txt", "/tmp/Test/aProject/build/Debug"])
            }
            results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("Thing-2.txt")) { task in
                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "-remove-static-executable", "/tmp/Test/aProject/Sources/Thing-2.txt", "/tmp/Test/aProject/build/Debug"])
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the handling of COMBINE_HIDPI_IMAGES rules.
    @Test(.requireSDKs(.macOS))
    func imageCombining() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Single.png"),
                    TestFile("Missing1x@2x.png"),
                    TestFile("Another.jpg"),
                    TestFile("Doubled.png"),
                    TestFile("Doubled@2x.png"),
                    TestFile("MixedType.png"),
                    TestFile("MixedType@2x.tiff"),
                    TestFile("sneaky.png"),
                    TestFile("other-directory/sneaky@2x.png"),
                    TestVariantGroup("daily-schedule.png", children: [
                        TestFile("Base.lproj/daily-schedule.png", regionVariantName: "Base"),
                        TestFile("en.lproj/daily-schedule.png", regionVariantName: "en"),
                        TestFile("de.lproj/daily-schedule.png", regionVariantName: "de")
                    ]),
                    TestVariantGroup("daily-schedule@2x.png", children: [
                        TestFile("Base.lproj/daily-schedule@2x.png", regionVariantName: "Base"),
                        TestFile("en.lproj/daily-schedule@2x.png", regionVariantName: "en"),
                        TestFile("de.lproj/daily-schedule@2x.png", regionVariantName: "de")
                    ]),
                    TestFile("CopiedPNG.png"),
                    TestFile("CopiedJPEG.jpg")
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget("App", type: .application, buildPhases: [
                    TestResourcesBuildPhase([
                        // Single files which get copied rather than combined.
                        "Single.png",
                        "Missing1x@2x.png",
                        "Another.jpg",
                        // A pair of files which get combined.
                        "Doubled.png",
                        "Doubled@2x.png",
                        // Single files which get copied rather than combined because they have different file extensions.
                        "MixedType.png",
                        "MixedType@2x.tiff",
                        // Single files which get copied rather than combined because they're in separate directories.
                        "sneaky.png",
                        "other-directory/sneaky@2x.png",
                        // Localized files which get combined.
                        "daily-schedule.png",
                        "daily-schedule@2x.png"
                    ]),
                    TestCopyFilesBuildPhase([
                        "CopiedPNG.png",
                        "CopiedJPEG.jpg"
                    ], destinationSubfolder: .resources, destinationSubpath: "Sources", onlyForDeployment: false)
                ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check behavior when combining.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["COMBINE_HIDPI_IMAGES": "YES", "APPLY_RULES_IN_COPY_FILES": "YES"]), runDestination: .macOS) { results in
            // There should be an individual copy of each single image, using the appropriate tool.
            do {
                let rule = "CopyPNGFile", name = "Single.png"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }
            do {
                let rule = "CopyPNGFile", name = "Missing1x@2x.png"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }
            do {
                let rule = "CpResource", name = "Another.jpg"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }
            do {
                let rule = "CopyPNGFile", name = "sneaky.png"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }
            do {
                let rule = "CopyPNGFile", name = "sneaky@2x.png"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/other-directory/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/other-directory/\(name)")
                }
            }

            // There should be a combining copy for the double image.
            results.checkTask(.matchRuleType("TiffUtil"), .matchRuleItemBasename("Doubled.tiff")) { task in
                task.checkRuleInfo(["TiffUtil", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/Doubled.tiff"])
                task.checkCommandLine(["tiffutil", "-cathidpicheck", "\(SRCROOT)/Sources/Doubled.png", "\(SRCROOT)/Sources/Doubled@2x.png", "-out", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/Doubled.tiff"])
                task.checkInputs([
                    .path("\(SRCROOT)/Sources/Doubled.png"),
                    .path("\(SRCROOT)/Sources/Doubled@2x.png"),
                    .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                    .namePattern(.prefix("target-"))])
            }

            // There should be an individual copy and copy-tiff for each of the MixedType images which have the same root name but different file types.
            do {
                let rule = "CopyPNGFile", name = "MixedType.png"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }
            do {
                let rule = "CopyTiffFile", name = "MixedType@2x.tiff"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }

            do {
                let rule = "CopyPNGFile", name = "CopiedPNG.png"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/Sources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }

            do {
                let rule = "CpResource", name = "CopiedJPEG.jpg"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/Sources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                }
            }

            // There should be a combining copy for each localization of the daily-schedule image.
            results.checkTasks(.matchRuleType("TiffUtil"), .matchRuleItemBasename("daily-schedule.tiff")) { tasks in
                for (region, task) in zip(["Base", "de", "en"], tasks.sorted(by: \.outputs[0].path)) {
                    task.checkRuleInfo(["TiffUtil", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/daily-schedule.tiff"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/\(region).lproj/daily-schedule.png"),
                        .path("\(SRCROOT)/Sources/\(region).lproj/daily-schedule@2x.png"),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])
                    XCTAssertMatch(task.outputs.map{ $0.path.str }, [
                        .equal("\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(region).lproj/daily-schedule.tiff")])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check behavior when not combining.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["COMBINE_HIDPI_IMAGES": "NO"]), runDestination: .macOS) { results in
            // There should be a CopyPNGFile or CopyTiffFile task for each file, as appropriate.
            for name in ["Single.png", "Missing1x@2x.png", "Doubled.png", "Doubled@2x.png", "MixedType.png", "MixedType@2x.tiff"] {
                let rule = Path(name).fileExtension == "png" ? "CopyPNGFile" : "CopyTiffFile"
                results.checkTask(.matchRuleType(rule), .matchRuleItemBasename(name)) { task in
                    task.checkRuleInfo([rule, "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)", "\(SRCROOT)/Sources/\(name)"])
                    // FIXME: This doesn't look right.
                    if rule == "CopyTiffFile" {
                        task.checkCommandLine(["builtin-copyTiff", "--outdir", "\(SRCROOT)/build/Debug/App.app/Contents/Resources", "--", "\(SRCROOT)/Sources/\(name)"])
                    } else {
                        task.checkCommandLine(["copypng", "\(SRCROOT)/Sources/\(name)", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)"])
                    }
                    #expect(task.inputs.first?.path.str == "\(SRCROOT)/Sources/\(name)")
                    XCTAssertMatch(task.outputs.map{ $0.path.str }, [
                            .equal("\(SRCROOT)/build/Debug/App.app/Contents/Resources/\(name)")])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the handling of COMBINE_HIDPI_IMAGES rules, from a sources phase.
    @Test(.requireSDKs(.macOS))
    func sourcesImageCombining() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Doubled@1x.png"),
                    TestFile("Doubled@2x.png"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget("App", type: .application, buildPhases: [
                    TestSourcesBuildPhase([
                        "Doubled@1x.png",
                        "Doubled@2x.png",
                    ]),
                ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check behavior when combining.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["COMBINE_HIDPI_IMAGES": "YES"]), runDestination: .macOS) { results in
            // There should no no TIFF combining copy task for the double image.
            results.checkNoTask(.matchRuleType("TiffUtil"), .matchRuleItemBasename(".tiff"))

            results.checkWarning("The file \"/tmp/Test/aProject/Sources/Doubled@1x.png\" cannot be processed by the Compile Sources build phase using the \"TiffUtil\" rule. (in target \'App\' from project 'aProject')")
            results.checkWarning("The file \"/tmp/Test/aProject/Sources/Doubled@2x.png\" cannot be processed by the Compile Sources build phase using the \"TiffUtil\" rule. (in target \'App\' from project 'aProject')")

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func multipleAssetCatalogs() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("A.xcassets"),
                    TestFile("B C.xcassets"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget("App", type: .application, buildPhases: [
                    TestResourcesBuildPhase([
                        "A.xcassets",
                        "B C.xcassets",
                    ]),
                ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            for variant in ["thinned", "unthinned"] {
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                    task.checkRuleInfo(["CompileAssetCatalogVariant", variant, "/tmp/Test/aProject/build/Debug/App.app/Contents/Resources", "/tmp/Test/aProject/Sources/A.xcassets", "/tmp/Test/aProject/Sources/B C.xcassets"])
                    task.checkCommandLineContains(["/tmp/Test/aProject/Sources/A.xcassets", "/tmp/Test/aProject/Sources/B C.xcassets"])
                }
            }

            results.checkNoTask(.matchRuleType("CompileAssetCatalog"))
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func multipleAssetCatalogsInSourcesPhase() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("A.xcassets"),
                    TestFile("B.xcassets"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "CODE_SIGN_IDENTITY": "",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget("App", type: .application, buildPhases: [
                    TestSourcesBuildPhase([
                        "A.xcassets",
                        "B.xcassets",
                    ]),
                ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            for variant in ["thinned", "unthinned"] {
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                    task.checkRuleInfo(["CompileAssetCatalogVariant", variant, "/tmp/Test/aProject/build/Debug/App.app/Contents/Resources", "/tmp/Test/aProject/Sources/A.xcassets", "/tmp/Test/aProject/Sources/B.xcassets"])
                    task.checkCommandLineContains(["/tmp/Test/aProject/Sources/A.xcassets", "/tmp/Test/aProject/Sources/B.xcassets"])
                }
            }

            results.checkNoTask(.matchRuleType("CompileAssetCatalog"))
            results.checkNoTask(.matchRuleType("CompileAssetCatalogVariant"))

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func sceneKitDAEProcessing() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("A.dae"),
                    TestFile("B.dae"),
                    TestFile("C.DAE"), // test that uppercase extensions work too
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget("App", type: .application, buildPhases: [
                    TestResourcesBuildPhase([
                        TestBuildFile("A.dae", decompress: false),
                        TestBuildFile("B.dae", decompress: true),
                        TestBuildFile("C.DAE", decompress: false),
                    ]),
                ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("Process"), .matchRuleItemBasename("A.dae")) { task in
                task.checkRuleInfo(["Process", "SceneKit", "document", "\(SRCROOT)/Sources/A.dae"])
                task.checkCommandLineContains(["scntool", "--compress", "\(SRCROOT)/Sources/A.dae"])
            }
            results.checkTask(.matchRuleType("Process"), .matchRuleItemBasename("B.dae")) { task in
                task.checkRuleInfo(["Process", "SceneKit", "document", "\(SRCROOT)/Sources/B.dae"])
                task.checkCommandLineContains(["scntool", "--decompress", "\(SRCROOT)/Sources/B.dae"])
            }
            results.checkTask(.matchRuleType("Process"), .matchRuleItemBasename("C.DAE")) { task in
                task.checkRuleInfo(["Process", "SceneKit", "document", "\(SRCROOT)/Sources/C.DAE"])
                task.checkCommandLineContains(["scntool", "--compress", "\(SRCROOT)/Sources/C.DAE", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/C.dae"])
            }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func dtraceProcessing() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: [
                    TestFile("foo.d"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ])
            ],
            targets: [
                TestStandardTarget(
                    "Framework", type: .framework,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            TestBuildFile("foo.d", additionalArgs: ["-Dextra"]),
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTask(.matchRuleItemBasename("foo.d")) { task in
                task.checkCommandLine(["/usr/sbin/dtrace", "-h", "-Dextra", "-s", "\(SRCROOT)/Sources/foo.d", "-o", "\(SRCROOT)/build/aProject.build/Debug/Framework.build/DerivedSources/foo.h"])
            }
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of copying variant groups.
    @Test(.requireSDKs(.macOS))
    func variantGroupResourceCopying() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("jp.lproj/Localizable.strings", regionVariantName: "jp"),
                    ]),
                    TestVariantGroup("Images", children: [
                        TestFile("en.lproj/Images", fileType: "folder", regionVariantName: "en"),
                        TestFile("jp.lproj/Images", fileType: "folder", regionVariantName: "jp"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Localizable.strings",
                            "Images",
                        ])
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTask(.matchRule(["CopyStringsFile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/en.lproj/Localizable.strings", "\(SRCROOT)/Sources/en.lproj/Localizable.strings"])) { _ in }
            results.checkTask(.matchRule(["CopyStringsFile", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/jp.lproj/Localizable.strings", "\(SRCROOT)/Sources/jp.lproj/Localizable.strings"])) { _ in }
            results.checkNoTask(.matchRuleType("CopyStringsFile"))

            results.checkTask(.matchRule(["CpResource", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/en.lproj/Images", "\(SRCROOT)/Sources/en.lproj/Images"])) { _ in }
            results.checkTask(.matchRule(["CpResource", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/jp.lproj/Images", "\(SRCROOT)/Sources/jp.lproj/Images"])) { _ in }
            results.checkNoTask(.matchRuleType("CpResource"))

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS), .bug("rdar://31822430"), .knownIssue("PlaygroundLogger build failure because Copy runs before Modules symlink (or maybe there is no such symlink)?"))
    func copyFilesIntoModulesSymLink() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: [
                    TestFile("foo.txt"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildPhases: [
                        TestCopyFilesBuildPhase(
                            [
                                "foo.txt"
                            ],
                            destinationSubfolder: .wrapper,
                            destinationSubpath: "Modules",
                            onlyForDeployment: false
                        ),
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTask(.matchRule(["MkDir", "/tmp/Test/aProject/build/Debug/Framework.framework/Versions/A/Modules"])) { _ in }
            results.checkTask(.matchRule(["SymLink", "/tmp/Test/aProject/build/Debug/Framework.framework/Modules", "Versions/Current/Modules"])) { _ in }
            results.checkTask(.matchRule(["Copy", "/tmp/Test/aProject/build/Debug/Framework.framework/Modules/foo.txt", "/tmp/Test/aProject/Sources/foo.txt"])) { _ in }

            results.checkNoDiagnostics()
        }
    }

    /// Test processing .applescript files.
    ///
    /// The source files are in the Sources build phase, but the OSA compiler spec places the outputs into the Resources folder of the product.
    @Test(.requireSDKs(.macOS))
    func appleScriptProcessing() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources",
                children: [
                    TestFile("main.m"),
                    TestFile("Foo.applescript"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                            "Foo.applescript",
                        ]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("App") { target in
                // There should be a task to process the .applescript file to the Resources folder.
                results.checkTask(.matchTarget(target), .matchRule(["OSACompile", "\(SRCROOT)/Foo.applescript"])) { task in
                    task.checkCommandLine(["/usr/bin/osacompile", "-l", "AppleScript", "-d", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/Foo.scpt", "\(SRCROOT)/Foo.applescript"])
                    task.checkInputs(contain: [.path("\(SRCROOT)/Foo.applescript")])
                    task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/Foo.scpt")])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test that the AppleScript build phase is properly reported as deprecated.
    @Test(.requireSDKs(.macOS))
    func appleScriptBuildPhaseDeprecation() async throws {
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Foo.applescript"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestAppleScriptBuildPhase([
                                "Foo.applescript",
                            ]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results in
                // There should be no OSACompile tasks.
                results.checkNoTask(.matchRuleType("OSACompile"))

                // Check that the AppleScript build phase diagnostic is emitted.
                results.checkError(.equal("AppleScript build phases are no longer supported.  AppleScript source files should be moved to the Compile Sources build phase. (in target \'App\' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }

        // Test that no error is emitted for an AppleScript build phase which does not contain any files.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "Sources",
                    children: [
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestAppleScriptBuildPhase([
                            ]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results in
                // There should be no OSACompile tasks.
                results.checkNoTask(.matchRuleType("OSACompile"))

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that when the intersection of ARCHS and VALID_ARCHS yield no architectures to build for, a warning is emitted for each target so configured.
    @Test(.requireSDKs(.watchOS))
    func warningsOnEmptyArchs() async throws {

        // Each of these tests builds a bundle, framework and appex target.

        func createProject(extraSettings: [String: String]) -> TestProject {
            return TestProject(
                "aProject",
                groupTree: TestGroup("Sources", children: [
                    TestFile("File.c"),
                ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "BUILD_VARIANTS": "normal debug",
                        "DEVELOPMENT_TEAM": "",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_STYLE": "Automatic",
                        "SDKROOT": "watchsimulator"].addingContents(of: extraSettings))],
                targets: [
                    TestAggregateTarget("All",
                                        dependencies: ["anAppex_watchOS"]),
                    TestStandardTarget(
                        "aBundle_watchOS", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: ["PRODUCT_NAME": "aBundle",
                                                                   "SDKROOT": "watchsimulator"])],
                        buildPhases: [TestSourcesBuildPhase([]),]),
                    TestStandardTarget(
                        "aFramework_watchOS", type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: ["PRODUCT_NAME": "aFramework",
                                                                   "SDKROOT": "watchsimulator"])],
                        buildPhases: [TestSourcesBuildPhase(["File.c"]),]),
                    TestStandardTarget(
                        "anAppex_watchOS", type: .applicationExtension,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: ["PRODUCT_NAME": "anAppex",
                                                                   "SDKROOT": "watchsimulator"])],
                        buildPhases: [TestSourcesBuildPhase(["File.c"]),],
                        dependencies: ["aFramework_watchOS", "aBundle_watchOS"])])
        }

        // Convenience method for toggling between debug and release builds.
        func checkBuild(_ tester: TaskConstructionTester, forRelease: Bool = false, file: StaticString = #filePath, line: UInt = #line, body: (TaskConstructionTester.PlanningResults) throws -> Void) async rethrows {
            let buildParameters = forRelease ? BuildParameters(action: .install, configuration: "Debug") : nil
            try await tester.checkBuild(buildParameters, runDestination: .watchOSSimulator) { results in
                try body(results)
            }
        }

        // Baseline test.
        do {
            let testProject = createProject(extraSettings: ["VALID_ARCHS": "powerpc"])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            // Perform a debug build
            await checkBuild(tester) { results in
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }

            // Perform a release build
            await checkBuild(tester, forRelease: true) { results in
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test EXCLUDED_ARCHS.
        do {
            let testProject = createProject(extraSettings: [
                "VALID_ARCHS": "x86_64 powerpc",
                "EXCLUDED_ARCHS": "x86_64"
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            // Perform a debug build
            await checkBuild(tester) { results in
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (x86_64, powerpc) which is not in EXCLUDED_ARCHS (x86_64). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (x86_64, powerpc) which is not in EXCLUDED_ARCHS (x86_64). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }

            // Perform a release build
            await checkBuild(tester, forRelease: true) { results in
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (x86_64, powerpc) which is not in EXCLUDED_ARCHS (x86_64). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (x86_64, powerpc) which is not in EXCLUDED_ARCHS (x86_64). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test EXCLUDED_ARCHS where it is a superset of VALID_ARCHS.
        do {
            let testProject = createProject(extraSettings: [
                "VALID_ARCHS": "i386",
                "EXCLUDED_ARCHS": "i386",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            // Perform a debug build
            await checkBuild(tester) { results in
                results.checkWarning(.equal("There are no architectures to compile for because all architectures in VALID_ARCHS (i386) are also in EXCLUDED_ARCHS (i386). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("There are no architectures to compile for because all architectures in VALID_ARCHS (i386) are also in EXCLUDED_ARCHS (i386). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }

            // Perform a release build
            await checkBuild(tester, forRelease: true) { results in
                results.checkWarning(.equal("There are no architectures to compile for because all architectures in VALID_ARCHS (i386) are also in EXCLUDED_ARCHS (i386). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("There are no architectures to compile for because all architectures in VALID_ARCHS (i386) are also in EXCLUDED_ARCHS (i386). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test with ONLY_ACTIVE_ARCH = YES.
        do {
            let testProject = createProject(extraSettings: [
                "VALID_ARCHS": "powerpc",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            // Perform a debug build
            await checkBuild(tester) { results in
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }

            // Perform a release build
            await checkBuild(tester, forRelease: true) { results in
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("None of the architectures in ARCHS (arm64, x86_64) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test with ONLY_ACTIVE_ARCH = YES and arch = i386.  This produces a warning that the "current architecture" is not valid.
        do {
            let testProject = createProject(extraSettings: [
                "arch": "i386",
                "VALID_ARCHS": "powerpc",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            // Perform a debug build
            await checkBuild(tester) { results in
                results.checkWarning(.equal("The active architecture (i386) is not valid - it is the only architecture considered because ONLY_ACTIVE_ARCH is enabled. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("The active architecture (i386) is not valid - it is the only architecture considered because ONLY_ACTIVE_ARCH is enabled. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (powerpc). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test with VALID_ARCHS = " ".  This produces a warning that VALID_ARCHS is empty.
        do {
            let testProject = createProject(extraSettings: ["VALID_ARCHS": " "])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            // Perform a debug build
            await checkBuild(tester) { results in
                results.checkWarning(.equal("There are no architectures to compile for because the VALID_ARCHS build setting is an empty list. (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("There are no architectures to compile for because the VALID_ARCHS build setting is an empty list. (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }

            // Perform a release build
            await checkBuild(tester, forRelease: true) { results in
                results.checkWarning(.equal("There are no architectures to compile for because the VALID_ARCHS build setting is an empty list. (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("There are no architectures to compile for because the VALID_ARCHS build setting is an empty list. (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test with ARCHS = " ".  This produces a warning noting that ARCHS is empty.
        do {
            let testProject = createProject(extraSettings: [
                "VALID_ARCHS": "i386",
                "ARCHS": " ",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            // Perform a debug build
            await checkBuild(tester) { results in
                results.checkWarning(.equal("There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (i386). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (i386). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }

            // Perform a release build
            await checkBuild(tester, forRelease: true) { results in
                results.checkWarning(.equal("There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (i386). (in target 'anAppex_watchOS' from project 'aProject')"))
                results.checkWarning(.equal("There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (i386). (in target 'aFramework_watchOS' from project 'aProject')"))
                // No warning for the bundle target because it contains no source files.

                // Check there are no other diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that having some other task producing a directory which is otherwise part of creating the product structure doesn't result in an error.
    @Test(.requireSDKs(.macOS))
    func alternateProducersOfProductStructure() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Scripts", fileType: "folder"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        // Copy the Scripts folder into the Resources build phase.
                        TestResourcesBuildPhase([
                            "Scripts",
                        ]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("CoreFoo") { target in
                // We should have a copy command to copy the Scripts folder into the Resources build phase.  And the checkBuild() logic will implicitly check that there isn't also a mkdir command for that directory.
                results.checkTask(.matchTarget(target), .matchRuleType("CpResource"), .matchRuleItemBasename("Scripts")) { task in
                    task.checkRuleInfo(["CpResource", "\(SRCROOT)/build/Debug/CoreFoo.framework/Versions/A/Resources/Scripts", "\(SRCROOT)/Sources/Scripts"])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

}

private func XCTAssertEqual(_ lhs: EnvironmentBindings, _ rhs: [String: String], file: StaticString = #filePath, line: UInt = #line) {
    #expect(lhs.bindingsDictionary == rhs)
}
