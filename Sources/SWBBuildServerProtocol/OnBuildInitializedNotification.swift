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

/// Like the language server protocol, the initialized notification is sent from the client to the server after the client received the result of the initialize request but before the client is sending any other request or notification to the server. The server can use the initialized notification for example to initialize intensive computation such as dependency resolution or compilation. The initialized notification may only be sent once.
public struct OnBuildInitializedNotification: NotificationType {
  public static let method: String = "build/initialized"

  public init() {}
}
