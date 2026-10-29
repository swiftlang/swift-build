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

package import SWBCore

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

    package struct BaseReference: Sendable {
        /// The base's position in EnvironmentBaseTable#declaredBases.
        package let index: Int
        /// The positions at which the command's own value differs from the base's
        package let positions: [Int]
    }

    private struct Candidate: Sendable {
        let bindings: [(String, String)]
        var declaredIndex: Int?
        let unshareable: Bool
        var references: Int
    }

    private static let minimumCommandsToShareABase = 2

    private var candidates: [Candidate] = []

    private var candidateIndexByKeys: [[String]: Int] = [:]

    private var lastRegistered: Int?

    private var baseReferenceByTask: [TaskIdentifier: BaseReference] = [:]

    package init() {}

    /// Build a table over all of a build's environments.
    package init(environments: some Sequence<(task: TaskIdentifier, environment: EnvironmentBindings)>) {
        var registered: [(task: TaskIdentifier, candidate: Int, positions: [Int])] = []

        for (task, environment) in environments {
            guard let candidate = register(environment.bindings) else { continue }
            registered.append((task, candidate, differingPositions(in: environment.bindings, relativeTo: candidates[candidate].bindings)))
        }

        nameSharedBases()

        for entry in registered {
            guard let index = candidates[entry.candidate].declaredIndex else { continue }
            baseReferenceByTask[entry.task] = BaseReference(index: index, positions: entry.positions)
        }
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        candidates.lazy.compactMap { candidate in candidate.declaredIndex.map { (Self.name(ofBase: $0), candidate.bindings) } }
    }

    package func encoding(for task: TaskIdentifier, environment: EnvironmentBindings) -> EnvironmentEncoding {
        guard let reference = baseReference(for: task) else {
            return .inline
        }
        let bindings = environment.bindings
        return .useBase(base: Self.name(ofBase: reference.index), overrides: reference.positions.map { bindings[$0] })
    }

    package func baseReference(for task: TaskIdentifier) -> BaseReference? {
        baseReferenceByTask[task]
    }

    private static func name(ofBase index: Int) -> String {
        "env-base-\(index)"
    }

    private mutating func register(_ bindings: [(String, String)]) -> Int? {
        guard !bindings.isEmpty else { return nil }

        if let lastRegistered, candidates[lastRegistered].bindings.count == bindings.count,
           zip(candidates[lastRegistered].bindings, bindings).allSatisfy({ $0.0 == $1.0 }) {
            candidates[lastRegistered].references += 1
            return lastRegistered
        }

        let keys = bindings.map { $0.0 }
        let index: Int
        if let existing = candidateIndexByKeys[keys] {
            candidates[existing].references += 1
            index = existing
        } else {
            let unshareable = Set(keys).count != keys.count
            candidates.append(Candidate(bindings: bindings, declaredIndex: nil, unshareable: unshareable, references: 1))
            index = candidates.count - 1
            candidateIndexByKeys[keys] = index
        }
        lastRegistered = index
        return index
    }

    private mutating func nameSharedBases() {
        var declared = 0
        for index in candidates.indices where !candidates[index].unshareable && candidates[index].references >= Self.minimumCommandsToShareABase {
            candidates[index].declaredIndex = declared
            declared += 1
        }
    }

    private func differingPositions(in bindings: [(String, String)], relativeTo base: [(String, String)]) -> [Int] {
        bindings.indices.filter { bindings[$0].1 != base[$0].1 }
    }
}
