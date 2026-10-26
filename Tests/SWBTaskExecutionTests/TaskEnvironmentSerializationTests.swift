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

import Foundation
import Testing
import SWBCore
import SWBUtil
import SWBTestSupport

@_spi(Testing) import SWBTaskExecution

@Suite
fileprivate struct TaskEnvironmentSerializationTests: CoreBasedTests {
    /// `count` bindings named `<prefix>0`...; `overrides` replaces the value at the given positions.
    private func bindings(count: Int = 40, prefix: String = "KEY", overrides: [Int: String] = [:], valueLength: Int = 12) -> [(String, String)] {
        (0..<count).map { position in
            (prefix + String(position), overrides[position] ?? ("value-" + String(position)).padding(toLength: valueLength, withPad: "x", startingAt: 0))
        }
    }

    private func same(_ lhs: [(String, String)], _ rhs: [(String, String)]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    private struct Result {
        let original: FrozenTaskStore
        let decoded: FrozenTaskStore
        let byteCount: Int
    }

    /// A serializer delegate that does not let tasks share environments.
    private final class NonSharingSerializerDelegate: ConfiguredTargetSerializerDelegate {
        var currentBuildParametersIndex = 0
        var buildParametersIndexes = [BuildParameters: Int]()
        var currentConfiguredTargetIndex = 0
        var configuredTargetIndexes = [ConfiguredTarget: Int]()
    }

    /// Builds a description from tasks with the given environments, and writes and reads back its task store.
    private func roundTrip(_ environments: [(name: String, bindings: [(String, String)])], sharing: Bool = true) async throws -> Result {
        let core = try await getCore()
        let type = GateTask.type
        let tasks = environments.map { name, bindings -> ConstructedTask in
            var builder = PlannedTaskBuilder(type: type, ruleInfo: ["Foo", name], commandLine: ["true"], environment: EnvironmentBindings(bindings), outputs: [MakePlannedPathNode(Path.root.join("tmp/\(name).out"))])
            return ConstructedTask(&builder, execTask: Task(&builder))
        }
        let workspace = try TestWorkspace("empty", projects: []).load(core)
        let description = try #require(try await BuildDescription.construct(workspace: workspace, tasks: tasks, path: Path.root.join("tmp"), signature: ByteString(encodingAsUTF8: "signature"), buildCommand: .build(style: .buildOnly, skipDependencies: false), fs: PseudoFS(), delegate: MockTestBuildDescriptionConstructionDelegate()))

        let taskActionRegistry = try await TaskActionRegistry(pluginManager: core.pluginManager)
        let serializerDelegate: any SerializerDelegate = sharing ? BuildDescriptionSerializerDelegate(taskActionRegistry: taskActionRegistry) : NonSharingSerializerDelegate()
        let serializer = MsgPackSerializer(delegate: serializerDelegate)
        serializer.serialize(description.taskStore)
        let deserializerDelegate = BuildDescriptionDeserializerDelegate(workspace: workspace, platformRegistry: core.platformRegistry, sdkRegistry: core.sdkRegistry, specRegistry: core.specRegistry, taskActionRegistry: taskActionRegistry)
        let decoded: FrozenTaskStore = try MsgPackDeserializer(serializer.byteString, delegate: deserializerDelegate).deserialize()
        return Result(original: description.taskStore, decoded: decoded, byteCount: serializer.byteString.bytes.count)
    }

    private func expectEnvironmentsSurvive(_ result: Result, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.decoded.taskCount == result.original.taskCount, sourceLocation: sourceLocation)
        result.original.forEachTask { original in
            let decoded = result.decoded.task(for: original.identifier)
            #expect(decoded != nil, "\(original.ruleInfo) missing after decoding", sourceLocation: sourceLocation)
            if let decoded {
                #expect(same(original.environment.bindings, decoded.environment.bindings), "environment of \(original.ruleInfo) changed", sourceLocation: sourceLocation)
            }
        }
    }

    @Test
    func environmentsSurviveRoundTrip() async throws {
        var repeatedKeys = bindings(count: 20, prefix: "DUP")
        repeatedKeys.append(("DUP3", "the same key again"))

        let result = try await roundTrip([
            // The same keys in the same order, with the same or different values, share a base.
            ("base", bindings()),
            ("overrides", bindings(overrides: [0: "first", 17: "middle", 39: "last"])),
            ("identical", bindings()),
            ("all-different", bindings(overrides: Dictionary(uniqueKeysWithValues: (0..<40).map { ($0, "other-\($0)") }))),
            // The same keys in a different order are a different sequence.
            ("reordered", Array(bindings().reversed())),
            ("reordered-overrides", Array(bindings(overrides: [5: "changed"]).reversed())),
            // Keys used by only one task, a repeated key, small and empty environments are written in full.
            ("other-keys", bindings(prefix: "OTHER")),
            ("repeated-keys", repeatedKeys),
            ("repeated-keys-again", repeatedKeys),
            ("small", bindings(count: 3)),
            ("empty", []),
        ])
        expectEnvironmentsSurvive(result)
    }

    @Test
    func sharingMakesTheStoreSmaller() async throws {
        func environments(_ count: Int) -> [(name: String, bindings: [(String, String)])] {
            (0..<count).map { i in ("task-\(i)", bindings(count: 400, overrides: [7: "per-task-\(i)", 211: "also-\(i)"], valueLength: 80)) }
        }

        let one = try await roundTrip(environments(1))
        let fifty = try await roundTrip(environments(50))
        expectEnvironmentsSurvive(fifty)
        #expect(fifty.byteCount < one.byteCount * 3, "fifty tasks took \(fifty.byteCount) bytes against \(one.byteCount) for one")
    }

    @Test
    func serializersThatDoNotShareWriteEnvironmentsInFull() async throws {
        let environments = (0..<20).map { i in ("task-\(i)", bindings(count: 200, overrides: [3: "per-task-\(i)"], valueLength: 40)) }

        let shared = try await roundTrip(environments)
        let inFull = try await roundTrip(environments, sharing: false)
        expectEnvironmentsSurvive(inFull)
        #expect(inFull.byteCount > shared.byteCount * 5, "written in full: \(inFull.byteCount) bytes, shared: \(shared.byteCount)")
    }

    @Test
    func environmentOrderIsPreserved() async throws {
        let derived = bindings(count: 30, overrides: [2: "two", 28: "twenty-eight"])
        let result = try await roundTrip([("a", bindings(count: 30)), ("b", derived)])
        let task = try #require(result.decoded.tasksForTarget(nil).first { $0.ruleInfo == ["Foo", "b"] })
        #expect(task.environment.bindings.map(\.0) == derived.map(\.0))
    }
}
