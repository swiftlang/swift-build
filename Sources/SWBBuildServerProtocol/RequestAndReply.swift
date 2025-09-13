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

import SWBUtil
import Synchronization

/// A request and a callback that returns the request's reply
public final class RequestAndReply<Params: RequestType>: Sendable {
  public let params: Params
  private let replyBlock: @Sendable (LSPResult<Params.Response>) -> Void

  /// Whether a reply has been made. Every request must reply exactly once.
  private let replied = SWBMutex<Bool>(false)

  public init(_ request: Params, reply: @escaping @Sendable (LSPResult<Params.Response>) -> Void) {
    self.params = request
    self.replyBlock = reply
  }

  deinit {
    precondition(replied.withLock { $0 }, "request never received a reply")
  }

  /// Call the `replyBlock` with the result produced by the given closure.
  public func reply(_ body: @Sendable () async throws -> Params.Response) async {
    precondition(!replied.withLock { $0 }, "replied to request more than once")
      replied.withLock { $0 = true }
    do {
      replyBlock(.success(try await body()))
    } catch {
      replyBlock(.failure(ResponseError(error)))
    }
  }
}
