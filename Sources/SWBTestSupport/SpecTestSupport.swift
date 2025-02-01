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
package import SWBCore
package import SWBUtil

package class CapturingTaskParserDelegate: TaskOutputParserDelegate {
    package let buildOperationIdentifier: BuildSystemOperationIdentifier = .init(UUID())

    package let diagnosticsEngine = DiagnosticsEngine()
    package var output = OutputByteStream()

    package init() {}
    package func skippedSubtask(signature: ByteString) {}
    package func startSubtask(buildOperationIdentifier: BuildSystemOperationIdentifier, taskName: String, id: ByteString, signature: ByteString, ruleInfo: String, executionDescription: String, commandLine: [ByteString], additionalOutput: [String], interestingPath: Path?, workingDirectory: Path?, serializedDiagnosticsPaths: [Path]) -> any TaskOutputParserDelegate { fatalError() }
    package func emitOutput(_ data: ByteString) { output <<< data }
    package func taskCompleted(exitStatus: Processes.ExitStatus) { }
    package func close() {}
}

package final class OutputParserMockTask: ExecutableTask {
    package let type: any TaskTypeDescription

    package init(basenames: [String], exec: String) {
        self.type = MockTaskTypeDescription(toolBasenameAliases: basenames)

        self.commandLine = [.literal(ByteString(encodingAsUTF8: exec))]
    }

    package var dependencyData: DependencyDataStyle? { return nil }
    package var payload: (any TaskPayload)? { return nil }
    package var forTarget: ConfiguredTarget? { return nil }
    package var ruleInfo: [String] { return [] }
    package let commandLine: [CommandLineArgument]
    package let additionalOutput: [String] = []
    package var environment: EnvironmentBindings { return .init() }
    package var workingDirectory: Path { return Path("/taskdir") }
    package var showEnvironment: Bool { return false }
    package var preparesForIndexing: Bool { return false }
    package var llbuildControlDisabled: Bool { return false }
    package var execDescription: String? { return nil }
    package var inputPaths: [Path] { return [] }
    package var outputPaths: [Path] { return [] }
    package var targetDependencies: [ResolvedTargetDependency] { return [] }
    package let isGate = false
    package let executionInputs: [ExecutionNode]? = nil
    package var showInLog: Bool { !isGate }
    package var showCommandLineInLog: Bool { true }
    package var priority: TaskPriority { .unspecified }
    package let isDynamic: Bool = false
    package var alwaysExecuteTask: Bool { false }
    package var additionalSignatureData: String { "" }

    final class MockTaskTypeDescription: TaskTypeDescription {
        init(toolBasenameAliases: [String]) {
            self.toolBasenameAliases = toolBasenameAliases
        }

        let payloadType: (any TaskPayload.Type)? = nil
        let isUnsafeToInterrupt: Bool = false
        let toolBasenameAliases: [String]
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
