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
fileprivate struct AssetCatalogTaskConstructionTests: CoreBasedTests {
    func assetCatalogThinningTestProject(tmpDir: Path, thinningBuildSettings: [String: String]) async throws -> TestProject {
        return try await TestProject(
            "aProject",
            sourceRoot: tmpDir,
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Test.swift"),
                    TestFile("Assets.xcassets"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.apple.project",
                        "SDKROOT": "iphoneos",
                        "CODE_SIGN_IDENTITY": "-",
                        // Thinning
                        "ENABLE_ONLY_ACTIVE_RESOURCES": "YES",
                        "BUILD_ACTIVE_RESOURCES_ONLY": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.0",
                    ].addingContents(of: thinningBuildSettings)),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Test.swift"),
                        ]),
                        TestResourcesBuildPhase([
                            TestBuildFile("Assets.xcassets"),
                        ]),
                    ]
                ),
            ], classPrefix: "XC")
    }

    @Test(.requireSDKs(.iOS))
    func filterForThinningDeviceConfiguration() async throws {
        let actoolPath = try await self.actoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await assetCatalogThinningTestProject(tmpDir: tmpDir, thinningBuildSettings: [
                "ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION": "myPhoneABCD,10-B",
                "ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION": "12.1235",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { task in
                    task.checkCommandLine([actoolPath.str,
                                           "\(SRCROOT)/Assets.xcassets",
                                           "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/thinned",
                                           "--output-format", "human-readable-text",
                                           "--notices", "--warnings",
                                           "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_thinned",
                                           "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_thinned",
                                           "--compress-pngs",
                                           "--enable-on-demand-resources", "NO",
                                           "--filter-for-thinning-device-configuration", "myPhoneABCD,10-B",
                                           "--filter-for-device-os-version", "12.1235",
                                           "--development-region", "English",
                                           "--target-device", "iphone",
                                           "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                           "--platform", "iphoneos",])
                }
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned")) { task in
                    task.checkCommandLine([actoolPath.str,
                                           "\(SRCROOT)/Assets.xcassets",
                                           "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/unthinned",
                                           "--output-format", "human-readable-text",
                                           "--notices", "--warnings",
                                           "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_unthinned",
                                           "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_unthinned",
                                           "--compress-pngs",
                                           "--enable-on-demand-resources", "NO",
                                           "--development-region", "English",
                                           "--target-device", "iphone",
                                           "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                           "--platform", "iphoneos",])
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func filterForThinningDeviceConfigurationAndDeviceModel() async throws {
        let actoolPath = try await self.actoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await assetCatalogThinningTestProject(tmpDir: tmpDir, thinningBuildSettings: [
                "ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION": "myPhoneFooBar12,3-B",
                "ASSETCATALOG_FILTER_FOR_DEVICE_MODEL": "myPhoneFooBar12,3",
                "ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION": "13.2",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { task in
                    task.checkCommandLine([actoolPath.str,
                                           "\(SRCROOT)/Assets.xcassets",
                                           "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/thinned",
                                           "--output-format", "human-readable-text",
                                           "--notices", "--warnings",
                                           "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_thinned",
                                           "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_thinned",
                                           "--compress-pngs",
                                           "--enable-on-demand-resources", "NO",
                                           "--filter-for-thinning-device-configuration", "myPhoneFooBar12,3-B",
                                           // --filter-for-device-model should be hidden because of ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION
                                           "--filter-for-device-os-version", "13.2",
                                           "--development-region", "English",
                                           "--target-device", "iphone",
                                           "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                           "--platform", "iphoneos",
                                           ])
                }
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned")) { task in
                    task.checkCommandLine([actoolPath.str,
                                           "\(SRCROOT)/Assets.xcassets",
                                           "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/unthinned",
                                           "--output-format", "human-readable-text",
                                           "--notices", "--warnings",
                                           "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_unthinned",
                                           "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_unthinned",
                                           "--compress-pngs",
                                           "--enable-on-demand-resources", "NO",
                                           "--development-region", "English",
                                           "--target-device", "iphone",
                                           "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                           "--platform", "iphoneos",
                                           ])
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func filterForDeviceModel() async throws {
        let actoolPath = try await self.actoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await assetCatalogThinningTestProject(tmpDir: tmpDir, thinningBuildSettings: [
                "ASSETCATALOG_FILTER_FOR_DEVICE_MODEL": "myPhoneFooBar12,3",
                "ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION": "13.2",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { task in
                    task.checkCommandLine([actoolPath.str,
                                           "\(SRCROOT)/Assets.xcassets",
                                           "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/thinned",
                                           "--output-format", "human-readable-text",
                                           "--notices", "--warnings",
                                           "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_thinned",
                                           "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_thinned",
                                           "--compress-pngs",
                                           "--enable-on-demand-resources", "NO",
                                           "--filter-for-device-model", "myPhoneFooBar12,3",
                                           "--filter-for-device-os-version", "13.2",
                                           "--development-region", "English",
                                           "--target-device", "iphone",
                                           "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                           "--platform", "iphoneos",
                                           ])
                }

                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned")) { task in
                    task.checkCommandLine([actoolPath.str,
                                           "\(SRCROOT)/Assets.xcassets",
                                           "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/unthinned",
                                           "--output-format", "human-readable-text",
                                           "--notices", "--warnings",
                                           "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_unthinned",
                                           "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_unthinned",
                                           "--compress-pngs",
                                           "--enable-on-demand-resources", "NO",
                                           "--development-region", "English",
                                           "--target-device", "iphone",
                                           "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                           "--platform", "iphoneos",
                                           ])
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func noFilters() async throws {
        let actoolPath = try await self.actoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await assetCatalogThinningTestProject(tmpDir: tmpDir, thinningBuildSettings: [:
                                                                                                               ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            await tester.checkBuild(runDestination: .iOS) { results in
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLine([actoolPath.str,
                                               "\(SRCROOT)/Assets.xcassets",
                                               "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/\(variant)",
                                               "--output-format", "human-readable-text",
                                               "--notices", "--warnings",
                                               "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_\(variant)",
                                               "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_\(variant)",
                                               "--compress-pngs",
                                               "--enable-on-demand-resources", "NO",
                                               "--development-region", "English",
                                               "--target-device", "iphone",
                                               "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                               "--platform", "iphoneos",
                                               ])
                    }
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func generateAssetSymbols() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await assetCatalogThinningTestProject(tmpDir: tmpDir, thinningBuildSettings: [
                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try await tester.checkBuild(runDestination: .iOS) { results in
                for variant in ["thinned", "unthinned"] {
                    let actoolCommandLine = try await [actoolPath.str,
                                                       "\(SRCROOT)/Assets.xcassets",
                                                       "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/\(variant)",
                                                       "--output-format", "human-readable-text",
                                                       "--notices", "--warnings",
                                                       "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_\(variant)",
                                                       "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_\(variant)",
                                                       "--compress-pngs",
                                                       "--enable-on-demand-resources", "NO",
                                                       "--development-region", "English",
                                                       "--target-device", "iphone",
                                                       "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                                       "--platform", "iphoneos",
                    ]

                    results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLine(actoolCommandLine)
                    }
                }

                let actoolCommandLine = try await [actoolPath.str,
                                                   "\(SRCROOT)/Assets.xcassets",
                                                   "--compile", "\(SRCROOT)/build/Debug-iphoneos/App.framework",
                                                   "--output-format", "human-readable-text",
                                                   "--notices", "--warnings",
                                                   "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies",
                                                   "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist",
                                                   "--compress-pngs",
                                                   "--enable-on-demand-resources", "NO",
                                                   "--development-region", "English",
                                                   "--target-device", "iphone",
                                                   "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                                   "--platform", "iphoneos",
                                                   ]

                let symbolsArgs = ["--bundle-identifier", "com.apple.project",
                                   "--generate-swift-asset-symbol-extensions", "NO",
                                   "--generate-swift-asset-symbols",
                                   "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift",
                                   "--generate-objc-asset-symbols",
                                   "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.h"]

                results.checkTask(.matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkCommandLineContainsUninterrupted(actoolCommandLine + symbolsArgs)

                    // The following arguments should only be passed when explicitly opting out (see testGenerateAssetSymbolsOptions):
                    task.checkCommandLineDoesNotContain("--generate-asset-symbol-framework-support")
                    task.checkCommandLineDoesNotContain("--generate-asset-symbol-warnings")
                    task.checkCommandLineDoesNotContain("--generate-asset-symbol-errors")
                    task.checkCommandLineDoesNotContain("--generate-asset-symbol-backwards-deployment-support")
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func generateAssetSymbolsOptions() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await assetCatalogThinningTestProject(tmpDir: tmpDir, thinningBuildSettings: [
                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
                "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "NO",
                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_FRAMEWORKS": "UIKit AppKit",
                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_BACKWARDS_DEPLOYMENT_SUPPORT": "YES",
                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_WARNINGS": "NO",
                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_ERRORS": "NO",
            ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try await tester.checkBuild(runDestination: .iOS) { results in
                for variant in ["thinned", "unthinned"] {
                    let actoolCommandLine = try await [actoolPath.str,
                                                       "\(SRCROOT)/Assets.xcassets",
                                                       "--compile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_output/\(variant)",
                                                       "--output-format", "human-readable-text",
                                                       "--notices", "--warnings",
                                                       "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies_\(variant)",
                                                       "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist_\(variant)",
                                                       "--compress-pngs",
                                                       "--enable-on-demand-resources", "NO",
                                                       "--development-region", "English",
                                                       "--target-device", "iphone",
                                                       "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                                       "--platform", "iphoneos",
                    ]

                    results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLine(actoolCommandLine)
                    }
                }

                let actoolCommandLine = try await [actoolPath.str,
                                                   "\(SRCROOT)/Assets.xcassets",
                                                   "--compile", "\(SRCROOT)/build/Debug-iphoneos/App.framework",
                                                   "--output-format", "human-readable-text",
                                                   "--notices", "--warnings",
                                                   "--export-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_dependencies",
                                                   "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/assetcatalog_generated_info.plist",
                                                   "--compress-pngs",
                                                   "--enable-on-demand-resources", "NO",
                                                   "--development-region", "English",
                                                   "--target-device", "iphone",
                                                   "--minimum-deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                                   "--platform", "iphoneos",
                                                   ]

                let symbolsArgs = ["--bundle-identifier", "com.apple.project",
                                   "--generate-asset-symbol-warnings", "NO",
                                   "--generate-asset-symbol-errors", "NO",
                                   "--generate-swift-asset-symbol-extensions", "NO",
                                   "--generate-asset-symbol-framework-support", "UIKit",
                                   "--generate-asset-symbol-framework-support", "AppKit",
                                   "--generate-asset-symbol-backwards-deployment-support", "YES",
                                   "--generate-swift-asset-symbols",
                                   "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift",
                                   "--generate-objc-asset-symbols",
                                   "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.h"]

                results.checkTask(.matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkCommandLineContainsUninterrupted(actoolCommandLine + symbolsArgs)
                }

                results.checkNoDiagnostics()
            }
        }
    }
}
