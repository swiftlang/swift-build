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
import SWBUtil
import SWBCore
import SWBTaskExecution

@Suite
fileprivate struct AuxiliaryFileTaskTests {
    var errorMessage: String? = nil

    @Test
    func basics() async throws {
        let executionDelegate = MockExecutionDelegate()
        let output = Path.root.join("output.txt")
        let input = Path.root.join("input")
        try executionDelegate.fs.write(input, contents: ByteString(encodingAsUTF8: "Hello, world!"))
        let action = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: output, input: input, permissions: 0o755, forceWrite: false, diagnostics: [], logContents: false))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["WriteAuxiliaryFile", output.basename], workingDirectory: .root, outputs: [MakePlannedPathNode(output)], action: action, execDescription: "")

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: MockTaskOutputDelegate()
        )
        #expect(result == .succeeded)
        #expect(try executionDelegate.fs.read(output) == ByteString(encodingAsUTF8: "Hello, world!"))
        #expect(try executionDelegate.fs.getFilePermissions(output) == 0o755)
    }

    @Test
    func logContents() async throws {
        let executionDelegate = MockExecutionDelegate()
        let output = Path.root.join("output.txt")
        let input = Path.root.join("input")
        try executionDelegate.fs.write(input, contents: ByteString(encodingAsUTF8: "Hello, world!"))
        let action = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: output, input: input, permissions: 0o755, forceWrite: false, diagnostics: [], logContents: true))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["WriteAuxiliaryFile", output.basename], workingDirectory: .root, outputs: [MakePlannedPathNode(output)], action: action, execDescription: "")

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.textBytes == "Hello, world!")
    }

    @Test
    func signature() {
        let output = Path.root.join("output.txt")
        let taskA = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: output, input: Path("ContentsA"), permissions: nil, forceWrite: false, diagnostics: [], logContents: false))
        do {
            let taskB = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: output, input: Path("ContentsB"), permissions: nil, forceWrite: false, diagnostics: [], logContents: false))
            #expect(taskA.computeInitialSignature() != taskB.computeInitialSignature())
        }
        do {
            let taskB = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: Path("/output2.txt"), input: Path("ContentsA"), permissions: nil, forceWrite: false, diagnostics: [], logContents: false))
            #expect(taskA.computeInitialSignature() != taskB.computeInitialSignature())
        }
        do {
            let taskB = AuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: output, input: Path("ContentsA"), permissions: 0o755, forceWrite: false, diagnostics: [], logContents: false))
            #expect(taskA.computeInitialSignature() != taskB.computeInitialSignature())
        }
    }
}
