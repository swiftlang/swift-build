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
import Testing
@_spi(Testing) import SWBUtil
import Synchronization

@Suite
fileprivate struct HeavyCacheTests {
    /// Check basic cache operation.
    @Test
    func basics() async {
        await withHeavyCache { squares in
            // The number of concurrent iterations to dispatch.
            let iterations = 10000
            let numItems = 4

            // Check basic operation of the cache, really we just check it doesn't crash.
            let numInserts = SWBMutex(0)

            _ = await (0..<iterations).concurrentMap(maximumParallelism: 100) { i in
                let n = i % numItems

                let square = squares.getOrInsert(n) {
                    numInserts.withLock { $0 += 1 }
                    return n * n
                }
                #expect(square == n * n)

                let count = squares.count
                #expect(count > 0)
            }
            let finalNumInserts = numInserts.withLock { $0 }

            // We must have had at least <numItems> inserts.
            #expect(finalNumInserts >= numItems)
            // We should have at least hit the cache sometimes.
            #expect(finalNumInserts < iterations / 2)
            // The final cache should have the expected number of items.
            #expect(squares.count == numItems)
        }
    }

    /// Check the global clear operation.
    @Test
    func globalClear() async {
        await withHeavyCacheGlobalState {
            await withHeavyCache(isolatedGlobalState: false) { a in
                await withHeavyCache(isolatedGlobalState: false) { b in
                    _ = a.getOrInsert(1) { "a" }
                    _ = b.getOrInsert(1) { "a" }
                    #expect(a.count == 1)
                    #expect(b.count == 1)
                    clearAllHeavyCaches()
                    #expect(a.count == 0)
                    #expect(b.count == 0)
                }
            }
        }
    }

    /// Check the cache maximum size.
    @Test
    func maxSize() async {
        do {
            let max = 4
            await withHeavyCache(maximumSize: max) { cache in
                for i in 0 ..< 100 {
                    if i < 50 {
                        _ = cache.getOrInsert(i) { i }
                    } else {
                        cache[i] = i
                    }
                    #expect(cache.count <= max)
                }
                #expect(cache.count == max)
            }
        }

        // Check max set after the fact.
        do {
            await withHeavyCache { cache in
                for i in 0 ..< 100 {
                    if i < 50 {
                        _ = cache.getOrInsert(i) { i }
                    } else {
                        cache[i] = i
                    }
                }
                #expect(cache.count == 100)
                cache.maximumSize = 4
                #expect(cache.count == 4)
            }
        }
    }

    /// Check initial TTL.
    @Test
    func TTL_initial() async throws {
        let fudgeFactor = 10.0
        let ttl = Duration.seconds(0.01)
        try await withHeavyCache(timeToLive: ttl) { cache in
            for i in 0 ..< 100 {
                if i < 50 {
                    _ = cache.getOrInsert(i) { i }
                } else {
                    cache[i] = i
                }
            }
            try await Task.sleep(for: ttl * fudgeFactor)
            await cache.waitForExpiration()
            #expect(cache.count == 0, "Expected cache to be empty after \(ttl.formatted()) due to TTL expiration")
        }
    }

    /// Check TTL set after the fact.
    @Test
    func TTL_after() async throws {
        let fudgeFactor = 10.0
        let ttl = Duration.seconds(0.01)
        try await withHeavyCache { cache in
            for i in 0 ..< 100 {
                _ = cache.getOrInsert(i) { i }
            }
            #expect(cache.count == 100, "Expected cache to contain all 100 items that were inserted")
            cache.timeToLive = ttl
            try await Task.sleep(for: ttl * fudgeFactor)
            await cache.waitForExpiration()
            #expect(cache.count == 0, "Expected cache to be empty after \(ttl.formatted()) due to TTL expiration")
        }
    }

    /// Check that accesses also refresh the TTL.
    @Test
    func TTL_accessRefresh() async throws {
        let ttl = Duration.seconds(0.01)
        await withHeavyCache(timeToLive: ttl) { (cache: HeavyCache<Int, Int>) in
            let startTime = cache.setTime(instant: .now)

            cache[0] = 0
            #expect(cache[0] != nil && cache.count == 1, "Expected cache to still contain the one item that was just inserted")

            cache.preventExpiration {
                cache.setTime(instant: startTime.advanced(by: ttl * 10))

                _ = cache.getOrInsert(0) {
                    Issue.record("The value '0' was unexpectedly evicted from the cache.")
                    return 0
                }
            }

            // If the access time wasn't updated by the getOrInsert call, this will remove the item from the cache
            await cache.waitForExpiration()

            #expect(cache.count == 1, "Expected cache to still contain the one item that was just inserted because the previous access refreshed the TTL")
        }
    }

    /// Check that we honor LRU.
    @Test
    func LRU() async throws {
        try await withHeavyCache(maximumSize: 3) { cache in
            cache[0] = 0
            cache[1] = 1
            for i in 2 ..< 100 {
                try await Task.sleep(for: .microseconds(1))
                cache[i] = i
                _ = cache[0]
                _ = cache.getOrInsert(1) {
                    Issue.record("The value '1' was unexpectedly evicted from the cache.")
                    return 1
                }
            }
            #expect(cache[0] == 0)
            #expect(cache[1] == 1)
        }
    }
}

/// Provides a HeavyCache suitable for use in tests (eviction policy disabled to prevent memory pressure interference).
fileprivate func withHeavyCache<Key, Value>(isolatedGlobalState: Bool = true, maximumSize: Int? = nil, timeToLive: Duration? = nil, _ block: (HeavyCache<Key, Value>) async throws -> Void) async rethrows {
    try await withHeavyCacheGlobalState(isolated: isolatedGlobalState) {
        try await block(HeavyCache<Key, Value>(maximumSize: maximumSize, timeToLive: timeToLive, evictionPolicy: .never))
    }
}
