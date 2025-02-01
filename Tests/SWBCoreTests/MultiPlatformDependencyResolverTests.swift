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

import Foundation

import Testing

public import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

// This is to workaround an issue on CI with duplicate definitions of the `deps()` helper.
protocol DependencyFilter {
    var value: String { get }
    var isWatchKitAppContainer: Bool { get }
}

extension DependencyFilter {
    var isWatchKitAppContainer: Bool {
        // rdar://73955181 - the watchos container targets "iphoneos", but the implicit dep is for "watchos", so it gets ignored.
        self.value == "Watchable WatchKit App"
    }
}

extension String: DependencyFilter {
    var value: String { return self }
}

extension TestTargetDependency: DependencyFilter {
    var value: String { return self.name }
}


extension SWBCore.Workspace {
    /// Finds the target with the given name.
    /// - Precondition: There are no duplicate targets with the given name.
    public func target(named: String) -> SWBCore.Target? {
        let candidates = self.targets(named: named)
        precondition(candidates.count <= 1)
        return candidates.first
    }
}

/*
 Provides a set of tests to very the behavior for multi-platform targets. These tests make use of the new mechanism for platform specialization: ALLOW_TARGET_PLATFORM_SPECIALIZATION=YES.
 */
@Suite fileprivate struct MultiPlatformDependencyResolverTests: CoreBasedTests {

    /// A helper function to determine which dependencies to return.
    func deps<T: DependencyFilter>(_ d: [T], useImplicitDependencies: Bool) -> [T] {
        let alwaysInclude = d.filter({ $0.isWatchKitAppContainer })
        if useImplicitDependencies { return alwaysInclude }
        return d
    }

    /// Used to create the test workspace to test with multiple top-level targets and shared targets across multiple projects.
    func createCoreScenarioTestWorkspace(useImplicitDependencies: Bool, overrides: [String:String] = [:]) async throws -> SWBCore.Workspace {
        let core = try await getCore()
        let defaultSettings: [String:String] = try await [
            "ARCHS": "$(ARCHS_STANDARD)",
            "ENABLE_ON_DEMAND_RESOURCES": "NO",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGN_IDENTITY": "",
            "SWIFT_VERSION": swiftVersion,
            "SWIFT_INSTALL_OBJC_HEADER": "NO",
            "SKIP_INSTALL": "YES",
            "GENERATE_INFOPLIST_FILE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
            "WATCHOS_DEPLOYMENT_TARGET": core.loadSDK(.watchOS).defaultDeploymentTarget,
            "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
            "TVOS_DEPLOYMENT_TARGET": core.loadSDK(.tvOS).defaultDeploymentTarget,
        ]

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: defaultSettings),
            ],
            targets: [
                TestStandardTarget(
                    "Watchable",
                    type: .watchKitAppContainer,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos",
                            "SUPPORTED_PLATFORMS": "iphoneos",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestCopyFilesBuildPhase(["Watchable WatchKit App.app"], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                               ),
                    ],
                    dependencies: deps(["Watchable WatchKit App"], useImplicitDependencies: useImplicitDependencies)
                ),
                TestStandardTarget(
                    "Watchable WatchKit App",
                    type: .watchKitApp,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                            "SDKROOT": "watchos",
                            "TARGETED_DEVICE_FAMILY": "4",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestCopyFilesBuildPhase(["Watchable WatchKit Extension.appex"], destinationSubfolder: .plugins, onlyForDeployment: false
                                               ),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                            TestBuildFile(.target("Other Shared Framework")),
                            TestBuildFile(.target("OtherSharedPkgTarget")),
                        ]),
                    ],
                    dependencies: deps(["Watchable WatchKit Extension", "Shared Framework", "Other Shared Framework"], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget"), TestTargetDependency("OtherSharedPkgTarget")])
                ),
                TestStandardTarget(
                    "Watchable WatchKit Extension",
                    type: .watchKitExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                            "SDKROOT": "watchos",
                            "TARGETED_DEVICE_FAMILY": "4",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "iOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                            "SDKROOT": "iphoneos",
                            "TARGETED_DEVICE_FAMILY": "1",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                            TestBuildFile(.target("Other Shared Framework")),
                            TestBuildFile(.target("OtherSharedPkgTarget")),
                        ]),
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework"), TestTargetDependency("Other Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget"), TestTargetDependency("OtherSharedPkgTarget")])
                ),
                TestStandardTarget(
                    "macCatalyst App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SDKROOT": "iphoneos",
                            "SUPPORTS_MACCATALYST": "YES",
                            "TARGETED_DEVICE_FAMILY": "2,6",
                        ])
                    ],
                    buildPhases: [
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                            TestBuildFile(.target("Other Shared Framework")),
                            TestBuildFile(.target("OtherSharedPkgTarget")),
                        ])
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework"), TestTargetDependency("Other Shared Framework"), ], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget"), TestTargetDependency("OtherSharedPkgTarget")])
                ),
                TestStandardTarget(
                    "macOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                            TestBuildFile(.target("Other Shared Framework")),
                            TestBuildFile(.target("OtherSharedPkgTarget")),
                        ]),
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework"), TestTargetDependency("Other Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget"), TestTargetDependency("OtherSharedPkgTarget")])
                ),
                TestStandardTarget(
                    "Shared Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    buildPhases: []
                ),
                TestStandardTarget(
                    "MacAppEmbeddingiOSApp", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("Other Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                            TestBuildFile(.target("OtherSharedPkgTarget")),
                        ]),
                        TestCopyFilesBuildPhase([TestBuildFile(.target("iOS App"))], destinationSubfolder: .builtProductsDir, destinationSubpath: "Samples")
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework"), TestTargetDependency("Other Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget"), TestTargetDependency("OtherSharedPkgTarget"),  TestTargetDependency("iOS App")])
                )
            ])

        let packageProject = TestPackageProject(
            "Package", groupTree: TestGroup("Sources"),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: defaultSettings),
            ],
            targets: [
                TestPackageProductTarget(
                    "SharedPackageProduct::SharedPkgTarget",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("SharedPkgTarget"))
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SUPPORTS_MACCATALYST": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    dependencies: deps(["SharedPkgTarget", "OtherSharedPkgTarget"], useImplicitDependencies: useImplicitDependencies)
                ),
                TestStandardTarget(
                    "SharedPkgTarget", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SUPPORTS_MACCATALYST": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    buildPhases: []
                ),
            ])

        let otherProject = TestProject(
            "otherProject",
            groupTree: TestGroup("Sources"),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: defaultSettings),
            ],
            targets: [
                TestStandardTarget(
                    "Other Shared Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    buildPhases: []
                ),
            ])

        let otherPackageProject = TestPackageProject(
            "OtherPackage",
            groupTree: TestGroup("Sources"),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: defaultSettings),
            ],
            targets: [
                TestPackageProductTarget(
                    "OtherSharedPackageProduct::OtherSharedPkgTarget",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("SharedPkgTarget"))
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SUPPORTS_MACCATALYST": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    dependencies: deps(["OtherSharedPkgTarget"], useImplicitDependencies: useImplicitDependencies)
                ),
                TestStandardTarget(
                    "OtherSharedPkgTarget", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SUPPORTS_MACCATALYST": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    buildPhases: []
                )
            ])

        return try TestWorkspace("Workspace", projects: [testProject, packageProject, otherProject, otherPackageProject]).load(core)
    }

    func _testCoreScenario(targetName: String, destination: RunDestinationInfo, useImplicitDependencies: Bool, validate: (BuildRequest.BuildTargetInfo, any TargetGraph) throws -> Void) async throws {
        try await _testCoreScenario(targetNames: [targetName], destination: destination, useImplicitDependencies: useImplicitDependencies) { targets, graph in
            let target = try #require(targets.first)
            try validate(target, graph)
        }
    }

    func _testCoreScenario(targetNames: [String], destination: RunDestinationInfo?, useImplicitDependencies: Bool, validate: ([BuildRequest.BuildTargetInfo], any TargetGraph) throws -> Void) async throws {

        let workspace = try await createCoreScenarioTestWorkspace(useImplicitDependencies: useImplicitDependencies)
        let workspaceContext = try await WorkspaceContext(core: getCore(), workspace: workspace, processExecutionCache: .sharedForTesting)

        let buildParameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)
        let targets = try targetNames.map({ BuildRequest.BuildTargetInfo(parameters: buildParameters, target: try #require(workspace.target(named: $0))) })
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: targets, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: useImplicitDependencies, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        try validate(targets, buildGraph)
    }

    func _testCoreScenario_macOSApp(useImplicitDependencies: Bool) async throws {
        try await _testCoreScenario(targetName: "macOS App", destination: .macOS, useImplicitDependencies: useImplicitDependencies) { target, graph in

            // NOTE: OS frameworks use arm64e, but! arm64e is not currently added to ARCHS by default for public SDKs.
            let expectedDeps = [
                "Other Shared Framework-macos",
                "OtherSharedPkgTarget-macos",
                "Shared Framework-macos",
                "SharedPkgTarget-macos",
            ].sorted()

            let deps = try graph.dependencies(target)
            #expect(deps.map(\.nameAndPlatform).sorted() == expectedDeps)

            for dep in deps {
                #expect(dep.parameters.overrides == [
                    "SDKROOT": "macosx",
                    "SDK_VARIANT": "macos",
                    "SUPPORTS_MACCATALYST": "NO",
                ])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func coreScenario_macOSApp_ExplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_macOSApp(useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.macOS))
    func coreScenario_macOSApp_ImplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_macOSApp(useImplicitDependencies: true)
    }

    func _testCoreScenario_iOSApp(useImplicitDependencies: Bool) async throws {
        try await _testCoreScenario(targetName: "iOS App", destination: .iOS, useImplicitDependencies: useImplicitDependencies) { target, graph in

            let expectedDeps = [
                "Other Shared Framework-iphoneos",
                "OtherSharedPkgTarget-iphoneos",
                "Shared Framework-iphoneos",
                "SharedPkgTarget-iphoneos",
            ].sorted()

            let deps = try graph.dependencies(target)
            #expect(deps.map(\.nameAndPlatform).sorted() == expectedDeps)

            for dep in deps {
                #expect(dep.parameters.overrides == [
                    "SDKROOT": "iphoneos",
                    "SDK_VARIANT": "iphoneos",
                    "SUPPORTS_MACCATALYST": "NO",
                ])
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func coreScenario_iOSApp_ExplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_iOSApp(useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.iOS))
    func coreScenario_iOSApp_ImplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_iOSApp(useImplicitDependencies: true)
    }

    func _testCoreScenario_macCatalystApp(useImplicitDependencies: Bool) async throws {
        try await _testCoreScenario(targetName: "macCatalyst App", destination: .macCatalyst, useImplicitDependencies: false) { target, graph in

            let expectedDeps = [
                "Other Shared Framework-iosmac",
                "OtherSharedPkgTarget-iosmac",
                "Shared Framework-iosmac",
                "SharedPkgTarget-iosmac",
            ]
            let deps = try graph.dependencies(target)
            #expect(deps.map(\.nameAndPlatform).sorted() == expectedDeps)

            for dep in deps {
                #expect(dep.parameters.overrides == [
                    "SDKROOT": "macosx",
                    "SDK_VARIANT": "iosmac",
                    "SUPPORTS_MACCATALYST": "YES",
                ])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func coreScenario_macCatalystApp_ExplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_macCatalystApp(useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.macOS))
    func coreScenario_macCatalystApp_ImplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_macCatalystApp(useImplicitDependencies: true)
    }

    func _testCoreScenario_watchApp(useImplicitDependencies: Bool) async throws {
        try await _testCoreScenario(targetName: "Watchable", destination: .watchOS, useImplicitDependencies: false) { target, graph in

            let expectedDeps1 = [
                "Watchable WatchKit App-watchos",
            ]
            let deps1 = try graph.dependencies(target)
            #expect(deps1.map(\.nameAndPlatform).sorted() == expectedDeps1)

            let expectedDeps2 = [
                "Other Shared Framework-watchos",
                "OtherSharedPkgTarget-watchos",
                "Shared Framework-watchos",
                "SharedPkgTarget-watchos",
                "Watchable WatchKit Extension-watchos",
            ]
            let deps2 = graph.dependencies(of: deps1[0])
            #expect(deps2.map(\.nameAndPlatform).sorted() == expectedDeps2)

            let noOverrides = ["Watchable WatchKit Extension-watchos", "Watchable WatchKit App-watchos"]
            for dep in deps1.appending(contentsOf: deps2) {
                if noOverrides.contains(dep.nameAndPlatform) {
                    #expect(dep.parameters.overrides == [:])
                }
                else {
                    #expect(dep.parameters.overrides == [
                        "SDKROOT": "watchos",
                        "SDK_VARIANT": "watchos",
                        "SUPPORTS_MACCATALYST": "NO",
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.watchOS))
    func coreScenario_watchApp_ExplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_watchApp(useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.watchOS))
    func coreScenario_watchApp_ImplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_watchApp(useImplicitDependencies: true)
    }

    func _testCoreScenario_AllTopLevelTargets(destination: RunDestinationInfo?, useImplicitDependencies: Bool) async throws {
        try await _testCoreScenario(targetNames: ["macOS App", "iOS App", "macCatalyst App", "Watchable"], destination: destination, useImplicitDependencies: useImplicitDependencies) { targets, graph in

            // Verify the macOS App target
            do {
                let target = try #require(targets.filter({ $0.target.name == "macOS App" }).first)

                let expectedDeps = [
                    "Other Shared Framework-macos",
                    "OtherSharedPkgTarget-macos",
                    "Shared Framework-macos",
                    "SharedPkgTarget-macos",
                ].sorted()

                let deps = try graph.dependencies(target)
                #expect(deps.map(\.nameAndPlatform).sorted() == expectedDeps)

                for dep in deps {
                    #expect(dep.parameters.overrides == [
                        "SDKROOT": "macosx",
                        "SDK_VARIANT": "macos",
                        "SUPPORTS_MACCATALYST": "NO",
                    ].addingContents(of: destination == .macOS || destination == .macCatalyst ? [:] : ["SUPPORTED_PLATFORMS": "macosx"]))
                }
            }

            // Verify the iOS App target
            do {
                let target = try #require(targets.filter({ $0.target.name == "iOS App" }).first)

                let expectedDeps = [
                    "Other Shared Framework-iphoneos",
                    "OtherSharedPkgTarget-iphoneos",
                    "Shared Framework-iphoneos",
                    "SharedPkgTarget-iphoneos",
                ].sorted()

                let deps = try graph.dependencies(target)
                #expect(deps.map(\.nameAndPlatform).sorted() == expectedDeps)

                for dep in deps {
                    #expect(dep.parameters.overrides == [
                        "SDKROOT": "iphoneos",
                        "SDK_VARIANT": "iphoneos",
                        "SUPPORTS_MACCATALYST": "NO",
                    ].addingContents(of: destination == .iOS ? [:] : ["SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]))
                }
            }

            // Verify the macCatalyst App target. When the run destination is .macOS, then this actually builds for .iOS.
            do {
                let target = try #require(targets.filter({ $0.target.name == "macCatalyst App" }).first)

                let expectedDeps = [
                    "Other Shared Framework-\([.iOS, .macOS, nil].contains(destination) ? "iphoneos" : "iosmac")",
                    "OtherSharedPkgTarget-\([.iOS, .macOS, nil].contains(destination) ? "iphoneos" : "iosmac")",
                    "Shared Framework-\([.iOS, .macOS, nil].contains(destination) ? "iphoneos" : "iosmac")",
                    "SharedPkgTarget-\([.iOS, .macOS, nil].contains(destination) ? "iphoneos" : "iosmac")",
                ].sorted()

                let deps = try graph.dependencies(target)
                #expect(deps.map(\.nameAndPlatform).sorted() == expectedDeps)

                for dep in deps {
                    #expect(dep.parameters.overrides == [
                        "SDKROOT": "\([.iOS, .macOS, nil].contains(destination) ? "iphoneos" : "macosx")",
                        "SDK_VARIANT": "\([.iOS, .macOS, nil].contains(destination) ? "iphoneos" : "iosmac")",
                    ]
                        .addingContents(of: [.iOS, .macCatalyst].contains(destination) ? [:] : ["SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"])
                        .addingContents(of: destination == .macCatalyst ? ["SUPPORTS_MACCATALYST": "YES"] : ["SUPPORTS_MACCATALYST": "NO"]))
                }
            }

            // Verify the watchOS app target
            do {
                let target = try #require(targets.filter({ $0.target.name == "Watchable" }).first)

                let expectedDeps1 = [
                    "Watchable WatchKit App-\(destination?.sdkVariant ?? "")",
                ]
                let deps1 = try graph.dependencies(target)
                #expect(deps1.map(\.nameAndPlatform).sorted() == expectedDeps1)

                let expectedDeps2 = [
                    "Other Shared Framework-watchos",
                    "OtherSharedPkgTarget-watchos",
                    "Shared Framework-watchos",
                    "SharedPkgTarget-watchos",
                    "Watchable WatchKit Extension-\(destination?.sdkVariant ?? "")", // why is this empty?
                ]
                let deps2 = graph.dependencies(of: deps1[0])
                #expect(deps2.map(\.nameAndPlatform).sorted() == expectedDeps2)

                let noOverrides = ["Watchable WatchKit Extension-watchos", "Watchable WatchKit App-watchos"]
                for dep in deps2 {
                    if noOverrides.contains(dep.nameAndPlatform) {
                        #expect(dep.parameters.overrides == [:])
                    }
                    else {
                        if dep.nameAndPlatform.starts(with: "Watchable WatchKit Extension-") {
                            #expect(dep.parameters.overrides == [:])
                        }
                        else {
                            #expect(dep.parameters.overrides == [
                                "SDKROOT": "watchos",
                                "SDK_VARIANT": "watchos",
                                "SUPPORTED_PLATFORMS": "watchos watchsimulator",
                                "SUPPORTS_MACCATALYST": "NO",
                            ])
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func coreScenario_AllTopLevelTargets_ExplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_AllTopLevelTargets(destination: nil, useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func coreScenario_AllTopLevelTargets_ImplicitDeps_PublicSDK() async throws {
        try await _testCoreScenario_AllTopLevelTargets(destination: nil, useImplicitDependencies: true)
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func coreScenario_AllTopLevelTargets_ExplicitDeps_PublicSDK_iOSDestination() async throws {
        try await _testCoreScenario_AllTopLevelTargets(destination: .iOS, useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func coreScenario_AllTopLevelTargets_ExplicitDeps_PublicSDK_macOSDestination() async throws {
        try await _testCoreScenario_AllTopLevelTargets(destination: .macOS, useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func coreScenario_AllTopLevelTargets_ExplicitDeps_PublicSDK_macCatalystDestination() async throws {
        try await _testCoreScenario_AllTopLevelTargets(destination: .macCatalyst, useImplicitDependencies: false)
    }

    // Helper test method to verify that SUPPORTED_PLATFORMS properly filters potential dependencies.
    func _testNarrowSpecialization(useImplicitDependencies: Bool) async throws {
        let core = try await getCore()
        let defaultSettings: [String:String] = try await [
            "ARCHS": "$(ARCHS_STANDARD)",
            "ENABLE_ON_DEMAND_RESOURCES": "NO",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGN_IDENTITY": "",
            "SWIFT_VERSION": swiftVersion,
            "SWIFT_INSTALL_OBJC_HEADER": "NO",
            "SKIP_INSTALL": "YES",
            "GENERATE_INFOPLIST_FILE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
            "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
        ]

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: defaultSettings),
            ],
            targets: [
                TestStandardTarget(
                    "iOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                            "SDKROOT": "iphoneos",
                            "TARGETED_DEVICE_FAMILY": "1",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                        ]),
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework")], useImplicitDependencies: useImplicitDependencies)
                ),
                TestStandardTarget(
                    "macOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                        ]),
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework")], useImplicitDependencies: useImplicitDependencies)
                ),
                TestStandardTarget(
                    "Shared Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "SUPPORTED_PLATFORMS": "macosx appletvos",
                            "SDKROOT": "macosx",
                        ])
                    ],
                    buildPhases: []
                )
            ])

        let workspace = try TestWorkspace("aWorkspace", projects: [testProject]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        let iosTarget = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug", activeRunDestination: .iOS), target: try #require(workspace.target(named: "iOS App")))
        let macTarget = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug", activeRunDestination: .macOS), target: try #require(workspace.target(named: "macOS App")))

        for buildTargets in [[iosTarget], [macTarget], [iosTarget, macTarget]] {
            let buildRequest = BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: useImplicitDependencies, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            if buildTargets.contains(where: { $0.target.guid == iosTarget.target.guid }) {
                // Verify the iOS target has no dependencies as the shared target does not support iOS when using implicit dependencies. However, the explicit dependency graph can still make a dependency upon the target.
                let iosDeps = try buildGraph.dependencies(iosTarget)
                #expect(iosDeps.map({ $0.nameAndPlatform }) == (useImplicitDependencies ? [] : ["Shared Framework-iphoneos"]))
            }

            if buildTargets.contains(where: { $0.target.guid == macTarget.target.guid }) {
                // Verify the macOS target.
                let macDeps = try buildGraph.dependencies(macTarget)
                #expect(macDeps.map({ $0.nameAndPlatform }) == ["Shared Framework-macos"])
            }
        }
    }

    @Test(.bug("rdar://74278644"), .knownIssue("Failing in 2021; needs re-evaluation"))
    func narrowSpecialization_ExplicitDependencies() async throws {
        try await _testNarrowSpecialization(useImplicitDependencies: false)
    }

    @Test(.bug("rdar://74278644"), .flaky("Failing in 2021; needs re-evaluation"))
    func narrowSpecialization_ImplicitDependencies() async throws {
        try await _testNarrowSpecialization(useImplicitDependencies: true)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func implicitDepsWithMultipleProductNameMatches() async throws {
        let core = try await getCore()
        let defaultSettings: [String: String] = try await [
            "ARCHS": "$(ARCHS_STANDARD)",
            "ENABLE_ON_DEMAND_RESOURCES": "NO",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGN_IDENTITY": "",
            "SWIFT_VERSION": swiftVersion,
            "SWIFT_INSTALL_OBJC_HEADER": "NO",
            "SKIP_INSTALL": "YES",
            "GENERATE_INFOPLIST_FILE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
            "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
        ]

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: defaultSettings),
            ],
            targets: [
                TestStandardTarget(
                    "macOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestFrameworksBuildPhase([
                            "shared.framework"
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "macCatalyst App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SDKROOT": "iphoneos",
                            "SUPPORTS_MACCATALYST": "YES",
                            "TARGETED_DEVICE_FAMILY": "2,6",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos",
                        ])
                    ],
                    buildPhases: [
                        TestFrameworksBuildPhase([
                            "shared.framework"
                        ])
                    ]
                ),
                TestStandardTarget(
                    "Shared Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "shared",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SDKROOT": "macosx",
                        ])
                    ],
                    buildPhases: []
                ),
                TestStandardTarget(
                    "Other Shared Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "shared",
                            "SUPPORTED_PLATFORMS": "iphoneos",
                            "SUPPORTS_MACCATALYST": "YES",
                            "SDKROOT": "iphoneos",
                        ])
                    ],
                    buildPhases: []
                )
            ])

        let workspace = try TestWorkspace("aWorkspace", projects: [testProject]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        let macTarget = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug", activeRunDestination: .macOS), target: try #require(workspace.target(named: "macOS App")))
        let macCatalystTarget = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug", activeRunDestination: .macCatalyst), target: try #require(workspace.target(named: "macCatalyst App")))

        // Verify the correct shared framework is used when building for macOS.
        do {
            let buildRequest = BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: [macTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.nameAndPlatform }) == ["Shared Framework-macos", "macOS App-macos"])

            if workspaceContext.userPreferences.enableDebugActivityLogs {
                // ignore the rejection diagnostics
            }
            else {
                delegate.checkNoDiagnostics()
            }
        }

        // Verify the correct shared framework is used when building for macCatalyst.
        do {
            let buildRequest = BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: [macCatalystTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.nameAndPlatform }) == ["Other Shared Framework-iosmac", "macCatalyst App-iosmac"])

            if workspaceContext.userPreferences.enableDebugActivityLogs {
                // ignore the rejection diagnostics
            }
            else {
                delegate.checkNoDiagnostics()
            }
        }
    }
}
