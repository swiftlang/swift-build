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
package import struct SWBProtocol.RunDestinationInfo
package import SWBTaskConstruction
package import SWBTaskExecution
package import SWBUtil

extension BuildDescription {
    package var tasks: [Task] {
        var tasks: [Task] = []
        taskStore.forEachTask { task in
            tasks.append(task)
        }
        return tasks.sorted(by: \.identifier)
    }
}

/// Category for tests which need to use BuildDescription objects.
extension CoreBasedTests {
    // This should be private, but is public to work around a compiler bug: rdar://108924001 (Unexpected missing symbol in tests (optimizer issue?))
    package func buildGraph(for workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, configuration: String = "Debug", activeRunDestination: RunDestinationInfo?, overrides: [String: String] = [:], useImplicitDependencies: Bool = false, dependencyScope: DependencyScope = .workspace, fs: any FSProxy = PseudoFS(), includingTargets predicate: (Target) -> Bool) async -> TargetBuildGraph {
        // Create a fake build request to build all targets.
        let parameters = BuildParameters(configuration: configuration, activeRunDestination: activeRunDestination, overrides: overrides)
        let buildTargets = workspaceContext.workspace.projects.flatMap{ project in
            project.targets.compactMap {
                return predicate($0) ? BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) : nil
            }
        }
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, dependencyScope: dependencyScope, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: useImplicitDependencies, useDryRun: false)

        // Create the build graph.
        return await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
    }

    package func planRequest(for workspace: Workspace, configuration: String = "Debug", activeRunDestination: RunDestinationInfo?, overrides: [String: String] = [:], fs: any FSProxy = PseudoFS(), includingTargets predicate: (Target) -> Bool) async throws -> BuildPlanRequest {
        // Create a workspace context.
        let workspaceContext = try await WorkspaceContext(core: getCore(), workspace: workspace, fs: fs, processExecutionCache: .sharedForTesting)

        workspaceContext.updateUserPreferences(.defaultForTesting)

        // Configure fake user and system info.
        workspaceContext.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid:12345, home: Path.root.join("Users/exampleUser"), environment: [:]))
        workspaceContext.updateSystemInfo(SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "x86_64"))

        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        let buildGraph = await self.buildGraph(for: workspaceContext, buildRequestContext: buildRequestContext, configuration: configuration, activeRunDestination: activeRunDestination, overrides: overrides, fs: fs, includingTargets: predicate)

        // Construct an appropriate set of provisioning inputs. This is important for performance testing to ensure we end up with representative code signing tasks, which trigger the mutable node analysis during build description construction.
        var provisioningInputs = [ConfiguredTarget: ProvisioningTaskInputs]()
        for ct in buildGraph.allTargets {
            // We just force everything to be signed.
            provisioningInputs[ct] = ProvisioningTaskInputs(identityHash: "-")
        }

        return BuildPlanRequest(workspaceContext: buildGraph.workspaceContext, buildRequest: buildGraph.buildRequest, buildRequestContext: buildRequestContext, buildGraph: buildGraph, provisioningInputs: provisioningInputs)
    }

    package func buildDescription(for workspace: Workspace, configuration: String = "Debug", activeRunDestination: RunDestinationInfo?, overrides: [String: String] = [:], fs: any FSProxy = PseudoFS(), includingTargets predicate: (Target) -> Bool = { _ in true }) async throws -> (BuildDescription, WorkspaceContext) {
        let tuple: (BuildDescriptionDiagnosticResults, WorkspaceContext) = try await buildDescription(for: workspace, configuration: configuration, activeRunDestination: activeRunDestination, overrides: overrides, fs: fs, includingTargets: predicate)
        return (tuple.0.buildDescription, tuple.1)
    }

    @_disfavoredOverload package func buildDescription(for workspace: Workspace, configuration: String = "Debug", activeRunDestination: RunDestinationInfo?, overrides: [String: String] = [:], fs: any FSProxy = PseudoFS(), includingTargets predicate: (Target) -> Bool = { _ in true }) async throws -> (BuildDescriptionDiagnosticResults, WorkspaceContext) {
        let planRequest = try await self.planRequest(for: workspace, configuration: configuration, activeRunDestination: activeRunDestination, overrides: overrides, fs: fs, includingTargets: predicate)
        let delegate = MockTestBuildDescriptionConstructionDelegate()
        guard let results = try await BuildDescriptionManager.constructBuildDescription(planRequest, signature: "", inDirectory: .root, fs: fs, bypassActualTasks: true, clientDelegate: MockTestTaskPlanningClientDelegate(), constructionDelegate: delegate).map({ BuildDescriptionDiagnosticResults(buildDescription: $0, workspace: workspace) }) ?? nil else {
            throw StubError.error("Could not construct build description")
        }
        return (results, planRequest.workspaceContext)
    }
}

package struct BuildDescriptionDiagnosticResults: Sendable {
    package let buildDescription: BuildDescription
    package let workspace: Workspace

    package init(buildDescription: BuildDescription, workspace: Workspace) {
        self.buildDescription = buildDescription
        self.workspace = workspace
    }

    package var errors: [String] {
        return buildDescription.diagnostics.formatLocalizedDescription(.debugWithoutBehavior, workspace: workspace, filter: { $0.behavior == .error })
    }

    package var warnings: [String] {
        return buildDescription.diagnostics.formatLocalizedDescription(.debugWithoutBehavior, workspace: workspace, filter: { $0.behavior == .warning })
    }

    package var notes: [String] {
        return buildDescription.diagnostics.formatLocalizedDescription(.debugWithoutBehavior, workspace: workspace, filter: { $0.behavior == .note })
    }
}

extension BuildDescriptionDiagnosticResults {
    package func checkNoDiagnostics(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(errors == [], sourceLocation: sourceLocation)
        #expect(warnings == [], sourceLocation: sourceLocation)
        #expect(notes == [], sourceLocation: sourceLocation)
    }
}
