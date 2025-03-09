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
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

@Suite fileprivate struct IndexDependencyResolutionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func multiPlatformTargetsButSameFramework() async throws {
        let core = try await getCore()

        let macApp = TestStandardTarget(
            "macApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestFrameworksBuildPhase(["FwkTarget.framework"]),
            ])

        let iosApp = TestStandardTarget(
            "iosApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestFrameworksBuildPhase(["FwkTarget.framework"]),
            ])

        let macApp2 = TestStandardTarget(
            "macApp2",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestFrameworksBuildPhase(["FwkTarget.framework"]),
            ],
            dependencies: [
                "FwkTarget_mac",
            ]
        )

        let iosApp2 = TestStandardTarget(
            "iosApp2",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestFrameworksBuildPhase(["FwkTarget.framework"]),
            ],
            dependencies: [
                "FwkTarget_ios",
            ]
        )

        let fwkTarget_mac = TestStandardTarget(
            "FwkTarget_mac",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "PRODUCT_NAME": "FwkTarget",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let fwkTarget_ios = TestStandardTarget(
            "FwkTarget_ios",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "FwkTarget",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        macApp, macApp2,
                        iosApp, iosApp2,
                        fwkTarget_mac,
                        fwkTarget_ios,
                    ])])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [macApp, macApp2, iosApp, iosApp2, fwkTarget_mac, fwkTarget_ios]) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "FwkTarget_mac-macos", "macApp-macos", "macApp2-macos",
                "FwkTarget_ios-iphoneos", "iosApp-iphoneos", "FwkTarget_ios-iphonesimulator", "iosApp-iphonesimulator", "iosApp2-iphoneos", "iosApp2-iphonesimulator",
                "FwkTarget_ios-iosmac"
            ])

            try results.checkDependencies(of: macApp, are: [.init(fwkTarget_mac)])
            try results.checkDependencies(of: macApp2, are: [.init(fwkTarget_mac)])
            try results.checkDependencies(of: .init(iosApp, "iphoneos"), are: [.init(fwkTarget_ios, "iphoneos")])
            try results.checkDependencies(of: .init(iosApp, "iphonesimulator"), are: [.init(fwkTarget_ios, "iphonesimulator")])
            try results.checkDependencies(of: .init(iosApp2, "iphoneos"), are: [.init(fwkTarget_ios, "iphoneos")])
            try results.checkDependencies(of: .init(iosApp2, "iphonesimulator"), are: [.init(fwkTarget_ios, "iphonesimulator")])
            try results.checkDependencies(of: fwkTarget_mac, are: [])
            try results.checkDependencies(of: .init(fwkTarget_ios, "iphoneos"), are: [])
            try results.checkDependencies(of: .init(fwkTarget_ios, "iphonesimulator"), are: [])
            if results.buildGraph.workspaceContext.userPreferences.enableDebugActivityLogs {
                results.delegate.checkDiagnostics([
                    "FwkTarget_mac rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphoneos). (in target 'iosApp' from project 'aProject')",
                    "FwkTarget_ios rejected as an implicit dependency because its SUPPORTED_PLATFORMS (iphoneos iphonesimulator) does not contain this target's platform (macosx). (in target 'macApp' from project 'aProject')",
                    "FwkTarget_mac rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphonesimulator). (in target 'iosApp' from project 'aProject')"
                ])
            } else {
                results.delegate.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func crossPlatformDependencies() async throws {
        let core = try await getCore()

        let macApp = TestStandardTarget(
            "macApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ])

        let iosApp = TestStandardTarget(
            "iosApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestCopyFilesBuildPhase([
                    "Watchable WatchKit App.app",
                ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                       ),
            ],
            dependencies: [
                "macApp",
                "Watchable WatchKit App",
            ]
        )

        let watchKitApp = TestStandardTarget(
            "Watchable WatchKit App",
            type: .watchKitApp,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "INFOPLIST_FILE": "Sources/watchosApp/Info.plist",
                    "SDKROOT": "watchos",
                    "SKIP_INSTALL": "YES",
                ])
            ],
            buildPhases: [
                TestCopyFilesBuildPhase([
                    "Watchable WatchKit Extension.appex",
                ], destinationSubfolder: .plugins, onlyForDeployment: false
                                       ),
            ]
        )

        let watchKitExt = TestStandardTarget(
            "Watchable WatchKit Extension",
            type: .watchKitExtension,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                    "INFOPLIST_FILE": "Sources/watchosExtension/Info.plist",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                    "SDKROOT": "watchos",
                    "SKIP_INSTALL": "YES",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.swift",
                ]),
            ]
        )

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        macApp,
                        iosApp,
                        watchKitApp,
                        watchKitExt,
                    ])])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [macApp, iosApp, watchKitApp, watchKitExt]) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "macApp-macos", "iosApp-iphoneos", "iosApp-iphonesimulator",
                "Watchable WatchKit Extension-watchos", "Watchable WatchKit App-watchos", "Watchable WatchKit Extension-watchsimulator", "Watchable WatchKit App-watchsimulator",
            ])

            try results.checkDependencies(of: .init(iosApp, "iphoneos"), are: [])
            try results.checkDependencies(of: .init(iosApp, "iphonesimulator"), are: [])
            try results.checkDependencies(of: .init(watchKitApp, "watchos"), are: [.init(watchKitExt, "watchos")])
            try results.checkDependencies(of: .init(watchKitApp, "watchsimulator"), are: [.init(watchKitExt, "watchsimulator")])
            if results.buildGraph.workspaceContext.userPreferences.enableDebugActivityLogs {
                results.delegate.checkDiagnostics([
                    "Watchable WatchKit App rejected as an implicit dependency because its SUPPORTED_PLATFORMS (watchos watchsimulator) does not contain this target's platform (iphoneos). (in target 'iosApp' from project 'aProject')",
                    "Watchable WatchKit App rejected as an implicit dependency because its SUPPORTED_PLATFORMS (watchos watchsimulator) does not contain this target's platform (iphonesimulator). (in target 'iosApp' from project 'aProject')"
                ])
            } else {
                results.delegate.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func hostToolDependencies() async throws {
        let core = try await getCore()

        let iosApp = TestStandardTarget(
            "iosApp", type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: [
                "hostTool",
                "watchApp"
            ]
        )

        let watchApp = TestStandardTarget(
            "watchApp",
            type: .watchKitApp,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "watchos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let hostToolDep = TestStandardTarget(
            "hostToolDep", type: .staticLibrary,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: []
        )

        let hostTool = TestStandardTarget(
            "hostTool", type: .hostBuildTool,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "auto",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: ["hostToolDep"]
        )

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        iosApp,
                        watchApp,
                        hostTool,
                        hostToolDep
                    ])])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [iosApp, watchApp, hostTool, hostToolDep]) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "hostToolDep-macos", "hostTool-macos",
                "iosApp-iphoneos", "iosApp-iphonesimulator",
                "watchApp-watchos", "watchApp-watchsimulator",
            ])

            try results.checkDependencies(of: .init(iosApp, "iphoneos"), are: [.init(hostTool, "macos")])
            try results.checkDependencies(of: .init(iosApp, "iphonesimulator"), are: [.init(hostTool, "macos")])
            try results.checkDependencies(of: .init(watchApp, "watchos"), are: [])
            try results.checkDependencies(of: .init(watchApp, "watchsimulator"), are: [])
            try results.checkDependencies(of: .init(hostToolDep, "macos"), are: [])
            try results.checkDependencies(of: .init(hostTool, "macos"), are: [.init(hostToolDep, "macos")])

            results.delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func hostToolDependencySharedWithProduct() async throws {
        let core = try await getCore()

        let commonDep = TestStandardTarget(
            "commonDep", type: .staticLibrary,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "auto",
                    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: []
        )

        let hostTool = TestStandardTarget(
            "hostTool", type: .hostBuildTool,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "auto",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: ["commonDep"]
        )

        let iosApp = TestStandardTarget(
            "iosApp", type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: [
                "hostTool",
                "commonDep"
            ]
        )

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        iosApp,
                        hostTool,
                        commonDep
                    ])])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [iosApp, hostTool, commonDep]) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "commonDep-macos", "hostTool-macos", "commonDep-iphoneos", "iosApp-iphoneos", "commonDep-iphonesimulator", "iosApp-iphonesimulator", "commonDep-iosmac"
            ])

            try results.checkDependencies(of: .init(commonDep, "macos"), are: [])
            try results.checkDependencies(of: .init(commonDep, "iosmac"), are: [])
            try results.checkDependencies(of: .init(commonDep, "iphoneos"), are: [])
            try results.checkDependencies(of: .init(commonDep, "iphonesimulator"), are: [])
            try results.checkDependencies(of: .init(hostTool, "macos"), are: [.init(commonDep, "macos")])
            try results.checkDependencies(of: .init(iosApp, "iphoneos"), are: [.init(hostTool, "macos"), .init(commonDep, "iphoneos")])
            try results.checkDependencies(of: .init(iosApp, "iphonesimulator"), are: [.init(hostTool, "macos"), .init(commonDep, "iphonesimulator")])

            results.delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func aggregateDependency() async throws {
        let core = try await getCore()

        let aggrTarget = TestAggregateTarget(
            "Aggregate",
            buildPhases: [
                TestShellScriptBuildPhase(name: "A", originalObjectID: "A", contents: "true")
            ],
            dependencies: ["macApp2", "iosApp2"]
        )

        let macApp = TestStandardTarget(
            "macApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: ["Aggregate"]
        )

        let iosApp = TestStandardTarget(
            "iosApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ],
            dependencies: ["Aggregate"]
        )

        let macApp2 = TestStandardTarget(
            "macApp2",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let iosApp2 = TestStandardTarget(
            "iosApp2",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "macosx",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        macApp, macApp2,
                        iosApp, iosApp2,
                        aggrTarget,
                    ])])

        let targetsToCheck = [macApp, iosApp, macApp2, iosApp2] // excludes `aggrTarget` from top-level targets.
        let checkDependencies = { (results: BuildOperationTester.BuildGraphResult) in
            try results.checkDependencies(of: macApp, are: [.init(aggrTarget, "macos")])
            try results.checkDependencies(of: .init(iosApp, "iphoneos"), are: [.init(aggrTarget, "iphoneos")])
            try results.checkDependencies(of: .init(iosApp, "iphonesimulator"), are: [.init(aggrTarget, "iphonesimulator")])
            try results.checkDependencies(of: .init(aggrTarget, "macos"), are: [.init(macApp2, "macos")])
            try results.checkDependencies(of: .init(aggrTarget, "iphoneos"), are: [.init(iosApp2, "iphoneos")])
            try results.checkDependencies(of: .init(aggrTarget, "iphonesimulator"), are: [.init(iosApp2, "iphonesimulator")])
            results.delegate.checkNoDiagnostics()
        }

        var macApp2_macosConfTarget: ConfiguredTarget!
        var iosApp2_iosConfTarget: ConfiguredTarget!

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: targetsToCheck) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "macApp2-macos",
                "Aggregate-macos",
                "macApp-macos",
                "iosApp2-iphoneos",
                "Aggregate-iphoneos",
                "iosApp-iphoneos",
                "iosApp2-iphonesimulator",
                "Aggregate-iphonesimulator",
                "iosApp-iphonesimulator",
            ])

            macApp2_macosConfTarget = try results.target(.init(macApp2, "macos"))
            iosApp2_iosConfTarget = try results.target(.init(iosApp2, "iphoneos"))

            try checkDependencies(results)
        }

        // Same request but with reversed order of top-level targets. Make sure the graph is same.
        try await tester.checkIndexBuildGraph(targets: targetsToCheck.reversed()) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "iosApp2-iphoneos",
                "iosApp2-iphonesimulator",
                "macApp2-macos",
                "Aggregate-iphoneos",
                "iosApp-iphoneos",
                "Aggregate-iphonesimulator",
                "iosApp-iphonesimulator",
                "Aggregate-macos",
                "macApp-macos",
            ])
            try checkDependencies(results)
        }

        try await tester.checkIndexBuildGraph(targets: [macApp]) { results throws in
            #expect(try results.target(.init(macApp2, "macos")).guid == macApp2_macosConfTarget.guid)
        }

        try await tester.checkIndexBuildGraph(targets: [iosApp]) { results throws in
            #expect(try results.target(.init(iosApp2, "iphoneos")).guid == iosApp2_iosConfTarget.guid)
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func macCatalyst() async throws {
        let core = try await getCore()
        let catalystAppTarget1 = TestStandardTarget(
            "catalystApp1",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "SUPPORTS_MACCATALYST": "YES",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.m"]),
                TestFrameworksBuildPhase([
                    "FwkTarget.framework",
                ]),
            ])

        let catalystAppTarget2 = TestStandardTarget(
            "catalystApp2",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
                    "SDK_VARIANT[sdk=macosx*]": "iosmac",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.m"]),
                TestFrameworksBuildPhase([
                    "FwkTarget.framework",
                ]),
            ])

        let catalystAppTarget3 = TestStandardTarget(
            "catalystApp3",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
                    "SUPPORTS_MACCATALYST": "YES",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.m"]),
                TestFrameworksBuildPhase([
                    "FwkTarget.framework",
                ]),
            ])

        let osxAppTarget = TestStandardTarget(
            "osxApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.m"]),
                TestFrameworksBuildPhase([
                    "FwkTarget.framework"
                ]),
            ])

        let osxAppTarget_iosmac = TestStandardTarget(
            "osxApp_iosmac",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SDK_VARIANT": "iosmac",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.m"]),
                TestFrameworksBuildPhase([
                    "FwkTarget.framework"
                ]),
            ])

        let fwkTarget = try await TestStandardTarget(
            "FwkTarget",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "SWIFT_VERSION": swiftVersion,
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let fwkTarget_osx = try await TestStandardTarget(
            "FwkTarget_osx",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "PRODUCT_NAME": "FwkTarget",
                    "SWIFT_VERSION": swiftVersion,
                    "IS_ZIPPERED": "YES",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                            TestFile("main.m"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        catalystAppTarget1, catalystAppTarget2, catalystAppTarget3,
                        osxAppTarget, osxAppTarget_iosmac,
                        fwkTarget, fwkTarget_osx,
                    ])])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [catalystAppTarget1, catalystAppTarget2, catalystAppTarget3, osxAppTarget, osxAppTarget_iosmac, fwkTarget, fwkTarget_osx]) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "FwkTarget-iphoneos", "catalystApp1-iphoneos", "FwkTarget-iphonesimulator", "catalystApp1-iphonesimulator", "FwkTarget-iosmac", "catalystApp1-iosmac", "catalystApp2-iphoneos", "catalystApp2-iphonesimulator", "catalystApp2-iosmac", "catalystApp3-iphoneos", "catalystApp3-iphonesimulator", "catalystApp3-iosmac", "FwkTarget_osx-macos", "catalystApp3-macos", "osxApp-macos", "osxApp_iosmac-iosmac", "FwkTarget_osx-iosmac",
            ])

            try results.checkDependencies(of: .init(catalystAppTarget1, "iphoneos"), are: [.init(fwkTarget, "iphoneos")])
            try results.checkDependencies(of: .init(catalystAppTarget1, "iphonesimulator"), are: [.init(fwkTarget, "iphonesimulator")])
            try results.checkDependencies(of: .init(catalystAppTarget1, "iosmac"), are: [.init(fwkTarget, "iosmac")])
            try results.checkDependencies(of: .init(catalystAppTarget2, "iphoneos"), are: [.init(fwkTarget, "iphoneos")])
            try results.checkDependencies(of: .init(catalystAppTarget2, "iphonesimulator"), are: [.init(fwkTarget, "iphonesimulator")])
            try results.checkDependencies(of: .init(catalystAppTarget2, "iosmac"), are: [.init(fwkTarget, "iosmac")])
            try results.checkDependencies(of: .init(catalystAppTarget3, "iphoneos"), are: [.init(fwkTarget, "iphoneos")])
            try results.checkDependencies(of: .init(catalystAppTarget3, "iphonesimulator"), are: [.init(fwkTarget, "iphonesimulator")])
            try results.checkDependencies(of: .init(catalystAppTarget3, "iosmac"), are: [.init(fwkTarget, "iosmac")])
            try results.checkDependencies(of: .init(catalystAppTarget3, "macos"), are: [.init(fwkTarget_osx, "macos")])
            try results.checkDependencies(of: osxAppTarget, are: [.init(fwkTarget_osx, "macos")])
            try results.checkDependencies(of: osxAppTarget_iosmac, are: [.init(fwkTarget, "iosmac")])

            if results.buildGraph.workspaceContext.userPreferences.enableDebugActivityLogs  {
                results.delegate.checkDiagnostics([
                    "FwkTarget rejected as an implicit dependency because its SUPPORTED_PLATFORMS (iphoneos iphonesimulator) does not contain this target's platform (macosx). (in target 'catalystApp3' from project 'aProject')",
                    "FwkTarget rejected as an implicit dependency because its SUPPORTED_PLATFORMS (iphoneos iphonesimulator) does not contain this target's platform (macosx). (in target 'osxApp' from project 'aProject')",
                    "FwkTarget_osx rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphoneos). (in target 'catalystApp1' from project 'aProject')",
                    "FwkTarget_osx rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphoneos). (in target 'catalystApp2' from project 'aProject')",
                    "FwkTarget_osx rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphoneos). (in target 'catalystApp3' from project 'aProject')",
                    "FwkTarget_osx rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphonesimulator). (in target 'catalystApp1' from project 'aProject')",
                    "FwkTarget_osx rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphonesimulator). (in target 'catalystApp2' from project 'aProject')",
                    "FwkTarget_osx rejected as an implicit dependency because its SUPPORTED_PLATFORMS (macosx) does not contain this target's platform (iphonesimulator). (in target 'catalystApp3' from project 'aProject')",
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'catalystApp1' from project 'aProject')",
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'catalystApp2' from project 'aProject')",
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'catalystApp3' from project 'aProject')",
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'osxApp_iosmac' from project 'aProject')",
                ])
            } else {
                // FIXME: rdar://94174240 (Consider how to resolve ambiguous implicit dependencies with both a iphoneos target and IS_ZIPPERED macosx target)
                // `supportsMacCatalyst` has a check for whether `IS_ZIPPERED` and `INDEX_ENABLE_BUILD_ARENA` are set and if so returns true. This then causes `addRunDestinationSettingsPlatformSDK` to add `macosx` as a `SUPPORTED_PLATFORMS` and `iosmac` as a `SDK_VARIANT`. Thus `fwkTarget_osx` matches as an implicit dependency *and* `fwkTarget` (since it's `iphoneos`). We should probably prefer `fwkTarget_osx` in this case though since it explicitly supports catalyst (through `IS_ZIPPERED`) where as `fwkTarget` only specifies `iphoneos`.
                results.delegate.checkDiagnostics([
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'catalystApp1' from project 'aProject')",
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'catalystApp2' from project 'aProject')",
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'catalystApp3' from project 'aProject')",
                    "[targetIntegrity] Multiple targets match implicit dependency for product reference 'FwkTarget.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'FwkTarget' (in project 'aProject')\nTarget 'FwkTarget_osx' (in project 'aProject') (in target 'osxApp_iosmac' from project 'aProject')",
                ])
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftPackage() async throws {
        let core = try await getCore()

        let packageLib = TestStandardTarget("PackageLib", type: .objectFile, buildConfigurations: [
            TestBuildConfiguration("Debug")
        ], buildPhases: [TestSourcesBuildPhase(["test.swift"])])

        let packageLib2 = TestStandardTarget(
            "PackageLib2", type: .objectFile,
            buildConfigurations: [TestBuildConfiguration("Debug")],
            buildPhases: [TestSourcesBuildPhase(["test.swift"])],
            dependencies: ["PackageTool"]
        )

        let unreferencedPackageLib = TestStandardTarget("UnreferencedPackageLib", type: .objectFile, buildConfigurations: [
            TestBuildConfiguration("Debug")
        ], buildPhases: [TestSourcesBuildPhase(["test.swift"])])

        let packageProduct = TestPackageProductTarget(
            "PackageLibProduct",
            frameworksBuildPhase: TestFrameworksBuildPhase([
                TestBuildFile(.target("PackageLib"))]),
            buildConfigurations: [
                TestBuildConfiguration("Debug"),
            ],
            dependencies: ["PackageLib"]
        )

        let packageTool = TestStandardTarget("PackageTool", type: .commandLineTool, buildConfigurations: [
            TestBuildConfiguration("Debug", buildSettings: [
                "EXECUTABLE_NAME": "PackageTool",
                "SUPPORTED_PLATFORMS": "macosx",
            ])
        ], buildPhases: [TestSourcesBuildPhase(["test.swift"])])

        let package = try await TestPackageProject(
            "aPackage", groupTree: TestGroup("Package", children: [TestFile("test.swift")]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": swiftVersion,
                    ])],
            targets: [
                packageProduct,
                packageLib,
                packageLib2,
                packageTool,
                unreferencedPackageLib,
            ])

        let macAppTarget = TestStandardTarget(
            "macAppTarget",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestFrameworksBuildPhase([
                    TestBuildFile(.target("PackageLibProduct"))
                ]),
            ],
            dependencies: ["PackageLibProduct"])

        let iosAppTarget = TestStandardTarget(
            "iOSAppTarget",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestFrameworksBuildPhase([
                    TestBuildFile(.target("PackageLibProduct"))
                ]),
            ],
            dependencies: ["PackageLibProduct"])

        let workspace = try await TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ])],
                    targets: [
                        macAppTarget,
                        iosAppTarget,
                    ]), package])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [macAppTarget, iosAppTarget]) { results in
            #expect(results.targets(macAppTarget).map { results.targetNameAndPlatform($0) } == [
                "macAppTarget-macos",
            ])
            #expect(results.targets(iosAppTarget).map {results.targetNameAndPlatform($0) } == [
                "iOSAppTarget-iphoneos", "iOSAppTarget-iphonesimulator",
            ])

            try results.checkDependencies(of: macAppTarget, are: [.init(packageProduct, "macos")])
            try results.checkDependencies(of: .init(iosAppTarget, "iphoneos"), are: [.init(packageProduct, "iphoneos")])
            try results.checkDependencies(of: .init(iosAppTarget, "iphonesimulator"), are: [.init(packageProduct, "iphonesimulator")])
            results.delegate.checkNoDiagnostics()
        }

        try await tester.checkIndexBuildGraph(targets: [packageLib, packageLib2, packageProduct, packageTool, unreferencedPackageLib], activeRunDestination: .macOS, graphTypes: TargetGraphFactory.GraphType.allCases) { results in
            #expect(results.targets(packageTool).map{ results.targetNameAndPlatform($0) } == ["PackageTool-macos"])
            #expect(results.targets(packageLib).map{ results.targetNameAndPlatform($0) } == ["PackageLib-macos"])
            #expect(results.targets(packageLib2).map{ results.targetNameAndPlatform($0) } == ["PackageLib2-macos"])
            #expect(results.targets(packageProduct).map{ results.targetNameAndPlatform($0) } == ["PackageLibProduct-macos"])
            #expect(results.targets(unreferencedPackageLib).map{ results.targetNameAndPlatform($0) } == ["UnreferencedPackageLib-macos"])

            switch results.graphType {
            case .dependency:
                try results.checkDependencies(of: packageLib2, are: [.init(packageTool, "macos")])
            case .linkage:
                try results.checkDependencies(of: packageLib2, are: [])
            }
            results.delegate.checkNoDiagnostics()
        }

        try await tester.checkIndexBuildGraph(targets: [packageLib, packageLib2, packageProduct, packageTool, unreferencedPackageLib], activeRunDestination: .iOS, graphTypes: TargetGraphFactory.GraphType.allCases) { results in
            #expect(results.targets(packageTool).map{ results.targetNameAndPlatform($0) } == ["PackageTool-macos"])
            #expect(results.targets(packageLib).map{ results.targetNameAndPlatform($0) } == ["PackageLib-iphoneos"])
            #expect(results.targets(packageLib2).map{ results.targetNameAndPlatform($0) } == ["PackageLib2-iphoneos"])
            #expect(results.targets(packageProduct).map{ results.targetNameAndPlatform($0) } == ["PackageLibProduct-iphoneos"])
            #expect(results.targets(unreferencedPackageLib).map{ results.targetNameAndPlatform($0) } == ["UnreferencedPackageLib-iphoneos"])

            try results.checkDependencies(of: .init(packageLib2, "iphoneos"), are: [])

            results.delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func mismatchedSDKRoot() async throws {
        let core = try await getCore()

        let iosApp = TestStandardTarget(
            "iosApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "iphonesimulator iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c"]),
            ])

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.c"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        iosApp,
                    ])])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [iosApp]) { results in
            #expect(results.targets().map { results.targetNameAndPlatform($0) } == [
                "iosApp-iphoneos", "iosApp-iphonesimulator",
            ])
            results.delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .driverKit))
    func multiArchDefaults() async throws {
        let core = try await getCore()

        func createTarget(name: String, sdkRoot: String, archs: String) -> any TestTarget {
            return TestStandardTarget(
                name,
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": sdkRoot,
                        "ARCHS": archs,
                    ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["main.swift"]),
                ])
        }
        let macosApp = createTarget(name: "macosApp", sdkRoot: "macosx", archs: "x86_64 arm64")
        let iosApp = createTarget(name: "iosApp", sdkRoot: "iphoneos", archs: "arm64")
        let driver = createTarget(name: "driver", sdkRoot: "driverkit", archs: "x86_64 arm64")

        let workspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                    targets: [
                        macosApp,
                        iosApp,
                        driver,
                    ])])

        func checkTargetArch(_ arch: String, expected: [String: String], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let tester = try await BuildOperationTester(core, workspace, simulated: false)
            tester.systemInfo = SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: arch)
            try await tester.checkIndexBuildGraph(targets: [macosApp, iosApp, driver]) { results in
                var actual: [String: String] = [:]
                for target in results.targets() {
                    actual[target.nameAndPlatform] = target.parameters.activeArchitecture
                }
                #expect(actual == expected)
            }
        }

        try await checkTargetArch("x86_64", expected: [
            "macosApp-macos": "x86_64",
            "iosApp-iphoneos": "arm64",
            "iosApp-iphonesimulator": "x86_64",
            "driver-driverkit": "x86_64",
        ])
        try await checkTargetArch("arm64", expected: [
            "macosApp-macos": "arm64",
            "iosApp-iphoneos": "arm64",
            "iosApp-iphonesimulator": "arm64",
            "driver-driverkit": "arm64",
        ])
    }

    @Test
    func verifyAllPlatformsHaveDefaultArch() async throws {
        let core = try await getCore()

        var defaultArchs: [String: String] = [:]
        for platform in core.platformRegistry.platforms {
            let archName: String? = platform.determineDefaultArchForIndexArena(preferredArch: "unknown_arch", using: core)
            defaultArchs[platform.name] = archName
            #expect(archName != nil, "'\(platform.identifier)' is missing a default architecture for indexing")
        }

        //attach(name: "Index Platform Architecture Defaults", plistObject: defaultArchs, lifetime: .keepAlways)
    }
}

extension TargetGraph {
    func target(for targetInfo: BuildRequest.BuildTargetInfo, platform: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> ConfiguredTarget {
        let foundTargets = allTargets.filter { $0.target == targetInfo.target && (platform == nil || $0.platformDiscriminator == platform) }
        return try #require(foundTargets.only, foundTargets.isEmpty ? "unable to find target '\(targetInfo.target.name)', platform '\(platform ?? "<nil>")'" : "found more than one target '\(targetInfo.target.name)', platform '\(platform ?? "<nil>")': \(foundTargets.map{$0.nameAndPlatform})", sourceLocation: sourceLocation)
    }

    func targets(for targetInfo: BuildRequest.BuildTargetInfo) -> [ConfiguredTarget] {
        return allTargets.filter { $0.target == targetInfo.target }
    }

    func dependencies(_ targetInfo: BuildRequest.BuildTargetInfo, platform: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> [ConfiguredTarget] {
        return dependencies(of: try target(for: targetInfo, platform: platform, sourceLocation: sourceLocation))
    }
}

extension ConfiguredTarget {
    var nameAndPlatform: String {
        return "\(target.name)-\(self.platformDiscriminator ?? "")"
    }
}
