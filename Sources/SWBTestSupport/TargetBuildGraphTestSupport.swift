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

package import SWBCore
package import SWBUtil
package import Testing

/// An empty delegate implementation.
package final class EmptyTargetDependencyResolverDelegate: TargetDependencyResolverDelegate, Sendable {
    package let diagnosticContext: DiagnosticContextData

    package let workspace: Workspace
    private let diagnosticsEngines = LockedValue<[ConfiguredTarget?: DiagnosticsEngine]>(.init())

    package init(workspace: Workspace) {
        self.workspace = workspace
        self.diagnosticContext = DiagnosticContextData(target: nil)
    }

    package func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return .init(diagnosticsEngines.withLock { $0.getOrInsert(target, { DiagnosticsEngine() }) })
    }

    package var diagnostics: [ConfiguredTarget?: [Diagnostic]] {
        diagnosticsEngines.withLock { $0.mapValues { $0.diagnostics } }
    }

    package func emit(_ diagnostic: Diagnostic) {
        diagnosticsEngine(for: nil).emit(diagnostic)
    }

    package func updateProgress(statusMessage: String, showInLog: Bool) { }
}

extension EmptyTargetDependencyResolverDelegate {
    package func checkNoDiagnostics(sourceLocation: SourceLocation = #_sourceLocation) {
        checkDiagnostics([], sourceLocation: sourceLocation)
    }

    package func checkDiagnostics(
        format: Diagnostic.LocalizedDescriptionFormat = .debugWithoutBehavior,
        _ diagnostics: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(self.diagnostics.formatLocalizedDescription(format, workspace: workspace, filter: { _ in true }).sorted() == diagnostics.sorted(), sourceLocation: sourceLocation)
    }
}


extension TargetBuildGraph {
    /// Convenience initializer which uses an empty delegate implementation for testing.
    package init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext) async {
        await self.init(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: EmptyTargetDependencyResolverDelegate(workspace: workspaceContext.workspace))
    }
}

package struct TargetGraphFactory: Sendable {
    let workspaceContext: WorkspaceContext
    let buildRequest: BuildRequest
    let buildRequestContext: BuildRequestContext
    let delegate: EmptyTargetDependencyResolverDelegate

    package init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: EmptyTargetDependencyResolverDelegate) {
        self.workspaceContext = workspaceContext
        self.buildRequest = buildRequest
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
    }

    package enum GraphType: CaseIterable, Sendable {
        case dependency
        case linkage
    }

    package func graph(type: GraphType) async -> any TargetGraph {
        switch type {
        case .dependency:
            return await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        case .linkage:
            return await TargetLinkageGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        }
    }
}
