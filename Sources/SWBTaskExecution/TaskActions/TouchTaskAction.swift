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

public import SWBCore
public import SWBUtil

/// Concrete implementation of task for touching a file or directory to update its modification timestamp.
public final class TouchTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "touch"
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        let generator = task.commandLineAsStrings.makeIterator()
        _ = generator.next() // consume program name "builtin-touch"

        guard let pathString = generator.next() else {
            outputDelegate.emitError("wrong number of arguments")
            return .failed
        }

        let path = Path(pathString)
        let fs = executionDelegate.fs

        // Validate that the path exists
        guard fs.exists(path) else {
            outputDelegate.emitError("path does not exist: \(path.str)")
            return .failed
        }

        // Touch the file/directory to update its modification timestamp
        do {
            try fs.touch(path)
            return .succeeded
        } catch {
            outputDelegate.emitError("failed to touch \(path.str): \(error)")
            return .failed
        }
    }
}
