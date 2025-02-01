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
fileprivate struct ConcatenateTaskTests {
    @Test
    func concatenate() async throws {
        let inputOne = Path.root.join("one.txt")
        let inputTwo = Path.root.join("two.txt")
        let inputThree = Path.root.join("three.txt")
        let output = Path.root.join("dst/output.txt")

        let executionDelegate = MockExecutionDelegate()
        try executionDelegate.fs.write(inputOne, contents: ByteString(encodingAsUTF8: "one"))
        try executionDelegate.fs.write(inputTwo, contents: ByteString(encodingAsUTF8: "two"))
        try executionDelegate.fs.write(inputThree, contents: ByteString(encodingAsUTF8: "three"))
        try executionDelegate.fs.createDirectory(output.dirname)

        let outputDelegate = MockTaskOutputDelegate()

        // Test creating a new file.
        var commandLine = ["builtin-concatenate", output.str, inputOne.str, inputTwo.str, inputThree.str].map{ ByteString(encodingAsUTF8: $0) }
        var inputs = [inputOne, inputTwo, inputThree].map { MakePlannedPathNode($0) }
        var builder = PlannedTaskBuilder(type: mockTaskType, ruleInfo: [], commandLine: commandLine.map { .literal($0) }, inputs: inputs, outputs: [MakePlannedPathNode(output)])
        var task = Task(&builder)

        var result = await ConcatenateTaskAction().performTaskAction(task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(), executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(), outputDelegate: outputDelegate)

        #expect(result == .succeeded)
        #expect(outputDelegate.messages == [])
        var outputContents = try executionDelegate.fs.read(output)
        #expect("onetwothree" == outputContents)

        // Test overwriting the file.
        commandLine = ["builtin-concatenate", output.str, inputThree.str, inputTwo.str, inputOne.str].map{ ByteString(encodingAsUTF8: $0) }
        inputs = [inputThree, inputTwo, inputOne].map { MakePlannedPathNode($0) }
        builder = PlannedTaskBuilder(type: mockTaskType, ruleInfo: [], commandLine: commandLine.map { .literal($0) }, inputs: inputs, outputs: [MakePlannedPathNode(output)])
        task = Task(&builder)

        result = await ConcatenateTaskAction().performTaskAction(task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(), executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(), outputDelegate: outputDelegate)

        #expect(result == .succeeded)
        #expect(outputDelegate.messages == [])
        outputContents = try executionDelegate.fs.read(output)
        #expect("threetwoone" == outputContents)
    }
}
