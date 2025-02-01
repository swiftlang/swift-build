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

extension Optional {
    /// Convenience wrapper for `a ?? b` expressions where the right-hand side is `async`, since this is not yet implemented in the compiler/stdlib.
    public func or(_ rhs: @autoclosure () async throws -> Wrapped) async rethrows -> Wrapped {
        if let lhs = self {
            return lhs
        }
        return try await rhs()
    }
}
