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

import SWBUtil

/// How a single command's environment should be handed to llbuild
package enum EnvironmentEncoding: Equatable {

    /// Send the environment whole, as the command's own `env`.
    case inline

    /// Point the command at the shared environment base named `base`, sending only
    /// `overrides`
    case useBase(base: String, overrides: [(String, String)])

    package static func == (lhs: EnvironmentEncoding, rhs: EnvironmentEncoding) -> Bool {
        switch (lhs, rhs) {
        case (.inline, .inline):
            return true
        case (.useBase(let lBase, let lOverrides), .useBase(let rBase, let rOverrides)):
            return lBase == rBase && lOverrides.elementsEqual(rOverrides, by: ==)
        case (.inline, _), (.useBase, _):
            return false
        }
    }
}

/// Shares the bulk of command environments, so variables many commands have in
/// common are declared once rather than repeated
package struct EnvironmentBaseTable: Sendable {

    private struct Candidate: Sendable {
        let bindings: [(String, String)]
        var declaredIndex: Int?
        let unshareable: Bool
        var references: Int
    }

    private static let minimumCommandsToShareABase = 2

    private var candidates: [Candidate] = []

    private var candidateIndexByKeys: [[String]: Int] = [:]

    package init() {}

    /// Build a table over all of a build's environments.
    package init(environments: some Sequence<[(String, String)]>) {
        for bindings in environments {
            register(bindings)
        }
        nameSharedBases()
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        candidates.lazy.compactMap { candidate in candidate.declaredIndex.map { (Self.name(ofBase: $0), candidate.bindings) } }
    }

    package func encoding(for bindings: [(String, String)]) -> EnvironmentEncoding {
        guard let reference = baseReference(for: bindings) else {
            return .inline
        }
        return .useBase(base: Self.name(ofBase: reference.index), overrides: reference.positions.map { bindings[$0] })
    }

    /// The base for `bindings`, by its position in `declaredBases`, and the positions at which `bindings` has a different value.
    package func baseReference(for bindings: [(String, String)]) -> (index: Int, positions: [Int])? {
        guard let candidate = candidate(forKeysOf: bindings), let index = candidate.declaredIndex else {
            return nil
        }
        return (index, differingPositions(in: bindings, relativeTo: candidate.bindings))
    }

    private static func name(ofBase index: Int) -> String {
        "env-base-\(index)"
    }

    private mutating func register(_ bindings: [(String, String)]) {
        guard !bindings.isEmpty else { return }

        if let index = candidateIndex(forKeysOf: bindings) {
            candidates[index].references += 1
            return
        }

        let unshareable = Set(bindings.lazy.map { $0.0 }).count != bindings.count
        candidates.append(Candidate(bindings: bindings, declaredIndex: nil, unshareable: unshareable, references: 1))
        candidateIndexByKeys[bindings.map { $0.0 }] = candidates.count - 1
    }

    private mutating func nameSharedBases() {
        var declared = 0
        for index in candidates.indices where !candidates[index].unshareable && candidates[index].references >= Self.minimumCommandsToShareABase {
            candidates[index].declaredIndex = declared
            declared += 1
        }
    }

    private func candidateIndex(forKeysOf bindings: [(String, String)]) -> Int? {
        candidateIndexByKeys[bindings.map { $0.0 }]
    }

    private func candidate(forKeysOf bindings: [(String, String)]) -> Candidate? {
        candidateIndex(forKeysOf: bindings).map { candidates[$0] }
    }

    private func differingPositions(in bindings: [(String, String)], relativeTo base: [(String, String)]) -> [Int] {
        bindings.indices.filter { bindings[$0].1 != base[$0].1 }
    }
}
