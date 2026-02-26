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

import SWBUtil

/// A `TargetDependencyResolverDelegate` wrapper that collects all emitted
/// diagnostics while forwarding them to an inner delegate.
///
/// Used by `TargetBuildGraph.cached(...)` to capture diagnostics during graph
/// resolution so they can be stored in the cache and re-emitted on cache hits.
final class DiagnosticCollectingDelegate: TargetDependencyResolverDelegate {
    private let inner: any TargetDependencyResolverDelegate

    /// All diagnostics emitted during resolution, in order.
    private(set) var collectedDiagnostics: [Diagnostic] = []

    /// Whether any error-level diagnostics were emitted.
    var hadErrors: Bool {
        collectedDiagnostics.contains { $0.behavior == .error }
    }

    init(inner: any TargetDependencyResolverDelegate) {
        self.inner = inner
    }

    func emit(_ diagnostic: Diagnostic) {
        collectedDiagnostics.append(diagnostic)
        inner.emit(diagnostic)
    }

    func updateProgress(statusMessage: String, showInLog: Bool) {
        inner.updateProgress(statusMessage: statusMessage, showInLog: showInLog)
    }

    var diagnosticContext: DiagnosticContextData {
        inner.diagnosticContext
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        inner.diagnosticsEngine(for: target)
    }
}
