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

public enum StatusCode: Int, Codable, Hashable, Sendable {
  /// Execution was successful.
  case ok = 1

  /// Execution failed.
  case error = 2

  /// Execution was cancelled.
  case cancelled = 3
}
