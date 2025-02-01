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

@Suite
fileprivate struct CopyPlistTaskTests {
    @Test
    func diagnostics() async {
        func checkDiagnostics(_ commandLine: [String], errors: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
            let action = CopyPlistTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
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
        await checkDiagnostics(["copyPlist", "--", "foo.plist"], errors: ["missing required '--outdir' argument"])
        await checkDiagnostics(["copyPlist", "--outdir"], errors: ["missing argument for option: '--outdir'", "no input files specified"])
        await checkDiagnostics(["copyPlist", "--convert"], errors: ["missing argument for option: '--convert'", "no input files specified", "missing required '--outdir' argument"])
        await checkDiagnostics(["copyPlist", "--convert", "bogus", "--outdir", "/", "--", "foo.plist"], errors: ["unrecognized argument to '--convert': 'bogus'"])
        await checkDiagnostics(["copyPlist", "--what", "--outdir", "/", "--", "foo.plist"], errors: ["unrecognized argument: '--what'"])
    }

    @Test
    func basicCopy() async throws {
        let input = Path.root.join("settings.plist")
        let output = Path.root.join("dst").join("settings.plist")
        let executionDelegate = MockExecutionDelegate()
        let inputContents = ByteString(encodingAsUTF8: "{ \"key\" = \"value\"; }")
        try executionDelegate.fs.createDirectory(output.dirname)
        try executionDelegate.fs.write(input, contents: inputContents)
        let action = CopyPlistTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyPlist", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
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
        let inputPlist = try PropertyList.fromBytes(inputContents.bytes)
        let outputPlist = try PropertyList.fromBytes(outputContents.bytes)
        #expect(inputPlist == outputPlist)
    }

    @Test
    func openStepToOpenStepCopy() async throws {
        let input = Path.root.join("settings.plist")
        let output = Path.root.join("dst").join("settings.plist")
        let executionDelegate = MockExecutionDelegate()
        let inputContents = ByteString(encodingAsUTF8: "{ \"key\" = \"value\"; }")
        try executionDelegate.fs.createDirectory(output.dirname)
        try executionDelegate.fs.write(input, contents: inputContents)
        let action = CopyPlistTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyPlist", "--validate", "--convert", "same-as-input", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
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

        // Check the file was copied, is the same as the source contents, and is in OpenStep format.
        let outputContents = try executionDelegate.fs.read(output)
        #expect(inputContents == outputContents)
        let inputPlist = try PropertyList.fromBytes(inputContents.bytes)
        let (outputPlist, format) = try PropertyList.fromBytesWithFormat(outputContents.bytes)
        #expect(inputPlist == outputPlist)
        #expect(format == .openStep)
    }

    @Test
    func openStepToBinaryCopy() async throws {
        let input = Path.root.join("settings.plist")
        let output = Path.root.join("dst").join("settings.plist")
        let executionDelegate = MockExecutionDelegate()
        let inputContents = ByteString(encodingAsUTF8: "{ \"key\" = \"value\"; }")
        try executionDelegate.fs.createDirectory(output.dirname)
        try executionDelegate.fs.write(input, contents: inputContents)
        let action = CopyPlistTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyPlist", "--convert", "binary1", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
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

        // Check the file was copied, is the same as the source contents, and is in OpenStep format.
        let outputContents = try executionDelegate.fs.read(output)
        let inputPlist = try PropertyList.fromBytes(inputContents.bytes)
        let (outputPlist, format) = try PropertyList.fromBytesWithFormat(outputContents.bytes)
        #expect(inputPlist == outputPlist)
        #expect(format == .binary)
    }

    @Test
    func openStepToXMLCopy() async throws {
        let input = Path.root.join("settings.plist")
        let output = Path.root.join("dst").join("settings.plist")
        let executionDelegate = MockExecutionDelegate()
        let inputContents = ByteString(encodingAsUTF8: "{ \"key\" = \"value\"; }")
        try executionDelegate.fs.createDirectory(output.dirname)
        try executionDelegate.fs.write(input, contents: inputContents)
        let action = CopyPlistTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyPlist", "--convert", "xml1", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
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

        // Check the file was copied, is the same as the source contents, and is in OpenStep format.
        let outputContents = try executionDelegate.fs.read(output)
        let inputPlist = try PropertyList.fromBytes(inputContents.bytes)
        let (outputPlist, format) = try PropertyList.fromBytesWithFormat(outputContents.bytes)
        #expect(inputPlist == outputPlist)
        #expect(format == .xml)
    }

    @Test
    func validation() async throws {
        do {
            let input = Path.root.join("settings.plist")
            let output = Path.root.join("dst").join("settings.plist")
            let executionDelegate = MockExecutionDelegate()
            let inputContents = ByteString(encodingAsUTF8: "{ \"key\" a= \"value\"; ")      // Missing closing curly brace
            try executionDelegate.fs.createDirectory(output.dirname)
            try executionDelegate.fs.write(input, contents: inputContents)
            let action = CopyPlistTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyPlist", "--validate", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Check the command failed as expected.
            #expect(result == .failed)
            #expect(outputDelegate.messages.count == 1)
            XCTAssertMatch(outputDelegate.messages[0], .prefix("error: unable to read input file as a property list:"))
        }

        // Test that copying a bad plist to binary reports an error.
        do {
            let input = Path.root.join("settings.plist")
            let output = Path.root.join("dst").join("settings.plist")
            let executionDelegate = MockExecutionDelegate()
            let inputContents = ByteString(encodingAsUTF8: "{ \"key\" = \"value\"; ")      // Missing closing curly brace
            try executionDelegate.fs.createDirectory(output.dirname)
            try executionDelegate.fs.write(input, contents: inputContents)
            let action = CopyPlistTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyPlist", "--convert", "binary1", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Check the command failed as expected.
            #expect(result == .failed)
            #expect(outputDelegate.messages.count == 1)
            XCTAssertMatch(outputDelegate.messages[0], .prefix("error: unable to read input file as a property list:"))
        }

        // Check validate and conversion of a plist with CFKeyedArchiverUID values.
        do {
            let input = Path.root.join("settings.plist")
            let output = Path.root.join("dst").join("settings.plist")
            let executionDelegate = MockExecutionDelegate()
            let inputContents = try localFS.read(#require(Bundle.module.url(forResource: "minimal-plist-with-uid", withExtension: "plist", subdirectory: "TestData")).filePath)
            try executionDelegate.fs.createDirectory(output.dirname)

            try executionDelegate.fs.write(input, contents: inputContents)
            let action = CopyPlistTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["copyPlist", "--validate", "--convert", "binary1", "--outdir", output.dirname.str, "--", input.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Property List")
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Check the command failed as expected.
            #expect(result == .succeeded)
            #expect(outputDelegate.messages == [])
            let outputContents = try executionDelegate.fs.read(output)
            #expect(inputContents == outputContents)
        }
    }
}
