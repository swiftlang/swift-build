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

import SWBProtocol
import SWBUtil

import Foundation

fileprivate extension ExternalToolResult {
    init(_ result: SWBExternalToolResult) {
        switch result {
        case .deferred:
            self = .deferred
        case let .result(status, stdout, stderr):
            self = .result(status: .init(status), stdout: stdout, stderr: stderr)
        }
    }
}

fileprivate extension Processes.ExitStatus {
    init(_ exitStatus: SWBProcessExitStatus) {
        switch exitStatus {
        case let .exit(code):
            self = .exit(code)
        case let .uncaughtSignal(signal):
            self = .uncaughtSignal(signal)
        }
    }
}

@discardableResult func handle(message: ExternalToolExecutionRequest, session: SWBBuildServiceSession, delegate: (any SWBPlanningOperationDelegate)?) async -> any Message {
    guard let delegate else {
        return await session.service.send(ErrorResponse("No delegate for response."))
    }

    let result = await Result.catching { try await delegate.executeExternalTool(commandLine: message.commandLine, workingDirectory: message.workingDirectory, environment: message.environment) }
    let reply = ExternalToolExecutionResponse(sessionHandle: message.sessionHandle, exchangeHandle: message.exchangeHandle, value: result.map(ExternalToolResult.init).mapError { .error("\($0)") })
    return await session.service.send(reply)
}
