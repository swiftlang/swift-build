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
import SWBTaskExecution

@Suite
fileprivate struct EnvironmentBaseTableTests {

    private func bindings(_ overrides: [String: String] = [:], count: Int = 12) -> EnvironmentBindings {
        EnvironmentBindings((0..<count).map { index in
            let key = "VAR_\(index)"
            return (key, overrides[key] ?? "shared-\(index)")
        })
    }

    /// llbuild's effective environment for a command encoded against a base
    private func effectiveEnvironment(base: [(String, String)], overrides: [(String, String)]) -> [(String, String)] {
        var result = base
        for (key, value) in overrides {
            if let index = result.firstIndex(where: { $0.0 == key }) {
                result[index] = (key, value)
            } else {
                result.append((key, value))
            }
        }
        return result
    }

    /// The first environment registered with a given key list is the one the base
    /// is declared with.
    @Test
    func firstEnvironmentDeclaresTheBase() {
        let environment = bindings()
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "first"), environment),
            (TaskIdentifier(rawValue: "second"), bindings(["VAR_3": "mine"])),
        ])

        let declared = table.declaredBases
        #expect(declared.count == 1)
        #expect(declared.first?.name == "env-base-0")
        #expect(declared.first?.bindings.map { "\($0.0)=\($0.1)" } == environment.bindings.map { "\($0.0)=\($0.1)" })
    }

    /// An environment identical to its base sends nothing at all
    @Test
    func identicalEnvironmentSendsNoOverrides() {
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "first"), bindings()),
            (TaskIdentifier(rawValue: "second"), bindings()),
        ])

        guard case .useBase(let base, let overrides) = table.encoding(for: TaskIdentifier(rawValue: "second"), environment: bindings()) else {
            Issue.record("expected an identical environment to reuse the base")
            return
        }
        #expect(base == "env-base-0")
        #expect(overrides.isEmpty)
    }

    /// The point of the whole thing: a command differing in a few values sends those
    /// bindings instead of all twelve
    @Test(arguments: [[0], [11], [3, 7], Array(0..<12)])
    func differingValuesAreSentAsOverrides(differing: [Int]) {
        let baseEnvironment = bindings()
        let environment = bindings(Dictionary(uniqueKeysWithValues: differing.map { ("VAR_\($0)", "mine-\($0)") }))
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "base"), baseEnvironment),
            (TaskIdentifier(rawValue: "differing"), environment),
        ])

        guard case .useBase(_, let overrides) = table.encoding(for: TaskIdentifier(rawValue: "differing"), environment: environment) else {
            Issue.record("expected the second environment to reuse the base")
            return
        }
        #expect(overrides.map { $0.0 } == differing.map { "VAR_\($0)" })

        let effective = effectiveEnvironment(base: baseEnvironment.bindings, overrides: overrides)
        #expect(effective.map { "\($0.0)=\($0.1)" } == environment.bindings.map { "\($0.0)=\($0.1)" })
    }

    /// Two environments with the same keys in a different order cannot share a
    /// base
    @Test
    func reorderedKeysGetSeparateBases() {
        let environment = bindings()
        let reordered = EnvironmentBindings(environment.bindings.reversed())
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "ordered"), environment),
            (TaskIdentifier(rawValue: "ordered-again"), environment),
            (TaskIdentifier(rawValue: "reordered"), reordered),
            (TaskIdentifier(rawValue: "reordered-again"), reordered),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: TaskIdentifier(rawValue: "ordered-again"), environment: environment) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.encoding(for: TaskIdentifier(rawValue: "reordered-again"), environment: reordered) == .useBase(base: "env-base-1", overrides: []))
    }

    /// A different key list gets its own base rather than inheriting one whose
    /// keys it would have to append to.
    @Test
    func differentKeysGetSeparateBases() {
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "twelve"), bindings()),
            (TaskIdentifier(rawValue: "twelve-again"), bindings()),
            (TaskIdentifier(rawValue: "thirteen"), bindings(count: 13)),
            (TaskIdentifier(rawValue: "thirteen-again"), bindings(count: 13)),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: TaskIdentifier(rawValue: "thirteen-again"), environment: bindings(count: 13)) == .useBase(base: "env-base-1", overrides: []))
    }

    @Test
    func interleavedKeyListsStillShareBases() {
        let twelve = bindings()
        let thirteen = bindings(count: 13)
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "twelve"), twelve),
            (TaskIdentifier(rawValue: "thirteen"), thirteen),
            (TaskIdentifier(rawValue: "twelve-again"), twelve),
            (TaskIdentifier(rawValue: "thirteen-again"), thirteen),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: TaskIdentifier(rawValue: "twelve-again"), environment: twelve) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.encoding(for: TaskIdentifier(rawValue: "thirteen-again"), environment: thirteen) == .useBase(base: "env-base-1", overrides: []))
    }

    @Test
    func keyListUsedOnceIsSentInline() {
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "twelve"), bindings()),
            (TaskIdentifier(rawValue: "four-hundred"), bindings(count: 400)),
        ])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: TaskIdentifier(rawValue: "twelve"), environment: bindings()) == .inline)
        #expect(table.encoding(for: TaskIdentifier(rawValue: "four-hundred"), environment: bindings(count: 400)) == .inline)
    }

    @Test
    func smallSharedEnvironmentGetsABase() {
        let environment = bindings(count: 1)
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "first"), environment),
            (TaskIdentifier(rawValue: "second"), environment),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0"])
        #expect(table.encoding(for: TaskIdentifier(rawValue: "second"), environment: environment) == .useBase(base: "env-base-0", overrides: []))
    }

    @Test
    func baseNamesSkipKeyListsUsedOnce() {
        let shared = bindings()
        let once = bindings(count: 5)
        let alsoShared = bindings(count: 13)
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "shared"), shared),
            (TaskIdentifier(rawValue: "shared-again"), shared),
            (TaskIdentifier(rawValue: "once"), once),
            (TaskIdentifier(rawValue: "also-shared"), alsoShared),
            (TaskIdentifier(rawValue: "also-shared-again"), alsoShared),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: TaskIdentifier(rawValue: "shared"), environment: shared) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.encoding(for: TaskIdentifier(rawValue: "once"), environment: once) == .inline)
        #expect(table.encoding(for: TaskIdentifier(rawValue: "also-shared"), environment: alsoShared) == .useBase(base: "env-base-1", overrides: []))
    }

    @Test
    func baseReferenceGivesTheBaseAndTheDifferingPositions() throws {
        let once = bindings(count: 5)
        let alsoShared = bindings(count: 13)
        let differing = bindings(["VAR_2": "mine", "VAR_9": "also mine"], count: 13)
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "shared"), bindings()),
            (TaskIdentifier(rawValue: "shared-again"), bindings()),
            (TaskIdentifier(rawValue: "once"), once),
            (TaskIdentifier(rawValue: "also-shared"), alsoShared),
            (TaskIdentifier(rawValue: "differing"), differing),
        ])

        #expect(table.baseReference(for: TaskIdentifier(rawValue: "once")) == nil)
        #expect(table.baseReference(for: TaskIdentifier(rawValue: "shared"))?.index == 0)
        #expect(table.baseReference(for: TaskIdentifier(rawValue: "shared"))?.positions == [])

        let reference = try #require(table.baseReference(for: TaskIdentifier(rawValue: "differing")))
        #expect(reference.index == 1)
        #expect(table.declaredBases[reference.index].name == "env-base-1")
        #expect(reference.positions == [2, 9])
    }

    @Test
    func duplicateKeysAreSentInline() {
        let environment = EnvironmentBindings(bindings().bindings + [("VAR_0", "again")])
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "first"), environment),
            (TaskIdentifier(rawValue: "second"), environment),
        ])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: TaskIdentifier(rawValue: "second"), environment: environment) == .inline)
    }

    @Test
    func emptyEnvironmentIsSentInline() {
        let shared = bindings()
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "empty"), EnvironmentBindings()),
            (TaskIdentifier(rawValue: "shared"), shared),
            (TaskIdentifier(rawValue: "empty-again"), EnvironmentBindings()),
            (TaskIdentifier(rawValue: "shared-again"), shared),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0"])
        #expect(table.encoding(for: TaskIdentifier(rawValue: "empty"), environment: EnvironmentBindings()) == .inline)
        #expect(table.encoding(for: TaskIdentifier(rawValue: "shared-again"), environment: shared) == .useBase(base: "env-base-0", overrides: []))
    }

    @Test
    func unregisteredCommandIsSentInline() {
        let table = EnvironmentBaseTable(environments: [
            (TaskIdentifier(rawValue: "first"), bindings()),
            (TaskIdentifier(rawValue: "second"), bindings()),
        ])

        #expect(table.declaredBases.count == 1)
        #expect(table.encoding(for: TaskIdentifier(rawValue: "never-registered"), environment: bindings()) == .inline)
    }

    @Test
    func encodingDoesNotDependOnQueryOrder() {
        let commands = [
            (TaskIdentifier(rawValue: "first"), bindings()),
            (TaskIdentifier(rawValue: "second"), bindings(["VAR_1": "a"])),
            (TaskIdentifier(rawValue: "third"), bindings(["VAR_2": "b"])),
        ]
        let table = EnvironmentBaseTable(environments: commands)

        let forward = commands.map { table.encoding(for: $0.0, environment: $0.1) }
        let backward = commands.reversed().map { table.encoding(for: $0.0, environment: $0.1) }
        #expect(forward == Array(backward.reversed()))
    }
}
