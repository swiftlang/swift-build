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
import SWBTaskExecution
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct ObjectLibraryAssemblerTaskActionTests {
    @Test
    func duplicateFileHandling() async throws {
        // Create input files with duplicate basenames (all named file.o)
        let inputOne = Path.root.join("input1").join("file.o")
        let inputTwo = Path.root.join("input2").join("file.o")
        let inputThree = Path.root.join("input3").join("file.o")
        let inputUnique = Path.root.join("unique.o")
        let output = Path.root.join("output")

        let executionDelegate = MockExecutionDelegate()
        try executionDelegate.fs.createDirectory(inputOne.dirname, recursive: true)
        try executionDelegate.fs.createDirectory(inputTwo.dirname, recursive: true)
        try executionDelegate.fs.createDirectory(inputThree.dirname, recursive: true)
        try executionDelegate.fs.write(inputOne, contents: ByteString(encodingAsUTF8: "one"))
        try executionDelegate.fs.write(inputTwo, contents: ByteString(encodingAsUTF8: "two"))
        try executionDelegate.fs.write(inputThree, contents: ByteString(encodingAsUTF8: "three"))
        try executionDelegate.fs.write(inputUnique, contents: ByteString(encodingAsUTF8: "unique"))

        let outputDelegate = MockTaskOutputDelegate()

        let commandLine = [
            "builtin-ObjectLibraryAssembler",
            "--linker-response-file-format",
            "unixShellQuotedSpaceSeparated",
            inputOne.str,
            inputTwo.str,
            inputThree.str,
            inputUnique.str,
            "--output",
            output.str
        ].map { ByteString(encodingAsUTF8: $0) }

        let inputs = [inputOne, inputTwo, inputThree, inputUnique].map { MakePlannedPathNode($0) }
        var builder = PlannedTaskBuilder(type: mockTaskType, ruleInfo: [], commandLine: commandLine.map { .literal($0) }, inputs: inputs, outputs: [MakePlannedPathNode(output)])
        let task = Task(&builder)

        let result = await ObjectLibraryAssemblerTaskAction().performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        #expect(result == .succeeded, "Task should succeed")
        #expect(outputDelegate.messages == [], "Should have no error messages")

        // Verify the output directory was created
        #expect(executionDelegate.fs.exists(output), "Output directory should exist")

        // Verify that files were copied with proper duplicate handling
        let copiedOriginal = output.join("file.o")
        let copiedDuplicate1 = output.join("file-1.o")
        let copiedDuplicate2 = output.join("file-2.o")
        let copiedUnique = output.join("unique.o")

        #expect(executionDelegate.fs.exists(copiedOriginal), "First file.o should exist")
        #expect(executionDelegate.fs.exists(copiedDuplicate1), "file-1.o should exist")
        #expect(executionDelegate.fs.exists(copiedDuplicate2), "file-2.o should exist")
        #expect(executionDelegate.fs.exists(copiedUnique), "unique.o should exist")

        // Verify content of copied files
        #expect(try executionDelegate.fs.read(copiedOriginal).asString == "one")
        #expect(try executionDelegate.fs.read(copiedDuplicate1).asString == "two")
        #expect(try executionDelegate.fs.read(copiedDuplicate2).asString == "three")
        #expect(try executionDelegate.fs.read(copiedUnique).asString == "unique")

        // Verify the response file was created with correct paths
        let responseFile = output.join("args.resp")
        #expect(executionDelegate.fs.exists(responseFile), "Response file should exist")

        let responseContent = try executionDelegate.fs.read(responseFile).asString
        #expect(responseContent.contains("file.o"), "Response should contain file.o")
        #expect(responseContent.contains("file-1.o"), "Response should contain file-1.o")
        #expect(responseContent.contains("file-2.o"), "Response should contain file-2.o")
        #expect(responseContent.contains("unique.o"), "Response should contain unique.o")
    }

    @Test
    func noDuplicates() async throws {
        // Test that files with unique basenames are not renamed
        let inputOne = Path.root.join("a.o")
        let inputTwo = Path.root.join("b.o")
        let inputThree = Path.root.join("c.o")
        let output = Path.root.join("output")

        let executionDelegate = MockExecutionDelegate()
        try executionDelegate.fs.write(inputOne, contents: ByteString(encodingAsUTF8: "a"))
        try executionDelegate.fs.write(inputTwo, contents: ByteString(encodingAsUTF8: "b"))
        try executionDelegate.fs.write(inputThree, contents: ByteString(encodingAsUTF8: "c"))

        let outputDelegate = MockTaskOutputDelegate()

        let commandLine = [
            "builtin-ObjectLibraryAssembler",
            "--linker-response-file-format",
            "unixShellQuotedSpaceSeparated",
            inputOne.str,
            inputTwo.str,
            inputThree.str,
            "--output",
            output.str
        ].map { ByteString(encodingAsUTF8: $0) }

        let inputs = [inputOne, inputTwo, inputThree].map { MakePlannedPathNode($0) }
        var builder = PlannedTaskBuilder(type: mockTaskType, ruleInfo: [], commandLine: commandLine.map { .literal($0) }, inputs: inputs, outputs: [MakePlannedPathNode(output)])
        let task = Task(&builder)

        let result = await ObjectLibraryAssemblerTaskAction().performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        #expect(result == .succeeded, "Task should succeed")

        // Verify files are copied with their original names (no -N suffix)
        let copiedA = output.join("a.o")
        let copiedB = output.join("b.o")
        let copiedC = output.join("c.o")

        #expect(executionDelegate.fs.exists(copiedA), "a.o should exist")
        #expect(executionDelegate.fs.exists(copiedB), "b.o should exist")
        #expect(executionDelegate.fs.exists(copiedC), "c.o should exist")

        // Verify that no renamed versions exist
        #expect(!executionDelegate.fs.exists(output.join("a-1.o")), "a-1.o should not exist")
        #expect(!executionDelegate.fs.exists(output.join("b-1.o")), "b-1.o should not exist")
        #expect(!executionDelegate.fs.exists(output.join("c-1.o")), "c-1.o should not exist")
    }
}
