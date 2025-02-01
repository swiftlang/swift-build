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
fileprivate struct QueuePerfTests: PerfTests {
    @Test
    func interleavedPushPop10k_X10() async {
        let numIterations = 10

        // Test interleaved push/pop of 2*N elements.
        let N = 10000
        let halfN = N / 2
        #expect(halfN * 2 == N)

        await measure {
            for _ in 0 ..< numIterations {
                var q = Queue<Int>()

                for i in 0 ..< N {
                    q.append(i)
                    q.append(i)
                    if q.popFirst() != i / 2 { fatalError() }
                }
                for i in 0 ..< N {
                    if q.popFirst() != halfN + i / 2 { fatalError() }
                }
            }
        }
    }
}
