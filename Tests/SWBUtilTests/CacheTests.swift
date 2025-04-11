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
import SWBUtil
import Synchronization

@Suite fileprivate struct CacheTests {
    @Test
    func basics() async {
        let squares = SWBUtil.Cache<Int, Int>()
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
        }

        let finalNumInserts = numInserts.withLock { $0 }

        // We must have had at least <numItems> inserts.
        #expect(finalNumInserts >= numItems)
        // We should have at least hit the cache sometimes.
        #expect(finalNumInserts < iterations / 2)
    }
}
