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

import SWBBuildSystem
import SWBCore
import SWBProtocol
import SWBServiceCore
import SWBTaskConstruction
import SWBTaskExecution
import SWBUtil
import struct Foundation.UUID

/// Manages exchanges with the client to get information needed by the service.  Task construction and task execution communicate with this object through delegate calls.
///
/// This delegate allows this client communication to be abstracted away from the calling code.
final class ClientExchangeDelegate: ClientDelegate {
    /// The request which initiated task construction.
    let request: Request
    /// The session in which task construction is happening.
    unowned let session: Session

    init(request: Request, session: Session) {
        self.request = request
        self.session = session
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
        // Create a synchronous client exchange which the session uses to handle the response from the client, to make the communication synchronous from the point of view of our caller.
        let exchange = SynchronousClientExchange<ExternalToolExecutionResponse>(session)

        // Construct the message and send it to the client.
        let message = ExternalToolExecutionRequest(sessionHandle: session.UID, exchangeHandle: exchange.uuid.description, commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
        return try await exchange.send(message, to: request).value.get()
    }
}

final class SynchronousClientExchange<ResponseMessageType: SessionMessage>: ClientExchange {
    private unowned let session: Session
    let uuid = UUID()
    private let condition = CancellableWaitCondition()
    private var response: ResponseMessageType? = nil

    fileprivate init(_ session: Session) {
        self.session = session
    }

    /// Sends the message to the client via the given Request object, and suspends until the response comes back.
    fileprivate func send(_ message: any SessionMessage, to request: Request) async throws -> ResponseMessageType {
        session.addClientExchange(self)
        request.send(message)

        do {
            try await condition.wait()
        } catch let error as CancellationError {
            // Discard the client exchange to ensure balanced state clean up.
            // This may or may not have been called already, depending on
            // whether or not handle(response:) managed to get called concurrently.
            _ = session.discardClientExchange(self)
            throw error
        }

        guard let response else {
            throw CancellationError()
        }

        return response
    }

    func handle(response: ResponseMessageType) -> Bool {
        // Store the response so our creator can handle it.
        self.response = response

        // Signal the semaphore so our caller can proceed with the result.
        let exchange = session.discardClientExchange(self)
        condition.signal()

        // Return to our calling message handler. If exchange is nil, send() already discarded the exchange due to cancellation.
        return exchange != nil
    }
}
