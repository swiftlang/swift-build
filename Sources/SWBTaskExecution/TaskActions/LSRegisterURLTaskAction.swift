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
        let commandLine = Array(task.commandLineAsStrings.dropFirst())
        let recordPath: Path?
        let lsregisterCommandLine: [String]

        if let separatorIndex = commandLine.firstIndex(of: "--") {
            let args = commandLine[..<separatorIndex]
            if let recordIndex = args.firstIndex(of: "--record-path"), args.index(after: recordIndex) < args.endIndex {
                recordPath = Path(String(args[args.index(after: recordIndex)]))
            } else {
                recordPath = nil
            }
            lsregisterCommandLine = Array(commandLine[commandLine.index(after: separatorIndex)...])
        } else {
            recordPath = nil
            lsregisterCommandLine = commandLine
        }

        let processDelegate = TaskProcessDelegate(outputDelegate: outputDelegate)
        do {
            try await spawn(commandLine: lsregisterCommandLine, environment: task.environment.bindingsDictionary, workingDirectory: task.workingDirectory, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: processDelegate)
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
        } else if let recordPath, let appPath = task.inputPaths.first {
            try? executionDelegate.fs.append(recordPath, contents: ByteString(encodingAsUTF8: appPath.str + "\n"))
        }

        return .succeeded
    }
}
