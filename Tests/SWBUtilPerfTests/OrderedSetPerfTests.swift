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
import SWBTestSupport
import SWBUtil

@Suite(.performance)
fileprivate struct OrderedSetPerfTests: PerfTests {
    @Test
    func appendTwice100k_X10() async {
        let numIterations = 10

        // Test insertion of 2*N elements, with N duplicates.
        let N = 100000
        let halfN = N / 2
        #expect(halfN * 2 == N)

        await measure {
            for _ in 0 ..< numIterations {
                // Test many inserts followed by many duplicates.
                var insertCount = 0
                do {
                    var set = OrderedSet<Int>()
                    for i in 0 ..< halfN {
                        if set.append(i).inserted {
                            insertCount += 1
                        }
                    }
                    for i in 0 ..< halfN {
                        if set.append(i).inserted {
                            insertCount += 1
                        }
                    }
                }
                // Test interleaved insert & duplicate.
                do {
                    var set = OrderedSet<Int>()
                    for i in 0 ..< halfN {
                        if set.append(i).inserted {
                            insertCount += 1
                        }
                        if set.append(i).inserted {
                            insertCount += 1
                        }
                    }
                }
                #expect(insertCount == N)
            }
        }
    }
}
