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
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil
import Foundation

@Suite fileprivate struct DependencyScopingTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func buildRequestScopeBasics() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T2"]
                        ),
                        TestStandardTarget(
                            "T2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T3"]
                        ),
                        TestStandardTarget(
                            "T3",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        )
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let t1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T1")!)
        let t2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T2")!)
        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T1"])
            #expect(try buildGraph.dependencies(t1).map(\.target.name) == [])
            delegate.checkNoDiagnostics()
        }
        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, t2], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T2", "T1"])
            #expect(try buildGraph.dependencies(t1).map(\.target.name) == ["T2"])
            #expect(try buildGraph.dependencies(t2).map(\.target.name) == [])
            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildRequestScopeRemovingInteriorTarget() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T2"]
                        ),
                        TestStandardTarget(
                            "T2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T3"]
                        ),
                        TestStandardTarget(
                            "T3",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        )
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let t1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T1")!)
        let t3 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T3")!)

        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, t3], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T3", "T1"])
        #expect(try buildGraph.dependencies(t1).map(\.target.name) == ["T3"])
        #expect(try buildGraph.dependencies(t3).map(\.target.name) == [])
        delegate.checkNoDiagnostics()
    }

    @Test(.requireSDKs(.macOS))
    func buildRequestScopeRemovingGroupOfInteriorTargets() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T2", "T3"]
                        ),
                        TestStandardTarget(
                            "T2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T4"]
                        ),
                        TestStandardTarget(
                            "T3",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: []
                        ),
                        TestStandardTarget(
                            "T4",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T5"]
                        ),
                        TestStandardTarget(
                            "T5",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T6", "T7"]
                        ),
                        TestStandardTarget(
                            "T6",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T8"]
                        ),
                        TestStandardTarget(
                            "T7",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: []
                        ),
                        TestStandardTarget(
                            "T8",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: []
                        )
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let t1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T1")!)
        let t2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T2")!)
        let t3 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T3")!)
        let t6 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T6")!)
        let t7 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T7")!)
        let t8 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T8")!)

        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, t2, t3, t6, t7, t8], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T8", "T6", "T7", "T2", "T3", "T1"])
        #expect(try buildGraph.dependencies(t1).map(\.target.name) == ["T2", "T3"])
        #expect(try buildGraph.dependencies(t2).map(\.target.name) == ["T6", "T7"])
        #expect(try buildGraph.dependencies(t3).map(\.target.name) == [])
        #expect(try buildGraph.dependencies(t6).map(\.target.name) == ["T8"])
        #expect(try buildGraph.dependencies(t7).map(\.target.name) == [])
        #expect(try buildGraph.dependencies(t8).map(\.target.name) == [])
        delegate.checkNoDiagnostics()
    }

    @Test(.requireSDKs(.macOS))
    func buildRequestScopeRemovingImplicitAndExplicitDependencies() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T2"]
                        ),
                        TestStandardTarget(
                            "T2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T3", "T4"]
                        ),
                        TestStandardTarget(
                            "T3",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"]),
                                TestFrameworksBuildPhase([
                                    "T5.framework",
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "T4",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                        TestStandardTarget(
                            "T5",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        )
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let t1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T1")!)
        let t2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T2")!)
        let t3 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T3")!)
        let t4 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T4")!)
        let t5 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T5")!)

        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, t2, t3], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T3", "T2", "T1"])
            #expect(try buildGraph.dependencies(t1).map(\.target.name) == ["T2"])
            #expect(try buildGraph.dependencies(t2).map(\.target.name) == ["T3"])
            #expect(try buildGraph.dependencies(t3).map(\.target.name) == [])
            delegate.checkNoDiagnostics()
        }

        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, t2, t3, t4], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T3", "T4", "T2", "T1"])
            #expect(try buildGraph.dependencies(t1).map(\.target.name) == ["T2"])
            #expect(try buildGraph.dependencies(t2).map(\.target.name) == ["T3", "T4"])
            #expect(try buildGraph.dependencies(t3).map(\.target.name) == [])
            #expect(try buildGraph.dependencies(t4).map(\.target.name) == [])
            delegate.checkNoDiagnostics()
        }

        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, t2, t3, t5], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T5", "T3", "T2", "T1"])
            #expect(try buildGraph.dependencies(t1).map(\.target.name) == ["T2"])
            #expect(try buildGraph.dependencies(t2).map(\.target.name) == ["T3"])
            #expect(try buildGraph.dependencies(t3).map(\.target.name) == ["T5"])
            #expect(try buildGraph.dependencies(t5).map(\.target.name) == [])
            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func interiorTargetRemovalDoesNotAffectSpecialization() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SDKROOT": "auto",
                                                                                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T2"]
                        ),
                        TestStandardTarget(
                            "T2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SDKROOT": "auto",
                                                                                "SUPPORTED_PLATFORMS": "macosx"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["T3"]
                        ),
                        TestStandardTarget(
                            "T3",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SDKROOT": "auto",
                                                                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        )
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug", activeRunDestination: .anyiOSDevice)
        let t1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T1")!)
        let t3 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T3")!)

        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, t3], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T3", "T1", "T3"])
        let t3ConfiguredAsDependencyOfT2 = buildGraph.allTargets[0]
        let t1Configured = buildGraph.allTargets[1]
        let t3ConfiguredTopLevel = buildGraph.allTargets[2]
        #expect(try buildGraph.dependencies(t1).map(\.target.name) == ["T3"])
        #expect(t1Configured.parameters.overrides["SDKROOT"] == "iphoneos")
        #expect(t3ConfiguredAsDependencyOfT2.parameters.overrides["SDKROOT"] == "macosx")
        #expect(t3ConfiguredTopLevel.parameters.overrides["SDKROOT"] == "iphoneos")
        delegate.checkNoDiagnostics()
    }

    @Test(.requireSDKs(.macOS))
    func buildRequestScopeWithPackages() async throws {
        let core = try await getCore()

        let workspace = try await TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ],
                            dependencies: ["PackageProductWithTransitiveRefs"]
                        ),
                    ]
                ),
                TestPackageProject(
                    "Package",
                    groupTree: TestGroup(
                        "OtherFiles",
                        children: [
                            TestFile("foo.c"),
                            TestFile("libBEGIN.a"),
                            TestFile("libEND.a"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "USE_HEADERMAP": "NO"]),
                    ],
                    targets: [
                        TestPackageProductTarget(
                            "SomePackageProduct",
                            frameworksBuildPhase: TestFrameworksBuildPhase([
                                TestBuildFile(.target("A"))]),
                            dependencies: ["A"]),
                        TestPackageProductTarget(
                            "NestedPackagedProduct",
                            frameworksBuildPhase: TestFrameworksBuildPhase([
                                TestBuildFile(.target("B"))]),
                            dependencies: ["B"]),
                        TestPackageProductTarget(
                            "PackageProductWithTransitiveRefs",
                            frameworksBuildPhase: TestFrameworksBuildPhase([
                                TestBuildFile(.target("SomePackageProduct")),
                                TestBuildFile(.target("NestedPackagedProduct")),
                                TestBuildFile(.target("C")),
                                TestBuildFile(.target("D"))]),
                            dependencies: ["SomePackageProduct", "NestedPackageProduct", "C", "D"]),
                        TestStandardTarget(
                            "A", type: .staticLibrary,
                            buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                        TestStandardTarget(
                            "B", type: .staticLibrary,
                            buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                        TestStandardTarget(
                            "C", type: .staticLibrary,
                            buildPhases: [
                                TestSourcesBuildPhase(["foo.c"]),
                                TestFrameworksBuildPhase([
                                    TestBuildFile(.target("C_Impl"))])],
                            dependencies: ["C_Impl"]),
                        TestStandardTarget(
                            "C_Impl", type: .staticLibrary,
                            buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                        TestStandardTarget(
                            "D", type: .objectFile,
                            buildPhases: [
                                TestSourcesBuildPhase([]),
                                TestFrameworksBuildPhase([
                                    TestBuildFile(.target("E"))])
                            ], dependencies: ["E"]),
                        TestStandardTarget(
                            "E", type: .objectFile,
                            buildPhases: [
                                TestSourcesBuildPhase(["foo.c"])
                            ]),
                    ])
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let t1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "T1")!)

        let somePackageProduct = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "SomePackageProduct")!)
        let packageProductWithTransitiveRefs = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.target(named: "PackageProductWithTransitiveRefs")!)

        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["T1"])
            #expect(try buildGraph.dependencies(t1).map(\.target.name) == [])
        }

        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, packageProductWithTransitiveRefs], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["C_Impl", "C", "E", "D", "PackageProductWithTransitiveRefs", "T1"])
        }

        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [t1, packageProductWithTransitiveRefs, somePackageProduct], dependencyScope: .buildRequest, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["C_Impl", "C", "E", "D", "A", "SomePackageProduct", "PackageProductWithTransitiveRefs", "T1"])
        }
    }
}
