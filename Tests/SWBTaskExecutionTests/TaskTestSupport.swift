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

// Support for testing tasks.

public import SWBCore
public import SWBTaskExecution
public import SWBUtil
import protocol SWBLLBuild.ProcessDelegate
import struct SWBLLBuild.CommandExtendedResult
import struct SWBLLBuild.llbuild_pid_t
import struct SWBProtocol.BuildOperationTaskEnded
import Foundation

class MockDynamicTaskExecutionDelegate: DynamicTaskExecutionDelegate {
    var allowsExternalToolExecution: Bool { false }
    var continueBuildingAfterErrors: Bool { false }

    func requestInputNode(node: ExecutionNode, nodeID: UInt) {
        // Do nothing for now.
    }

    func discoveredDependencyNode(_ node: ExecutionNode) {
        // Do nothing for now.
    }

    func discoveredDependencyDirectoryTree(_ path: Path) {
        // Do nothing for now.
    }

    func requestDynamicTask(
        toolIdentifier: String,
        taskKey: DynamicTaskKey,
        taskID: UInt,
        singleUse: Bool,
        workingDirectory: Path,
        environment: EnvironmentBindings,
        forTarget: ConfiguredTarget?,
        priority: TaskPriority,
        showEnvironment: Bool,
        reason: DynamicTaskRequestReason?
    ) {
        // Do nothing for now.
    }

    @discardableResult
    func spawn(
        commandLine: [String],
        environment: [String: String],
        workingDirectory: String,
        processDelegate: any ProcessDelegate
    ) async throws -> Bool {
        if commandLine.isEmpty {
            throw StubError.error("Invalid number of arguments")
        }

        let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: commandLine[0]), arguments: Array(commandLine.dropFirst()), currentDirectoryURL: URL(fileURLWithPath: workingDirectory), environment: .init(environment))

        // FIXME: Pass the real PID
        let pid = llbuild_pid_t.invalid
        processDelegate.processStarted(pid: pid)
        processDelegate.processHadOutput(output: Array(executionResult.stdout))
        processDelegate.processHadOutput(output: Array(executionResult.stderr))
        processDelegate.processFinished(result: CommandExtendedResult(result: .init(executionResult.exitStatus), exitStatus: executionResult.exitStatus.isSuccess ? 0 : 1, pid: pid))

        return executionResult.exitStatus.isSuccess
    }

    var operationContext: DynamicTaskOperationContext { fatalError() }

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        // Do nothing for now
        return ActivityID(rawValue: -1)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        // Do nothing for now
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        // Do nothing for now
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        // Do nothing for now
    }

    var hadErrors: Bool {
        false
    }
}

extension Task {
    // FIXME: Eliminate this.
    public convenience init(type: any TaskTypeDescription = mockTaskType, dependencyInfo: DependencyDataStyle? = nil, payload: (any TaskPayload)? = nil, forTarget: ConfiguredTarget?, ruleInfo: [String], commandLine: [String], environment: EnvironmentBindings = EnvironmentBindings(), workingDirectory: Path, outputs: [any PlannedNode] = [], action: TaskAction?, execDescription: String? = nil, preparesForIndexing: Bool = false) {
        var builder = PlannedTaskBuilder(type: type, ruleInfo: ruleInfo, commandLine: commandLine.map{ .literal(ByteString(encodingAsUTF8: $0)) }, environment: environment, outputs: outputs)
        builder.forTarget = forTarget
        builder.dependencyData = dependencyInfo
        builder.payload = payload
        builder.workingDirectory = workingDirectory
        builder.action = action
        builder.execDescription = execDescription
        builder.preparesForIndexing = preparesForIndexing
        self.init(&builder)
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
