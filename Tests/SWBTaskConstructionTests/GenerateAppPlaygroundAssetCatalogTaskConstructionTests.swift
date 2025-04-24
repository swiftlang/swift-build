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

import SWBTaskConstruction
import SWBProtocol

@Suite
fileprivate struct GenerateAppPlaygroundAssetCatalogTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func assetCatalogGenerationNotEnabled() async throws {
        let testProject = try await TestProject(
            "AssetCatalogGenerationNotEnabled",
            groupTree: TestGroup(
                "Sources", children: [
                    TestFile("Source.swift")
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                ])
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.swift"]),
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkNoTask(.matchTargetName("Foo"), .matchRuleType("GenerateAppPlaygroundAssetCatalog"))
            results.checkNoTask(.matchTargetName("Foo"), .matchRuleType("CompileAssetCatalog"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func assetCatalogGenerationDisabled() async throws {
        let testProject = try await TestProject(
            "AssetCatalogGenerationDisabled",
            groupTree: TestGroup(
                "Sources", children: [
                    TestFile("Source.swift")
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "APP_PLAYGROUND_GENERATE_ASSET_CATALOG": "NO",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                ])
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.swift"]),
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkNoTask(.matchTargetName("Foo"), .matchRuleType("GenerateAppPlaygroundAssetCatalog"))
            results.checkNoTask(.matchTargetName("Foo"), .matchRuleType("CompileAssetCatalog"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func assetCatalogGenerationEnabled() async throws {
        let testProject = try await TestProject(
            "AssetCatalogGenerationEnabled",
            groupTree: TestGroup(
                "Sources", children: [
                    TestFile("Source.swift"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ASSETCATALOG_EXEC": actoolPath.str,
                    "APP_PLAYGROUND_GENERATE_ASSET_CATALOG": "YES",
                    "APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PLACEHOLDER_APPICON": "magicWand",
                    "APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PRESET_ACCENT_COLOR": "orange",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "__PlaceholderAppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "__PresetAccentColor",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                ])
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.swift"]),
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchTargetName("Foo"), .matchRuleType("GenerateAppPlaygroundAssetCatalog")) { task in
                task.checkNoInputs(contain: [.pathPattern(.suffix(".xcassets"))])
                task.checkOutputs(contain: [.pathPattern(.suffix("AppPlaygroundDefaultAssetCatalog.xcassets"))])
                task.checkCommandLineContainsUninterrupted(["-generatePlaceholderAppIconAsset", "-placeholderAppIconEnumName", "magicWand"])
                task.checkCommandLineContainsUninterrupted(["-appIconAssetName", "__PlaceholderAppIcon"])
                task.checkCommandLineContainsUninterrupted(["-generateAccentColorAsset", "-accentColorPresetName", "orange"])
                task.checkCommandLineContainsUninterrupted(["-accentColorAssetName", "__PresetAccentColor"])
            }
            for variant in ["thinned", "unthinned"] {
                results.checkTask(.matchTargetName("Foo"), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                    task.checkInputs(contain: [.pathPattern(.suffix("AppPlaygroundDefaultAssetCatalog.xcassets"))])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func assetCatalogGenerationWithOtherAssetCatalog() async throws {
        let testProject = try await TestProject(
            "AssetCatalogGenerationWithOtherAssetCatalog",
            groupTree: TestGroup(
                "Sources", children: [
                    TestFile("Source.swift"),
                    TestFile("Assets.xcassets"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ASSETCATALOG_EXEC": actoolPath.str,
                    "APP_PLAYGROUND_GENERATE_ASSET_CATALOG": "YES",
                    "APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PLACEHOLDER_APPICON": "magicWand",
                    "APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PRESET_ACCENT_COLOR": "orange",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "__PlaceholderAppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "__PresetAccentColor",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                ])
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.swift"]),
                        TestResourcesBuildPhase(["Assets.xcassets"]),
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchTargetName("Foo"), .matchRuleType("GenerateAppPlaygroundAssetCatalog")) { task in
                task.checkInputs(contain: [.pathPattern(.suffix("Assets.xcassets"))])
                task.checkOutputs(contain: [.pathPattern(.suffix("AppPlaygroundDefaultAssetCatalog.xcassets"))])
                task.checkCommandLineContainsUninterrupted(["-generatePlaceholderAppIconAsset", "-placeholderAppIconEnumName", "magicWand"])
                task.checkCommandLineContainsUninterrupted(["-appIconAssetName", "__PlaceholderAppIcon"])
                task.checkCommandLineContainsUninterrupted(["-generateAccentColorAsset", "-accentColorPresetName", "orange"])
                task.checkCommandLineContainsUninterrupted(["-accentColorAssetName", "__PresetAccentColor"])
            }
            for variant in ["thinned", "unthinned"] {
                results.checkTask(.matchTargetName("Foo"), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                    task.checkInputs(contain: [.pathPattern(.suffix("Assets.xcassets")), .pathPattern(.suffix("AppPlaygroundDefaultAssetCatalog.xcassets"))])
                }
            }
        }
    }
}
