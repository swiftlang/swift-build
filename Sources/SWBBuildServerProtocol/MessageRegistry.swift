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

public final class MessageRegistry: Sendable {

  private let methodToRequest: [String: _RequestType.Type]
  private let methodToNotification: [String: NotificationType.Type]

  public init(requests: [any _RequestType.Type], notifications: [any NotificationType.Type]) {
    self.methodToRequest = Dictionary(uniqueKeysWithValues: requests.map { ($0.method, $0) })
    self.methodToNotification = Dictionary(uniqueKeysWithValues: notifications.map { ($0.method, $0) })
  }

  /// Returns the type of the message named `method`, or nil if it is unknown.
  public func requestType(for method: String) -> _RequestType.Type? {
    return methodToRequest[method]
  }

  /// Returns the type of the message named `method`, or nil if it is unknown.
  public func notificationType(for method: String) -> NotificationType.Type? {
    return methodToNotification[method]
  }

}
