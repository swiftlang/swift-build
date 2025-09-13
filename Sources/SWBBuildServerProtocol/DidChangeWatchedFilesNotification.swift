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

/// Notification from the client when changes to watched files are detected.
///
/// - Parameter changes: The set of file changes.
public struct DidChangeWatchedFilesNotification: NotificationType {
  public static let method: String = "workspace/didChangeWatchedFiles"

  /// The file changes.
  public var changes: [FileEvent]

  public init(changes: [FileEvent]) {
    self.changes = changes
  }
}
