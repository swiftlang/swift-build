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

package actor Deferrable {
    private var workItems: [() async -> Void] = []

    fileprivate init() {}

    package func addBlock(_ work: @Sendable @escaping () async -> Void) {
        workItems.append(work)
    }

    fileprivate func runBlocks() async {
        for workItem in workItems.reversed() {
            await workItem()
        }
    }
}

package func withAsyncDeferrable<T>(_ work: (Deferrable) async throws -> T) async throws -> T {
    let deferrable = Deferrable()
    let result: Result<T, any Error>
    do {
        result = try await .success(work(deferrable))
    } catch {
        result = .failure(error)
    }
    await deferrable.runBlocks()
    return try result.get()
}
