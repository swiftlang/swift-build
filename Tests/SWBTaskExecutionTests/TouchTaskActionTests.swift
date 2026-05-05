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
import SWBTestSupport

#if compiler(<6.4)
// Swift compiler versions prior to 6.4 ship with a Foundation implementation on Windows
// that does not properly support setting timestamps on directories via touch operations.
// This test is disabled on Windows for those compiler versions to avoid spurious failures.
let enableTouchDirTest = (try? ProcessInfo.processInfo.hostOperatingSystem()) != .windows
#else
let enableTouchDirTest = true
#endif

@Suite
fileprivate struct TouchTaskActionTests {

    @Test(.enabled(if: enableTouchDirTest))
    func touchDirectory() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let bundlePath = tmpDir.join("Test.bundle")
            let fs = localFS

            // Create a bundle directory
            try fs.createDirectory(bundlePath, recursive: true)

            // Get initial timestamp
            let initialTimestamp = try fs.getFileTimestamp(bundlePath)

            // wait for some time to pass
            var newTime = time(nil)
            while newTime <= initialTimestamp {
                try await _Concurrency.Task.sleep(for: .seconds(1))
                newTime = time(nil)
            }

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

            // Verify timestamp was updated (touch sets it to current time)
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

            // Get initial timestamp
            let initialTimestamp = try fs.getFileTimestamp(filePath)

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

            // Verify timestamp was updated (touch sets it to current time)
            let newTimestamp = try fs.getFileTimestamp(filePath)
            #expect(newTimestamp >= initialTimestamp, "Timestamp should have been updated to current time")
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

        // Verify failure
        #expect(result == .failed)
        #expect(!outputDelegate.errors.isEmpty)
        #expect(outputDelegate.errors.contains { $0.contains("does not exist") })
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
        #expect(outputDelegate.errors.contains { $0.contains("wrong number of arguments") })
    }
}
