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

public import SWBUtil
import SWBCSupport

extension Diagnostic {
    /// libRemarks is optional and the check lives in SWBCSupport. Pre-compute the availability here to avoid making all clients depend on it.
    public static let libRemarksAvailable = isLibRemarksAvailable()
}

public struct DiagnosticProducingDelegateProtocolPrivate<T> {
    fileprivate let instance: T

    public init(_ instance: T) {
        self.instance = instance
    }
}

extension DiagnosticProducingDelegateProtocolPrivate where T == DiagnosticsEngine {
    public func emit(_ diagnostic: Diagnostic) {
        instance.emit(diagnostic)
    }
}

/// Common protocol for delegates for things which can produce diagnostics.
public protocol DiagnosticProducingDelegate {
    /// The diagnostics engine to use.
    var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> { get }

    /// Emit a diagnostic.
    func emit(_ diagnostic: Diagnostic)

    /// Emit a string note diagnostic.
    func note(_ message: String, location: Diagnostic.Location, component: Component)

    /// Emit a string warning diagnostic.
    func warning(_ message: String, location: Diagnostic.Location, component: Component)

    /// Emit a string error diagnostic.
    func error(_ message: String, location: Diagnostic.Location, component: Component)

    /// Emit a string remark diagnostic.
    func remark(_ message: String, location: Diagnostic.Location, component: Component)
}

/// Simplified string diagnostics.
public extension DiagnosticProducingDelegate {
    /// Emit a diagnostic.
    func emit(_ diagnostic: Diagnostic) {
        diagnosticsEngine.instance.emit(diagnostic)
    }

    /// Emit a string note diagnostic.
    func note(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        diagnosticsEngine.instance.emit(data: DiagnosticData(message, component: component), behavior: .note, location: location)
    }

    /// Emit a string warning diagnostic.
    func warning(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        diagnosticsEngine.instance.emit(data: DiagnosticData(message, component: component), behavior: .warning, location: location)
    }

    /// Emit a string error diagnostic.
    func error(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        diagnosticsEngine.instance.emit(data: DiagnosticData(message, component: component), behavior: .error, location: location)
    }

    /// Emit a string remark diagnostic.
    func remark(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        diagnosticsEngine.instance.emit(data: DiagnosticData(message, component: component), behavior: .remark, location: location)
    }

    /// Emit a typed error diagnostic using its string description form.
    func error(_ error: any Error) {
        self.error("\(error)")
    }

    /// Emit a string note diagnostic.
    func note(_ path: Path, line: Int? = nil, column: Int? = nil, _ message: String) {
        self.note(message, location: .path(path, line: line, column: column))
    }

    /// Emit a string warning diagnostic.
    func warning(_ path: Path, line: Int? = nil, column: Int? = nil, _ message: String) {
        self.warning(message, location: .path(path, line: line, column: column))
    }

    /// Emit a string error diagnostic.
    func error(_ path: Path, line: Int? = nil, column: Int? = nil, _ message: String) {
        self.error(message, location: .path(path, line: line, column: column))
    }

    /// Emit a string remark diagnostic.
    func remark(_ path: Path, line: Int? = nil, column: Int? = nil, _ message: String) {
        self.remark(message, location: .path(path, line: line, column: column))
    }
}

/// A delegate which can emit string warning diagnostics for a particular `ConfiguredTarget`.
public protocol TargetDiagnosticProducingDelegate: DiagnosticProducingDelegate {
    /// Emit a diagnostic for a particular target.
    func emit(_ context: TargetDiagnosticContext, _ diagnostic: Diagnostic)

    /// Emit a string note diagnostic for a particular target.
    func note(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location, component: Component)

    /// Emit a string warning diagnostic for a particular target.
    func warning(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location, component: Component, childDiagnostics: [Diagnostic])

    /// Emit a string error diagnostic for a particular target.
    func error(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location, component: Component)

    /// Emit a string error diagnostic for a particular target.
    func remark(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location, component: Component)

    /// The target context that diagnostic messages should be associated with, if any.
    var diagnosticContext: DiagnosticContextData { get }

    /// The diagnostics engine to use for target-specific diagnostics.
    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine>
}

public struct DiagnosticContextData: Sendable {
    let target: ConfiguredTarget?

    public init(target: ConfiguredTarget?) {
        self.target = target
    }
}

public enum TargetDiagnosticContext {
    /// Emits a diagnostic in the context of the delegate's target, if the delegate is associated with a target context. If no target context is associated, emits a global diagnostic.
    case `default`

    /// Emits a diagnostic in the context of the given target.
    ///
    /// This should not normally be used if `default` would otherwise be sufficient, but can be used in special cases where the target must be different from the delegate's, or if the delegate is not associated with any target context.
    case overrideTarget(_ target: ConfiguredTarget)

    /// Emits a global diagnostic.
    ///
    /// This can be used where the delegate is associated with a target context, but the diagnostic specifically should not be associated with any target for some reason.
    case global
}

extension TargetDiagnosticProducingDelegate {
    private func target(for context: TargetDiagnosticContext) -> ConfiguredTarget? {
        switch context {
        case .default:
            return diagnosticContext.target
        case let .overrideTarget(target):
            return target
        case .global:
            return nil
        }
    }

    public var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        diagnosticsEngine(for: nil)
    }

    private func diagnosticsEngine(for context: TargetDiagnosticContext) -> DiagnosticsEngine {
        (target(for: context).map { diagnosticsEngine(for: $0).instance } ?? diagnosticsEngine.instance)
    }

    public func emit(_ context: TargetDiagnosticContext, _ diagnostic: Diagnostic) {
        diagnosticsEngine(for: context).emit(diagnostic)
    }

    public func note(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        diagnosticsEngine(for: context).emit(data: DiagnosticData(message, component: component), behavior: .note, location: location)
    }

    public func warning(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location = .unknown, component: Component = .default, childDiagnostics: [Diagnostic] = []) {
        diagnosticsEngine(for: context).emit(data: DiagnosticData(message, component: component), behavior: .warning, location: location, childDiagnostics: childDiagnostics)
    }

    public func error(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        diagnosticsEngine(for: context).emit(data: DiagnosticData(message, component: component), behavior: .error, location: location)
    }

    public func remark(_ context: TargetDiagnosticContext, _ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        diagnosticsEngine(for: context).emit(data: DiagnosticData(message, component: component), behavior: .remark, location: location)
    }

    /// Emit a diagnostic.
    public func emit(_ diagnostic: Diagnostic) {
        self.emit(.default, diagnostic)
    }

    /// Emit a string note diagnostic.
    public func note(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        self.note(.default, message, location: location, component: component)
    }

    /// Emit a string warning diagnostic.
    public func warning(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default, childDiagnostics: [Diagnostic] = []) {
        self.warning(.default, message, location: location, component: component, childDiagnostics: childDiagnostics)
    }

    /// Emit a string error diagnostic.
    public func error(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        self.error(.default, message, location: location, component: component)
    }

    /// Emit a string error diagnostic.
    public func remark(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        self.remark(.default, message, location: location, component: component)
    }
}
