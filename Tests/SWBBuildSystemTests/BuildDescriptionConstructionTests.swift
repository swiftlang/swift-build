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

import class Foundation.ProcessInfo

import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil

import SWBTaskExecution

/// Test constructing build descriptions for projects, and checking for issues in them.
@Suite
fileprivate struct BuildDescriptionConstructionTests: CoreBasedTests {
    private func arenaInfo(from path: Path) -> ArenaInfo {
        return ArenaInfo.buildArena(derivedDataRoot: path)
    }

    /// An app which is embedding content inside it, which it needs to re-sign.
    @Test(.requireSDKs(.macOS, .iOS))
    func copyAndResign() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        // App target sources
                        TestFile("main.m"),
                        // Framework target sources
                        TestFile("ClassOne.swift"),
                        // Plugin target sources
                        TestFile("ClassTwo.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "INFOPLIST_FILE": "Info.plist",
                            "SDKROOT": "macosx",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "CODE_SIGN_IDENTITY": "-",
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.m"]),
                            TestCopyFilesBuildPhase([
                                TestBuildFile("FwkTarget.framework", codeSignOnCopy: true),
                            ], destinationSubfolder: .frameworks),
                            TestCopyFilesBuildPhase([
                                TestBuildFile("PluginTarget.bundle", codeSignOnCopy: true),
                            ], destinationSubfolder: .plugins),
                        ],
                        dependencies: ["FwkTarget", "PluginTarget"]
                    ),
                    TestStandardTarget(
                        "FwkTarget",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["ClassOne.swift"]),
                        ]
                    ),
                    TestStandardTarget(
                        "PluginTarget",
                        type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["ClassTwo.swift"]),
                        ]
                    )
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: true)

            // Signing info for building for iOS.
            let appIdentifierPrefix = "F154D0C"
            let teamIdentifierPrefix = appIdentifierPrefix
            let appIdentifier = "\(appIdentifierPrefix).com.apple.dt.AppTarget"
            let appSignedEntitlements: PropertyListItem = [
                "application-identifier": appIdentifier,
                "com.apple.developer.team-identifier": teamIdentifierPrefix,
                "get-task-allow": 1,
                "keychain-access-groups": [
                    appIdentifier
                ],
            ]
            let provisioningInputs = [
                "FwkTarget": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing"),
                "PluginTarget": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing"),
                "AppTarget": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing", signedEntitlements: appSignedEntitlements, simulatedEntitlements: [:]),
            ]

            // Check the build description for macOS.
            try await tester.checkBuildDescription(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, signableTargets: Set(provisioningInputs.keys)) { results in
                // Check that there are no warnings or errors.  In the past we've seen warnings here because not all of the inputs to the re-signing task were being generated by the copy task.
                results.checkNoDiagnostics()
            }

            // Check the build description for iOS, which uses shallow bundles.
            try await tester.checkBuildDescription(BuildParameters(action: .install, configuration: "Debug", overrides: ["SDKROOT": "iphoneos"]), runDestination: .macOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                // Check that there are no warnings or errors.  In the past we've seen warnings here because not all of the inputs to the re-signing task were being generated by the copy task.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func copiedPathMap() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("Fwk.h"),
                        TestFile("Fwk.m"),
                        TestFile("ClassOne.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "FwkTarget",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["ClassOne.swift"]),
                            TestHeadersBuildPhase([TestBuildFile("Fwk.h", headerVisibility: .public)])
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: true)

            try await tester.checkBuildDescription(runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                #expect(results.buildDescription.copiedPathMap == [
                    "\(tmpDir.str)/build/Debug/FwkTarget.framework/Versions/A/Headers/Fwk.h": "\(tmpDir.str)/Fwk.h"
                ])
            }
        }
    }

    @Test(.requireSDKs(.host))
    func copiedPathMapDuplicates() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("Fwk.h"),
                        TestFile("Subdir/Fwk.h"),
                        TestFile("Fwk.m"),
                        TestFile("ClassOne.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGNING_ALLOWED": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "PUBLIC_HEADERS_FOLDER_PATH": "foo/bar",
                        ]
                    )],
                targets: [
                    TestAggregateTarget(
                        "All",
                        dependencies: ["lib1", "lib2"]
                    ),
                    TestStandardTarget(
                        "lib1",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("Fwk.h", headerVisibility: .public),
                                TestBuildFile("Subdir/Fwk.h", headerVisibility: .public),
                            ])
                        ]
                    ),
                    TestStandardTarget(
                        "lib2",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("Fwk.h", headerVisibility: .public),
                                TestBuildFile("Subdir/Fwk.h", headerVisibility: .public),
                            ])
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: true)

            try await tester.checkBuildDescription(runDestination: .host) { results in
                let buildProductsDirSuffix = RunDestinationInfo.host.builtProductsDirSuffix
                results.checkWarning(.equal("duplicate output file '\(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar/Fwk.h", normalize: true).str)' on task: CpHeader \(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar/Fwk.h", normalize: true).str) \(tmpDir.join("Subdir/Fwk.h", normalize: true).str) (in target 'lib1' from project 'aProject')"))
                results.checkWarning(.equal("duplicate output file '\(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar/Fwk.h", normalize: true).str)' on task: CpHeader \(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar/Fwk.h", normalize: true).str) \(tmpDir.join("Fwk.h", normalize: true).str) (in target 'lib2' from project 'aProject')"))
                results.checkWarning(.equal("duplicate output file '\(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar/Fwk.h", normalize: true).str)' on task: CpHeader \(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar/Fwk.h", normalize: true).str) \(tmpDir.join("Subdir/Fwk.h", normalize: true).str) (in target 'lib2' from project 'aProject')"))
                results.checkWarning(.equal("duplicate output file '\(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar", normalize: true).str)' on task: MkDir \(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar", normalize: true).str) (in target 'lib2' from project 'aProject')"))
                results.checkWarning(.equal("duplicate output file '' on task: MkDir \(tmpDir.join("build/Debug\(buildProductsDirSuffix)/foo/bar", normalize: true).str) (in target 'lib2' from project 'aProject')"))
                results.checkNoDiagnostics()

                // Nothing in the map because there are multiple sources for the same destination path.
                // The build will have already failed because of this, though.
                #expect(results.buildDescription.copiedPathMap == [:])
            }
        }
    }

    // Check that the copied path map is populated with the header when in debug and unifdef is being used (without
    // -B having been specified)
    @Test(.requireSDKs(.macOS))
    func unifdefCopiedPathMap() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("Test.h"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "COPY_HEADERS_RUN_UNIFDEF": "YES",
                            "GCC_OPTIMIZATION_LEVEL": "0",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "Empty",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("Test.h", headerVisibility: .public)])
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: true)

            try await tester.checkBuildDescription(runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                #expect(results.buildDescription.copiedPathMap == [
                    "\(tmpDir.str)/build/Debug/Empty.framework/Versions/A/Headers/Test.h": "\(tmpDir.str)/Test.h"
                ])
            }

            try await tester.checkBuildDescription(BuildParameters(action: .build, configuration: "Debug", overrides: ["COPY_HEADERS_UNIFDEF_FLAGS": "-B"]), runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                #expect(results.buildDescription.copiedPathMap == [:])
            }

            try await tester.checkBuildDescription(BuildParameters(action: .build, configuration: "Debug", overrides: ["GCC_OPTIMIZATION_LEVEL": "1"]), runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                #expect(results.buildDescription.copiedPathMap == [:])
            }
        }
    }

    func targetsForPackageProduct(libraryName: String, offerDynamicVariant: Bool = false, packageTarget: String? = nil, hasResourceBundle: Bool = false) -> [any TestTarget] {
        let packageTargetName = packageTarget ?? libraryName
        let resourceBundleName = "\(packageTargetName)_Resources"
        let dependencyOnResourceBundle = hasResourceBundle ? [TestTargetDependency(resourceBundleName)] : []
        return [
            TestPackageProductTarget(
                "\(libraryName)Product",
                frameworksBuildPhase: TestFrameworksBuildPhase([
                    TestBuildFile(.target("\(packageTargetName)"))]),
                dynamicTargetVariantName: offerDynamicVariant ? "\(libraryName)Product-dynamic" : "",
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
                ],
                dependencies: ["\(packageTargetName)"] + (hasResourceBundle ? [resourceBundleName] : [])
            ),
            TestStandardTarget(
                "\(libraryName)Product-dynamic",
                type: .framework,
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
                ],
                buildPhases: [TestFrameworksBuildPhase([TestBuildFile(.target("\(packageTargetName)"))])],
                dependencies: [TestTargetDependency("\(packageTargetName)")] + dependencyOnResourceBundle
            ),
        ] + ((packageTarget != nil) ? [] : [
            TestStandardTarget("\(packageTargetName)",
                               type: .objectFile,
                               buildConfigurations: [
                                // Targets need to opt-in to specialization.
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "SDKROOT": "auto",
                                    "SDK_VARIANT": "auto",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ]),
                               ],
                               dependencies: dependencyOnResourceBundle,
                               dynamicTargetVariantName: "\(packageTargetName)-dynamic"),
            TestStandardTarget("\(packageTargetName)-dynamic",
                               type: .framework,
                               buildConfigurations: [
                                // Targets need to opt-in to specialization.
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "SDKROOT": "auto",
                                    "SDK_VARIANT": "auto",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ]),
                               ], dependencies: dependencyOnResourceBundle),
        ]) + (hasResourceBundle ? [
            TestStandardTarget(resourceBundleName, type: .bundle),
        ] : [])
    }

    func withTesterForPackageDiamondProblemDiagnostic(topLevelTargetName: String = "App", topLevelTargetType: TestStandardTarget.TargetType = .application, disableDiagnostic: Bool = false, hasDiamondProblem: Bool = true, hasCopyResources: Bool = false, hasResourceBundle: Bool = false, offerDynamicVariant: Bool = false, requiresMultiPass: Bool = false, body: (BuildOperationTester, Path) async throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDir in
            let frameworksBuildPhase = TestFrameworksBuildPhase([
                TestBuildFile(.auto("A.framework")),
                TestBuildFile(.target("PackageLibProduct")),
                TestBuildFile(.auto("C.framework")),
            ])

            let workspace = TestWorkspace("Workspace",
                                          sourceRoot: tmpDir,
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles"),
                                                                 buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                        "ALWAYS_SEARCH_USER_PATHS": "NO"
                                                                    ])
                                                                 ],
                                                                 targets: [
                                                                    TestStandardTarget(
                                                                        topLevelTargetName,
                                                                        type: topLevelTargetType,
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: ["DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC": disableDiagnostic ? "YES" : "NO", "SDKROOT": "iphoneos"]),
                                                                        ],
                                                                        buildPhases: hasCopyResources ? [ frameworksBuildPhase, TestCopyFilesBuildPhase([ TestBuildFile(.target("PackageLib")) ], destinationSubfolder: .frameworks) ] : [ frameworksBuildPhase ],
                                                                        dependencies: hasDiamondProblem ? ["iOSFwk", "iOSFwk-3", "PackageLibProduct"] : ["iOSFwk", "iOSFwk-3"]
                                                                    ),
                                                                    TestStandardTarget(
                                                                        "iOSFwk",
                                                                        type: .framework,
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "A", "SDKROOT": "iphoneos"]),
                                                                        ],
                                                                        buildPhases: [
                                                                            TestFrameworksBuildPhase([
                                                                                TestBuildFile(.target("PackageLibProduct")),
                                                                            ]),
                                                                        ],
                                                                        dependencies: ["PackageLibProduct"]
                                                                    ),
                                                                    TestStandardTarget(
                                                                        "iOSFwk-2",
                                                                        type: .framework,
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "B", "SDKROOT": "iphoneos"]),
                                                                        ],
                                                                        buildPhases: [
                                                                            TestFrameworksBuildPhase([
                                                                                TestBuildFile(.target("PackageLibProduct")),
                                                                            ]),
                                                                        ],
                                                                        dependencies: ["PackageLibProduct"]
                                                                    ),
                                                                    TestStandardTarget(
                                                                        "iOSFwk-3",
                                                                        type: .framework,
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: ["DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC": disableDiagnostic ? "YES" : "NO", "PRODUCT_NAME": "C", "SDKROOT": "iphoneos"]),
                                                                        ],
                                                                        buildPhases: [ TestFrameworksBuildPhase([
                                                                            TestBuildFile(.auto("D.framework")),
                                                                            TestBuildFile(.auto("E.framework")),
                                                                            TestBuildFile(.target("PackageLib2Product")),
                                                                        ]) ],
                                                                        dependencies: hasDiamondProblem ? ["iOSFwk-4", "iOSFwk-5", "PackageLib2Product"] : []
                                                                    ),
                                                                    TestStandardTarget(
                                                                        "iOSFwk-4",
                                                                        type: .framework,
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: ["DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC": disableDiagnostic ? "YES" : "NO", "PRODUCT_NAME": "D", "SDKROOT": "iphoneos"]),
                                                                        ],
                                                                        buildPhases: [
                                                                            TestFrameworksBuildPhase([
                                                                                TestBuildFile(.target("PackageLibProduct")),
                                                                            ]),
                                                                        ],
                                                                        dependencies: ["PackageLibProduct"]
                                                                    ),
                                                                    TestStandardTarget(
                                                                        "iOSFwk-5",
                                                                        type: .framework,
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: ["DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC": disableDiagnostic ? "YES" : "NO", "PRODUCT_NAME": "E", "SDKROOT": "iphoneos"]),
                                                                        ],
                                                                        buildPhases: [
                                                                            TestFrameworksBuildPhase([
                                                                                TestBuildFile(.target("PackageLibProduct")),
                                                                            ]),
                                                                        ],
                                                                        dependencies: ["PackageLibProduct"]
                                                                    ),
                                                                 ]
                                                                ),
                                                     TestPackageProject("aPackage", groupTree: TestGroup("SomeFiles"),
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: [
                                                                                "ALWAYS_SEARCH_USER_PATHS": "NO"
                                                                            ])
                                                                        ],
                                                                        targets: targetsForPackageProduct(libraryName: "PackageLib", offerDynamicVariant: offerDynamicVariant, hasResourceBundle: hasResourceBundle) + (requiresMultiPass ? targetsForPackageProduct(libraryName: "PackageLib2", offerDynamicVariant: offerDynamicVariant, packageTarget: "PackageLib", hasResourceBundle: hasResourceBundle) : [])),
                                          ]
            )
            try await body(BuildOperationTester(getCore(), workspace, simulated: true), tmpDir)
        }
    }

    func withTesterForPackageDiamondProblemDiagnosticWithTargets(offerDynamicVariant: Bool = false, conflictsWithPackageProduct: Bool = false, body: (BuildOperationTester, Path) async throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDir in
            let workspace = TestWorkspace(
                "Workspace",
                sourceRoot: tmpDir,
                projects: [
                    TestPackageProject(
                        "aProject",
                        groupTree: TestGroup("SomeFiles"),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)"
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "PackageLibProduct",
                                type: .framework,
                                buildConfigurations: [
                                    // Targets need to opt-in to specialization.
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SDKROOT": "auto",
                                        "SDK_VARIANT": "auto",
                                        "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                                    ]),
                                ],
                                buildPhases: [ TestFrameworksBuildPhase([
                                    TestBuildFile(.target("PackageLib")), TestBuildFile(.target("Utility")), TestBuildFile(.target("PackageLibProduct2")), TestBuildFile(.target("Mock"))]) ],
                                dependencies: ["PackageLib", "Utility", "PackageLibProduct2", "Mock"]
                            ),
                            TestStandardTarget("PackageLib", type: .objectFile),
                            TestStandardTarget(
                                "PackageLibProduct2",
                                type: .framework,
                                buildConfigurations: [
                                    // Targets need to opt-in to specialization.
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "SDKROOT": "auto",
                                        "SDK_VARIANT": "auto",
                                        "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                                    ]),
                                ],
                                buildPhases: [ TestFrameworksBuildPhase([
                                    TestBuildFile(.target("PackageLib2")), TestBuildFile(.target("Utility"))]) ],
                                dependencies: ["PackageLib2", "Utility"]
                            ),
                            TestStandardTarget("PackageLib2", type: .objectFile),
                            TestStandardTarget("Utility", type: .objectFile, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME": (conflictsWithPackageProduct ? "YES" : "NO")])], dynamicTargetVariantName: offerDynamicVariant ? "Utility-dynamic" : ""),
                            TestStandardTarget("Utility-dynamic", type: .framework),
                            TestPackageProductTarget("Mock", frameworksBuildPhase: TestFrameworksBuildPhase()),
                        ]
                    )]
            )

            try await body(BuildOperationTester(getCore(), workspace, simulated: true), tmpDir)
        }
    }

    // Check that we are not generating false positives with the diamond problem diagnostics.
    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticNoFalsePositives() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(hasDiamondProblem: false) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticDoesNotConsiderCopyResources() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(hasDiamondProblem: false, hasCopyResources: true) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageDiamondProblemDiagnosticConsidersPackageTargets() async throws {
        try await withTesterForPackageDiamondProblemDiagnosticWithTargets { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .macOS) { results in
                results.checkError(.equal("Swift package target 'Utility' is linked as a static library by 'PackageLibProduct' and 'PackageLibProduct2'. This will result in duplication of library code."))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageDiamondProblemDiagnosticConsidersConflictingPackageProducts() async throws {
        try await withTesterForPackageDiamondProblemDiagnosticWithTargets(conflictsWithPackageProduct: true) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .macOS) { results in
                results.checkError(.equal("Swift package target 'Utility' is linked as a static library by 'PackageLibProduct' and 'PackageLibProduct2', but cannot be built dynamically because there is a package product with the same name."))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageDiamondProblemDiagnosticConsidersPackageTargetsAndUsesDynamicVariantIfAvailable() async throws {
        try await withTesterForPackageDiamondProblemDiagnosticWithTargets(offerDynamicVariant: true) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .macOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS), .userDefaults(["EnableDiagnosingDiamondProblemsWhenUsingPackages": "0"]))
    func packageDiamondProblemDiagnosticUserDefault() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnostic() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkError(.equal("Swift package product 'PackageLibProduct' is linked as a static library by 'App' and 'iOSFwk'. This will result in duplication of library code."))
                results.checkError(.equal("Swift package product 'PackageLibProduct' is linked as a static library by 'iOSFwk-3' and 'iOSFwk-4'. This will result in duplication of library code."))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticRequiresMultiPass() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(offerDynamicVariant: true, requiresMultiPass: true) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkNoDiagnostics()

                // Check that we end up with a single, dynamic package target. During the first pass, we will make one of the package products dynamic, but subsequently discover a new diamond which involves the package target. Once we make that dynamic, we will eliminate the now redundant dynamic package product.
                let packageTargets = results.buildDescription.allConfiguredTargets.filter {
                    tester.workspaceContext.workspace.project(for: $0.target).isPackage
                }
                #expect(packageTargets.map { $0.target.name } == ["PackageLib-dynamic"])
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticRequiresMultiPassWithResources() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(hasResourceBundle: true, offerDynamicVariant: true, requiresMultiPass: true) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkNoErrors()

                // Check that we end up with a single, dynamic package target and the resource bundle target. During the first pass, we will make one of the package products dynamic, but subsequently discover a new diamond which involves the package target. Once we make that dynamic, we will eliminate the now redundant dynamic package product.
                let packageTargets = results.buildDescription.allConfiguredTargets.filter {
                    tester.workspaceContext.workspace.project(for: $0.target).isPackage
                }
                #expect(packageTargets.map { $0.target.name }.sorted() == ["PackageLib_Resources", "PackageLib-dynamic"].sorted())
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticUsesDynamicVariantIfAvailable() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(offerDynamicVariant: true) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func packageDiamondProblemDoesNotCrashDuringBuild() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(offerDynamicVariant: true, requiresMultiPass: true) { tester, tmpDir in
            let regularTarget = tester.workspace.projects[0].targets[0]
            let packageTarget = tester.workspace.projects[1].targets[0]

            // This explicitly uses macOS here in conjunction with the `testerForPackageDiamondProblemDiagnostic` project containing an iOS framework to require two configured targets for the same package target.
            let parameters = BuildParameters(action: .build, configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build")))
            let request = BuildRequest(parameters: parameters, buildTargets: [regularTarget, packageTarget].map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuildDescription(parameters, runDestination: .macOS, buildRequest: request) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func packageDiamondProblemDoesNotCrashDuringIndexBuild() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(offerDynamicVariant: true, requiresMultiPass: true) { tester, tmpDir in
            let regularTarget = tester.workspace.projects[0].targets[0]
            let packageTarget = tester.workspace.projects[1].targets[0]

            let parameters = BuildParameters(action: .indexBuild, configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build")))
            let command = BuildCommand.prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true)
            let request = BuildRequest(parameters: parameters, buildTargets: [regularTarget, packageTarget].map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: command)

            try await tester.checkBuildDescription(parameters, runDestination: .macOS, buildRequest: request) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticForDylibs() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(topLevelTargetName: "Lib", topLevelTargetType: .dynamicLibrary) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkError(.equal("Swift package product 'PackageLibProduct' is linked as a static library by 'Lib' and 'iOSFwk'. This will result in duplication of library code."))
                results.checkError(.equal("Swift package product 'PackageLibProduct' is linked as a static library by 'iOSFwk-3' and 'iOSFwk-4'. This will result in duplication of library code."))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticOptOut() async throws {
        try await withTesterForPackageDiamondProblemDiagnostic(disableDiagnostic: true) { tester, tmpDir in
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .iOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func packageDiamondProblemDiagnosticTransitive() async throws {
        try await withTemporaryDirectory { tmpDir in
            let workspace = TestWorkspace("Workspace",
                                          sourceRoot: tmpDir,
                                          projects: [
                                            TestPackageProject("aPackage", groupTree: TestGroup("SomeFiles", children: [TestFile("test.c")]), targets: [
                                                TestPackageProductTarget(
                                                    "PackageLibProduct",
                                                    frameworksBuildPhase: TestFrameworksBuildPhase([
                                                        TestBuildFile(.target("PackageLib"))]),
                                                    buildConfigurations: [
                                                        // Targets need to opt-in to specialization.
                                                        TestBuildConfiguration("Debug", buildSettings: [
                                                            "SDKROOT": "auto",
                                                            "SDK_VARIANT": "auto",
                                                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                                                        ]),
                                                    ],
                                                    dependencies: ["PackageLib", "SecondPackageLibProduct"]
                                                ),
                                                TestStandardTarget(
                                                    "PackageLib", type: .objectFile,
                                                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "PackageLib",])],
                                                    buildPhases: [TestFrameworksBuildPhase([
                                                        TestBuildFile(.target("SecondPackageLibProduct"))]),
                                                                  TestSourcesBuildPhase([TestBuildFile("test.c")])],
                                                    dependencies: ["SecondPackageLibProduct"]
                                                ),
                                                TestPackageProductTarget(
                                                    "SecondPackageLibProduct",
                                                    frameworksBuildPhase: TestFrameworksBuildPhase([
                                                        TestBuildFile(.target("SecondPackageLib"))]),
                                                    buildConfigurations: [
                                                        // Targets need to opt-in to specialization.
                                                        TestBuildConfiguration("Debug", buildSettings: [
                                                            "SDKROOT": "auto",
                                                            "SDK_VARIANT": "auto",
                                                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                                                        ]),
                                                    ],
                                                    dependencies: ["SecondPackageLib"]
                                                ),
                                                TestStandardTarget("SecondPackageLib", type: .objectFile,
                                                                   buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "SecondPackageLib",])], buildPhases: [TestSourcesBuildPhase([TestBuildFile("test.c")])]),
                                            ]
                                                              ),
                                            TestProject("aProject",
                                                        groupTree: TestGroup("SomeFiles"),
                                                        targets: [
                                                            TestStandardTarget(
                                                                "App",
                                                                type: .application,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                        TestBuildFile(.auto("A.framework")),
                                                                        TestBuildFile(.target("SecondPackageLibProduct")),
                                                                    ]),
                                                                ],
                                                                dependencies: ["iOSFwk", "SecondPackageLibProduct"]
                                                            ),
                                                            TestStandardTarget(
                                                                "iOSFwk",
                                                                type: .framework,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "A", "SDKROOT": "iphoneos"]),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                        TestBuildFile(.target("PackageLibProduct")),
                                                                    ]),
                                                                ],
                                                                dependencies: ["PackageLibProduct"]
                                                            )])]
            )

            let tester = try await BuildOperationTester(getCore(), workspace, simulated: true)
            let parameters = BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build")))
            let target = try #require(tester.workspace.allTargets.filter({ $0.name == "App" }).first, "could not find app target")
            try await tester.checkBuildDescription(runDestination: .iOS, buildRequest: BuildRequest(parameters: parameters, buildTargets: [ BuildRequest.BuildTargetInfo(parameters: parameters, target: target) ], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)) { results in
                results.checkError(.equal("Swift package product 'SecondPackageLibProduct' is linked as a static library by 'App' and 'iOSFwk'. This will result in duplication of library code."))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageDiamondProblemDiagnosticDoesNotFlagExecutables() async throws {
        try await withTemporaryDirectory { tmpDir in
            let workspace = TestWorkspace("Workspace",
                                          sourceRoot: tmpDir,
                                          projects: [
                                            TestPackageProject("aPackage", groupTree: TestGroup("SomeFiles", children: [TestFile("test.c")]),
                                                               buildConfigurations: [
                                                                TestBuildConfiguration("Debug", buildSettings: [
                                                                    "CODE_SIGNING_ALLOWED": "NO"
                                                                ])
                                                               ],
                                                               targets: [
                                                                TestStandardTarget(
                                                                    "PackageExecutable", type: .commandLineTool,
                                                                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "PackageExecutable",])],
                                                                    buildPhases: [
                                                                        TestSourcesBuildPhase([TestBuildFile("test.c")])],
                                                                    dependencies: ["SecondPackageLibProduct"]
                                                                ),
                                                                TestPackageProductTarget(
                                                                    "PackageLibProduct",
                                                                    frameworksBuildPhase: TestFrameworksBuildPhase([
                                                                        TestBuildFile(.target("PackageLib"))]),
                                                                    buildConfigurations: [
                                                                        // Targets need to opt-in to specialization.
                                                                        TestBuildConfiguration("Debug", buildSettings: [
                                                                            "SDKROOT": "auto",
                                                                            "SDK_VARIANT": "auto",
                                                                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                                                                        ]),
                                                                    ],
                                                                    dependencies: ["PackageLib", "SecondPackageLibProduct"]
                                                                ),
                                                                TestStandardTarget(
                                                                    "PackageLib", type: .dynamicLibrary,
                                                                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "PackageLib",])],
                                                                    buildPhases: [TestFrameworksBuildPhase([
                                                                        TestBuildFile(.target("SecondPackageLibProduct"))]),
                                                                                  TestSourcesBuildPhase([TestBuildFile("test.c")])],
                                                                    dependencies: ["SecondPackageLibProduct", "PackageExecutable"]
                                                                ),
                                                                TestPackageProductTarget(
                                                                    "SecondPackageLibProduct",
                                                                    frameworksBuildPhase: TestFrameworksBuildPhase([
                                                                        TestBuildFile(.target("SecondPackageLib"))]),
                                                                    buildConfigurations: [
                                                                        // Targets need to opt-in to specialization.
                                                                        TestBuildConfiguration("Debug", buildSettings: [
                                                                            "SDKROOT": "auto",
                                                                            "SDK_VARIANT": "auto",
                                                                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                                                                        ]),
                                                                    ],
                                                                    dependencies: ["SecondPackageLib"]
                                                                ),
                                                                TestStandardTarget("SecondPackageLib", type: .objectFile,
                                                                                   buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "SecondPackageLib",])], buildPhases: [TestSourcesBuildPhase([TestBuildFile("test.c")])]),
                                                               ]
                                                              )]
            )

            let tester = try await BuildOperationTester(getCore(), workspace, simulated: true)
            let parameters = BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build")))
            let target = try #require(tester.workspace.allTargets.filter({ $0.name == "PackageLibProduct" }).first, "could not find package product target")
            try await tester.checkBuildDescription(runDestination: .macOS, buildRequest: BuildRequest(parameters: parameters, buildTargets: [ BuildRequest.BuildTargetInfo(parameters: parameters, target: target) ], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageDiamondProblemDiagnosticWithBundleLoader() async throws {
        try await withTemporaryDirectory { tmpDir in
            let workspace = try await TestWorkspace("Workspace",
                                                    sourceRoot: tmpDir,
                                                    projects: [TestPackageProject( /* this isn't quite right, but I can't get the diagnostic in a normal target. fix with rdar://79639888 */
                                                        "aProject",
                                                        groupTree: TestGroup(
                                                            "SomeFiles",
                                                            children: [
                                                                TestFile("SwiftyJSON.swift"),
                                                                TestFile("SwiftyJSONTests.swift"),
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
                                                                "SwiftJSONTests", type: .unitTest,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                        // The extraneous path separators tests path normalization.
                                                                        "BUNDLE_LOADER[sdk=macosx*]": "$(BUILT_PRODUCTS_DIR)/SwiftyJSON.app/Contents/MacOS/.//SwiftyJSON",
                                                                        "BUNDLE_LOADER": "$(BUILT_PRODUCTS_DIR)///SwiftyJSON.app/SwiftyJSON",
                                                                    ])
                                                                ],
                                                                buildPhases: [
                                                                    TestSourcesBuildPhase(["SwiftyJSONTests.swift"]),
                                                                    TestFrameworksBuildPhase([
                                                                        TestBuildFile(.target("PackageLibProduct")),
                                                                    ]),
                                                                ],
                                                                dependencies: [
                                                                    "SwiftyJSON", "PackageLibProduct",
                                                                ]),

                                                            TestStandardTarget(
                                                                "SwiftyJSON", type: .application,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                        "MACH_O_TYPE": "mh_execute",
                                                                    ])
                                                                ],
                                                                buildPhases: [
                                                                    TestSourcesBuildPhase(["SwiftyJSON.swift"]),
                                                                    TestFrameworksBuildPhase([
                                                                        TestBuildFile(.target("PackageLibProduct")),
                                                                    ]),
                                                                ], dependencies: ["PackageLibProduct"]),
                                                            TestPackageProductTarget(
                                                                "PackageLibProduct",
                                                                frameworksBuildPhase: TestFrameworksBuildPhase([
                                                                    TestBuildFile(.target("PackageLib"))]),
                                                                buildConfigurations: [
                                                                    // Targets need to opt-in to specialization.
                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                        "SDKROOT": "auto",
                                                                        "SDK_VARIANT": "auto",
                                                                        "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                                                                    ]),
                                                                ],
                                                                dependencies: ["PackageLib"]
                                                            ),
                                                            TestStandardTarget("PackageLib", type: .objectFile),
                                                        ])
                                                    ])
            let tester = try await BuildOperationTester(getCore(), workspace, simulated: true)
            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDir.join("build"))), runDestination: .macOS) { results in
                results.checkError(.equal("Swift package product 'PackageLibProduct' is linked as a static library by 'SwiftJSONTests' and 'SwiftyJSON'. This will result in duplication of library code."))
                results.checkNoDiagnostics()
            }
        }
    }

    // Regression test for rdar://84790611
    @Test(.requireSDKs(.macOS))
    func buildDescriptionCacheDirectoryCreationWithEmptyArenaMultipleProjectsAndCustomSymroot() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: []),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SYMROOT": tmpDir.join("custom").str
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "FwkTarget",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                        ]
                    ),
                ])
            let testProject2 = TestProject(
                "bProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: []),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "FwkTarget2",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                        ]
                    ),
                ])
            let testWorkspace = TestWorkspace("workspace", sourceRoot: tmpDir, projects: [testProject, testProject2])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: true)

            let target = try #require(tester.workspace.targets(named: "FwkTarget").only)

            // Build description creation should succeed.
            try await tester.checkBuildDescription(runDestination: .macOS, buildRequest: BuildRequest(parameters: BuildParameters(action: .build, configuration: "Debug", arena: arenaInfo(from: Path(""))), buildTargets: [.init(parameters: BuildParameters(action: .build, configuration: "Debug"), target: target)], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func capturedBuildInfo() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("foo.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "aTarget",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["foo.c"]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: true)

            try await tester.checkBuildDescription(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
                #expect(results.buildDescription.capturedBuildInfo == nil)
                try tester.fs.remove(results.buildDescription.manifestPath)
            }

            let ctx = try await WorkspaceContext(core: getCore(), workspace: tester.workspace, fs: tester.fs, processExecutionCache: .sharedForTesting)
            ctx.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid: 12345, home: Path("/Users/exampleUser"),
                                    environment: [
                                        "PATH" : "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                        "CAPTURED_BUILD_INFO_DIR" : tmpDir.join("captured-build-info").str
                                    ].addingContents(of: ProcessInfo.processInfo.environment.filter(keys: [
                                        "__XCODE_BUILT_PRODUCTS_DIR_PATHS", "XCODE_DEVELOPER_DIR_PATH"
                                    ]))))
            ctx.updateSystemInfo(tester.systemInfo)
            ctx.updateUserPreferences(tester.userPreferences)
            try await tester.checkBuildDescription(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, workspaceContext: ctx) { results in
                #expect(results.buildDescription.capturedBuildInfo != nil)
            }
        }
    }
}
