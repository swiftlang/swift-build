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
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct GenerateEmbedInCodeAccessorTaskTests {
    @Test(arguments: [[], [0, 1, 127, 128, 255]] as [[UInt8]])
    func objectResource(bytes: [UInt8]) async throws {
        let executionDelegate = MockExecutionDelegate()
        let fs = executionDelegate.fs
        let input = Path.root.join("a \"quoted\" resource\n.bin")
        let literalInput = Path.root.join("literal.txt")
        let output = Path.root.join("derived/embedded_resources.swift")
        let info = EmbeddedResourceObjectInfo(moduleName: "Test", path: input, outputDirectory: output.dirname)
        let source = info.sourcePath
        let payload = info.payloadPath
        try fs.createDirectory(output.dirname)
        try fs.write(input, contents: ByteString(bytes))
        try fs.write(literalInput, contents: ByteString([65, 66, 67]))

        let commandLine = [
            "builtin-generateEmbedInCodeAccessor", "--output", output.str,
            "--module-name", "Test", "--object", input.str,
            "--byte-array", literalInput.str,
        ]
        var builder = PlannedTaskBuilder(
            type: mockTaskType, ruleInfo: [],
            commandLine: commandLine.map { .literal(ByteString(encodingAsUTF8: $0)) },
            inputs: [input, literalInput].map { MakePlannedPathNode($0) },
            outputs: [output, source, payload].map { MakePlannedPathNode($0) }
        )
        let task = Task(&builder)
        let outputDelegate = MockTaskOutputDelegate()
        for contents in [bytes, bytes.reversed().map { $0 }, bytes + [42], []] {
            try fs.write(input, contents: ByteString(contents))
            let result = await GenerateEmbedInCodeAccessorTaskAction().performTaskAction(
                task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .succeeded)
            #expect(outputDelegate.messages.isEmpty)
            #expect(try fs.read(payload).bytes == contents)
            let cSource = try fs.read(source).asString
            #expect(cSource.contains("#embed \"\(payload.basename)\" if_empty(0)"))
            #expect(!cSource.contains(input.str))
            #expect(cSource.contains("const unsigned char *const"))
            let accessor = try fs.read(output).asString
            #expect(accessor.contains("static let literal_txt: [UInt8] = [65,66,67]"))
            #expect(accessor.contains(": RawSpan {"))
            #expect(accessor.contains("RawSpan(_unsafeStart:"))
            #expect(accessor.contains("byteCount: \(contents.count)"))
            #expect(accessor.contains("UnsafeRawPointer"))
            #expect(!accessor.contains("Span<UInt8>"))
            #expect(!accessor.contains("withUnsafePointer"))
        }
    }
}
