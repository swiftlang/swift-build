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

package struct TimeoutError: Error {
    package var description: String?
}

package func withTimeout<T: Sendable>(
    timeout: Duration,
    description: String? = nil,
    block: sending () async throws -> T
) async throws -> T {
    try await withoutActuallyEscaping(block) { escapingClosure in
        // This lets block be captured in the Sendable function x.
        // since x is Sendable, we can smuggle it through.
        nonisolated(unsafe) let b = escapingClosure
        let x: @Sendable () async throws -> T = {
            try await b()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await x()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError(description: description)
            }

            let result = await group.nextResult()

            group.cancelAll()

            switch result {
            case .failure(let error):
                throw error
            case .none:
                throw TimeoutError(description: description)
            case .success(let value):
                return value
            }
        }
    }
}
