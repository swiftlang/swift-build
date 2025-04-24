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

import SWBUtil
public import SWBCore
import Foundation

/// Concrete implementation of task for registering a built app.
public final class LSRegisterURLTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "lsregisterurl"
    }

    override public func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let processDelegate = TaskProcessDelegate(outputDelegate: outputDelegate)
        do {
            try await spawn(commandLine: Array(task.commandLineAsStrings), environment: task.environment.bindingsDictionary, workingDirectory: task.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: processDelegate)
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
        if let error = processDelegate.executionError {
            outputDelegate.error(error)
            return .failed
        }

        // We don't ever fail if `lsregister` fails, instead we just emit a note.
        if processDelegate.commandResult != .succeeded {
            outputDelegate.note("LaunchServices registration failed and was skipped")
            outputDelegate.updateResult(.exit(exitStatus: .exit(0), metrics: nil))
        }

        return .succeeded
    }
}
