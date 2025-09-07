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

public import Foundation
import SWBUtil
import Synchronization

public extension Task {
  /// Awaits the value of the result.
  ///
  /// If the current task is cancelled, this will cancel the subtask as well.
  var valuePropagatingCancellation: Success {
    get async throws {
      try await withTaskCancellationHandler {
        return try await self.value
      } onCancel: {
        self.cancel()
      }
    }
  }
}

extension Task where Failure == Never {
  /// Awaits the value of the result.
  ///
  /// If the current task is cancelled, this will cancel the subtask as well.
  public var valuePropagatingCancellation: Success {
    get async {
      await withTaskCancellationHandler {
        return await self.value
      } onCancel: {
        self.cancel()
      }
    }
  }
}
