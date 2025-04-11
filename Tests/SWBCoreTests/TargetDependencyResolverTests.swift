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
import SWBMacro

fileprivate enum TargetPlatformSpecializationMode {
    /// The v1 support of target platform specialization that uses SDKROOT=auto and SDK_VARIANT=auto to opt-in.
    case sdkroot

    /// The v2 support that uses an explicit opt-in setting: ALLOW_TARGET_PLATFORM_SPECIALIZATION=YES
    case explicit

    func settings(isPackage: Bool = false, _ additional: [String:String] = [:]) -> [String:String] {
        var dict = additional

        if (self == .sdkroot) || isPackage {
            dict["SDKROOT"] = "auto"
            dict["SDK_VARIANT"] = "auto"
        }
        else {
            dict["ALLOW_TARGET_PLATFORM_SPECIALIZATION"] = "YES"
        }

        return dict
    }
}


// MARK: Test cases for utility methods supporting dependency resolution.

@Suite fileprivate struct DependencyResolutionSupportTests: CoreBasedTests {
    /// Test `BuildRequestContext.potentialOverride(for:buildParameters:)`.
    @Test
    func potentialOverride() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let core = try await self.getCore()
            let workspace = try TestWorkspace("Workspace",
                                              projects: [TestProject("aProject",
                                                                     groupTree: TestGroup("SomeFiles"),
                                                                     targets: [
                                                                        TestStandardTarget("anApp", type: .application),
                                                                     ]
                                                                    )]
            ).load(core)
            let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: localFS, processExecutionCache: .sharedForTesting)

            // Configure all the overrides.
            let overrides = [
                "OVERRIDE": "override_level",
            ]
            let commandLineOverrides = [
                "COMMAND_LINE_OVERRIDE": "commandLineOverride_level",
            ]
            let commandLineConfigOverrides = [
                "COMMAND_LINE_CONFIG_OVERRIDE": "commandLineConfigOverride_level",
            ]
            let commandLineConfigOverridesPath = tmpDirPath.join("commandLine.xcconfig")
            try localFS.write(commandLineConfigOverridesPath, contents: ByteString(stringLiteral: "COMMAND_LINE_CONFIG_PATH_OVERRIDE = commandLineConfigPathOverride_level"))
            let environmentConfigOverrides = [
                "ENV_LINE_CONFIG_OVERRIDE": "environmentLineConfigOverride_level",
            ]
            let environmentConfigOverridesPath = tmpDirPath.join("environment.xcconfig")
            try localFS.write(environmentConfigOverridesPath, contents: ByteString(stringLiteral: "ENV_LINE_CONFIG_PATH_OVERRIDE = environmentLineConfigPathOverride_level"))

            // Create a BuildRequest with all the relevant override levels.
            let buildParameters = BuildParameters(configuration: "Debug", overrides: overrides, commandLineOverrides: commandLineOverrides, commandLineConfigOverridesPath: commandLineConfigOverridesPath, commandLineConfigOverrides: commandLineConfigOverrides, environmentConfigOverridesPath: environmentConfigOverridesPath, environmentConfigOverrides: environmentConfigOverrides)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

            // Check the expected values of the various overrides
            if let override = buildRequestContext.potentialOverride(for: "OVERRIDE", buildParameters: buildParameters) {
                #expect(override.value == "override_level")
                if case .buildParametersOverrides(_) = override.source {} else {
                    Issue.record("Source of value of OVERRIDE was not .buildParametersOverrides but was \(override.source)")
                }
            }
            else {
                Issue.record("Expected value for COMMAND_LINE_OVERRIDE not found")
            }
            if let override = buildRequestContext.potentialOverride(for: "COMMAND_LINE_OVERRIDE", buildParameters: buildParameters) {
                #expect(override.value == "commandLineOverride_level")
                if case .commandLineOverrides(_) = override.source {} else {
                    Issue.record("Source of value of COMMAND_LINE_OVERRIDE was not .commandLineOverrides but was \(override.source)")
                }
            }
            else {
                Issue.record("Expected value for COMMAND_LINE_OVERRIDE not found")
            }
            if let override = buildRequestContext.potentialOverride(for: "COMMAND_LINE_CONFIG_OVERRIDE", buildParameters: buildParameters) {
                #expect(override.value == "commandLineConfigOverride_level")
                if case .commandLineConfigOverrides(_) = override.source {} else {
                    Issue.record("Source of value of COMMAND_LINE_CONFIG_OVERRIDE was not .commandLineConfigOverrides but was \(override.source)")
                }
            }
            else {
                Issue.record("Expected value for COMMAND_LINE_CONFIG_OVERRIDE not found")
            }
            if let override = buildRequestContext.potentialOverride(for: "COMMAND_LINE_CONFIG_PATH_OVERRIDE", buildParameters: buildParameters) {
                #expect(override.value == "commandLineConfigPathOverride_level")
                if case .commandLineConfigOverridesPath(_,_) = override.source {} else {
                    Issue.record("Source of value of COMMAND_LINE_CONFIG_PATH_OVERRIDE was not .commandLineConfigOverridesPath but was \(override.source)")
                }
            }
            else {
                Issue.record("Expected value for COMMAND_LINE_CONFIG_PATH_OVERRIDE not found")
            }
            if let override = buildRequestContext.potentialOverride(for: "ENV_LINE_CONFIG_OVERRIDE", buildParameters: buildParameters) {
                #expect(override.value == "environmentLineConfigOverride_level")
                if case .environmentConfigOverrides(_) = override.source {} else {
                    Issue.record("Source of value of ENV_LINE_CONFIG_OVERRIDE was not .environmentConfigOverrides but was \(override.source)")
                }
            }
            else {
                Issue.record("Expected value for ENV_LINE_CONFIG_OVERRIDE not found")
            }
            if let override = buildRequestContext.potentialOverride(for: "ENV_LINE_CONFIG_PATH_OVERRIDE", buildParameters: buildParameters) {
                #expect(override.value == "environmentLineConfigPathOverride_level")
                if case .environmentConfigOverridesPath(_,_) = override.source {} else {
                    Issue.record("Source of value of ENV_LINE_CONFIG_PATH_OVERRIDE was not .buildParametersOverrides but was \(override.source)")
                }
            }
            else {
                Issue.record("Expected value for ENV_LINE_CONFIG_PATH_OVERRIDE not found")
            }

            // Also check the case where there is no override.
            if let noSuchOverride = buildRequestContext.potentialOverride(for: "NO_SUCH_OVERRIDE", buildParameters: buildParameters) {
                Issue.record("Unexpected value '\(noSuchOverride.value)' for NO_SUCH_OVERRIDE from \(noSuchOverride.source)" )
            }
        }
    }
}


// MARK: Test cases for resolving explicit dependencies

@Suite fileprivate struct ExplicitDependencyResolutionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func twoAppsAndAFramework() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles"),
                                                                 targets: [
                                                                    TestStandardTarget("anApp", type: .application, dependencies: ["aFramework"]),
                                                                    TestStandardTarget("anotherApp", type: .application, dependencies: ["aFramework"]),
                                                                    TestStandardTarget("aFramework", type: .application)])]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Perform some simple correctness tests.
        #expect(project.targets.count == 3)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let appTarget2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
        let fwkTarget  = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[2])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget1, appTarget2], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework", "anApp", "anotherApp"])
        #expect(try buildGraph.dependencies(appTarget1) == [try buildGraph.target(for: fwkTarget)])
        #expect(try buildGraph.dependencies(appTarget2) == [try buildGraph.target(for: fwkTarget)])
        #expect(try buildGraph.dependencies(fwkTarget) == [])

        delegate.checkNoDiagnostics()
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func twoAppsAFrameworkAndDifferentBuildParameters() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles"),
                                                                 targets: [
                                                                    TestStandardTarget("anApp", type: .application, dependencies: ["aFramework"]),
                                                                    TestStandardTarget("anotherApp", type: .application, dependencies: ["aFramework"]),
                                                                    TestStandardTarget("aFramework", type: .application)])]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Perform some simple correctness tests.
        #expect(project.targets.count == 3)

        // Configure the targets and create a BuildRequest.
        let buildParametersmacOS = BuildParameters(configuration: "macOS", overrides: ["SDKROOT": "macosx"])
        let buildParametersiOS = BuildParameters(configuration: "iOS", overrides: ["SDKROOT": "iphoneos"])
        let appTarget1 = BuildRequest.BuildTargetInfo(parameters: buildParametersmacOS, target: project.targets[0])
        let appTarget2 = BuildRequest.BuildTargetInfo(parameters: buildParametersiOS, target: project.targets[1])
        let fwkTargetmacOS = BuildRequest.BuildTargetInfo(parameters: buildParametersmacOS, target: project.targets[2])
        let fwkTargetiOS = BuildRequest.BuildTargetInfo(parameters: buildParametersiOS, target: project.targets[2])
        let buildRequest = BuildRequest(parameters: buildParametersiOS, buildTargets: [appTarget1, appTarget2], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.count == 4)
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework", "anApp", "aFramework", "anotherApp"])
        #expect(dependencyClosure[safe: 0]?.target === project.targets[safe: 2])          // The framework target configured for macOS is first
        #expect(dependencyClosure[safe: 0]?.parameters == buildParametersmacOS)
        #expect(dependencyClosure[safe: 1]?.target === project.targets[safe: 0])          // The first app target is second
        #expect(dependencyClosure[safe: 1]?.parameters == buildParametersmacOS)
        #expect(dependencyClosure[safe: 2]?.target === project.targets[safe: 2])          // The framework target configured for iOS is third
        #expect(dependencyClosure[safe: 2]?.parameters == buildParametersiOS)
        #expect(dependencyClosure[safe: 3]?.target === project.targets[safe: 1])          // The second app target is fourth
        #expect(dependencyClosure[safe: 3]?.parameters == buildParametersiOS)
        #expect(try buildGraph.dependencies(appTarget1) == [try buildGraph.target(for: fwkTargetmacOS)])
        #expect(try buildGraph.dependencies(appTarget2) == [try buildGraph.target(for: fwkTargetiOS)])
        #expect(try buildGraph.dependencies(fwkTargetmacOS) == [])
        #expect(try buildGraph.dependencies(fwkTargetiOS) == [])

        delegate.checkNoDiagnostics()
    }

    @Test
    func missingExplicitDependency() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles"),
                                                                 targets: [
                                                                    TestStandardTarget("anApp", type: .application, dependencies: ["aFramework", "Missing"]),
                                                                    TestStandardTarget("aFramework", type: .application),
                                                                 ]
                                                                )]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Perform some simple correctness tests.
        #expect(project.targets.count == 2)

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let fwkTarget  = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [try buildGraph.target(for: fwkTarget)])

        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.checkDiagnostics(["Skipping target dependency 'Missing' because there is no target with GUID 'Missing' in the workspace (it may exist in a project pointed to by a missing project reference). (in target 'anApp' from project 'aProject')"])
        } else {
            delegate.checkNoDiagnostics()
        }
    }

    @Test
    func excludedExplicitDependency() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
            projects: [TestProject("aProject",
                groupTree: TestGroup("SomeFiles"),
                targets: [
                    TestStandardTarget("anApp", type: .application, buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                        TestBuildConfiguration("Debug-LimitedDeps", buildSettings: [
                            "EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES": "excludedFramework",
                        ]),
                    ], dependencies: ["aFramework", "excludedFramework"]),
                    TestStandardTarget("aFramework", type: .framework),
                    TestStandardTarget("excludedFramework", type: .framework),
                ]
            )]
        ).load(core)

        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Perform some simple correctness tests.
        #expect(project.targets.count == 3)

        // Test the Debug configuration first (which does not exclude any dependencies).
        do {
            let buildParameters = BuildParameters(configuration: "Debug")
            let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            let dependencyClosure = buildGraph.allTargets
            #expect(dependencyClosure.map { $0.target.name } == ["aFramework", "excludedFramework", "anApp"])
        }

        // Next, test the Debug-LimitedDeps configuration (which _does_ exclude a dependency).
        do {
            let buildParameters = BuildParameters(configuration: "Debug-LimitedDeps")
            let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
            let dependencyClosure = buildGraph.allTargets
            #expect(dependencyClosure.map { $0.target.name } == ["aFramework", "anApp"])
        }
    }

    /// Check the behavior of target-specialization through package product targets.
    @Test(.requireSDKs(.iOS, .watchOS))
    func packageProductBasedSpecialization() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [
                                            TestProject("aProject",
                                                        groupTree: TestGroup("SomeFiles"),
                                                        targets: [
                                                            TestAggregateTarget("ALL", dependencies: ["iOSFwk", "watchOSFwk"]),
                                                            TestStandardTarget(
                                                                "iOSFwk",
                                                                type: .framework,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]),
                                                                ],
                                                                dependencies: ["PackageLibProduct"]
                                                            ),
                                                            TestStandardTarget(
                                                                "watchOSFwk",
                                                                type: .framework,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "watchos"]),
                                                                ],
                                                                dependencies: ["PackageLibProduct"]
                                                            ),
                                                        ]
                                                       ),
                                            TestPackageProject("Package",
                                                               groupTree: TestGroup("SomeFile"),
                                                               targets: [
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
                                                                TestStandardTarget("PackageLib", type: .staticLibrary),
                                                               ])]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let allTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [allTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let targetList = Array(buildGraph.allTargets.reversed())
        #expect(targetList.map({ $0.target.name }) == ["ALL", "watchOSFwk", "PackageLibProduct", "PackageLib", "iOSFwk", "PackageLibProduct", "PackageLib"])

        // Check the immediate dependencies lists.
        let allDeps = buildGraph.dependencies(of: targetList[0])
        #expect(allDeps.map({ $0.target.name }) == ["iOSFwk", "watchOSFwk"])
        do {
            let iOSFwk = allDeps[0]
            let clientSettings = buildRequestContext.getCachedSettings(iOSFwk.parameters, target: iOSFwk.target)
            let deps = buildGraph.dependencies(of: iOSFwk)
            #expect(deps.map({ $0.target.name }) == ["PackageLibProduct"])
            guard let dep = deps[safe: 0] else {
                Issue.record()
                return
            }
            let depSettings = buildRequestContext.getCachedSettings(dep.parameters, target: dep.target)
            XCTAssertMatch(depSettings.sdk?.displayName, .prefix("iOS"))
            #expect(depSettings.deploymentTarget == clientSettings.deploymentTarget)
            #expect(depSettings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS) == ["iphoneos", "iphonesimulator"])
        }
        do {
            let watchOSFwk = allDeps[1]
            let clientSettings = buildRequestContext.getCachedSettings(watchOSFwk.parameters, target: watchOSFwk.target)
            let deps = buildGraph.dependencies(of: watchOSFwk)
            #expect(deps.map({ $0.target.name }) == ["PackageLibProduct"])
            guard let dep = deps[safe: 0] else {
                Issue.record()
                return
            }
            let depSettings = buildRequestContext.getCachedSettings(dep.parameters, target: dep.target)
            XCTAssertMatch(depSettings.sdk?.displayName, .prefix("watchOS"))
            #expect(depSettings.deploymentTarget == clientSettings.deploymentTarget)
            #expect(depSettings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS) == ["watchos", "watchsimulator"])
        }

        delegate.checkNoDiagnostics()
    }

    private func _testSpecializationWithPlatformFiltering(_ mode: TargetPlatformSpecializationMode) async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("AppSource.m"),
                        ]
                    ),
                    targets: [
                        TestStandardTarget(
                            "Universal",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: mode.settings(["SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)"])
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    "AppSource.m",
                                ]),
                            ],
                            dependencies: [
                                TestTargetDependency(
                                    "PackageLibProduct",
                                    platformFilters: Set([
                                        PlatformFilter.iOSFilters,
                                        PlatformFilter.watchOSFilters
                                    ].flatMap { $0 })
                                ),
                            ]
                        ),
                    ]),
                TestPackageProject("Package", groupTree: TestGroup("SomeFiles"), targets: [
                    TestPackageProductTarget(
                        "PackageLibProduct",
                        frameworksBuildPhase: TestFrameworksBuildPhase([
                            TestBuildFile(.target("PackageLib"))
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: mode.settings(isPackage: true, ["SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)"])
                            ),
                        ],
                        dependencies: ["PackageLib"]
                    ),
                    TestStandardTarget("PackageLib", type: .staticLibrary),
                ]
                                  )
            ]
        ).load(core)

        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let expectedDependencies: [RunDestinationInfo: [String]] = [
            .iOSSimulator: ["PackageLibProduct"],
            .iOS: ["PackageLibProduct"],
            .macOS: [],
            .watchOS: ["PackageLibProduct"],
            .watchOSSimulator: ["PackageLibProduct"],
            .tvOS: [],
            .tvOSSimulator: [],
        ]

        for (runDestination, expectedDependencies) in expectedDependencies {
            let buildParameters = BuildParameters(
                configuration: "Debug",
                activeRunDestination: runDestination
            )
            let expectedDiagnostics: [String]
            if workspaceContext.userPreferences.enableDebugActivityLogs && expectedDependencies.isEmpty {
                expectedDiagnostics = ["Skipping target dependency 'PackageLibProduct' because its platform filter (ios, watchos) does not match the platform filter of the current context (\(runDestination.platformFilterString)). (in target 'Universal' from project 'aProject')"]
            } else {
                expectedDiagnostics = []
            }
            let buildGraph = try await computeBuildGraph(
                of: workspace,
                context: workspaceContext,
                buildRequestContext: buildRequestContext,
                buildParameters: buildParameters,
                expectedDiagnostics: expectedDiagnostics,
                type: .dependency
            )

            let universalTarget = try #require(buildGraph.allTargets.first{ $0.target.name == "Universal" })
            let deps = buildGraph.dependencies(of: universalTarget)
            #expect(deps.map{ $0.target.name } == expectedDependencies)
        }
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func specializationWithPlatformFilteringV1() async throws {
        try await _testSpecializationWithPlatformFiltering(.sdkroot)
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func specializationWithPlatformFilteringV2() async throws {
        try await _testSpecializationWithPlatformFiltering(.explicit)
    }

    private func _testSpecializationWithCommandLineOverrides(_ mode: TargetPlatformSpecializationMode) async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [
            TestProject("aProject",
                        groupTree: TestGroup("SomeFiles"),
                        targets: [
                            TestStandardTarget("BestTarget", type: .framework, buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: mode.settings(["SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"]))])
                        ])
        ]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS, activeArchitecture: "x86_64", overrides: [:], commandLineOverrides: ["SDKROOT": "iphonesimulator\(core.loadSDK(.iOS).version)"], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)
        let allTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [allTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        for type in TargetGraphFactory.GraphType.allCases {
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)
            let target = buildGraph.allTargets.first!
            let settings = buildRequestContext.getCachedSettings(target.parameters, target: target.target)

            #expect(settings.platform?.displayName == "iOS Simulator")

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func specializationWithCommandLineOverridesV1() async throws {
        try await _testSpecializationWithCommandLineOverrides(.sdkroot)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func specializationWithCommandLineOverridesV2() async throws {
        try await _testSpecializationWithCommandLineOverrides(.explicit)
    }

    /// Check that we don't create unnecessary specialized targets, just because one was created without specialization active.
    @Test
    func packageProductBasedSpecializationUniquing() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [
                                            TestProject("aProject",
                                                        groupTree: TestGroup("SomeFiles"),
                                                        targets: [
                                                            // We check specialization by having both direct dependencies and ones from a consumer (and we have two instances, to check that order doesn't matter).
                                                            TestAggregateTarget("ALL", dependencies: ["Lib", "SpecializingConsumer", "Lib2"]),
                                                            // This is an intermediate target, used to drive specialization.
                                                            TestStandardTarget(
                                                                "SpecializingConsumer",
                                                                type: .framework,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]),
                                                                ],
                                                                dependencies: ["PackageProduct"]
                                                            ),
                                                        ]
                                                       ),
                                            TestPackageProject("Package",
                                                               groupTree: TestGroup("SomeFiles"),
                                                               targets: [
                                                                TestPackageProductTarget(
                                                                    "PackageProduct",
                                                                    frameworksBuildPhase: TestFrameworksBuildPhase([
                                                                        TestBuildFile(.target("Lib")),
                                                                        TestBuildFile(.target("Lib2"))]),
                                                                    dependencies: ["Lib", "Lib2"]
                                                                ),
                                                                // These are the targets we are testing specialization of.
                                                                TestStandardTarget("Lib", type: .staticLibrary),
                                                                TestStandardTarget("Lib2", type: .staticLibrary),
                                                               ]
                                                              ),
                                          ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let allTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [allTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        for type in TargetGraphFactory.GraphType.allCases {
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)
            let targetList = Array(buildGraph.allTargets.reversed())
            if type == .linkage { // <rdar://problem/61461826> `TargetLinkageGraph.allTargets` isn't sorted in dependency order
                #expect(targetList.map({ $0.target.name }).sorted() == ["ALL", "Lib", "Lib2", "PackageProduct", "SpecializingConsumer"])
            } else {
                #expect(targetList.map({ $0.target.name }) == ["ALL", "SpecializingConsumer", "PackageProduct", "Lib2", "Lib"])
            }

            delegate.checkNoDiagnostics()
        }
    }

    func setupWatchOSProject(dynamic: Bool) async throws -> (SWBCore.Project, WorkspaceContext) {
        let core = try await getCore()
        let packageProductTarget: any TestTarget
        if dynamic {
            packageProductTarget = TestStandardTarget(
                "PackageLibProduct",
                type: .dynamicLibrary,
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator",
                    ]),
                ],
                buildPhases: [
                    TestFrameworksBuildPhase([
                        TestBuildFile(.target("PackageLib"))]),
                    TestSourcesBuildPhase([
                        "Package.m",
                    ]),
                ],
                dependencies: ["PackageLib"])
        } else {
            packageProductTarget = TestPackageProductTarget(
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
            )
        }

        let watchosSDKVersion = "5.2"
        let workspace = try await TestWorkspace(
            "Workspace",
            projects: [
                TestProject("aProject",
                            groupTree: TestGroup(
                                "Sources", path: "Sources",
                                children: [
                                    // iOS app files
                                    TestFile("iosApp/main.m"),
                                    TestFile("iosApp/CompanionClass.swift"),
                                    TestFile("iosApp/Main.storyboard"),
                                    TestFile("iosApp/Assets.xcassets"),
                                    TestFile("iosApp/Info.plist"),

                                    // watchOS app files
                                    TestFile("watchosApp/Interface.storyboard"),
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
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "CODE_SIGN_IDENTITY": "Apple Development",
                                        "SDKROOT": "iphoneos",
                                        "SWIFT_VERSION": swiftVersion,
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
                                            "Main.storyboard",
                                            "iosApp/Assets.xcassets",
                                        ]),
                                        TestCopyFilesBuildPhase([
                                            "Watchable WatchKit App.app",
                                        ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                                               ),
                                    ],
                                    dependencies: ["Watchable WatchKit App", "PackageLibProduct"]
                                ),
                                TestStandardTarget(
                                    "Watchable WatchKit App",
                                    type: .watchKitApp,
                                    buildConfigurations: [
                                        TestBuildConfiguration(
                                            "Debug",
                                            buildSettings: [
                                                "ARCHS[sdk=watchos*]": "armv7k",
                                                "ARCHS[sdk=watchsimulator*]": "i386",
                                                "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                                                "INFOPLIST_FILE": "Sources/watchosApp/Info.plist",
                                                "SDKROOT": "watchos",
                                                "SKIP_INSTALL": "YES",
                                                "TARGETED_DEVICE_FAMILY": "4",
                                                "WATCHOS_DEPLOYMENT_TARGET": watchosSDKVersion,
                                            ]),
                                    ],
                                    buildPhases: [
                                        TestResourcesBuildPhase([
                                            "Interface.storyboard",
                                            "watchosApp/Assets.xcassets",
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
                                        TestBuildConfiguration(
                                            "Debug",
                                            buildSettings: [
                                                "ARCHS[sdk=watchos*]": "armv7k",
                                                "ARCHS[sdk=watchsimulator*]": "i386",
                                                "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                                                "INFOPLIST_FILE": "Sources/watchosExtension/Info.plist",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                                                "SDKROOT": "watchos",
                                                "SKIP_INSTALL": "YES",
                                                "SWIFT_VERSION": swiftVersion,
                                                "TARGETED_DEVICE_FAMILY": "4",
                                                "WATCHOS_DEPLOYMENT_TARGET": watchosSDKVersion,
                                            ]),
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "Controller.m",
                                            "watchosExtension/WatchClass.swift",
                                        ]),
                                        TestResourcesBuildPhase([
                                            "Interface.storyboard",
                                            "watchosExtension/Assets.xcassets",
                                        ]),
                                    ],
                                    dependencies: ["PackageLibProduct"]
                                ),
                            ]),
                TestPackageProject(
                    "Package",
                    groupTree: TestGroup(
                        "Sources", path: "Sources",
                        children: [
                            TestFile("Package.m"),
                        ]),
                    targets: [
                        packageProductTarget,
                        TestStandardTarget("PackageLib", type: .staticLibrary),
                    ])
            ]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        return (workspace.projects[0], workspaceContext)
    }

    // Compute dependency graph for phone app with embedded watch app and verify that a package product used by both will be specialized accordingly and build twice.
    func instantiateMultiplePackageProductsTest(dynamicPackageProduct: Bool) async throws {
        let (project, workspaceContext) = try await setupWatchOSProject(dynamic: dynamicPackageProduct)

        let buildParameters = BuildParameters(configuration: "Debug")
        let allTargets = project.targets.filter { $0.name == "Watchable" }.map { BuildRequest.BuildTargetInfo(parameters: buildParameters, target: $0) }
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: allTargets, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let targetList = Array(buildGraph.allTargets.reversed())
        #expect(targetList.map({ $0.target.name }) == ["Watchable", "PackageLibProduct", "PackageLib", "Watchable WatchKit App", "Watchable WatchKit Extension", "PackageLibProduct", "PackageLib"])

        if targetList.count < 6 {
            Issue.record("cannot continue with incomplete target list")
            return
        }
        let watchProduct = targetList[5]
        let watchProductSettings = buildRequestContext.getCachedSettings(watchProduct.parameters, target: watchProduct.target)
        XCTAssertMatch(watchProductSettings.sdk?.displayName, .prefix("watchOS"))
        #expect(watchProductSettings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS) == ["watchos", "watchsimulator"])
        #expect(watchProductSettings.globalScope.evaluate(BuiltinMacros.TOOLCHAINS).map { Path($0).basename } == [])

        let phoneProduct = targetList[1]
        let phoneProductSettings = buildRequestContext.getCachedSettings(phoneProduct.parameters, target: phoneProduct.target)
        XCTAssertMatch(phoneProductSettings.sdk?.displayName, .prefix("iOS"))
        #expect(phoneProductSettings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS) == ["iphoneos", "iphonesimulator"])
        #expect(phoneProductSettings.globalScope.evaluate(BuiltinMacros.TOOLCHAINS).map { Path($0).basename } == [])

        delegate.checkNoDiagnostics()
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func instantiateMultiplePackageProductsStatic() async throws {
        try await instantiateMultiplePackageProductsTest(dynamicPackageProduct: false)
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func instantiateMultiplePackageProductsDynamic() async throws {
        try await instantiateMultiplePackageProductsTest(dynamicPackageProduct: true)
    }

    @Test
    func toolchainOverridesDoNotConflictWithSpecialization() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [TestPackageProject("aProject",
                                                                        groupTree: TestGroup("SomeFiles"),
                                                                        targets: [
                                                                            TestAggregateTarget("ALL", dependencies: ["iOSFwk", "PackageLibProduct"]),
                                                                            TestStandardTarget(
                                                                                "iOSFwk",
                                                                                type: .framework,
                                                                                buildConfigurations: [
                                                                                    TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]),
                                                                                ],
                                                                                dependencies: ["PackageLibProduct"]
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
                                                                                dependencies: ["PackageLib"]
                                                                            ),
                                                                            TestStandardTarget("PackageLib", type: .staticLibrary),
                                                                        ]
                                                                       )]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug", activeRunDestination: RunDestinationInfo.macOS, toolchainOverride: "com.apple.dt.toolchain.OSX10_15")
        let allTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let packageTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[2])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [allTarget, packageTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        for type in TargetGraphFactory.GraphType.allCases {
            // Get the dependency closure for the build request and examine it.
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            _ = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)
            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func macCatalystSpecialization() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [TestProject("aProject", groupTree: TestGroup("SomeFiles"), targets: [
            TestAggregateTarget("ALL", dependencies: ["macOSFwk", "macCatalystFwk"]),
            TestStandardTarget(
                "macOSFwk",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]),
                ],
                dependencies: ["PackageLibProduct"]
            ),
            TestStandardTarget(
                "macCatalystFwk",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SDK_VARIANT": MacCatalystInfo.sdkVariantName]),
                ],
                dependencies: ["PackageLibProduct"]
            ),
        ]), TestPackageProject("Package", groupTree: TestGroup("SomeFiles"), targets: [
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
            TestStandardTarget("PackageLib", type: .staticLibrary),
        ])]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let runDestination = RunDestinationInfo.macCatalyst
        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)
        let allTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [allTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let targetList = Array(buildGraph.allTargets.reversed())
        #expect(targetList.map({ $0.target.name }) == ["ALL", "macCatalystFwk", "PackageLibProduct", "PackageLib", "macOSFwk", "PackageLibProduct", "PackageLib"])

        guard let macCatalystFwk = targetList.filter({ $0.target.name == "macCatalystFwk" }).first else {
            Issue.record("No macCatalystFwk")
            return
        }
        let deps = buildGraph.dependencies(of: macCatalystFwk)
        guard let macCatalystPackageProduct = deps.filter({ $0.target.name == "PackageLibProduct" }).first else {
            Issue.record("No PackageLibProduct")
            return
        }
        let macCatalystPackageProductSettings = buildRequestContext.getCachedSettings(macCatalystPackageProduct.parameters, target: macCatalystPackageProduct.target)
        #expect(macCatalystPackageProductSettings.platform?.displayName == "macOS")
        #expect(macCatalystPackageProductSettings.sdkVariant?.name == MacCatalystInfo.sdkVariantName)

        guard let macOSFwk = targetList.filter({ $0.target.name == "macOSFwk" }).first else {
            Issue.record("No macOSFwk")
            return
        }
        let deps2 = buildGraph.dependencies(of: macOSFwk)
        guard let macOSPackageProduct = deps2.filter({ $0.target.name == "PackageLibProduct" }).first else {
            Issue.record("No PackageLibProduct")
            return
        }
        let macOSPackageProductSettings = buildRequestContext.getCachedSettings(macOSPackageProduct.parameters, target: macOSPackageProduct.target)
        #expect(macOSPackageProductSettings.platform?.displayName == "macOS")
        #expect(macOSPackageProductSettings.sdkVariant?.name == "macos")

        delegate.checkNoDiagnostics()
    }

    func basicPackage(linkage: TestStandardTarget.TargetType = .staticLibrary, additionalBuildSettings: [String:String] = [:]) -> TestProject {
        return TestPackageProject("aPackage", groupTree: TestGroup("Package"), targets: [
            TestPackageProductTarget(
                "PackageLibProduct",
                frameworksBuildPhase: TestFrameworksBuildPhase([
                    TestBuildFile(.target("PackageLib"))]),
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ].merging(additionalBuildSettings, uniquingKeysWith: { a, b in a })),
                ],
                dependencies: ["PackageLib"]
            ),
            TestStandardTarget("PackageLib", type: linkage)
        ])
    }

    func packageWorkspace(with targets: [any TestTarget], linkage: TestStandardTarget.TargetType = .staticLibrary, additionalBuildSettings: [String:String] = [:], dependenciesForTopLevelAggregateTarget: [String]? = nil) async throws -> (SWBCore.Workspace, WorkspaceContext) {
        let core = try await getCore()
        let allTargets = [TestAggregateTarget("ALL", dependencies: dependenciesForTopLevelAggregateTarget ?? targets.map { $0.name })] + targets.map { $0 as (any TestTarget) }
        let workspace = try TestWorkspace("Workspace", projects: [TestProject("aProject", groupTree: TestGroup("SomeFiles"), targets: allTargets), basicPackage(linkage: linkage, additionalBuildSettings: additionalBuildSettings)]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        return (workspace, workspaceContext)
    }

    fileprivate func computeBuildGraph(of workspace: SWBCore.Workspace, context: WorkspaceContext, buildRequestContext: BuildRequestContext, buildCommand: BuildCommand? = nil, buildParameters: BuildParameters, additionalTargets: [SWBCore.Target] = [], diagnosticFormat: Diagnostic.LocalizedDescriptionFormat = .debugWithoutBehavior, expectedDiagnostics: [String] = [], type: TargetGraphFactory.GraphType, useImplicitDependencies: Bool = false, skipDependencies: Bool = false) async throws -> any TargetGraph {
        let allTarget = workspace.projects[0].targets[0]
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: ([allTarget] + additionalTargets).map { BuildRequest.BuildTargetInfo(parameters: buildParameters, target:$0) }, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: useImplicitDependencies, useDryRun: false, buildCommand: buildCommand ?? .build(style: .buildOnly, skipDependencies: skipDependencies))

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspace)
        let buildGraph = await TargetGraphFactory(workspaceContext: context, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)
        delegate.checkDiagnostics(format: diagnosticFormat, expectedDiagnostics)
        return buildGraph
    }

    @discardableResult private func verifyPlatform(for clientTargetName: String, buildGraph: any TargetGraph, buildRequestContext: BuildRequestContext, graphType: TargetGraphFactory.GraphType) -> ConfiguredTarget? {
        let targetList = Array(buildGraph.allTargets.reversed())
        guard let clientTarget = targetList.filter({ $0.target.name == clientTargetName }).first else {
            Issue.record("No client target for name '\(clientTargetName)'")
            return nil
        }
        let clientTargetSettings = buildRequestContext.getCachedSettings(clientTarget.parameters, target: clientTarget.target)
        let deps = buildGraph.dependencies(of: clientTarget)
        guard let packageProduct = deps.filter({ $0.target.name == "PackageLibProduct" }).first else {
            Issue.record("No PackageLibProduct for client target '\(clientTargetName)'")
            return nil
        }
        let packageProductSettings = buildRequestContext.getCachedSettings(packageProduct.parameters, target: packageProduct.target)
        #expect(packageProductSettings.platform?.displayName == clientTargetSettings.platform?.displayName)
        return packageProduct
    }

    func frameworkTarget(name: String, buildSettings: [String:String]) -> TestStandardTarget {
        return TestStandardTarget(
            name,
            type: .framework,
            buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: buildSettings) ],
            buildPhases: [ TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct"))]) ],
            dependencies: ["PackageLibProduct"]
        )
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func aggregatesMayOnlyLeadToASingleSetOfSpecializations() async throws {
        let targets: [any TestTarget] = [
            TestStandardTarget(
                "BestFramework",
                type: .framework,
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]) ],
                dependencies: ["Aggregate"]
            ),
            TestAggregateTarget(
                "Aggregate",
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                dependencies: ["PackageLibProduct"]
            ),
        ]

        let (workspace, workspaceContext) = try await packageWorkspace(with: targets, linkage: .staticLibrary)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .watchOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            _ = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, expectedDiagnostics: ["unsupported configuration: the aggregate target \'Aggregate\' has package dependencies, but targets that build for different platforms depend on it"], type: type)
        }
    }

    @Test
    func aggregateErrorIsNotEmittedIfThereAreNoPackageDependencies() async throws {
        let targets: [any TestTarget] = [
            TestStandardTarget(
                "BestFramework",
                type: .framework,
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]) ],
                dependencies: ["Aggregate"]
            ),
            TestAggregateTarget(
                "Aggregate",
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                dependencies: []
            ),
        ]

        let (workspace, workspaceContext) = try await packageWorkspace(with: targets, linkage: .staticLibrary)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .watchOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            _ = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, expectedDiagnostics: [], type: type)
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func aggregateTargetsAreTransparentToPlatformSpecialization() async throws {
        let targets: [any TestTarget] = [
            TestStandardTarget(
                "BestFramework",
                type: .framework,
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "OTHER_LDFLAGS": "-framework Dep" ]) ],
                dependencies: ["Intermediate"]
            ),
            TestAggregateTarget(
                "Intermediate",
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                dependencies: ["Aggregate"]
            ),
            TestAggregateTarget(
                "Aggregate",
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                dependencies: ["PackageLibProduct"]
            ),
            TestAggregateTarget(
                "Aggregate2",
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                dependencies: ["BestFramework"]
            ),
            TestStandardTarget(
                "SomeDependency",
                type: .framework,
                buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "PRODUCT_NAME": "Dep" ]) ]
            )
        ]

        let (workspace, workspaceContext) = try await packageWorkspace(with: targets, linkage: .staticLibrary, dependenciesForTopLevelAggregateTarget: ["Aggregate2"])
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .watchOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, type: type, useImplicitDependencies: true)

            let frameworkConfiguredTarget = try #require(buildGraph.allTargets.filter { $0.target.name == "BestFramework" }.first)
            let fwkSettings = buildRequestContext.getCachedSettings(frameworkConfiguredTarget.parameters, target: frameworkConfiguredTarget.target)
            #expect(fwkSettings.platform?.name == "iphoneos")

            // Target dependency graph should contain implicit dependency on Dep.framework
            if type == .dependency {
                let deps = buildGraph.dependencies(of: frameworkConfiguredTarget)
                #expect(deps.map { $0.target.name } == ["Intermediate", "SomeDependency"])
            }

            let packageProducts = buildGraph.allTargets.filter { $0.target.name == "PackageLibProduct" }
            #expect(packageProducts.count == 1)
            let packageLibProductConfiguredTarget = try #require(packageProducts.first)
            let pkgSettings = buildRequestContext.getCachedSettings(packageLibProductConfiguredTarget.parameters, target: packageLibProductConfiguredTarget.target)
            #expect(pkgSettings.platform?.name == fwkSettings.platform?.name)
        }
    }

    // Check that we are always building package products for the same platform as the client.
    @Test(.requireSDKs(.macOS, .iOS, .tvOS, .watchOS))
    func platformSpecialization() async throws {
        let core = try await getCore()
        var testPlatforms = [SWBCore.Platform]()
        let targets = core.platformRegistry.platforms.filter({ !$0.isSimulator }).compactMap { platform in
            if let sdkCanonicalName = platform.sdkCanonicalName, core.sdkRegistry.lookup(sdkCanonicalName) != nil {
                testPlatforms.append(platform)
                return frameworkTarget(name: "\(platform.name)Fwk", buildSettings: ["SDKROOT": sdkCanonicalName])
            }
            return nil
        } + [frameworkTarget(name: "McFwk", buildSettings: ["SDKROOT": "macosx",
                                                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName])]
        #expect(testPlatforms.count > 0)      // ensure this test doesn't pass just because we somehow ended up with no platforms with valid SDKs

        let linkages: [TestStandardTarget.TargetType] = [.staticLibrary, .dynamicLibrary]
        for linkage in linkages {
            let (workspace, workspaceContext) = try await packageWorkspace(with: targets, linkage: linkage)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            guard let packageLibProductTarget = workspace.projects.last?.targets.filter({ $0.name == "PackageLibProduct" }).first else {
                Issue.record("No PackageLibProduct")
                return
            }
            for runDestination in [RunDestinationInfo.iOS, RunDestinationInfo.iOSSimulator, RunDestinationInfo.macOS, RunDestinationInfo.watchOS, RunDestinationInfo.tvOS, RunDestinationInfo.macCatalyst] {
                let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

                for type in TargetGraphFactory.GraphType.allCases {
                    //let runDestinationString = "\(runDestination.sdk)" + (runDestination.sdkVariant.map({ $0 != runDestination.sdk ? "-\($0)" : "" }) ?? "")
                    //try await XCTContext.runActivity(named: "graphType:\(type) runDestination:\(runDestinationString) linkage:\(linkage)", block: { _ in
                        let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, additionalTargets: [packageLibProductTarget], type: type)

                        for platform in testPlatforms {
                            verifyPlatform(for: "\(platform.name)Fwk", buildGraph: buildGraph, buildRequestContext: buildRequestContext, graphType: type)
                        }

                        // Verify the MacCatalyst framework target gets linked with the correct package.
                        verifyPlatform(for: "McFwk", buildGraph: buildGraph, buildRequestContext: buildRequestContext, graphType: type)
                    //})
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func platformSpecializationWithOverrides() async throws {
        let fwkTarget = TestStandardTarget(
            "iOSFwk",
            type: .framework,
            buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]) ],
            buildPhases: [ TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct"))]) ],
            dependencies: ["PackageLibProduct"]
        )
        let (workspace, workspaceContext) = try await packageWorkspace(with: [fwkTarget])
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        guard let packageLibProductTarget = workspace.projects.last?.targets.filter({ $0.name == "PackageLibProduct" }).first else {
            Issue.record("No PackageLibProduct")
            return
        }

        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: ["SDKROOT": "watchos"], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, additionalTargets: [packageLibProductTarget], type: type)
            #expect(buildGraph.allTargets.filter { $0.target.name == "PackageLibProduct" }.count == 1)
            verifyPlatform(for: fwkTarget.name, buildGraph: buildGraph, buildRequestContext: buildRequestContext, graphType: type)
        }
    }

    @Test
    func platformSpecializationWithCommandLineOverrides() async throws {
        let fwkTarget = TestStandardTarget(
            "iOSFwk",
            type: .framework,
            buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]) ],
            buildPhases: [ TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct"))]) ],
            dependencies: ["PackageLibProduct"]
        )
        let (workspace, workspaceContext) = try await packageWorkspace(with: [fwkTarget])
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        guard let packageLibProductTarget = workspace.projects.last?.targets.filter({ $0.name == "PackageLibProduct" }).first else {
            Issue.record("No PackageLibProduct")
            return
        }

        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: ["SDKROOT": "watchos"], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, additionalTargets: [packageLibProductTarget], type: type)
            #expect(buildGraph.allTargets.filter { $0.target.name == "PackageLibProduct" }.count == 1)
            verifyPlatform(for: fwkTarget.name, buildGraph: buildGraph, buildRequestContext: buildRequestContext, graphType: type)
        }
    }

    @Test
    func platformSpecializationWithCommandLineConfigOverrides() async throws {
        let fwkTarget = TestStandardTarget(
            "iOSFwk",
            type: .framework,
            buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]) ],
            buildPhases: [ TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct"))]) ],
            dependencies: ["PackageLibProduct"]
        )
        let (workspace, workspaceContext) = try await packageWorkspace(with: [fwkTarget])
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        guard let packageLibProductTarget = workspace.projects.last?.targets.filter({ $0.name == "PackageLibProduct" }).first else {
            Issue.record("No PackageLibProduct")
            return
        }

        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: ["SDKROOT": "watchos"], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, additionalTargets: [packageLibProductTarget], type: type)
            #expect(buildGraph.allTargets.filter { $0.target.name == "PackageLibProduct" }.count == 1)
            verifyPlatform(for: fwkTarget.name, buildGraph: buildGraph, buildRequestContext: buildRequestContext, graphType: type)
        }
    }

    @Test
    func platformSpecializationWithEnvironmentConfigOverrides() async throws {
        let fwkTarget = TestStandardTarget(
            "iOSFwk",
            type: .framework,
            buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"]) ],
            buildPhases: [ TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct"))]) ],
            dependencies: ["PackageLibProduct"]
        )
        let (workspace, workspaceContext) = try await packageWorkspace(with: [fwkTarget])
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        guard let packageLibProductTarget = workspace.projects.last?.targets.filter({ $0.name == "PackageLibProduct" }).first else {
            Issue.record("No PackageLibProduct")
            return
        }

        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: ["SDKROOT": "watchos"], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, additionalTargets: [packageLibProductTarget], type: type)
            #expect(buildGraph.allTargets.filter { $0.target.name == "PackageLibProduct" }.count == 1)
            verifyPlatform(for: fwkTarget.name, buildGraph: buildGraph, buildRequestContext: buildRequestContext, graphType: type)
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func specializationRespectsSupportedPlatforms() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("workspace", projects: [
            TestPackageProject("aPackage", groupTree: TestGroup("Group"), targets: [
                TestStandardTarget("Library", type: .framework, buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ])
                ], dependencies: ["Tool", "WatchApp"]),
                TestStandardTarget("Tool", type: .commandLineTool, buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "macosx",
                    ])
                ]),
                TestStandardTarget("WatchApp", type: .watchKitApp, buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "watchos watchsimulator",
                    ])
                ]),
            ]),
        ]).load(core)

        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, type: type)

            let expectedSDKs = [
                "Library": "iphoneos",  // matches run destination
                "Tool": "macosx",       // is confined to macOS by supported platforms
                "WatchApp": "watchos",  // supports a single conceptual platform
            ]

            for sdk in expectedSDKs {
                let target = try #require(buildGraph.targets(named: sdk.0).first)
                let settings = buildRequestContext.getCachedSettings(target.parameters, target: target.target)
                #expect(try settings.sdk?.path == core.sdkRegistry.lookup(sdk.1, activeRunDestination: nil)?.path)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func specializationRespectsSupportedPlatformsWithSDKROOTOverride() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("workspace", projects: [
            TestPackageProject("aPackage", groupTree: TestGroup("Group"), targets: [
                TestStandardTarget("Library", type: .framework, buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "iphonesimulator iphoneos watchos appletvos",
                    ])
                ], dependencies: ["Tool"]),
                TestStandardTarget("Tool", type: .commandLineTool, buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "iphonesimulator iphoneos watchos appletvos",
                    ])
                ])
            ]),
        ]).load(core)

        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let macOS_SDKPath = try #require(workspaceContext.core.sdkRegistry.lookup("macosx", activeRunDestination: nil)?.path)
        let buildParameters = [
            BuildParameters(action: .build, configuration: "Debug", activeRunDestination: nil, activeArchitecture: nil, overrides: [:], commandLineOverrides: ["SDKROOT": "macosx"], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil),
            BuildParameters(action: .build, configuration: "Debug", activeRunDestination: nil, activeArchitecture: nil, overrides: [:], commandLineOverrides: ["SDKROOT": macOS_SDKPath.str], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil),
        ]

        for parameters in buildParameters {
            for type in TargetGraphFactory.GraphType.allCases {
                let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: parameters, expectedDiagnostics: ["Target \'Library\' does not support any of the imposed platforms \'macosx\' and a single platform could not be chosen from its own supported platforms \'iphonesimulator iphoneos watchos appletvos\'. For backwards compatibility, it will be built for macOS.", "Target \'Tool\' does not support any of the imposed platforms \'macosx\' and a single platform could not be chosen from its own supported platforms \'iphonesimulator iphoneos watchos appletvos\'. For backwards compatibility, it will be built for macOS."], type: type)

                let expectedSDKs = [
                    "Library": "macosx",
                    "Tool": "macosx",
                ]

                for sdk in expectedSDKs {
                    let target = try #require(buildGraph.targets(named: sdk.0).first)
                    let settings = buildRequestContext.getCachedSettings(target.parameters, target: target.target)
                    #expect(try settings.sdk?.path == core.sdkRegistry.lookup(sdk.1, activeRunDestination: nil)?.path)
                }
            }
        }
    }

    @Test
    func previewBuildsUseDynamicTargetReference() async throws {
        let project = TestPackageProject("aPackage", groupTree: TestGroup("Package"), targets: [
            TestPackageProductTarget(
                "PackageLibProduct",
                frameworksBuildPhase: TestFrameworksBuildPhase([
                    TestBuildFile(.target("PackageLib"))]),
                dynamicTargetVariantName: "PackageLibProduct-dynamic",
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
                ],
                dependencies: ["PackageLib"]
            ),
            TestStandardTarget("PackageLib", type: .objectFile),
            TestStandardTarget(
                "PackageLibProduct-dynamic",
                type: .framework,
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
                ],
                buildPhases: [TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib"))])],
                dependencies: ["PackageLib"]
            ),
        ])
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [project]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        // This adds `PACKAGE_BUILD_DYNAMICALLY` as an override to activate dynamic variants of targets.
        let buildParametersWithOverrides = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: ["PACKAGE_BUILD_DYNAMICALLY": "YES"], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        for type in TargetGraphFactory.GraphType.allCases {
            let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, type: type)
            #expect(!buildGraph.allTargets.map { $0.target.name }.contains("PackageLibProduct-dynamic"), "regular builds should not build the dynamic target")

            let previewBuildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildCommand: .preview(style: .dynamicReplacement), buildParameters: buildParametersWithOverrides, type: type)
            #expect(previewBuildGraph.allTargets.map { $0.target.name }.contains("PackageLibProduct-dynamic"), "preview builds should build the dynamic target")

            let previewBuildGraphWithoutOverrides = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildCommand: .preview(style: .dynamicReplacement), buildParameters: buildParameters, type: type)
            #expect(!previewBuildGraphWithoutOverrides.allTargets.map { $0.target.name }.contains("PackageLibProduct-dynamic"), "preview builds without overrides should not build the dynamic target")
        }
    }

    @Test
    func explicitDependenciesUseDynamicTargets() async throws {
        let project = TestPackageProject("aPackage", groupTree: TestGroup("Package"), targets: [
            TestPackageProductTarget(
                "PackageLibProduct",
                frameworksBuildPhase: TestFrameworksBuildPhase([
                    TestBuildFile(.target("PackageLib"))]),
                dynamicTargetVariantName: "PackageLibProduct-dynamic",
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
                ],
                dependencies: ["PackageLib"]
            ),
            TestStandardTarget("PackageLib", type: .objectFile),
            TestStandardTarget(
                "PackageLibProduct-dynamic",
                type: .framework,
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ]),
                ],
                buildPhases: [TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib"))])],
                dependencies: ["PackageLib"]
            ),
            TestStandardTarget(
                "ThePackage",
                type: .commandLineTool,
                dependencies: ["PackageLibProduct"]
            ),
        ])
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [project]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // This adds `PACKAGE_BUILD_DYNAMICALLY` as an override to activate dynamic variants of targets.
        let buildParametersWithOverrides = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.iOS, activeArchitecture: nil, overrides: ["PACKAGE_BUILD_DYNAMICALLY": "YES"], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        let buildRequest = BuildRequest(parameters: buildParametersWithOverrides, buildTargets: (workspace.projects[0].targets).map { BuildRequest.BuildTargetInfo(parameters: buildParametersWithOverrides, target:$0) }, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false, buildCommand: .preview(style: .dynamicReplacement))

        let resolver = TargetDependencyResolver(
            workspaceContext: workspaceContext,
            buildRequest: buildRequest,
            buildRequestContext: buildRequestContext,
            delegate: EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace))

        let configuredTarget = try ConfiguredTarget(
            parameters: buildParametersWithOverrides,
            target: #require(workspace.projects[0].targets.last)
        )
        let dynamicTarget = try #require(workspace.projects[0].targets.first(where: { $0.name == "PackageLibProduct-dynamic" }))
        let result: [String] = await resolver.resolver.explicitDependencies(for: configuredTarget).map(\.guid)
        let expected: [String] = [dynamicTarget.guid]
        #expect(result == expected)
    }

    @Test
    func implicitDependencyDoesNotShadowPackageProductDependency() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [
            TestProject("Simple", groupTree: TestGroup("Simple"), targets: [
                TestAggregateTarget("Best", dependencies: ["App", "Package2"]),
                TestStandardTarget("App", type: .application, buildPhases: [ TestFrameworksBuildPhase([TestBuildFile(.target("Package"))]) ], dependencies: ["Package"]),
                TestStandardTarget("Package2", type: .commandLineTool, buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Package"]) ]),
            ]),
            TestPackageProject("Package", groupTree: TestGroup("Package"), targets: [
                TestPackageProductTarget("Package", frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib"))]), buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Package"]) ], dependencies: ["PackageLib"]),
                TestStandardTarget("PackageLib", type: .objectFile)
            ]),
        ]).load(core)

        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let buildParameters = BuildParameters(configuration: "Debug")
        let buildGraph = try await computeBuildGraph(of: workspace, context: workspaceContext, buildRequestContext: buildRequestContext, buildParameters: buildParameters, type: TargetGraphFactory.GraphType.linkage)

        let app = try #require(buildGraph.allTargets.first { $0.target.name == "App" })
        let deps = buildGraph.dependencies(of: app)
        #expect(deps.map { $0.target.name } == ["Package"]) // Both the CLI tool and the package have the same product name, but different target names.
    }

    func checkTarget(_ graphType: TargetGraphFactory.GraphType, _ buildRequestContext: BuildRequestContext, _ buildGraph: any TargetGraph, name: String, expectedPlatform: String, sourceLocation: SourceLocation = #_sourceLocation) throws {

        let matchedTargets = buildGraph.allTargets.filter { $0.target.name == name }
        #expect(matchedTargets.count == 1)
        let target = try #require(matchedTargets.only, sourceLocation: sourceLocation)
        let settings = buildRequestContext.getCachedSettings(target.parameters, target: target.target)
        #expect(settings.target?.name == name, sourceLocation: sourceLocation)
        #expect(settings.platform?.name == expectedPlatform, sourceLocation: sourceLocation)
    }

    func checkTarget(_ graphType: TargetGraphFactory.GraphType, _ buildRequestContext: BuildRequestContext, _ buildGraph: any TargetGraph, name: String, expectedPlatforms: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let targets = buildGraph.allTargets.filter { $0.target.name == name }
        #expect(targets.count == expectedPlatforms.count)

        var unexpectedPlatforms: [String] = []
        var visitedPlatforms = Set(expectedPlatforms)
        for target in targets {
            let settings = buildRequestContext.getCachedSettings(target.parameters, target: target.target)
            guard let platform = settings.platform else {
                Issue.record("Target \(target.target.name) has no platform", sourceLocation: sourceLocation)
                continue
            }
            if visitedPlatforms.remove(platform.name) == nil {
                unexpectedPlatforms.append(platform.name)
            }
        }

        #expect(visitedPlatforms == [])
        #expect(unexpectedPlatforms == [])
    }

    let specializationWorkspace_basic: TestWorkspace = {
        return TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "MacApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: ["MultiPlatformFramework", "SinglePlatformFramework"]
                ),
                TestStandardTarget(
                    "PhoneApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["MultiPlatformFramework", "SinglePlatformFramework"]
                ),

                TestStandardTarget(
                    "MultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "SinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: []
                ),
            ]),
        ])
    }()

    let specializationWorkspace_aggregate: TestWorkspace = {
        return TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "MacApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: ["Intermediate", "SpecializedIntermediate"]
                ),
                TestStandardTarget(
                    "PhoneApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["Intermediate", "SpecializedIntermediate"]
                ),

                TestAggregateTarget(
                    "Intermediate",
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                    dependencies: ["MultiPlatformFramework", "SinglePlatformFramework"]
                ),

                TestAggregateTarget(
                    "SpecializedIntermediate",
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES"]) ],
                    dependencies: ["OtherMultiPlatformFramework", "SinglePlatformFramework"]
                ),

                TestStandardTarget(
                    "MultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "SinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "OtherMultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: []
                ),
            ]),
        ])
    }()

    func specializationWorkspace_aggregate(specializedEnabled: Bool) -> TestWorkspace {
        let specializationValue = specializedEnabled ? "YES" : "NO"

        return TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "MacApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: ["Intermediate", "SpecializedIntermediate"]
                ),
                TestStandardTarget(
                    "PhoneApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["Intermediate", "SpecializedIntermediate"]
                ),

                TestAggregateTarget(
                    "Intermediate",
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                    dependencies: ["MultiPlatformFramework", "SinglePlatformFramework"]
                ),

                TestAggregateTarget(
                    "SpecializedIntermediate",
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": specializationValue]) ],
                    dependencies: ["OtherMultiPlatformFramework", "OtherSinglePlatformFramework"]
                ),

                TestStandardTarget(
                    "MultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": specializationValue]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "SinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "OtherMultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": specializationValue]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "OtherSinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]) ],
                    dependencies: []
                ),
            ]),
        ])
    }

    func specializationWorkspace_aggregate_simple(specializedEnabled: Bool) -> TestWorkspace {
        let specializationValue = specializedEnabled ? "YES" : "NO"

        return TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "MacApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: ["SpecializedIntermediate", "SpecializedIntermediate2"]
                ),
                TestStandardTarget(
                    "PhoneApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["SpecializedIntermediate"]
                ),

                TestAggregateTarget(
                    "SpecializedIntermediate",
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": specializationValue]) ],
                    dependencies: ["OtherSinglePlatformFramework"]
                ),

                TestStandardTarget(
                    "SpecializedIntermediate2",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": specializationValue]) ],
                    dependencies: ["OtherSinglePlatformFramework2"]
                ),

                TestStandardTarget(
                    "OtherSinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "OtherSinglePlatformFramework2",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]) ],
                    dependencies: []
                ),
            ]),
        ])
    }

    let specializationWorkspace_specializedAggregate: TestWorkspace = {
        return TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "MacApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: ["Intermediate"]
                ),
                TestStandardTarget(
                    "PhoneApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["Intermediate"]
                ),

                TestAggregateTarget(
                    "Intermediate",
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: ["MultiPlatformFramework", "SinglePlatformFramework"]
                ),

                TestStandardTarget(
                    "MultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "SinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: []
                ),
            ]),
        ])
    }()

    let specializationWorkspace_intermediateFramework: TestWorkspace = {
        return TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "MacApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: ["Intermediate", "MultiPlatformFramework"]
                ),
                TestStandardTarget(
                    "PhoneApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["Intermediate", "MultiPlatformFramework"]
                ),

                TestStandardTarget(
                    "Intermediate",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]) ],
                    dependencies: ["MultiPlatformFramework", "SinglePlatformFramework"]
                ),

                TestStandardTarget(
                    "MultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: []
                ),

                TestStandardTarget(
                    "SinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: []
                ),
            ]),
        ])
    }()

    func specializationCheck(_ testWorkspace: TestWorkspace, _ targetNames: [String], _ activeRunDestination: RunDestinationInfo, validation: (TargetGraphFactory.GraphType, BuildRequestContext, any TargetGraph, EmptyTargetDependencyResolverDelegate) throws -> Void) async throws {
        let core = try await getCore()
        let workspace = try testWorkspace.load(core)

        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: activeRunDestination)
        let targets: [BuildRequest.BuildTargetInfo] = try targetNames.map({ name in
            let target = try #require(workspace.projects[0].targets.filter({ $0.name == name }).only)
            return BuildRequest.BuildTargetInfo(parameters: buildParameters, target: target)
        })

        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: targets, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)

        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        for type in TargetGraphFactory.GraphType.allCases {
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            // Get the dependency closure for the build request and examine it.
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)

            try validation(type, buildRequestContext, buildGraph, delegate)
        }
    }

    @Test(.requireSDKs(.iOS))
    func specialization_SingleTopLevelTarget_SpecializedLeafFramework_iOS() async throws {
        // Test that the chosen run destination doesn't change how things are building as it should have no impact.
        try await specializationCheck(specializationWorkspace_basic, ["PhoneApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["iphoneos"])
            #expect(buildGraph.allTargets.count == 3)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func specialization_SingleTopLevelTarget_SpecializedLeafFramework_macOS() async throws {
        try await specializationCheck(specializationWorkspace_basic, ["MacApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx"])
            #expect(buildGraph.allTargets.count == 3)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func specialization_MultipleTopLevelTarget_SpecializedLeafFramework_iOS() async throws {
        try await specializationCheck(specializationWorkspace_basic, ["MacApp", "PhoneApp", "SinglePlatformFramework"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")

            // The following targets should be configured for macOS and iOS.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 5)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func specialization_MultipleTopLevelTarget_SpecializedLeafFramework_macOS() async throws {
        try await specializationCheck(specializationWorkspace_basic, ["MacApp", "PhoneApp", "SinglePlatformFramework"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")

            // The following targets should be configured for macOS and iOS.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 5)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func specialization_SingleTopLevelTarget_Intermediate_SpecializedLeafFramework_iOS() async throws {
        // Test that the chosen run destination doesn't change how things are building as it should have no impact.
        try await specializationCheck(specializationWorkspace_aggregate, ["PhoneApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["iphoneos"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["iphoneos"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["iphoneos"])

            #expect(buildGraph.allTargets.count == 6)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func specialization_SingleTopLevelTarget_Intermediate_SpecializedLeafFramework_macOS() async throws {
        try await specializationCheck(specializationWorkspace_aggregate, ["MacApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["macosx"])

            #expect(buildGraph.allTargets.count == 6)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func specialization_SingleTopLevelTarget_Intermediate_SpecializedLeafFramework_iOS_mismatched() async throws {
        try await specializationCheck(specializationWorkspace_aggregate, ["MacApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["macosx"])

            #expect(buildGraph.allTargets.count == 6)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS, .macOS),
          // Force ordering due to rdar://108715828; this is specifically for regression testing.
          .userDefaults(["DisableConcurrentDependencyResolution": "1"]))
    func specialization_MultipleTopLevelTarget_Intermediate_SpecializedLeafFramework_iOS() async throws {
        func check(_ topLevelTargets: [String], expectedPlatform: String) async throws {
            try await specializationCheck(specializationWorkspace_aggregate, topLevelTargets, .iOS) { graphType, buildRequestContext, buildGraph, delegate in
                // The following targets should only be configured once.
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])

                // NOTE: Due to how the aggregate targets are specialized "transparently", this means this project configuration is actually non-deterministic
                // as our dependency resolver can run concurrently. This test forces the order to verify the specialization is happening correctly, but the
                // project configuration itself is non-deterministic. It's also an odd setup as the leaf framework is not used by any of the top-level targets,
                // which would mean this target would be specialized.
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: [expectedPlatform])

                try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["macosx", "iphoneos"])
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

                #expect(buildGraph.allTargets.count == 9)

                delegate.checkNoDiagnostics()
            }
        }

        try await check(["MacApp", "PhoneApp"], expectedPlatform: "macosx")
        try await check(["PhoneApp", "MacApp"], expectedPlatform: "iphoneos")
    }

    /// Ensure that specialization being turned on does not affect the build graph for equivalent requests.
    @Test(.requireSDKs(.macOS, .iOS), .userDefaults(["DisableConcurrentDependencyResolution": "1"]))
    func specialization_EquivalentGraphsWhenEnabledOrDisabled() async throws {
        for isEnabled in [false, true] {
            // Baseline for the MacApp experience.
            try await specializationCheck(specializationWorkspace_aggregate(specializedEnabled: isEnabled), ["MacApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")

                try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["macosx"])

                try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherSinglePlatformFramework", expectedPlatforms: ["iphoneos"])

                try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx"])
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["macosx"])

                #expect(buildGraph.allTargets.count == 7)

                delegate.checkNoDiagnostics()
            }

            // Baseline for the PhoneApp experience.
            try await specializationCheck(specializationWorkspace_aggregate(specializedEnabled: isEnabled), ["PhoneApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")

                try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["iphoneos"])

                try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherSinglePlatformFramework", expectedPlatforms: ["iphoneos"])

                try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["iphoneos"])
                try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["iphoneos"])

                #expect(buildGraph.allTargets.count == 7)

                delegate.checkNoDiagnostics()
            }
        }

        // Baseline for the [MacApp, PhoneApp] experience. No specialization, so no additional targets created. Also, the order of the top-level targets matters for which downstream target is configured.
        try await specializationCheck(specializationWorkspace_aggregate(specializedEnabled: false), ["MacApp", "PhoneApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["macosx"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherSinglePlatformFramework", expectedPlatforms: ["iphoneos"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["macosx"])

            #expect(buildGraph.allTargets.count == 8)

            delegate.checkNoDiagnostics()
        }

        // Baseline for the [PhoneApp, MacApp] experience. No specialization, so no additional targets created. Also, the order of the top-level targets matters for which downstream target is configured.
        try await specializationCheck(specializationWorkspace_aggregate(specializedEnabled: false), ["PhoneApp", "MacApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["iphoneos"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherSinglePlatformFramework", expectedPlatforms: ["iphoneos"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["iphoneos"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["iphoneos"])

            #expect(buildGraph.allTargets.count == 8)

            delegate.checkNoDiagnostics()
        }

        // Baseline for the [MacApp, PhoneApp] experience. Specialization is enabled, so additional targets should be created.
        try await specializationCheck(specializationWorkspace_aggregate(specializedEnabled: true), ["MacApp", "PhoneApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["macosx", "iphoneos"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherSinglePlatformFramework", expectedPlatforms: ["iphoneos"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 10)

            delegate.checkNoDiagnostics()
        }

        // Baseline for the [PhoneApp, MacApp] experience. Specialization is enabled, so additional targets should be created.
        try await specializationCheck(specializationWorkspace_aggregate(specializedEnabled: true), ["PhoneApp", "MacApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SpecializedIntermediate", expectedPlatforms: ["macosx", "iphoneos"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherSinglePlatformFramework", expectedPlatforms: ["iphoneos"])

            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["iphoneos"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "OtherMultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 10)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func specialization_SingleTopLevelTarget_Intermediate_SpecializedLeafFramework_TopLevelDep_macOS() async throws {
        try await specializationCheck(specializationWorkspace_intermediateFramework, ["MacApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx"])

            #expect(buildGraph.allTargets.count == 4)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func specialization_SingleTopLevelTarget_Intermediate_SpecializedLeafFramework_TopLevelDep_iOS() async throws {
        try await specializationCheck(specializationWorkspace_intermediateFramework, ["PhoneApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])

            // NOTE: This is expected to build for macOS as the `Intermediate` target builds for macOS and has a dependency on this target.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 5)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func specialization_MultipleTopLevelTarget_Intermediate_SpecializedLeafFramework_TopLevelDep_iOS() async throws {
        try await specializationCheck(specializationWorkspace_intermediateFramework, ["MacApp", "PhoneApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 6)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func specialization_MultipleTopLevelTarget_Intermediate_SpecializedLeafFramework_TopLevelDep_macOS() async throws {
        try await specializationCheck(specializationWorkspace_intermediateFramework, ["MacApp", "PhoneApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Intermediate", expectedPlatforms: ["macosx"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 6)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func specialization_DependenciesOfSpecializedFrameworksAreNotSpecialized() async throws {
        let testWorkspace = TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "MacApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: ["MultiPlatformFramework"]
                ),
                TestStandardTarget(
                    "PhoneApp",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["MultiPlatformFramework"]
                ),

                TestStandardTarget(
                    "MultiPlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: ["SinglePlatformFramework"]
                ),

                // NOTE: This should NOT be specialized as targets are _only_ specialized based on the target's immediate parent. Note that 'MultiPlatformFramework' is also a dependency of the top-level targets that will be specialized.
                TestStandardTarget(
                    "SinglePlatformFramework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: []
                ),
            ]),
        ])

        try await specializationCheck(testWorkspace, ["MacApp", "PhoneApp"], .macOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MacApp", expectedPlatform: "macosx")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "SinglePlatformFramework", expectedPlatform: "macosx")

            // The following targets should be configured for macOS and iOS.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "MultiPlatformFramework", expectedPlatforms: ["macosx", "iphoneos"])

            #expect(buildGraph.allTargets.count == 5)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func specialization_rdar77954162() async throws {
        let testWorkspace = TestWorkspace("Workspace", projects: [
            TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                TestStandardTarget(
                    "PhoneApp",
                    type: .application,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                    dependencies: ["WatchApp", "Framework"]
                ),

                TestStandardTarget(
                    "WatchApp",
                    type: .watchKitApp,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "watchos", "SUPPORTED_PLATFORMS": "watchos watchsimulator"]) ],
                    dependencies: ["WatchExtension", "Framework"]
                ),

                TestStandardTarget(
                    "WatchExtension",
                    type: .watchKitExtension,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "watchos", "SUPPORTED_PLATFORMS": "watchos watchsimulator"]) ],
                    dependencies: ["Framework"]
                ),

                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "watchos watchsimulator iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES" ]) ],
                    dependencies: ["Aggregate"]
                ),

                TestAggregateTarget(
                    "Aggregate",
                    buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                    dependencies: []
                ),
            ]),
        ])

        try await specializationCheck(testWorkspace, ["PhoneApp"], .iOS) { graphType, buildRequestContext, buildGraph, delegate in
            // The following targets should only be configured once.
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "WatchApp", expectedPlatform: "watchos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "WatchExtension", expectedPlatform: "watchos")
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Framework", expectedPlatforms: ["watchos", "iphoneos"])
            try checkTarget(graphType, buildRequestContext, buildGraph, name: "Aggregate", expectedPlatform: "macosx")

            #expect(buildGraph.allTargets.count == 6)

            delegate.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func aggregateTargetsSpecializeAppropriately() async throws {
        func check(_ activeRunDestination: RunDestinationInfo) async throws {
            let core = try await getCore()

            let workspace = try TestWorkspace("Workspace", projects: [
                TestProject("aProject", groupTree: TestGroup("aGroup"), targets: [
                    TestStandardTarget(
                        "MacApp",
                        type: .framework,
                        buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx" ]) ],
                        dependencies: ["Aggregate"]
                    ),
                    TestStandardTarget(
                        "PhoneApp",
                        type: .framework,
                        buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator" ]) ],
                        dependencies: ["Aggregate"]
                    ),

                    TestStandardTarget(
                        "Aggregate",
                        type: .framework,
                        buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES"]) ],
                        dependencies: []
                    ),

                ]),
            ]).load(core)

            let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: activeRunDestination)
            let targets = [
                BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.projects[0].targets[0]),
                BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.projects[0].targets[1]),
            ]
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: targets, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)

            let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

            func checkTarget(_ buildGraph: any TargetGraph, name: String, expectedPlatform: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
                let target = try #require(buildGraph.allTargets.filter { $0.target.name == name }.first, sourceLocation: sourceLocation)
                let settings = buildRequestContext.getCachedSettings(target.parameters, target: target.target)
                #expect(settings.target?.name == name, sourceLocation: sourceLocation)
                #expect(settings.platform?.name == expectedPlatform, sourceLocation: sourceLocation)
            }

            func checkTarget(_ buildGraph: any TargetGraph, name: String, expectedPlatforms: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {

                let targets = buildGraph.allTargets.filter { $0.target.name == name }
                #expect(targets.count == expectedPlatforms.count)

                var visitedPlatforms = Set(expectedPlatforms)
                for target in targets {
                    let settings = buildRequestContext.getCachedSettings(target.parameters, target: target.target)
                    #expect(visitedPlatforms.remove(settings.platform?.name ?? "") != nil, sourceLocation: sourceLocation)
                }

                #expect(visitedPlatforms == [])
            }

            for type in TargetGraphFactory.GraphType.allCases {
                let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

                // Get the dependency closure for the build request and examine it.
                let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)

                // The following targets should only be configured once.
                try checkTarget(buildGraph, name: "MacApp", expectedPlatform: "macosx")
                try checkTarget(buildGraph, name: "PhoneApp", expectedPlatform: "iphoneos")
                try checkTarget(buildGraph, name: "Aggregate", expectedPlatforms: ["iphoneos", "macosx"])
                #expect(buildGraph.allTargets.count == 4)

                delegate.checkNoDiagnostics()
            }
        }

        // Test that the chosen run destination doesn't change how things are building as it should have no impact.
        try await check(.iOS)
        try await check(.macOS)
    }
}


// MARK: Test cases for resolving implicit dependencies

@Suite fileprivate struct ImplicitDependencyResolutionTests: CoreBasedTests {
    /// Test the simple implicit dependency of an application target linking against a framework build by a target in another project.
    @Test
    func appAndFramework() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aFramework.framework"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "aFramework.framework",
                                ]),
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]
        let fwkProject = workspace.projects[1]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let fwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [try buildGraph.target(for: fwkTarget)])
        #expect(try buildGraph.dependencies(fwkTarget) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test the case of an application target which links against the binary of a bundle produced by a target in another project.
    @Test
    func appAndBundle() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("IDEStuff.ideplugin/Contents/MacOS/IDEStuff", fileType: "compiled.mach-o.dylib"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "IDEStuff",
                                ]),
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "IDEStuff",
                            type: .bundle,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "IDEStuff"]),
                            ],
                            productReferenceName: "IDEStuff.ideplugin"
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]
        let bndlProject = workspace.projects[1]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let bndlTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: bndlProject.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["IDEStuff", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [try buildGraph.target(for: bndlTarget)])
        #expect(try buildGraph.dependencies(bndlTarget) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test resolving implicit dependencies for an app target which embeds inside its product a tool and a framework, and where the tool links against the framework.
    @Test
    func appAndEmbeddedProducts() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aTool", fileType: "compiled.mach-o.executable"),
                            TestFile("aFramework.framework"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestCopyFilesBuildPhase([
                                    "aTool",
                                    "aFramework.framework",
                                ], destinationSubfolder: .frameworks),
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aTool",
                            type: .commandLineTool,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aTool"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "aFramework.framework",
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "aFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]
        let toolProject = workspace.projects[1]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let toolTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: toolProject.targets[0])
        let fwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: toolProject.targets[1])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework", "aTool", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [try buildGraph.target(for: toolTarget), try buildGraph.target(for: fwkTarget)])
        #expect(try buildGraph.dependencies(toolTarget) == [try buildGraph.target(for: fwkTarget)])
        #expect(try buildGraph.dependencies(fwkTarget) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test that a target which implicitly depends on itself does not result in an infinite recursion.
    @Test
    func selfDependency() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: []
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aTool",
                            type: .commandLineTool,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aTool"]),
                            ],
                            buildPhases: [
                                TestCopyFilesBuildPhase([
                                    "aTool",
                                ], destinationSubfolder: .frameworks),
                            ]
                        )
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 1)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let target = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [target], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aTool"])
        #expect(try buildGraph.dependencies(target) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test that we properly filter on SUPPORTED_PLATFORMS to determine an implicit dependency.
    @Test(.requireSDKs(.macOS, .iOS))
    func supportedPlatformsFilter() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aFramework.framework"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "anApp",
                                                        "SDKROOT": "macosx",
                                                       ]
                                                      ),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "aFramework.framework",
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "osxFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "aFramework",
                                                        "SUPPORTED_PLATFORMS": "macosx",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "aFramework.framework"
                        ),
                        TestStandardTarget(
                            "iosFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "aFramework",
                                                        "SUPPORTED_PLATFORMS": "iphoneos",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "aFramework.framework"
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 1)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let osxFwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        // The app target should depend on the macOS framework target, and the iOS framework target should not be in the dependency closure.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(try dependencyClosure.elements == [buildGraph.target(for: osxFwkTarget), buildGraph.target(for: appTarget)])
        #expect(try buildGraph.dependencies(appTarget) == [buildGraph.target(for: osxFwkTarget)])
        #expect(try buildGraph.dependencies(osxFwkTarget) == [])
        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.checkDiagnostics(["iosFramework rejected as an implicit dependency because its SUPPORTED_PLATFORMS 'iphoneos' does not contain this target's platform 'macosx'. (in target 'anApp' from project 'P1')"])
        } else {
            delegate.checkNoDiagnostics()
        }
    }

    /// Test that we properly match platforms to determine an implicit dependency.
    @Test(.requireSDKs(.macOS, .iOS))
    func platformMatching() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aFramework.framework"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "anApp",
                                                        "SDKROOT": "macosx",
                                                       ]
                                                      ),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "aFramework.framework",
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "osxFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "aFramework",
                                                        "SDKROOT": "macosx",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "aFramework.framework"
                        ),
                        TestStandardTarget(
                            "iosFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "aFramework",
                                                        "SDKROOT": "iphoneos",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "aFramework.framework"
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 1)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let osxFwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        // The app target should depend on the macOS framework target, and the iOS framework target should not be in the dependency closure.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(try dependencyClosure.elements == [buildGraph.target(for: osxFwkTarget), buildGraph.target(for: appTarget)])
        #expect(try buildGraph.dependencies(appTarget) == [buildGraph.target(for: osxFwkTarget)])
        #expect(try buildGraph.dependencies(osxFwkTarget) == [])
        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.checkDiagnostics(["iosFramework rejected as an implicit dependency because its SUPPORTED_PLATFORMS 'iphoneos iphonesimulator' does not contain this target's platform 'macosx'. (in target 'anApp' from project 'P1')"])
        } else {
            delegate.checkNoDiagnostics()
        }
    }

    /// Test that SDK variant is properly used to determine an implicit dependency.
    @Test(.requireSDKs(.macOS))
    func SDKVariantMatching() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "Project",
                    groupTree: TestGroup(
                        "Group",
                        children: [
                            TestFile("Fmwk.framework"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "TOOLCHAINS": "default",
                        ]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "macOSApplication",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "Appl",
                                                        "SDKROOT": "macosx",
                                                       ]
                                                      ),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "Fmwk.framework",
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "MacCatalystApplication",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "iAppl",
                                                        "SDKROOT": "macosx",
                                                        "SDK_VARIANT": MacCatalystInfo.sdkVariantName
                                                       ]
                                                      ),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "Fmwk.framework"
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "MacCatalystFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "Fmwk",
                                                        "SDKROOT": "macosx",
                                                        "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "Fmwk.framework"
                        ),
                        TestStandardTarget(
                            "macOSFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "Fmwk",
                                                        "SDKROOT": "macosx",
                                                        "SDK_VARIANT": "macos",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "Fmwk.framework"
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 1)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let macAppTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let uikitAppTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
        let uikitFwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[2])
        let macosFwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[3])

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // The macOS app target should depend on the macOS framework target, and the UIKit framework target should not be in the dependency closure.
        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [macAppTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            // Get the dependency closure for the build request and examine it.
            let dependencyClosure = buildGraph.allTargets
            #expect(try dependencyClosure.elements == [
                buildGraph.target(for: macosFwkTarget),
                buildGraph.target(for: macAppTarget)])
            #expect(try buildGraph.dependencies(macAppTarget) == [buildGraph.target(for: macosFwkTarget)])
            #expect(try buildGraph.dependencies(macosFwkTarget) == [])
        }

        // Similarly, the UIKit app target should depend on the UIKit framework target, and the macOS framework target should not be in the dependency closure.
        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [uikitAppTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            // Get the dependency closure for the build request and examine it.
            let dependencyClosure = buildGraph.allTargets
            #expect(try dependencyClosure.elements == [
                buildGraph.target(for: uikitFwkTarget),
                buildGraph.target(for: uikitAppTarget)])
            #expect(try buildGraph.dependencies(uikitAppTarget) == [buildGraph.target(for: uikitFwkTarget)])
            #expect(try buildGraph.dependencies(uikitFwkTarget) == [])
        }

        // Building everything at once should work too.
        do {
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [macAppTarget, uikitAppTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            // Get the dependency closure for the build request and examine it.
            let dependencyClosure = buildGraph.allTargets
            #expect(try dependencyClosure.elements == [
                buildGraph.target(for: macosFwkTarget),
                buildGraph.target(for: macAppTarget),
                buildGraph.target(for: uikitFwkTarget),
                buildGraph.target(for: uikitAppTarget)])
            #expect(try buildGraph.dependencies(macAppTarget) == [buildGraph.target(for: macosFwkTarget)])
            #expect(try buildGraph.dependencies(macosFwkTarget) == [])
            #expect(try buildGraph.dependencies(uikitAppTarget) == [buildGraph.target(for: uikitFwkTarget)])
            #expect(try buildGraph.dependencies(uikitFwkTarget) == [])
        }

        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.checkDiagnostics([
                "MacCatalystFramework rejected as an implicit dependency because its SDK_VARIANT 'iosmac' is not equal to this target's SDK_VARIANT 'macos' and it is not zippered. (in target 'macOSApplication' from project 'Project')",
                "macOSFramework rejected as an implicit dependency because its SDK_VARIANT 'macos' is not equal to this target's SDK_VARIANT 'iosmac' and it is not zippered. (in target 'MacCatalystApplication' from project 'Project')",
                "macOSFramework rejected as an implicit dependency because its SDK_VARIANT 'macos' is not equal to this target's SDK_VARIANT 'iosmac' and it is not zippered. (in target 'MacCatalystApplication' from project 'Project')",
                "MacCatalystFramework rejected as an implicit dependency because its SDK_VARIANT 'iosmac' is not equal to this target's SDK_VARIANT 'macos' and it is not zippered. (in target 'macOSApplication' from project 'Project')"
            ])
        } else {
            delegate.checkNoDiagnostics()
        }
    }

    /// Test that we match architectures to determine an implicit dependency.
    @Test(.requireSDKs(.iOS))
    func architectureMatching() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aFramework.framework"),
                            TestFile("anotherFramework.framework"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "anApp",
                                                        "SDKROOT": "iphoneos",
                                                        "ARCHS": "arm64",
                                                       ]
                                                      ),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "aFramework.framework",
                                    "anotherFramework.framework",
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "iOSFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "aFramework",
                                                        "SDKROOT": "iphoneos",
                                                        "ARCHS": "arm64",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "aFramework.framework"
                        ),
                        TestStandardTarget(
                            "oldFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "anotherFramework",
                                                        "SDKROOT": "iphoneos",
                                                        "ARCHS": "arm64e",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "anotherFramework.framework"
                        ),
                        TestStandardTarget(
                            "updatedOldFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "anotherFramework",
                                                        "SDKROOT": "iphoneos",
                                                        "ARCHS": "arm64",
                                                       ]
                                                      ),
                            ],
                            productReferenceName: "anotherFramework.framework"
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 1)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let iosFwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
        let updatedFwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[3])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        // The app target should depend on the iOS framework target, and the updated old framework target, but not the really old framework target.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(try dependencyClosure.elements == [buildGraph.target(for: iosFwkTarget), buildGraph.target(for: updatedFwkTarget), buildGraph.target(for: appTarget)])
        #expect(try buildGraph.dependencies(appTarget) == [buildGraph.target(for: iosFwkTarget), buildGraph.target(for: updatedFwkTarget)])
        #expect(try buildGraph.dependencies(iosFwkTarget) == [])
        #expect(try buildGraph.dependencies(updatedFwkTarget) == [])
        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.checkDiagnostics(["oldFramework rejected as an implicit dependency because its ARCHS 'arm64e' are not a superset of this target's ARCHS 'arm64'. (in target 'anApp' from project 'P1')"])
        } else {
            delegate.checkNoDiagnostics()
        }
    }

    @Test
    func implicitDependenciesUseOverridingParameters() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles", children: [TestFile("aFramework.framework")]),
                                                                 targets: [
                                                                    TestStandardTarget("anApp", type: .application, buildPhases: [TestFrameworksBuildPhase(["aFramework.framework"])]),
                                                                    TestStandardTarget("aFramework", type: .application, productReferenceName: "aFramework.framework"),
                                                                 ]
                                                                )]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParametersForApp = BuildParameters(configuration: "Debug", overrides: ["SWIFT_MIGRATE_DIR": "/app1"])
        let buildParametersForFwk = BuildParameters(configuration: "Debug", overrides: ["SWIFT_MIGRATE_DIR": "/fwk"])
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParametersForApp, target: project.targets[0])
        let fwkTarget  = BuildRequest.BuildTargetInfo(parameters: buildParametersForFwk, target: project.targets[1])
        let buildRequest = BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: [appTarget, fwkTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        if let fwkTarget = dependencyClosure.filter({ $0.target.name == "aFramework" }).first {
            #expect(fwkTarget.parameters == buildParametersForFwk)
        } else {
            Issue.record("framework target not found in target build graph")
        }

        delegate.checkNoDiagnostics()
    }

    @Test
    func implicitDependenciesUseOtherLinkerFlags() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("SomeFiles", children: [
                        TestFile("aFramework.framework"),
                        TestFile("libDynamic.dylib"),
                        TestFile("libStatic.a"),
                    ]),
                    targets: [
                        TestAggregateTarget("test", dependencies: [
                            "test0",
                            "test1",
                            "test2",
                            "test3",
                            "testDisabled",
                        ]),
                        TestStandardTarget(
                            "test0",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        // We should support both ways to pass Ld flags
                                        "OTHER_LDFLAGS": "-framework aFramework",
                                        "PRODUCT_SPECIFIC_LDFLAGS": "-lDynamic -lStatic",
                                    ]),
                            ]
                        ),
                        TestStandardTarget(
                            "test1",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "OTHER_LDFLAGS": "-weak_framework aFramework -weak-lDynamic -weak-lStatic",
                                    ]),
                            ]
                        ),
                        TestStandardTarget(
                            "test2",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "OTHER_LDFLAGS": "-reexport_framework aFramework -reexport-lDynamic -reexport-lStatic",
                                    ]),
                            ]
                        ),
                        TestStandardTarget(
                            "test3",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "OTHER_LDFLAGS": "-lazy_framework aFramework -lazy-lDynamic -lazy-lStatic",
                                    ]),
                            ]
                        ),
                        TestStandardTarget(
                            "testDisabled",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "OTHER_LDFLAGS": "-framework aFramework -lDynamic -lStatic",
                                        "IMPLICIT_DEPENDENCIES_IGNORE_LDFLAGS": "YES",
                                    ]),
                            ]
                        ),

                        // Ensure that more than one target has the same "stem" ("Dynamic"), so that we don't get an ambiguous match including the framework from a -lDynamic argument.
                        TestStandardTarget("aFramework", type: .application, productReferenceName: "aFramework.framework"),
                        TestStandardTarget("aFramework2", type: .application, productReferenceName: "Dynamic.framework"),
                        TestStandardTarget("aDynamicLib", type: .application, productReferenceName: "libDynamic.dylib"),
                        TestStandardTarget("aStaticLib", type: .application, productReferenceName: "libStatic.a"),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParametersForApp = BuildParameters(configuration: "Debug")
        let testBuildTargetInfo = BuildRequest.BuildTargetInfo(parameters: buildParametersForApp, target: project.targets[0])
        let buildRequest = BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: [testBuildTargetInfo], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets

        guard let fwkTarget = (dependencyClosure.first { $0.target.name == "aFramework" }) else { Issue.record(); return }
        guard let dynamicLibTarget = (dependencyClosure.first { $0.target.name == "aDynamicLib" }) else { Issue.record(); return }
        guard let staticLibTarget = (dependencyClosure.first { $0.target.name == "aStaticLib" }) else { Issue.record(); return }

        // Check that supported flags get the right dependencies
        for i in 0...3 {
            let t = dependencyClosure.first { $0.target.name == "test\(i)" }!
            #expect(buildGraph.dependencies(of: t).contains(fwkTarget), "Expected \(t.target.name) to depend on \(fwkTarget.target.name)")
            #expect(buildGraph.dependencies(of: t).contains(dynamicLibTarget), "Expected \(t.target.name) to depend on \(dynamicLibTarget.target.name)")
            #expect(buildGraph.dependencies(of: t).contains(staticLibTarget), "Expected \(t.target.name) to depend on \(staticLibTarget.target.name)")
        }

        // Check that it can be disabled by a target-level setting
        do {
            let t = dependencyClosure.first { $0.target.name == "testDisabled" }!
            #expect(buildGraph.dependencies(of: t).isEmpty)
        }

        delegate.checkNoDiagnostics()
    }

    /// Test that platform filtering works for implicit dependencies.
    @Test
    func implicitDependencyPlatformFiltering() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aFramework.framework"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    TestBuildFile("aFramework.framework", platformFilters: PlatformFilter.macCatalystFilters),
                                ]),
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test that an implicit dependency which results in an ambiguity, emits a diagnostic.
    @Test
    func ambiguousImplicitDependency() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aFramework.framework"),
                            TestFile("bFramework", path: "bFramework.framework/Versions/A/bFramework", fileType: "compiled.mach-o.executable", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR"))
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "aFramework.framework",
                                    "bFramework",
                                ]),
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "aFramework2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "bFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "bFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "bFramework2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "bFramework"]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]
        let fwkProject = workspace.projects[1]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let fwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[0])
        let fwkTarget2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[2])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework1", "bFramework1", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [
            try buildGraph.target(for: fwkTarget),
            try buildGraph.target(for: fwkTarget2),
        ])
        #expect(try buildGraph.dependencies(fwkTarget) == [])
        delegate.checkDiagnostics([
            "[targetIntegrity] Multiple targets match implicit dependency for product reference 'aFramework.framework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'aFramework1' (in project 'P2')\nTarget 'aFramework2' (in project 'P2') (in target 'anApp' from project 'P1')",
            "[targetIntegrity] Multiple targets match implicit dependency for product bundle executable reference 'bFramework'. Consider adding an explicit dependency on the intended target to resolve this ambiguity.\nTarget 'bFramework1' (in project 'P2')\nTarget 'bFramework2' (in project 'P2') (in target 'anApp' from project 'P1')",
        ])
    }

    /// Test that an implicit dependency which results in an ambiguity, does not emit a diagnostic if it has an explicit dependency on at least one of the targets in list of dependencies which would be ambiguous.
    @Test(.skipHostOS(.windows, "coolLib1 target is somehow missing"))
    func disambiguatedImplicitDependency() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("aFramework.framework"),
                            TestFile("bFramework", path: "bFramework.framework/Versions/A/bFramework", fileType: "compiled.mach-o.executable", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR"))
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "anApp",
                                    "OTHER_LDFLAGS": "-framework FlagFramework -lCool"
                                ]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "aFramework.framework",
                                    "bFramework",
                                ]),
                            ],
                            dependencies: [
                                "aFramework1",
                                "bFramework1",
                                "flagFramework2",
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "aFramework2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "aFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "bFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "bFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "bFramework2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "bFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "flagFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "FlagFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "flagFramework2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "FlagFramework"]),
                            ]
                        ),
                        TestStandardTarget(
                            "coolLib1",
                            type: .dynamicLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Cool"]),
                            ]
                        ),
                        TestStandardTarget(
                            "coolLib2",
                            type: .staticLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Cool"]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]
        let fwkProject = workspace.projects[1]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let fwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[0])
        let fwkTarget2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[2])
        let flagFramework2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[5])
        let coolLib1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[6])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework1", "bFramework1", "flagFramework2", "coolLib1", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [
            try buildGraph.target(for: fwkTarget),
            try buildGraph.target(for: fwkTarget2),
            try buildGraph.target(for: flagFramework2),
            try buildGraph.target(for: coolLib1)
        ])
        #expect(try buildGraph.dependencies(fwkTarget) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test that implicit dependencies which don't match anything, get skipped
    @Test
    func implicitDependencySkipping() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("Base", path: "Base.framework/Versions/A/Base", fileType: "compiled.mach-o.executable", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR"))
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "Base",
                                ]),
                            ]
                        )
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 1)
        let appProject = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test that implicit dependencies which don't match anything due to ineligibility (even if they otherwise match by name), get skipped
    @Test
    func implicitDependencySkippingIneligible() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("Base", path: "Base.framework/Versions/A/Base", fileType: "compiled.mach-o.executable", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR"))
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "Base",
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "aFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "Base",
                                    "SUPPORTED_PLATFORMS": "watchos watchsimulator",
                                ]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 1)
        let appProject = workspace.projects[0]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [])
        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.checkDiagnostics(["aFramework1 rejected as an implicit dependency because its SUPPORTED_PLATFORMS 'watchos watchsimulator' does not contain this target's platform 'macosx'. (in target 'anApp' from project 'P1')"])
        } else {
            delegate.checkNoDiagnostics()
        }
    }

    /// Test that implicit dependency stem matching works correctly with targets whose products share a base name and both exist.
    @Test(.requireSDKs(.macOS))
    func implicitDependencyStemMatching() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("Base.framework"),
                            TestFile("libBase.dylib")
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "Base.framework",
                                    "libBase.dylib",
                                ]),
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Base"]),
                            ]
                        ),
                        TestStandardTarget(
                            "aLibrary1",
                            type: .dynamicLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Base"]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]
        let fwkProject = workspace.projects[1]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let fwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[0])
        let libTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[1])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework1", "aLibrary1", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [
            try buildGraph.target(for: fwkTarget),
            try buildGraph.target(for: libTarget),
        ])
        #expect(try buildGraph.dependencies(fwkTarget) == [])
        delegate.checkNoDiagnostics()
    }

    /// Test that implicit dependency stem matching doesn't match stems of incompatible products.
    @Test
    func implicitDependencyMixedStemMatching() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("Base", path: "Base.framework/Versions/A/Base", fileType: "compiled.mach-o.executable", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR"))
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "anApp",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "anApp"]),
                            ],
                            buildPhases: [
                                TestFrameworksBuildPhase([
                                    "Base",
                                ]),
                            ]
                        )
                    ]
                ),
                TestProject(
                    "P2",
                    groupTree: TestGroup(
                        "G2",
                        children:[
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "aFramework1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Base"]),
                            ]
                        ),
                        TestStandardTarget(
                            "aLibrary1",
                            type: .dynamicLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Base"]),
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        // Perform some simple correctness tests.
        #expect(workspace.projects.count == 2)
        let appProject = workspace.projects[0]
        let fwkProject = workspace.projects[1]

        // Configure the targets and create a BuildRequest.
        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: appProject.targets[0])
        let fwkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: fwkProject.targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        // Get the dependency closure for the build request and examine it.
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        let dependencyClosure = buildGraph.allTargets
        #expect(dependencyClosure.map({ $0.target.name }) == ["aFramework1", "anApp"])
        #expect(try buildGraph.dependencies(appTarget) == [
            try buildGraph.target(for: fwkTarget),
        ])
        #expect(try buildGraph.dependencies(fwkTarget) == [])
        delegate.checkNoDiagnostics()
    }

    @Test
    func packagesDoNotConsiderImplicitDependencies() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [
            TestProject("Project", groupTree: TestGroup("RootGroup"),
                        targets: [
                            TestStandardTarget(
                                "Base",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Base"]),
                                ]
                            ),
                        ]),
            TestPackageProject("Package", groupTree: TestGroup("RootGroup"),
                               targets: [
                                TestStandardTarget(
                                    "Package",
                                    type: .objectFile,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "PRODUCT_NAME": "pkg",
                                            "OTHER_LDFLAGS": "-framework Base",
                                        ]),
                                    ]
                                ),
                               ]),
        ]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        let buildParameters = BuildParameters(configuration: "Debug")
        let pkgTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.projects[1].targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [pkgTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)


        for type in TargetGraphFactory.GraphType.allCases {
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)
            #expect(buildGraph.allTargets.map({ $0.target.name }) == ["Package"]) // does not contain 'Base' even though we are linking it
        }
    }

    @Test
    func implicitDependenciesWithNameCollisionOnPackageTarget() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [
            TestProject("Project", groupTree: TestGroup("RootGroup", children: [TestFile("NameCollision.framework")]),
                        targets: [
                            TestStandardTarget(
                                "Base",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "Base"]),
                                ],
                                buildPhases: [
                                    TestFrameworksBuildPhase(["NameCollision.framework"])
                                ],
                                dependencies: [TestTargetDependency("NameCollision")]
                            ),

                            TestStandardTarget(
                                "NameCollision",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "NameCollision"]),
                                ]
                            ),
                        ]),
            TestPackageProject("Package", groupTree: TestGroup("RootGroup"),
                               targets: [
                                TestPackageProductTarget("Package", frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("NameCollision"))]), buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "NameCollision"]) ], dependencies: ["NameCollision"]),
                                TestStandardTarget("NameCollision", type: .framework),
                               ]),
        ]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        let buildParameters = BuildParameters(configuration: "Debug")
        let baseTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.projects[0].targets[0])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [baseTarget], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        for type in TargetGraphFactory.GraphType.allCases {
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: type)

            // Verify that `NameCollision` is used and it's from `Project` not `Package`.
            #expect(buildGraph.allTargets.map({ $0.target.name }).sorted() == ["Base", "NameCollision"])
            #expect(buildGraph.allTargets.map({ workspaceContext.workspace.project(for: $0.target).name }) == ["Project", "Project"])

            // Also, ensure there no diagnostic issues (rdar://75047366)
            delegate.checkNoDiagnostics()
        }
    }



    @Test
    func consistentlyUseParametersFromBuildRequest() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [
                                            TestProject("aProject",
                                                        groupTree: TestGroup("SomeFiles"),
                                                        targets: [
                                                            TestStandardTarget("App", type: .application, dependencies: ["Framework", "PackageProduct"]),
                                                            TestStandardTarget("Framework", type: .framework),
                                                        ]),
                                            TestPackageProject("aPackageProject",
                                                               groupTree: TestGroup("SomeMoreFiles"),
                                                               targets: [
                                                                TestPackageProductTarget("PackageProduct", frameworksBuildPhase: TestFrameworksBuildPhase(), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "auto", "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)"])]),
                                                               ]),
                                          ]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        let buildParameters = BuildParameters(configuration: "Debug", activeRunDestination: RunDestinationInfo.macOS).mergingOverrides(["BEST": "1"])
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters.mergingOverrides(["BEST": "2"]), target: workspace.projects[0].targets[0])
        let frameworkTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters.mergingOverrides(["BEST": "3"]), target: workspace.projects[0].targets[1])
        let packageProduct = BuildRequest.BuildTargetInfo(parameters: buildParameters.mergingOverrides(["BEST": "4"]), target: workspace.projects[1].targets[0])

        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget, frameworkTarget, packageProduct], continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)

        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

        delegate.checkNoDiagnostics()
        #expect(buildGraph.allTargets.count == workspace.projects[0].targets.count + workspace.projects[1].targets.count)
        #expect(buildGraph.dependencies(of: buildGraph.allTargets[0]) == [])
        #expect(buildGraph.dependencies(of: buildGraph.allTargets[1]) == [])
        #expect(buildGraph.dependencies(of: buildGraph.allTargets[2]).map { $0.target.name } == ["Framework", "PackageProduct"])
    }

    /// This is a specific regression test for part of rdar://73361908.
    @Test(.requireSDKs(.macOS, .iOS))
    func implicitDependencyResolutionMultiPlatDepsSameProductName() async throws {
        let core = try await getCore()

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // app files
                    TestFile("app/app.swift"),

                    // multi-plat framework files
                    TestFile("multiplat/multiplat.swift"),

                    // Shared framework files
                    TestFile("shared/lib.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "$(ARCHS_STANDARD)",
                    "ENABLE_ON_DEMAND_RESOURCES": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGN_IDENTITY": "",
                    "SWIFT_VERSION": swiftVersion,
                    "SWIFT_INSTALL_OBJC_HEADER": "NO",
                    "SKIP_INSTALL": "YES",
                    "GENERATE_INFOPLIST_FILE": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["app/app.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("Shared.framework"),
                            TestBuildFile("MultiPlat.framework"),
                        ])
                    ],
                    dependencies: []
                ),
                TestStandardTarget(
                    "MultiPlat Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "PRODUCT_NAME": "MultiPlat",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("multiplat/multiplat.swift")]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("Shared.framework"),
                            TestBuildFile("MultiPlatMore.framework")
                        ])
                    ]
                ),
                TestStandardTarget(
                    "Shared Framework 1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "PRODUCT_NAME": "Shared",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("shared/lib.swift")]),
                    ]
                ),
                TestStandardTarget(
                    "Shared Framework 2",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "PRODUCT_NAME": "Shared",
                            "SDK_VARIANT": "iosmac",
                            "EFFECTIVE_PLATFORM_NAME": "-iosmac",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("shared/lib.swift")]),
                    ]
                ),
                TestStandardTarget(
                    "Downstream MultiPlat Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "PRODUCT_NAME": "MultiPlatMore",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("multiplat/multiplat.swift")]),
                    ]
                ),
            ])

        let workspace = try TestWorkspace("TestWorkspace", projects: [testProject]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)

        let buildParameters = BuildParameters(configuration: "Debug")
        let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: workspace.projects[0].targets[0])

        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

        XCTAssertEqualSequences(buildGraph.allTargets.map({ $0.target.name }).sorted(), ["Shared Framework 1", "App", "MultiPlat Framework", "Downstream MultiPlat Framework"].sorted())

        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.checkDiagnostics([
                "Shared Framework 2 rejected as an implicit dependency because its SDK_VARIANT 'iosmac' is not equal to this target\'s SDK_VARIANT 'macos' and it is not zippered. (in target \'App\' from project \'aProject\')", "Shared Framework 2 rejected as an implicit dependency because its SDK_VARIANT 'iosmac' is not equal to this target\'s SDK_VARIANT 'macos' and it is not zippered. (in target \'MultiPlat Framework\' from project \'aProject\')"])
        }
        else {
            delegate.checkNoDiagnostics()
        }
    }

    /// Test that targets with different `IMPLICIT_DEPENDENCY_DOMAIN` values only match targets with the same values.
    @Test
    func implicitDependencyDomain() async throws {
        let core = try await getCore()

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // app files
                    TestFile("app/app.swift"),

                    // framework files
                    TestFile("framework/framework.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "$(ARCHS_STANDARD)",
                    "ENABLE_ON_DEMAND_RESOURCES": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGN_IDENTITY": "",
                    "SDKROOT": "macosx",
                    "SWIFT_VERSION": swiftVersion,
                    "SWIFT_INSTALL_OBJC_HEADER": "NO",
                    "SKIP_INSTALL": "YES",
                    "GENERATE_INFOPLIST_FILE": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "DefaultApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "App",
                            // IMPLICIT_DEPENDENCY_DOMAIN = default
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["app/app.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("Framework.framework"),
                        ])
                    ],
                    dependencies: []
                ),
                TestStandardTarget(
                    "DefaultFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "Framework",
                            // IMPLICIT_DEPENDENCY_DOMAIN = default
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("framework/framework.swift")]),
                    ]
                ),
                TestStandardTarget(
                    "OtherApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "App",
                            "IMPLICIT_DEPENDENCY_DOMAIN": "other",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["app/app.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("Framework.framework"),
                            TestBuildFile("ExplicitFramework.framework"),
                        ])
                    ],
                    dependencies: [
                        "ExplicitFramework",
                    ]
                ),
                TestStandardTarget(
                    "OtherFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "Framework",
                            "IMPLICIT_DEPENDENCY_DOMAIN": "other",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("framework/framework.swift")]),
                    ]
                ),
                // These targets test that they will not match against anything, because they set their domain to empty.
                TestStandardTarget(
                    "EmptyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "App",
                            "IMPLICIT_DEPENDENCY_DOMAIN": "",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["app/app.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("Framework.framework"),
                            TestBuildFile("ExplicitFramework.framework"),
                        ])
                    ],
                    dependencies: [
                        "ExplicitFramework",
                    ]
                ),
                TestStandardTarget(
                    "EmptyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "Framework",
                            "IMPLICIT_DEPENDENCY_DOMAIN": "",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("framework/framework.swift")]),
                    ]
                ),
                // Test that domains don't affect explicit dependencies.
                TestStandardTarget(
                    "ExplicitFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "ExplicitFramework",
                            // IMPLICIT_DEPENDENCY_DOMAIN = default
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("framework/framework.swift")]),
                    ]
                ),
            ])
        let workspace = try TestWorkspace("TestWorkspace", projects: [testProject]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        // Enable this line to test the diagnostics.
        //workspaceContext.userPreferences = UserPreferences(enableDebugActivityLogs: true, enableBuildDebugging: false, enableBuildSystemCaching: false, activityTextShorteningLevel: .full, usePerConfigurationBuildLocations: nil, allowsExternalToolExecution: true)
        let buildParameters = BuildParameters(configuration: "Debug")

        // Test the default domain.
        do {
            let appTargetName = "DefaultApp"
            guard let target = workspace.projects[0].targets.filter({ $0.name == appTargetName }).only else {
                Issue.record("Could not find singleton target named '\(appTargetName)' among targets: \(workspace.projects[0].targets.map({ $0.name }).joined(separator: ", "))")
                return
            }
            let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: target)
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            XCTAssertEqualSequences(buildGraph.allTargets.map({ $0.target.name }).sorted(), ["DefaultFramework", "DefaultApp"].sorted())

            if workspaceContext.userPreferences.enableDebugActivityLogs {
                delegate.checkDiagnostics([
                    "EmptyFramework rejected as an implicit dependency because its IMPLICIT_DEPENDENCY_DOMAIN is empty (trying to match this target\'s domain \'default\'). (in target \'DefaultApp\' from project \'aProject\')",
                    "OtherFramework rejected as an implicit dependency because its IMPLICIT_DEPENDENCY_DOMAIN \'other\' is not equal to this target\'s domain \'default\'. (in target \'DefaultApp\' from project \'aProject\')",
                ])
            }
            else {
                delegate.checkNoDiagnostics()
            }
        }

        // Test the lar domain.
        do {
            let appTargetName = "OtherApp"
            guard let target = workspace.projects[0].targets.filter({ $0.name == appTargetName }).only else {
                Issue.record("Could not find singleton target named '\(appTargetName)' among targets: \(workspace.projects[0].targets.map({ $0.name }).joined(separator: ", "))")
                return
            }
            let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: target)
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            XCTAssertEqualSequences(buildGraph.allTargets.map({ $0.target.name }).sorted(), ["ExplicitFramework", "OtherApp", "OtherFramework"].sorted())

            if workspaceContext.userPreferences.enableDebugActivityLogs {
                delegate.checkDiagnostics([
                    "DefaultFramework rejected as an implicit dependency because its IMPLICIT_DEPENDENCY_DOMAIN \'default\' is not equal to this target\'s domain \'other\'. (in target \'OtherApp\' from project \'aProject\')",
                    "EmptyFramework rejected as an implicit dependency because its IMPLICIT_DEPENDENCY_DOMAIN is empty (trying to match this target\'s domain \'other\'). (in target \'OtherApp\' from project \'aProject\')",
                ])
            }
            else {
                delegate.checkNoDiagnostics()
            }
        }

        // Test the empty domain.
        do {
            let appTargetName = "EmptyApp"
            guard let target = workspace.projects[0].targets.filter({ $0.name == appTargetName }).only else {
                Issue.record("Could not find singleton target named '\(appTargetName)' among targets: \(workspace.projects[0].targets.map({ $0.name }).joined(separator: ", "))")
                return
            }
            let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: target)
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            XCTAssertEqualSequences(buildGraph.allTargets.map({ $0.target.name }).sorted(), ["EmptyApp", "ExplicitFramework"].sorted())

            if workspaceContext.userPreferences.enableDebugActivityLogs {
                delegate.checkDiagnostics([
                    "EmptyApp not resolving implicit dependencies because IMPLICIT_DEPENDENCY_DOMAIN is empty. (in target \'EmptyApp\' from project \'aProject\')",
                ])
            }
            else {
                delegate.checkNoDiagnostics()
            }
        }
    }

    @Test
    func implicitDependenciesHonorExcludedSourceFileNames() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [
                                            TestProject(
                                                "Project",
                                                groupTree: TestGroup("SomeFiles"),
                                                buildConfigurations: [
                                                    TestBuildConfiguration("Release"),
                                                    TestBuildConfiguration("Release-LightDeps"),
                                                ],
                                                targets: [
                                                    TestStandardTarget(
                                                        "AppTarget",
                                                        type: .application,
                                                        buildConfigurations: [
                                                            TestBuildConfiguration("Release"),
                                                            TestBuildConfiguration("Release-LightDeps", buildSettings: [
                                                                "EXCLUDED_SOURCE_FILE_NAMES": "SometimesUsedDependency.framework",
                                                            ]),
                                                        ],
                                                        buildPhases: [
                                                            TestFrameworksBuildPhase([
                                                                "AlwaysUsedDependency.framework",
                                                                "SometimesUsedDependency.framework",
                                                            ]),
                                                            TestCopyFilesBuildPhase([
                                                                "AlwaysUsedDependency.framework",
                                                                "SometimesUsedDependency.framework",
                                                            ], destinationSubfolder: .frameworks),
                                                        ]
                                                    ),
                                                    TestStandardTarget(
                                                        "AlwaysUsedDependency",
                                                        type: .framework,
                                                        buildConfigurations: [
                                                            TestBuildConfiguration("Release"),
                                                            TestBuildConfiguration("Release-LightDeps"),
                                                        ],
                                                        buildPhases: [
                                                            TestFrameworksBuildPhase(),
                                                        ]
                                                    ),
                                                    TestStandardTarget(
                                                        "SometimesUsedDependency",
                                                        type: .framework,
                                                        buildConfigurations: [
                                                            TestBuildConfiguration("Release"),
                                                            TestBuildConfiguration("Release-LightDeps"),
                                                        ],
                                                        buildPhases: [
                                                            TestFrameworksBuildPhase(),
                                                        ]
                                                    ),
                                                ]
                                            )
                                          ]
        ).load(core)

        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]
        guard let target = project.targets.filter({ $0.name == "AppTarget" }).only else {
            Issue.record("Could not find singleton target named 'AppTarget' among targets: \(project.targets.map({ $0.name }).joined(separator: ", "))")
            return
        }

        // Test the Release configuration
        do {
            let buildParameters = BuildParameters(configuration: "Release")
            let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: target)
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            XCTAssertEqualSequences(buildGraph.allTargets.map({ $0.target.name }).sorted(), ["AppTarget", "AlwaysUsedDependency", "SometimesUsedDependency"].sorted())
        }

        // Test the Release-LightDeps configuration
        do {
            let buildParameters = BuildParameters(configuration: "Release-LightDeps")
            let appTarget = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: target)
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [appTarget], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)

            let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)

            XCTAssertEqualSequences(buildGraph.allTargets.map({ $0.target.name }).sorted(), ["AppTarget", "AlwaysUsedDependency"].sorted())
        }
    }
}

@Suite fileprivate struct SuperimposedPropertiesTests: CoreBasedTests {
    /// Test properties imposed on dependencies of frameworks configured with `AUTOMATICALLY_MERGE_DEPENDENCIES`.
    @Test(.requireSDKs(.iOS))
    func mergedFrameworkPropertyImposition() async throws {
        let core = try await getCore()
        let workspace = try await TestWorkspace("Workspace",
                                                projects: [
                                                    TestProject(
                                                        "aProject",
                                                        groupTree: TestGroup("SomeFiles"),
                                                        buildConfigurations: [
                                                            TestBuildConfiguration(
                                                                "Release",
                                                                buildSettings: [
                                                                    "CODE_SIGN_IDENTITY": "-",
                                                                    "INFOPLIST_FILE": "$(TARGET_NAME)-Info.plist",
                                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                    "SDKROOT": "iphoneos",
                                                                    "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                                                    "SWIFT_VERSION": swiftVersion,
                                                                    "TAPI_EXEC": tapiToolPath.str,
                                                                ]),
                                                        ],
                                                        targets: [
                                                            // App target
                                                            TestStandardTarget(
                                                                "AppTarget",
                                                                type: .application,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release"),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                        "MergedFwkTarget.framework",
                                                                    ]),
                                                                    // Embed
                                                                    TestCopyFilesBuildPhase([
                                                                        "MergedFwkTarget.framework",
                                                                        "FwkTarget1.framework",
                                                                        "FwkTarget2.framework",
                                                                        // FIXME: rdar://105297527: Realistically people will add the dylib here, but we should not copy it if we merged it into the merged framework
                                                                    ], destinationSubfolder: .frameworks),
                                                                ],
                                                                dependencies: ["MergedFwkTarget"]
                                                            ),
                                                            // Merged framework target
                                                            TestStandardTarget(
                                                                "MergedFwkTarget",
                                                                type: .framework,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release",
                                                                                           buildSettings: [
                                                                                            "AUTOMATICALLY_MERGE_DEPENDENCIES": "YES",
                                                                                           ]),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                        "FwkTarget1.framework",
                                                                        "FwkTarget2.framework",
                                                                        "libDylibTarget.dylib",
                                                                        "libStaticLibTarget.a",
                                                                    ]),
                                                                    TestCopyFilesBuildPhase([
                                                                        "XPCServiceTarget.xpc",
                                                                    ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/XPCServices"),
                                                                    TestCopyFilesBuildPhase([
                                                                        "BundleTarget.bundle",
                                                                    ], destinationSubfolder: .plugins),
                                                                ],
                                                                // We want to test both explicit and implicit dependencies so not all targets are listed here.
                                                                dependencies: ["FwkTarget1"]
                                                            ),
                                                            // Targets which the merged target depends on.  Some of these will be configured as mergeable, and others will not.
                                                            TestStandardTarget(
                                                                "FwkTarget1",
                                                                type: .framework,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release"),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                    ]),
                                                                ]
                                                            ),
                                                            TestStandardTarget(
                                                                "FwkTarget2",
                                                                type: .framework,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release"),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                    ]),
                                                                ]
                                                            ),
                                                            TestStandardTarget(
                                                                "DylibTarget",
                                                                type: .dynamicLibrary,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release"),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                    ]),
                                                                ]
                                                            ),
                                                            TestStandardTarget(
                                                                "StaticLibTarget",
                                                                type: .staticLibrary,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release"),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                    ]),
                                                                ]
                                                            ),
                                                            TestStandardTarget(
                                                                // The merged framework embedding an XPC service seems like something that might occur.
                                                                "XPCServiceTarget",
                                                                type: .xpcService,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release"),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                    ]),
                                                                ]
                                                            ),
                                                            TestStandardTarget(
                                                                // Bundles are largely treated like dylibs, but they cannot be explicitly linked against and must be dlopen()ed.
                                                                "BundleTarget",
                                                                type: .bundle,
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Release"),
                                                                ],
                                                                buildPhases: [
                                                                    TestFrameworksBuildPhase([
                                                                    ]),
                                                                ]
                                                            ),
                                                        ])
                                                ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let project = workspace.projects[0]

        // The key thing that's being tested here is that all of the targets are top-level targets, but since MergedFwkTarget has AUTOMATICALLY_MERGE_DEPENDENCIES set, it will impose on its framework & dylib dependencies, and we want to make sure that none of them show up more than once, there should only be one of each, with MERGEABLE_LIBRARY enabled.
        // TaskConstructionTests.MergeableLibraryTests will also exercise this, but this is a lower-level test exercising target dependency resolution specifically.
        let parameters = BuildParameters(configuration: "Release")
        let targets = project.targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace)
        let buildGraph = await TargetGraphFactory(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate).graph(type: .dependency)
        delegate.checkNoDiagnostics()

        // Check the dependency closure, especially that each target was configured only once.
        let targetList = Array(buildGraph.allTargets)
        #expect(targetList.map({ $0.target.name }) == ["FwkTarget1", "FwkTarget2", "DylibTarget", "StaticLibTarget", "XPCServiceTarget", "BundleTarget", "MergedFwkTarget", "AppTarget"])

        // Check that MERGEABLE_LIBRARY was imposed on targets it should have been.
        for targetName in ["FwkTarget1", "FwkTarget2", "DylibTarget"] {
            if let target = targetList.first(where: { $0.target.name == targetName}) {
                #expect(target.parameters.overrides[BuiltinMacros.MERGEABLE_LIBRARY.name] == "YES")
            }
        }
        // Check that MERGEABLE_LIBRARY was *not* imposed on targets it shouldn't have been.
        for targetName in ["StaticLibTarget", "XPCServiceTarget", "BundleTarget"] {
            if let target = targetList.first(where: { $0.target.name == targetName}) {
                if let value = target.parameters.overrides[BuiltinMacros.MERGEABLE_LIBRARY.name] {
                    Issue.record("\(target.target.name) has unexpected value '\(value)' for \(BuiltinMacros.MERGEABLE_LIBRARY.name)")
                }
            }
        }
    }
}

private extension TargetGraph {
    func target(for targetInfo: BuildRequest.BuildTargetInfo, sourceLocation: SourceLocation = #_sourceLocation) throws -> ConfiguredTarget {
        return try #require(target(for: targetInfo), "unable to find target \(targetInfo.target.name)", sourceLocation: sourceLocation)
    }

    private func target(for targetInfo: BuildRequest.BuildTargetInfo) -> ConfiguredTarget? {
        for target in allTargets {
            if target.target == targetInfo.target && target.parameters == targetInfo.parameters {
                return target
            }
        }
        return nil
    }

    func targets(named: String) -> [ConfiguredTarget] {
        return allTargets.filter({ $0.target.name == named })
    }

    func dependencies(_ targetInfo: BuildRequest.BuildTargetInfo) throws -> [ConfiguredTarget] {
        return dependencies(of: try target(for: targetInfo))
    }
}
