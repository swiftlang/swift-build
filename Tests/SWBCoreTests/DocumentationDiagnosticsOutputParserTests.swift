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

@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

@Suite fileprivate struct DocumentationDiagnosticsOutputParserTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func parsingDiagnosticsFile() async throws {
        let diagnosticJSON = """
{
  "version": {
    "major": 1,
    "minor": 0,
    "patch": 0
  },
  "diagnostics": [
    {
      "summary": "Topic reference 'LineList/translateToFileSpace(_:)' couldn't be resolved. Reference is ambiguous after '/SymbolKit/SymbolGraph/LineList'.",
      "source": "file:///Users/username/Development/swift-docc-symbolkit/Sources/SymbolKit/SymbolGraph/LineList/LineList.swift",
      "severity": "warning",
      "range": {
        "start": {
          "line": 173,
          "column": 41
        },
        "end": {
          "line": 173,
          "column": 78
        }
      },
      "solutions": [
        {
          "summary": "Insert '9dlzx' to refer to 'func translateToFileSpace(_ position: SourceRange.Position) -> SourceRange.Position?'",
          "replacements": [
            {
              "range": {
                "start": {
                  "line": 173,
                  "column": 76
                },
                "end": {
                  "line": 173,
                  "column": 76
                }
              },
              "text": "-9dlzx"
            }
          ]
        },
        {
          "summary": "Insert '4tk1b' to refer to 'func translateToFileSpace(_ range: SourceRange) -> SourceRange?'",
          "replacements": [
            {
              "range": {
                "start": {
                  "line": 173,
                  "column": 76
                },
                "end": {
                  "line": 173,
                  "column": 76
                }
              },
              "text": "-4tk1b"
            }
          ]
        }
      ],
      "notes": []
    }
  ]
}
"""
        let delegate = CapturingTaskParserDelegate()

        try await withTemporaryDirectory { (tmpDir: Path) in
            let diagnosticsFilePath = tmpDir.join("test-diagnostics.json")
            try localFS.write(diagnosticsFilePath, contents: ByteString(encodingAsUTF8: diagnosticJSON))

            let payload = DocumentationTaskPayload(bundleIdentifier: "com.example", outputPath: tmpDir.join("output-path"), targetIdentifier: nil, documentationDiagnosticsPath: diagnosticsFilePath)

            let task = DocumentationDiagnosticsOutputParserMockTask(payload: payload)
            let core = try await getCore()
            let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
            let parser = DocumentationDiagnosticsOutputParser(for: task, workspaceContext: workspaceContext, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate, progressReporter: nil)
            parser.write(bytes: "error: is an error\n") // no diagnostic should be created created for this
            parser.close(result: TaskResult.exit(exitStatus: .exit(0), metrics: nil))
        }

        // DiagnosticsEngineTester doesn't check child diagnostics so this test manually asserts that the diagnostics are equal to what's expected

        let diagnosticPath = Path("/Users/username/Development/swift-docc-symbolkit/Sources/SymbolKit/SymbolGraph/LineList/LineList.swift")
        let expectedDiagnostic = Diagnostic(
            behavior: .warning,
            location: .path(diagnosticPath, line: 173, column: 41),
            sourceRanges: [
                .init(path: diagnosticPath, startLine: 173, startColumn: 41, endLine: 173, endColumn: 78)
            ],
            data: DiagnosticData("Topic reference 'LineList/translateToFileSpace(_:)' couldn't be resolved. Reference is ambiguous after '/SymbolKit/SymbolGraph/LineList'."),
            fixIts: [],
            childDiagnostics: [
                Diagnostic(
                    behavior: .note,
                    location: .path(diagnosticPath, line: 173, column: 41),
                    sourceRanges: [
                        .init(path: diagnosticPath, startLine: 173, startColumn: 41, endLine: 173, endColumn: 78)
                    ],
                    data: DiagnosticData("Insert '9dlzx' to refer to 'func translateToFileSpace(_ position: SourceRange.Position) -> SourceRange.Position?'"),
                    fixIts: [
                        Diagnostic.FixIt(
                            sourceRange: .init(path: diagnosticPath, startLine: 173, startColumn: 76, endLine: 173, endColumn: 76),
                            newText: "-9dlzx"
                        )
                    ]
                ),
                Diagnostic(
                    behavior: .note,
                    location: .path(diagnosticPath, line: 173, column: 41),
                    sourceRanges: [
                        .init(path: diagnosticPath, startLine: 173, startColumn: 41, endLine: 173, endColumn: 78)
                    ],
                    data: DiagnosticData("Insert '4tk1b' to refer to 'func translateToFileSpace(_ range: SourceRange) -> SourceRange?'"),
                    fixIts: [
                        Diagnostic.FixIt(
                            sourceRange: .init(path: diagnosticPath, startLine: 173, startColumn: 76, endLine: 173, endColumn: 76),
                            newText: "-4tk1b"
                        )
                    ]
                )
            ]
        )
        #expect(delegate.diagnosticsEngine.diagnostics == [expectedDiagnostic])
    }
}

fileprivate final class DocumentationDiagnosticsOutputParserMockTask: ExecutableTask {
    let type: any TaskTypeDescription = MockTaskTypeDescription()

    init(payload: DocumentationTaskPayload) {
        self.payload = payload
    }

    var dependencyData: DependencyDataStyle? { return nil }
    let payload: (any TaskPayload)?
    var forTarget: ConfiguredTarget? { return nil }
    var ruleInfo: [String] { return [] }
    var commandLine: [CommandLineArgument] { [] }
    var additionalOutput: [String] { [] }
    var environment: EnvironmentBindings { return .init() }
    var workingDirectory: Path { return Path("/taskdir") }
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
        let payloadType: (any TaskPayload.Type)? = DocumentationTaskPayload.self
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
