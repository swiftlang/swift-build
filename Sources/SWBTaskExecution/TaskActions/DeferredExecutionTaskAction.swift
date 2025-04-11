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
import SWBUtil
public import SWBLLBuild
import Foundation
import SWBProtocol

public final class DeferredExecutionTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        "deferrable-shell-task"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
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
        return processDelegate.commandResult ?? .failed
    }
}

fileprivate extension CommandResult {
    init(_ exitStatus: Processes.ExitStatus) {
        if exitStatus.isSuccess {
            self = .succeeded
        } else if exitStatus.wasCanceled {
            self = .cancelled
        } else {
            self = .failed
        }
    }
}

extension TaskAction {
    func spawn(commandLine: [String], environment: [String: String], workingDirectory: String, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, processDelegate: any ProcessDelegate) async throws {
        guard dynamicExecutionDelegate.allowsExternalToolExecution else {
            try await dynamicExecutionDelegate.spawn(commandLine: commandLine, environment: environment, workingDirectory: workingDirectory, processDelegate: processDelegate)
            return
        }
        switch try await clientDelegate.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment) {
        case .deferred:
            try await dynamicExecutionDelegate.spawn(commandLine: commandLine, environment: environment, workingDirectory: workingDirectory, processDelegate: processDelegate)
        case let .result(status, stdout, stderr):
            // NOTE: This is not strictly correct, as we really should forward the merged output in the same order it was emitted, rather than all of stdout and then all of stderr. But we need much better APIs in order to do that, and for the current (Swift Playgrounds) use case it shouldn't matter in practice.
            let pid = llbuild_pid_t.invalid
            processDelegate.processStarted(pid: pid)
            processDelegate.processHadOutput(output: Array(stdout))
            processDelegate.processHadOutput(output: Array(stderr))
            processDelegate.processFinished(result: .init(result: .init(status), exitStatus: status.isSuccess ? 0 : 1, pid: pid))
        }
    }
}
