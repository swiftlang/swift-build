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

import Foundation
import Testing
import SWBCore
import SWBUtil
import SWBTaskExecution
import SWBMacro

fileprivate final class MockTask: ExecutableTask {
    let type: any TaskTypeDescription

    init(exec: String, args: [String]) {
        self.type = MockTaskTypeDescription()

        self.commandLine = [.literal(ByteString(encodingAsUTF8: exec))] + args.map { .literal(ByteString(encodingAsUTF8: $0)) }
    }

    var dependencyData: DependencyDataStyle? { return nil }
    var payload: (any TaskPayload)? { return nil }
    var forTarget: ConfiguredTarget? { return nil }
    var ruleInfo: [String] { return [] }
    let commandLine: [CommandLineArgument]
    var additionalOutput: [String] { [] }
    var environment: EnvironmentBindings { return .init() }
    var workingDirectory: Path { return .root }
    var showEnvironment: Bool { return false }
    var preparesForIndexing: Bool { return false }
    var llbuildControlDisabled: Bool { return false }
    var execDescription: String? { return nil }
    var inputPaths: [Path] { return [] }
    var outputPaths: [Path] { return [] }
    var targetDependencies: [ResolvedTargetDependency] { return [] }
    var isGate: Bool { false }
    var executionInputs: [ExecutionNode]? { nil }
    var showInLog: Bool { !isGate }
    var showCommandLineInLog: Bool { true }
    var priority: TaskPriority { .unspecified }
    let isDynamic: Bool = false
    var alwaysExecuteTask: Bool { false }
    var additionalSignatureData: String { "" }

    final class MockTaskTypeDescription: TaskTypeDescription {
        let payloadType: (any TaskPayload.Type)? = nil
        let isUnsafeToInterrupt: Bool = false
        let toolBasenameAliases: [String] = []
        func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]? { return nil }
        func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] { return [] }
        func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] { return [] }
        func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] { return [] }
        func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] { return [] }
        func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] { return [] }
        func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? { return nil }
        func interestingPath(for task: any ExecutableTask) -> Path? { return nil }
    }
}

@Suite
fileprivate struct CreateBuildDirectoryTaskActionTests {
    @Test
    func signature() {
        let taskAction = CreateBuildDirectoryTaskAction()

        let task = MockTask(exec: "foobar", args: ["arg1", "-option1", "optionArg1", "arg2"])
        let task2 = MockTask(exec: "foobar", args: ["arg1", "arg2"])
        let task3 = MockTask(exec: "otherExecutable", args: ["arg1", "-option1", "optionArg1", "arg2"])
        let task4 = MockTask(exec: "foobar", args: [])
        let task5 = MockTask(exec: "foobar", args: ["arg1"])

        let tasks = [task, task2, task3, task4, task5]

        let executionDelegate = MockExecutionDelegate()

        // all signatures should be different
        for i in 0..<tasks.count {
            for j in (i + 1)..<tasks.count {
                let t1 = tasks[i]
                let t2 = tasks[j]
                #expect(taskAction.getSignature(t1, executionDelegate: executionDelegate) != taskAction.getSignature(t2, executionDelegate: executionDelegate))
            }
        }

        #expect(taskAction.getSignature(task, executionDelegate: executionDelegate) == taskAction.getSignature(task, executionDelegate: MockExecutionDelegate()))
        #expect(taskAction.getSignature(task, executionDelegate: executionDelegate) == taskAction.getSignature(MockTask(exec: "foobar", args: ["arg1", "-option1", "optionArg1", "arg2"]), executionDelegate: executionDelegate))
    }
}
