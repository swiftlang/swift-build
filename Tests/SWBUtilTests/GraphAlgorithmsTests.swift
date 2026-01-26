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

@Suite fileprivate struct GraphAlgorithmsTests {
    @Test
    func minimumDistance() {
        #expect(SWBUtilTests.minimumDistance(from: 1, to: 2, in: [1: [2]]) == 1)

        // Check we find the minimum.
        #expect(SWBUtilTests.minimumDistance(from: 1, to: 5, in: [1: [2, 3], 2: [4], 3: [5], 4: [5]]) == 2)
        #expect(SWBUtilTests.minimumDistance(from: 1, to: 5, in: [1: [3, 2], 2: [4], 3: [5], 4: [5]]) == 2)

        // Check we handle missing.
        #expect(SWBUtilTests.minimumDistance(from: 1, to: 3, in: [1: [2]]) == nil)

        // Check we handle cycles.
        #expect(SWBUtilTests.minimumDistance(from: 1, to: 3, in: [1: [2], 2: [1]]) == nil)
    }

    @Test
    func shortestPath() {
        #expect(SWBUtilTests.shortestPath(from: 1, to: 2, in: [1: [2]])! == [1, 2])

        // Check we find the minimum.
        #expect(SWBUtilTests.shortestPath(from: 1, to: 5, in: [1: [2, 3], 2: [4], 3: [5], 4: [5]])! == [1, 3, 5])
        #expect(SWBUtilTests.shortestPath(from: 1, to: 5, in: [1: [3, 2], 2: [4], 3: [5], 4: [5]])! == [1, 3, 5])

        // Check we handle missing.
        #expect(SWBUtilTests.shortestPath(from: 1, to: 3, in: [1: [2]]) == nil)

        // Check we handle cycles.
        #expect(SWBUtilTests.shortestPath(from: 1, to: 3, in: [1: [2], 2: [1]]) == nil)
    }

    @Test
    func transitiveClosure() {
        #expect([2] == SWBUtilTests.transitiveClosure(1, [1: [2]]))
        #expect([] == SWBUtilTests.transitiveClosure(2, [1: [2]]))
        #expect([2] == SWBUtilTests.transitiveClosure([2, 1], [1: [2]]))

        // A diamond.
        let diamond: [Int: [Int]] = [
            1: [3, 2],
            2: [4],
            3: [4]
        ]
        #expect([2, 3, 4] == SWBUtilTests.transitiveClosure(1, diamond))
        #expect([4] == SWBUtilTests.transitiveClosure([3, 2], diamond))
        #expect([2, 3, 4] == SWBUtilTests.transitiveClosure([4, 3, 2, 1], diamond))

        // Test cycles.
        #expect([1] == SWBUtilTests.transitiveClosure(1, [1: [1]]))
        #expect([1, 2] == SWBUtilTests.transitiveClosure(1, [1: [2], 2: [1]]))
    }

    @Test
    func transitiveClosureDupes() {
        let diamond: [Int: [Int]] = [
            1: [3, 2],
            2: [4],
            3: [4]
        ]
        let dupes = SWBUtil.transitiveClosure([4, 3, 2, 1], successors: { diamond[$0] ?? [] }).1
        #expect([4] == dupes)
    }

}

private func minimumDistance<T>(
    from source: T, to destination: T, in graph: [T: [T]]
) -> Int? {
    return minimumDistance(from: source, to: destination, successors: { graph[$0] ?? [] })
}

private func shortestPath<T>(
    from source: T, to destination: T, in graph: [T: [T]]
) -> [T]? {
    return shortestPath(from: source, to: destination, successors: { graph[$0] ?? [] })
}

private func transitiveClosure(_ nodes: [Int], _ successors: [Int: [Int]]) -> [Int] {
    return transitiveClosure(nodes, successors: { successors[$0] ?? [] }).0.map{$0}.sorted()
}
private func transitiveClosure(_ node: Int, _ successors: [Int: [Int]]) -> [Int] {
    return transitiveClosure([node], successors)
}
