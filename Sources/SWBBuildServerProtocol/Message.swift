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

public protocol MessageType: Codable, Sendable {}

/// `RequestType` with no associated type or same-type requirements. Most users should prefer
/// `RequestType`.
public protocol _RequestType: MessageType {

  /// The name of the request.
  static var method: String { get }

  /// *Implementation detail*. Dispatch `self` to the given handler and reply on `connection`.
  /// Only needs to be declared as a protocol requirement of `_RequestType` so we can call the implementation on `RequestType` from the underscored type.
  func _handle(
    _ handler: any MessageHandler,
    id: RequestID,
    reply: @Sendable @escaping (LSPResult<any ResponseType>, RequestID) -> Void
  )
}

/// A request, which must have a unique `method` name as well as an associated response type.
public protocol RequestType: _RequestType {

  /// The type of of the response to this request.
  associatedtype Response: ResponseType
}

/// A notification, which must have a unique `method` name.
public protocol NotificationType: MessageType {

  /// The name of the request.
  static var method: String { get }
}

/// A response.
public protocol ResponseType: MessageType {}

extension RequestType {
  public func _handle(
    _ handler: any MessageHandler,
    id: RequestID,
    reply: @Sendable @escaping (LSPResult<any ResponseType>, RequestID) -> Void
  ) {
    handler.handle(self, id: id) { response in
      reply(response.map({ $0 as (any ResponseType) }), id)
    }
  }
}

extension NotificationType {
  public func _handle(_ handler: any MessageHandler) {
    handler.handle(self)
  }
}

/// A `textDocument/*` notification, which takes a text document identifier
/// indicating which document it operates in or on.
public protocol TextDocumentNotification: NotificationType {
  var textDocument: TextDocumentIdentifier { get }
}

/// A `textDocument/*` request, which takes a text document identifier
/// indicating which document it operates in or on.
public protocol TextDocumentRequest: RequestType {
  var textDocument: TextDocumentIdentifier { get }
}
