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

/// Like the language server protocol, the shutdown build request is
/// sent from the client to the server. It asks the server to shut down,
/// but to not exit (otherwise the response might not be delivered
/// correctly to the client). There is a separate exit notification
/// that asks the server to exit.
public struct BuildShutdownRequest: RequestType {
  public static let method: String = "build/shutdown"
  public typealias Response = VoidResponse

  public init() {}
}
