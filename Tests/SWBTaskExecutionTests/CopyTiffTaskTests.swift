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
import SWBLibc
import SWBTaskExecution
import SWBTestSupport
import SWBUtil

@Suite(.requireHostOS(.macOS)) // `tiffutil` only exists on macOS
fileprivate struct CopyTiffTaskTests {
    @Test
    func diagnostics() async {
        func checkDiagnostics(_ commandLine: [String], errors: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
            let action = CopyTiffTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Image Asset")
            let executionDelegate = MockExecutionDelegate()
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .failed, sourceLocation: sourceLocation)
            #expect(outputDelegate.messages == errors.map { "error: \($0)" }, sourceLocation: sourceLocation)
        }

        await checkDiagnostics([], errors: ["no input files specified", "missing required '--outdir' argument"])
        await checkDiagnostics(["copyTiff", "--outdir"], errors: ["missing argument for option: '--outdir'", "no input files specified"])
        await checkDiagnostics(["copyTiff", "--compression"], errors: ["missing argument for option: '--compression'", "no input files specified", "missing required '--outdir' argument"])
        await checkDiagnostics(["copyPlist", "--compression", "other", "--outdir", "/", "--what"], errors: ["unrecognized argument: '--what'", "no input files specified"])
    }

    @Test
    func basicCopy() async throws {
        let input = Path("/file.tiff")
        let output = Path("/dst/file.tiff")
        let executionDelegate = MockExecutionDelegate()
        let inputContents = ByteString(encodingAsUTF8: "TIFF")
        try executionDelegate.fs.createDirectory(output.dirname)
        try executionDelegate.fs.write(input, contents: inputContents)
        let action = CopyTiffTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyTiff", "--compression", "none", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Image Asset")
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the command succeeded with no errors.
        #expect(result == .succeeded)
        #expect(outputDelegate.messages == [])

        // Check the file was copied, and is the same as the source contents.
        let outputContents = try executionDelegate.fs.read(output)
        #expect(inputContents == outputContents)
        let inputData = try PropertyList.fromBytes(inputContents.bytes)
        let outputData = try PropertyList.fromBytes(outputContents.bytes)
        #expect(inputData == outputData)
    }

    @Test
    func tiffutilBasedFailingCopy() async throws {
        try await withTemporaryDirectory { tmpDir in
            // Check that basic copying of a file works (in this case, we do no transformations so we can use an in-memory FS.
            let input = tmpDir.join("file.tiff")
            let output = tmpDir.join("dst/file.tiff")
            let executionDelegate = MockExecutionDelegate()
            let inputContents = ByteString(encodingAsUTF8: "TIFF")
            try executionDelegate.fs.createDirectory(output.dirname, recursive: true)
            try executionDelegate.fs.write(input, contents: inputContents)
            let action = CopyTiffTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyTiff", "--compression", "cathidpicheck", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Image Asset")
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Check the command succeeded with no errors.
            #expect(result == .failed)
            let outputString = outputDelegate.textBytes.asString
            #expect(outputString.contains("Failed to create image source") || outputString.contains("Can't open"), "unexpected tiffutil failure: \(output)")
            XCTAssertMatch(outputString, .contains("No output file created due to errors"))
            #expect(outputDelegate.messages == ["error: tiffutil failed"])
        }
    }
}
