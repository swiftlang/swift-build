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

/// This request is a no-op and doesn't have any effects.
///
/// If the build server is currently updating the build graph, this request should return after those updates have
/// finished processing.
public struct WorkspaceWaitForBuildSystemUpdatesRequest: RequestType, Hashable {
  public typealias Response = VoidResponse

  public static let method: String = "workspace/waitForBuildSystemUpdates"

  public init() {}
}
