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

public import SWBCore
import SWBUtil

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
        let arguments = Array(task.commandLineAsStrings.dropFirst())  // drop program name "builtin-touch"
        guard arguments.count == 1, let pathString = arguments.first else {
            outputDelegate.emitError("expected a single path argument to builtin-touch")
            return .failed
        }

        let path = Path(pathString)
        let fs = executionDelegate.fs

        // Matches `touch -c`: don't create the path, and treat a missing path as success. The
        // touch task is only a convenience for consumers that check the product's timestamp (it
        // is also planned for `headers`-only builds, where the product may not exist), so build
        // integrity must not depend on it.
        guard fs.exists(path) else {
            return .succeeded
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
