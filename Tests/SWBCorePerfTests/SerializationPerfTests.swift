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

import Testing
import SWBUtil
import SWBCore
import SWBMacro
import SWBTestSupport
import Synchronization

@Suite(.performance)
fileprivate struct SerializationPerfTests: CoreBasedTests, PerfTests {
    /// Create a test macro scope, for a mock project.
    private func createTestScope(tmpDirPath: Path) async throws -> MacroEvaluationScope {
        let helper = try await TestWorkspace(
            "Workspace",
            sourceRoot: tmpDirPath,
            projects: [
                TestProject("aProject",
                            groupTree: TestGroup("SomeFiles"),
                            targets: [TestStandardTarget("Target1", type: .application)]
                           )
            ]).loadHelper(getCore())
        let project = helper.project
        let target = project.targets[0]
        return helper.globalScope(buildRequestContext: BuildRequestContext(workspaceContext: helper.workspaceContext), project: project, target: target)
    }

    private func serializeMacroEvaluationScope(_ scope: MacroEvaluationScope) -> MsgPackSerializer {
        let sz = MsgPackSerializer()
        sz.serialize(scope)
        return sz
    }

    func _testSerializingTargetScopePerf_XXX(numberOfTargets: Int) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let didEmitSerializedSize = SWBMutex(false)

            let scope = try await createTestScope(tmpDirPath: tmpDirPath)

            // Measure the time to construct the settings for this target.
            await measure {
                var accumulatedBytes: Float64 = 0

                for _ in 0..<numberOfTargets {
                    let sz = self.serializeMacroEvaluationScope(scope)
                    accumulatedBytes += Float64(sz.byteString.count)
                }


                if !didEmitSerializedSize.withLock({ $0 }) {
                    let mb = accumulatedBytes / (1000.0 * 1000.0)
                    perfPrint("Serialized \(mb) megabytes for \(numberOfTargets) targets")
                    didEmitSerializedSize.withLock { $0 = true }
                }
            }
        }
    }

    /// Measure the time to serialize the settings for a MacroEvaluationScope for a simple target.
    @Test
    func serializingTargetScopePerf_X100() async throws {
        try await _testSerializingTargetScopePerf_XXX(numberOfTargets: 100)
    }

    @Test
    func serializingTargetScopePerf_X1000() async throws {
        try await _testSerializingTargetScopePerf_XXX(numberOfTargets: 1000)
    }

    struct MacroEvaluationScopeDeserializerDelegate: MacroValueAssignmentTableDeserializerDelegate {
        let namespace: MacroNamespace
    }

    /// Measure the time to serialize the settings for a MacroEvaluationScope for a simple target.
    @Test
    func deserializingTargetScopePerf_X100() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let scope = try await createTestScope(tmpDirPath: tmpDirPath)
            let sz = self.serializeMacroEvaluationScope(scope)

            let mb = Float64(sz.byteString.bytes.count) / (1000.0 * 1000.0)
            perfPrint("Will deserialize \(mb) megabytes")

            let delegate = MacroEvaluationScopeDeserializerDelegate(namespace: scope.namespace)

            // Measure the time to construct the settings for this target.
            try await measure {
                for _ in 0..<100 {
                    let dsz = MsgPackDeserializer(sz.byteString, delegate: delegate)
                    let dszScope: MacroEvaluationScope = try dsz.deserialize()

                    let projectName = try #require(scope.namespace.lookupMacroDeclaration("PROJECT_NAME"))
                    let projectName2 = try #require(dszScope.namespace.lookupMacroDeclaration("PROJECT_NAME"))
                    #expect(scope.evaluateAsString(projectName) == dszScope.evaluateAsString(projectName2))
                }
            }
        }
    }

    @Test
    func deserializingTargetScopePerf_X1000() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let scope = try await createTestScope(tmpDirPath: tmpDirPath)
            let sz = self.serializeMacroEvaluationScope(scope)

            let mb = Float64(sz.byteString.bytes.count) / (1000.0 * 1000.0)
            perfPrint("Will deserialize \(mb) megabytes")

            let delegate = MacroEvaluationScopeDeserializerDelegate(namespace: scope.namespace)

            // Measure the time to construct the settings for this target.
            try await measure {
                for _ in 0..<1000 {
                    let dsz = MsgPackDeserializer(sz.byteString, delegate: delegate)
                    let dszScope: MacroEvaluationScope = try dsz.deserialize()
                    let name = scope.evaluateAsString(try #require(scope.namespace.lookupMacroDeclaration("PROJECT_NAME")))
                    let dszName = dszScope.evaluateAsString(try #require(dszScope.namespace.lookupMacroDeclaration("PROJECT_NAME")))

                    #expect(name == dszName)
                }
            }
        }
    }
}
