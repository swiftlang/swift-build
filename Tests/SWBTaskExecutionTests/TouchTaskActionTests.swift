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

import Foundation
import Testing
import SWBUtil
import SWBCore
import SWBTaskExecution
import SWBTestSupport

@Suite
fileprivate struct TouchTaskActionTests {

    @Test
    func touchDirectory() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let bundlePath = tmpDir.join("Test.bundle")
            let fs = localFS

            // Create a bundle directory
            try fs.createDirectory(bundlePath, recursive: true)

            // Seed a known timestamp in the past so we can deterministically observe the touch
            // advancing it, without racing the wall clock.
            let initialTimestamp = 1_000_000_000  // 2001-09-09 UTC, comfortably in the past
            try fs.setFileTimestamp(bundlePath, timestamp: initialTimestamp)

            // Execute touch action
            let executionDelegate = MockExecutionDelegate(fs: fs)
            let action = TouchTaskAction()
            let task = Task(forTarget: nil, ruleInfo: ["Touch", bundlePath.str], commandLine: ["builtin-touch", bundlePath.str], workingDirectory: tmpDir, outputs: [], action: action, execDescription: "Touch Test.bundle")

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Verify success
            #expect(result == .succeeded)
            #expect(outputDelegate.errors.isEmpty)

            // Verify timestamp was updated to current time (strictly later than the seeded value)
            let newTimestamp = try fs.getFileTimestamp(bundlePath)
            #expect(newTimestamp > initialTimestamp, "Timestamp should have been updated to current time")
        }
    }

    @Test
    func touchFile() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let filePath = tmpDir.join("test.txt")
            let fs = localFS

            // Create a file
            try fs.write(filePath, contents: "test content")

            // Seed a known timestamp in the past so we can deterministically observe the touch
            // advancing it, without racing the wall clock.
            let initialTimestamp = 1_000_000_000  // 2001-09-09 UTC, comfortably in the past
            try fs.setFileTimestamp(filePath, timestamp: initialTimestamp)

            // Execute touch action
            let executionDelegate = MockExecutionDelegate(fs: fs)
            let action = TouchTaskAction()
            let task = Task(forTarget: nil, ruleInfo: ["Touch", filePath.str], commandLine: ["builtin-touch", filePath.str], workingDirectory: tmpDir, outputs: [], action: action, execDescription: "Touch test.txt")

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Verify success
            #expect(result == .succeeded)
            #expect(outputDelegate.errors.isEmpty)

            // Verify timestamp was updated to current time (strictly later than the seeded value)
            let newTimestamp = try fs.getFileTimestamp(filePath)
            #expect(newTimestamp > initialTimestamp, "Timestamp should have been updated to current time")
        }
    }

    @Test
    func touchNonexistentPath() async throws {
        let fs = PseudoFS()
        let nonexistentPath = Path.root.join("does-not-exist")

        let executionDelegate = MockExecutionDelegate(fs: fs)
        let action = TouchTaskAction()
        let task = Task(forTarget: nil, ruleInfo: ["Touch", nonexistentPath.str], commandLine: ["builtin-touch", nonexistentPath.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Touch does-not-exist")

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // A missing path is a no-op success, matching `touch -c`.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors.isEmpty)
        #expect(!fs.exists(nonexistentPath))
    }

    @Test
    func touchWithMissingArguments() async throws {
        let fs = PseudoFS()

        let executionDelegate = MockExecutionDelegate(fs: fs)
        let action = TouchTaskAction()
        // Command line with only program name, no path argument
        let task = Task(forTarget: nil, ruleInfo: ["Touch"], commandLine: ["builtin-touch"], workingDirectory: .root, outputs: [], action: action, execDescription: "Touch")

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Verify failure
        #expect(result == .failed)
        #expect(!outputDelegate.errors.isEmpty)
        #expect(outputDelegate.errors.contains { $0.contains("expected a single path argument") })
    }

    @Test
    func touchWithExtraArguments() async throws {
        let fs = PseudoFS()
        let pathA = Path.root.join("a")
        let pathB = Path.root.join("b")

        let executionDelegate = MockExecutionDelegate(fs: fs)
        let action = TouchTaskAction()
        // Command line with more than one path argument.
        let task = Task(forTarget: nil, ruleInfo: ["Touch"], commandLine: ["builtin-touch", pathA.str, pathB.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Touch")

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Verify failure
        #expect(result == .failed)
        #expect(!outputDelegate.errors.isEmpty)
        #expect(outputDelegate.errors.contains { $0.contains("expected a single path argument") })
    }
}
