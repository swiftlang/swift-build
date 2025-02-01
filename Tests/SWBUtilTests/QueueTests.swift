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

@Suite fileprivate struct QueueTests {
    @Test
    func basics() {
        do {
            let q = Queue<Int>()
            #expect(q.isEmpty)
            #expect(q.count == 0)
        }

        do {
            var q = Queue<Int>()
            q.append(1)
            #expect(q.count == 1)
            #expect(q.popFirst() == 1)
            #expect(q.isEmpty)
        }

        do {
            var q = Queue<Int>()
            q.append(1)
            q.append(2)
            #expect(q.count == 2)
            #expect(q.popFirst() == 1)
            #expect(q.count == 1)
            #expect(q.popFirst() == 2)
            #expect(q.isEmpty)
        }

        do {
            var q = Queue<Int>()
            q.append(contentsOf: [1, 2])
            #expect(q.count == 2)
            #expect(q.popFirst() == 1)
            #expect(q.count == 1)
            #expect(q.popFirst() == 2)
            #expect(q.isEmpty)
        }

        // Check interleaved append/pop.
        do {
            var q = Queue<Int>()
            q.append(1)
            q.append(2)
            #expect(q.count == 2)
            #expect(q.popFirst() == 1)
            #expect(q.count == 1)
            q.append(3)
            #expect(q.count == 2)
            #expect(q.popFirst() == 2)
            #expect(q.count == 1)
            #expect(q.popFirst() == 3)
            #expect(q.count == 0)
            #expect(q.isEmpty)
        }

        // Test batch insertion (forcing growth).
        do {
            var q = Queue<Int>()
            let n = 1000
            for i in 0..<n {
                q.append(i)
            }
            #expect(q.count == n)
            for i in 0..<n {
                #expect(q.popFirst() == i)
            }
        }

        // Test interleaved batch insertion (forcing growth).
        do {
            var q = Queue<Int>()
            let n = 1000
            for i in 0..<n {
                q.append(i)
                q.append(i)
                #expect(q.popFirst() == i / 2)
            }
            #expect(q.count == n)
            for i in 0..<n {
                #expect(q.popFirst() == n / 2 + i / 2)
            }
            #expect(q.isEmpty)
        }
    }

    /// Check that the queue is a value type.
    @Test
    func valueness() {
        var q = Queue([1, 2])
        #expect(q.count == 2)
        var q2 = q
        #expect(q2.count == 2)
        #expect(q2.popFirst() == 1)
        #expect(q2.count == 1)
        #expect(q2.popFirst() == 2)
        #expect(q2.count == 0)
        #expect(q.count == 2)
        #expect(q.popFirst() == 1)
        #expect(q.popFirst() == 2)
        #expect(q.count == 0)
    }

    /// Check that the queue is a value type.
    @Test
    func expressibleByArrayLiteral() {
        var q: Queue<Int> = [1, 2]
        #expect(q.count == 2)
        #expect(q.popFirst() == 1)
        #expect(q.popFirst() == 2)
    }

    @Test
    func collectionConformance() {
        var q = Queue<Int>()

        // Empty
        #expect(Array(q) == [])

        // Incrementally adding items
        q.append(1)
        #expect(Array(q) == [1])
        q.append(2)
        #expect(Array(q) == [1, 2])

        // Subscript access
        #expect(q[0] == 1)
        #expect(q[1] == 2)

        // Traversing the queue does not consume it
        #expect(Array(q) == [1, 2])
        #expect(Array(q) == [1, 2])

        // Popping items (i.e. Queue.Iterator is not confused by head pointer changes)
        let _ = q.popFirst()
        #expect(Array(q) == [2])
        let _ = q.popFirst()
        #expect(Array(q) == [])

        // Match Array's behavior: for-in loops snapshot the queue so that mutations in the loop don't affect the loop's view of the queue
        q.append(1)
        q.append(2)
        var forLoopResults = Array<Int>()
        for x in q {
            forLoopResults.append(x)
            q.append(x)
        }

        #expect(forLoopResults == [1, 2])
        #expect(Array(q) == [1, 2, 1, 2])
    }

    /// Check that creating a `Queue` from an empty `Sequence` works.
    @Test
    func initFromEmptySequence() {
        var q: Queue<Int> = []

        #expect(q.count == 0)

        q.append(1)
        #expect(q.count == 1)
        #expect(q[0] == 1)
        q.append(2)
        #expect(q.count == 2)

        let _ = q.popFirst()
        #expect(q.count == 1)
        let _ = q.popFirst()
        #expect(q.count == 0)
    }
}
