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

import Testing
import SWBUtil

@Suite
private struct ScopedKeepAliveCacheTests {
    @Test
    func scopedKeepAliveCacheCache() throws {
        // Manually evicting base cache
        let base = Registry<Int, Int>()
        let cache = ScopedKeepAliveCache(base)

        // Empty state, insert 1st cache entry
        #expect(1 == cache.getOrInsert(1) { 1 })

        // Since base hasn't evicted yet, we should be able to retrieve an entry without re-inserting it
        #expect(1 == cache.getOrInsert(1) { 0 })

        // If base evicts, expect to insert again, we aren't preventing eviction yet
        base.removeAll()
        #expect(11 == cache.getOrInsert(1) { 11 })

        // Add another entry
        #expect(2 == cache.getOrInsert(2) { 2 })

        // During this block, pre-existing values can be evicted, but values inserted or retrieved within the block cannot
        cache.keepAlive {
            // Retrieve the existing 2nd entry to protect it from eviction
            #expect(2 == cache.getOrInsert(2) { 0 })

            // `keepAlive` should allow for recursion
            cache.keepAlive {
                // Insert a brand new 3rd entry
                #expect(3 == cache.getOrInsert(3) { 3 })
            }

            // Evict from base
            base.removeAll()

            // We expect that 2 and 3 are still available but 1 was evicted
            #expect(111 == cache.getOrInsert(1) { 111 })
            #expect(2 == cache.getOrInsert(2) { 0 })
            #expect(3 == cache.getOrInsert(3) { 0 })

            // Let base evict again
            base.removeAll()
        }

        // After the block, we expect values protected during the block to be evicted if they're also evicted from base, so they should all get inserted again. Clients shouldn't depend on this behavior if there may be concurrent invocations of `keepAlive` which keep values alive past any one specific `keepAlive`.
        #expect(1111 == cache.getOrInsert(1) { 1111 })
        #expect(2222 == cache.getOrInsert(2) { 2222 })
        #expect(3333 == cache.getOrInsert(3) { 3333 })
    }

    @Test
    func scopedKeepAliveCacheConcurrent() async {
        // Manually evicting base cache
        let base = Registry<Int, Int>()
        let cache = ScopedKeepAliveCache(base)
        let iterations = 10000

        func exercise(key: Int) async {
            for _ in 0..<iterations {
                let value = key
                cache.keepAlive {
                    #expect(value == cache.getOrInsert(key) { value })
                    base.removeAll()
                    #expect(value == cache.getOrInsert(key) { 0 })
                }

                // With concurrent `keepAlive` invocations, we can't guarantee whether `key` is evicted or not here, there may be other in-flight `keepAlive` keeping it alive
            }
        }

        let keys = 0..<3
        await withTaskGroup(of: Void.self) { taskGroup in
            for key in keys {
                taskGroup.addTask { await exercise(key: key) }
            }
            await taskGroup.waitForAll()
        }

        // After the last `keepAlive` and eviction from base, none of the keys should be present
        base.removeAll()
        for key in keys {
            #expect(0 == cache.getOrInsert(key) { 0 })
        }
    }
}
