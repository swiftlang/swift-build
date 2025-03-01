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

import SWBBuildSystem
import SWBCore
import SWBProtocol
import SWBServiceCore
import SWBTaskConstruction
import SWBTaskExecution
import SWBUtil

final private class ResolverDelegate: TargetDependencyResolverDelegate {
    var cancelled: Bool { false }
    func emit(_ diagnostic: Diagnostic) {
        _diagnosticsEngine.emit(diagnostic)
    }
    func updateProgress(statusMessage: String, showInLog: Bool) {}
    let diagnosticContext: DiagnosticContextData = .init(target: nil)
    private var _diagnosticsEngine: DiagnosticsEngine = DiagnosticsEngine()
    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }
    var hasErrors: Bool {
        _diagnosticsEngine.hasErrors
    }
    var diagnostics: [Diagnostic] {
        _diagnosticsEngine.diagnostics
    }
    init() {
    }
}

private func constructTargetBuildGraph(for targetGUIDs: [TargetGUID], in workspaceContext: WorkspaceContext, buildParameters: BuildParametersMessagePayload, includeImplicitDependencies: Bool, dependencyScope: DependencyScopeMessagePayload) async throws -> TargetBuildGraph {
    var targets: [SWBCore.Target] = []
    for guid in targetGUIDs {
        guard let target = workspaceContext.workspace.target(for: guid.rawValue) else {
            throw MsgParserError.missingTarget(guid: guid.rawValue)
        }
        targets.append(target)
    }
    let parameters = try BuildParameters(from: buildParameters)
    let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
    let delegate = ResolverDelegate()

    let scope: DependencyScope
    switch dependencyScope {
    case .workspace:
        scope = .workspace
    case .buildRequest:
        scope = .buildRequest
    }
    let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext,
                                      buildRequest: BuildRequest(parameters: parameters,
                                                                 buildTargets: targets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }, dependencyScope: scope,
                                                                 continueBuildingAfterErrors: false,
                                                                 hideShellScriptEnvironment: true,
                                                                 useParallelTargets: false,
                                                                 useImplicitDependencies: includeImplicitDependencies,
                                                                 useDryRun: false),
                                      buildRequestContext: buildRequestContext,
                                      delegate: delegate,
                                      purpose: .dependencyGraph)
    if delegate.hasErrors {
        throw StubError.error("unable to get target build graph:\n" + delegate.diagnostics.map { $0.formatLocalizedDescription(.debug) }.joined(separator: "\n"))
    }
    return buildGraph
}

struct ComputeDependencyClosureMsg: MessageHandler {
    func handle(request: Request, message: ComputeDependencyClosureRequest) async throws -> StringListResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let buildGraph = try await constructTargetBuildGraph(for: message.targetGUIDs.map(TargetGUID.init(rawValue:)), in: workspaceContext, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope)
        let guids = buildGraph.allTargets.map(\.target.guid)
        return StringListResponse(guids)
    }
}

struct ComputeDependencyGraphMsg: MessageHandler {
    func handle(request: Request, message: ComputeDependencyGraphRequest) async throws -> DependencyGraphResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let buildGraph = try await constructTargetBuildGraph(for: message.targetGUIDs, in: workspaceContext, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope)
        var adjacencyList: [TargetGUID: [TargetGUID]] = [:]
        for configuredTarget in buildGraph.allTargets {
            adjacencyList[TargetGUID(rawValue: configuredTarget.target.guid), default: []].append(contentsOf: buildGraph.dependencies(of: configuredTarget).map { TargetGUID(rawValue: $0.target.guid) })
        }
        return DependencyGraphResponse(adjacencyList: adjacencyList)
    }
}
