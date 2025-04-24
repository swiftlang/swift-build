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

public import SWBProtocol
import SWBUtil
import Synchronization

/// An individual request made by a service client.
///
/// This type is used to track the lifetime of an individual request.
///
/// API clients are expected to always explicitly _complete_ a request by invoking one of `reply()` or `cancel()` once the request has been satisfied. This is a checked error in debug builds.
///
/// NOTE: We do not currently provide the initiating message as part of the request, but this could easily be added.
public final class Request: Sendable {
    /// The service the request was initiated from.
    public unowned let service: Service

    /// The channel allocated for this request, used in the reply.
    let channel: UInt64

    /// The name of the request (for debugging purposes).
    public let name: String

    /// Whether the request has been completed.
    private let completed = SWBMutex<Bool>(false)

    /// Create a new request.
    ///
    /// - Parameters:
    ///   - service: The service the request was initiated from.
    ///   - channel: The channel allocated for this request, used in the reply.
    ///   - name: The name of the request (for debugging purposes).
    ///   - span: The tracing span, if available.
    public init(service: Service, channel: UInt64, name: String) {
        self.service = service
        self.channel = channel
        self.name = name
    }

#if DEBUG
    /// Validate that every request is completed, in debug builds.
    deinit {
        completed.withLock { completed in
            if !completed {
                fatalError("unexpected incomplete request: \(self)")
            }
        }
    }
#endif

    /// Send a message to the client.
    public func send(_ message: any Message) {
        completed.withLock { completed in
            precondition(!completed, "Attempting to send message after the request has already been completed: \(message)")
            service.send(channel, message)
        }
    }

    /// Cancel the request.
    public func cancel() {
        completed.withLock { completed in
            precondition(!completed, "Attempting to cancel the request after it has already been completed")
            reply(ErrorResponse("the request was cancelled by the service"))
        }
    }

    /// Complete the request with the given response.
    public func reply(_ message: any Message) {
        completed.withLock { completed in
            precondition(!completed, "Attempting to send reply after the request has already been completed: \(message)")
            completed = true
            service.send(channel, message)
        }
    }
}
