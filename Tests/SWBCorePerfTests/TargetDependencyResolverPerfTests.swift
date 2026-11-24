//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
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

@Suite(.performance)
fileprivate struct TargetDependencyResolverPerfTests: CoreBasedTests, PerfTests {
    /// Measure the time to compute the dependency graph of an iOS app with many frameworks and libraries, which use a host tool with a chain of dependencies. Under an iOS simulator destination, the host tool's dependencies are built for the host's architecture.
    @Test(.requireSDKs(.macOS, .iOS))
    func dependencyGraphWithHostToolDependencies() async throws {
        let libraryCount = 240
        let frameworkCount = 60
        let hostToolDependencyCount = 40
        let autoSettings = ["SDKROOT": "auto", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"]

        func target(_ name: String, type: TestStandardTarget.TargetType, buildSettings: [String: String] = autoSettings, dependencies: [String]) -> TestStandardTarget {
            TestStandardTarget(name, type: type, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: buildSettings)], buildPhases: [TestSourcesBuildPhase(["file.swift"])], dependencies: dependencies.map { TestTargetDependency($0) })
        }
        var targets = [any TestTarget]()
        targets.append(target("App", type: .application, buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"], dependencies: (0..<frameworkCount).map { "Framework\($0)" }))
        for index in 0..<frameworkCount {
            targets.append(target("Framework\(index)", type: .framework, dependencies: ["HostTool"] + (0..<4).map { "Library\((index * 4 + $0) % libraryCount)" }))
        }
        for index in 0..<libraryCount {
            targets.append(target("Library\(index)", type: .staticLibrary, dependencies: [index + 1, index + 2].filter { $0 < libraryCount }.map { "Library\($0)" }))
        }
        targets.append(target("HostTool", type: .hostBuildTool, buildSettings: ["SDKROOT": "auto"], dependencies: ["HostToolDependency0"]))
        for index in 0..<hostToolDependencyCount {
            targets.append(target("HostToolDependency\(index)", type: .staticLibrary, dependencies: index + 1 < hostToolDependencyCount ? ["HostToolDependency\(index + 1)"] : []))
        }

        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace", projects: [
            TestProject(
                "aProject",
                groupTree: TestGroup("Sources", children: [TestFile("file.swift")]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)", "MACOSX_DEPLOYMENT_TARGET": "26.0"])],
                targets: targets)
        ]).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let parameters = BuildParameters(configuration: "Debug", activeRunDestination: .iOSSimulator)
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: parameters, target: workspace.projects[0].targets[0])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        try await measure {
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspace)
            let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
            #expect(buildGraph.allTargets.count == 1 + frameworkCount + libraryCount + 1 + hostToolDependencyCount)
            #expect(buildGraph.configuredTargetReplacements.count == hostToolDependencyCount)
        }
    }
}
