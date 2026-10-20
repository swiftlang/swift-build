//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
import SWBUtil
import Synchronization

@Suite fileprivate struct InFlightTasksTests {
    @Test
    func identicalKeysShareTheTaskInFlight() async {
        let tasks = InFlightTasks<Int, Int>()
        let invocations = SWBMutex(0)
        let (release, continuation) = AsyncStream<Void>.makeStream()

        let first = tasks.task(for: 1) {
            invocations.withLock { $0 += 1 }
            for await _ in release { break }
            return 42
        }
        let second = tasks.task(for: 1) {
            invocations.withLock { $0 += 1 }
            return -1
        }
        #expect(tasks.count == 1)

        continuation.yield()
        #expect(await first.value == 42)
        #expect(await second.value == 42)
        #expect(invocations.withLock { $0 } == 1)
    }

    @Test
    func differentKeysRunSeparately() async {
        let tasks = InFlightTasks<Int, Int>()
        let (release, continuation) = AsyncStream<Void>.makeStream()

        let first = tasks.task(for: 1) {
            for await _ in release { break }
            return 1
        }
        let second = tasks.task(for: 2) { 2 }
        #expect(await second.value == 2)

        continuation.yield()
        #expect(await first.value == 1)
    }

    @Test
    func finishedTasksAreNotReused() async {
        let tasks = InFlightTasks<Int, Int>()
        let invocations = SWBMutex(0)

        let first = await tasks.task(for: 1) {
            invocations.withLock { $0 += 1 }
            return 1
        }.value
        // The task removes itself once it has produced its value.
        while tasks.count != 0 {
            await Task.yield()
        }
        let second = await tasks.task(for: 1) {
            invocations.withLock { $0 += 1 }
            return 2
        }.value

        #expect(first == 1)
        #expect(second == 2)
        #expect(invocations.withLock { $0 } == 2)
    }
}
