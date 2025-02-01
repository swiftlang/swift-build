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

import Foundation
import SWBUtil
import Testing

@Suite fileprivate struct WaitConditionTests {
    /// Tests that calling `signal()` and `wait()` multiple times has no obvious adverse effects.
    @Test
    func idempotency() async {
        let condition = WaitCondition()

        condition.signal()
        condition.signal()

        await condition.wait()
        await condition.wait()
    }

    /// Regression test for `wait()` hanging when called from multiple tasks.
    @Test
    func multipleWaiters() async {
        let condition = WaitCondition()

        let tasks = (0..<100).map { _ in
            Task.detached {
                await condition.wait()
            }
        }

        condition.signal()

        for task in tasks {
            await task.value
        }
    }

    /// Tests cancellation behaviors.
    @Test
    func cancellation() async {
        let condition = CancellableWaitCondition()
        let task = Task {
            try await condition.wait()
        }

        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) {
            try result.get()
        }
    }
}
