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

package import Testing

package import SWBCore
package import SWBProtocol
import SWBUtil
package import SWBMacro

extension CoreBasedTests {
    package func testActiveRunDestination(_ targetType: TestStandardTarget.TargetType = .application, extraBuildSettings: [String: String] = [:], runDestination: RunDestinationInfo?, activeArchitecture: String? = nil, hostArchitecture: String? = nil, _ check: (WorkspaceContext, Settings, MacroEvaluationScope) throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var buildSettings = [
            "ONLY_ACTIVE_ARCH": "YES",
        ]
        buildSettings.addContents(of: extraBuildSettings)

        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "Project",
                    groupTree: TestGroup("SomeFiles", children: [TestFile("file.c")]),
                    targets: [
                        TestStandardTarget(
                            "Target",
                            type: targetType,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: buildSettings)],
                            buildPhases: [TestSourcesBuildPhase(["file.c"])])])]).load(getCore(sourceLocation: sourceLocation))

        let context = try await contextForTestData(testWorkspace, systemInfo: hostArchitecture.map { hostArchitecture in SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: hostArchitecture) } ?? nil)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination, activeArchitecture: activeArchitecture)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
        let scope = settings.globalScope

        try check(context, settings, scope)
    }
}
