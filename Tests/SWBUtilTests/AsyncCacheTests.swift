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

@Suite fileprivate struct AsyncCacheTests {
    private struct TestError: Error { }

    @Test
    func valueComputesOncePerKey() async throws {
        let cache = AsyncCache<Int, Int>()
        let invocations = SWBMutex(0)

        let first = try await cache.value(forKey: 1) {
            invocations.withLock { $0 += 1 }
            return 42
        }
        let second = try await cache.value(forKey: 1) {
            invocations.withLock { $0 += 1 }
            return -1
        }

        #expect(first == 42)
        #expect(second == 42)
        #expect(invocations.withLock { $0 } == 1)
    }

    @Test
    func peekReturnsNilForAbsentKey() async {
        let cache = AsyncCache<Int, Int>()
        #expect(await cache.peek(forKey: 1) == nil)
    }

    @Test
    func peekReturnsFinishedSuccessValue() async throws {
        let cache = AsyncCache<Int, Int>()
        _ = try await cache.value(forKey: 1) { 42 }
        #expect(await cache.peek(forKey: 1) == 42)
    }

    @Test
    func peekReturnsNilForCachedFailure() async {
        let cache = AsyncCache<Int, Int>()
        await #expect(throws: TestError.self) {
            try await cache.value(forKey: 1) { throw TestError() }
        }
        // A cached failure is not a value; peek must not surface it.
        #expect(await cache.peek(forKey: 1) == nil)
    }

    @Test
    func removeForcesRecompute() async throws {
        let cache = AsyncCache<Int, Int>()
        let invocations = SWBMutex(0)

        let first = try await cache.value(forKey: 1) {
            invocations.withLock { $0 += 1 }
            return 1
        }
        #expect(first == 1)

        await cache.remove(forKey: 1)

        let second = try await cache.value(forKey: 1) {
            invocations.withLock { $0 += 1 }
            return 2
        }
        #expect(second == 2)
        #expect(invocations.withLock { $0 } == 2)
    }

    @Test
    func removeAbsentKeyIsNoop() async {
        let cache = AsyncCache<Int, Int>()
        await cache.remove(forKey: 1)   // must not crash
        #expect(await cache.peek(forKey: 1) == nil)
    }

    /// Removing a key whose computation is still in flight must be ignored: evicting a `.requested`
    /// entry would strand its waiters and trip the invariant check when the computing task resumes.
    @Test
    func removeIsIgnoredWhileComputationIsInFlight() async throws {
        let cache = AsyncCache<Int, Int>()
        let bodyEntered = WaitCondition()
        let release = WaitCondition()
        let invocations = SWBMutex(0)

        async let computed: Int = cache.value(forKey: 1) {
            invocations.withLock { $0 += 1 }
            bodyEntered.signal()
            await release.wait()
            return 100
        }

        // Wait until the computation is registered and running.
        await bodyEntered.wait()

        // The entry is in flight: peek sees no value, and remove is a no-op.
        #expect(await cache.peek(forKey: 1) == nil)
        await cache.remove(forKey: 1)

        // Let the original computation finish; the waiter must still receive its result.
        release.signal()
        let value = try await computed
        #expect(value == 100)
        #expect(invocations.withLock { $0 } == 1)
        #expect(await cache.peek(forKey: 1) == 100)
    }
}
