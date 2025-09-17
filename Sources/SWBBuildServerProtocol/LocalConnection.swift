//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation
import SWBUtil
import Synchronization

/// A connection between two message handlers in the same process.
///
/// You must call `start(handler:)` before sending any messages, and must call `close()` when finished to avoid a memory leak.
///
/// ```
/// let client: MessageHandler = ...
/// let server: MessageHandler = ...
/// let conn = LocalConnection()
/// conn.start(handler: server)
/// conn.send(...) // handled by server
/// conn.close()
/// ```
public final class LocalConnection: Connection, Sendable {
  private enum State {
    case ready, started, closed
  }

  /// A name of the endpoint for this connection, used for logging, e.g. `clangd`.
  private let name: String

  /// The queue guarding `_nextRequestID`.
  private let queue: DispatchQueue = DispatchQueue(label: "local-connection-queue")

  private let _nextRequestID = SWBMutex<UInt32>(0)

  /// - Important: Must only be accessed from `queue`
  nonisolated(unsafe) private var state: State = .ready

  /// - Important: Must only be accessed from `queue`
  nonisolated(unsafe) private var handler: (any MessageHandler)? = nil

  public init(receiverName: String) {
    self.name = receiverName
  }

  public convenience init(receiverName: String, handler: any MessageHandler) {
    self.init(receiverName: receiverName)
    self.start(handler: handler)
  }

  deinit {
    queue.sync {
      if state != .closed {
        closeAssumingOnQueue()
      }
    }
  }

  public func start(handler: any MessageHandler) {
    queue.sync {
      precondition(state == .ready)
      state = .started
      self.handler = handler
    }
  }

  /// - Important: Must only be called from `queue`
  private func closeAssumingOnQueue() {
    dispatchPrecondition(condition: .onQueue(queue))
    precondition(state != .closed)
    handler = nil
    state = .closed
  }

  public func close() {
    queue.sync {
      closeAssumingOnQueue()
    }
  }

  public func nextRequestID() -> RequestID {
    return .string("sk-\(_nextRequestID.fetchAndIncrement())")
  }

  public func send<Notification: NotificationType>(_ notification: Notification) {
    guard let handler = queue.sync(execute: { handler }) else {
      return
    }
    handler.handle(notification)
  }

  public func send<Request: RequestType>(
    _ request: Request,
    id: RequestID,
    reply: @Sendable @escaping (LSPResult<Request.Response>) -> Void
  ) {
    guard let handler = queue.sync(execute: { handler }) else {
      reply(.failure(.serverCancelled))
      return
    }

    precondition(self.state == .started)
    handler.handle(request, id: id) { result in
      reply(result)
    }
  }
}
