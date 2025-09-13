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

extension ResponseError {
  package init(_ error: some Error) {
    switch error {
    case let error as ResponseError:
      self = error
    case is CancellationError:
      self = .cancelled
    default:
      self = .unknown("Unknown error: \(error)")
    }
  }
}
