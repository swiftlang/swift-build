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

import SWBProtocol
import SWBUtil

import Foundation

// rdar://142511013 (Remove deprecated macro evaluation scope logic from SWBuild)

/// An `SWBMacroEvaluationScope` provides a means to evaluate build settings against a macro evaluation scope in Swift Build.  A client must either request such a scope from the service, or must be running in a context where it can locate such a scope, and it can then request that the service evaluate build settings, strings, and string lists against the corresponding scope.
///
/// An object of this class is always associated with a specific session in the service.
@available(*, deprecated, message: "SWBMacroEvaluationScope is deprecated and should not be used")
public final class SWBMacroEvaluationScope: Sendable {
    /// The session containing the scope in the client.
    private unowned let session: SWBBuildServiceSession
    /// The UID of the settings in the session whose scope will be used for evaluation.
    let settingsHandle: String
    private let invalidated = LockedValue(false)

    init(_ session: SWBBuildServiceSession, _ settingsUID: String) {
        self.session = session
        self.settingsHandle = settingsUID
    }

    /// Discard the service-side `Settings` object when we are deinitialized.
    deinit {
        if !invalidated.withLock({ $0 }) {
            preconditionFailure("Scope must be invalidated before being deallocated.")
        }
    }

    /// Invalidates the receiver, directing the service to throw away its associated `Settings` object.
    ///
    /// - note: This method is idempotent. Only the first call to this method has the potential to throw an error.
    public func invalidate() async throws {
        if invalidated.withLock({ invalidated in
            if invalidated {
                return true
            }
            invalidated = true
            return false
        }) {
            return
        }
        try await session.discardMacroEvaluationScope(self)
    }

    // MARK: Evaluate macros


    // FIXME: It would be good to keep the string types we have internally here.
    // FIXME: It would be nice if there were a simple and extremely cheap way in the methods below to determine if there are not macros to expand, since then we could skip the round-trip to the service.

    /// Evaluate the given macro as a string (regardless of type).
    ///
    /// - Parameter overrides: If provided, this map of macro names to macro expressions will be consulted for each initial macro lookup to provide an alternate expression to evaluate.
    public func evaluateMacroAsString(_ macro: String, overrides: [String: String]? = nil) async throws -> String {
        return try await session.evaluateMacroAsString(macro, context: .settingsHandle(settingsHandle), overrides: overrides)
    }

    /// Evaluate the given macro as a string list.
    ///
    /// - Parameter overrides: If provided, this map of macro names to macro expressions will be consulted for each initial macro lookup to provide an alternate expression to evaluate.
    public func evaluateMacroAsStringList(_ macro: String, overrides: [String: String]? = nil) async throws -> [String] {
        return try await session.evaluateMacroAsStringList(macro, context: .settingsHandle(settingsHandle), overrides: overrides)
    }

    /// Evaluate the given macro as a boolean.
    ///
    /// - Parameter overrides: If provided, this map of macro names to macro expressions will be consulted for each initial macro lookup to provide an alternate expression to evaluate.
    public func evaluateMacroAsBool(_ macro: String, overrides: [String: String]? = nil) async throws -> Bool {
        return try await session.evaluateMacroAsBoolean(macro, context: .settingsHandle(settingsHandle), overrides: overrides)
    }


    // MARK: Evaluate macro expressions


    /// Evaluate the given string expression.
    ///
    /// - Parameter overrides: If provided, this map of macro names to macro expressions will be consulted for each initial macro lookup to provide an alternate expression to evaluate.
    public func evaluateMacroExpressionAsString(_ expr: String, overrides: [String: String]? = nil) async throws -> String {
        return try await session.evaluateMacroExpressionAsString(expr, context: .settingsHandle(settingsHandle), overrides: overrides)
    }

    /// Evaluate the given string expression as a string list.
    ///
    /// - Parameter overrides: If provided, this map of macro names to macro expressions will be consulted for each initial macro lookup to provide an alternate expression to evaluate.
    public func evaluateMacroExpressionAsStringList(_ expr: String, overrides: [String: String]? = nil) async throws -> [String] {
        return try await session.evaluateMacroExpressionAsStringList(expr, context: .settingsHandle(settingsHandle), overrides: overrides)
    }

    /// Evaluate the given string list expression.
    ///
    /// - Parameter overrides: If provided, this map of macro names to macro expressions will be consulted for each initial macro lookup to provide an alternate expression to evaluate.
    public func evaluateMacroExpressionArrayAsStringList(_ expr: [String], overrides: [String: String]? = nil) async throws -> [String] {
        return try await session.evaluateMacroExpressionArrayAsStringList(expr, context: .settingsHandle(settingsHandle), overrides: overrides)
    }


    // MARK: Specialized macro requests


    @available(*, deprecated, message: "use IDEBlueprint.getExportedMacroNamesAndValues() instead of using a scope")
    public func getExportedMacroNamesAndValues() async throws -> [String: String] {
        try await session.service.send(request: AllExportedMacrosAndValuesRequest(sessionHandle: session.uid, context: .settingsHandle(settingsHandle))).result
    }

}
