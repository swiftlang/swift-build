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

    @Test
    func topologicalSort() throws {
        let linear: [Int: [Int]] = [
            1: [2],
            2: [3],
            3: []
        ]
        let linearResult = SWBUtilTests.topologicalSort([1, 2, 3], linear)
        #expect(linearResult == [1, 2, 3])

        let diamond: [Int: [Int]] = [
            1: [2, 3],
            2: [4],
            3: [4],
            4: []
        ]
        let diamondResult = SWBUtilTests.topologicalSort([1, 2, 3, 4], diamond)
        #expect(diamondResult.first == 1)
        #expect(diamondResult.last == 4)
        let diamondIndex1 = try #require(diamondResult.firstIndex(of: 1))
        let diamondIndex2 = try #require(diamondResult.firstIndex(of: 2))
        let diamondIndex3 = try #require(diamondResult.firstIndex(of: 3))
        let diamondIndex4 = try #require(diamondResult.firstIndex(of: 4))
        #expect(diamondIndex1 < diamondIndex2)
        #expect(diamondIndex1 < diamondIndex3)
        #expect(diamondIndex2 < diamondIndex4)
        #expect(diamondIndex3 < diamondIndex4)

        let empty: [Int: [Int]] = [:]
        #expect(SWBUtilTests.topologicalSort([], empty) == [])

        let single: [Int: [Int]] = [1: []]
        #expect(SWBUtilTests.topologicalSort([1], single) == [1])

        let independent: [Int: [Int]] = [
            1: [2],
            2: [],
            3: [4],
            4: []
        ]
        let indepResult = SWBUtilTests.topologicalSort([1, 2, 3, 4], independent)
        #expect(indepResult.count == 4)
        let indepIndex1 = try #require(indepResult.firstIndex(of: 1))
        let indepIndex2 = try #require(indepResult.firstIndex(of: 2))
        let indepIndex3 = try #require(indepResult.firstIndex(of: 3))
        let indepIndex4 = try #require(indepResult.firstIndex(of: 4))
        #expect(indepIndex1 < indepIndex2)
        #expect(indepIndex3 < indepIndex4)

        let complex: [Int: [Int]] = [
            1: [3],
            2: [3, 4],
            3: [5],
            4: [5],
            5: []
        ]
        let complexResult = SWBUtilTests.topologicalSort([1, 2, 3, 4, 5], complex)
        #expect(complexResult.last == 5)
        let complexIndex1 = try #require(complexResult.firstIndex(of: 1))
        let complexIndex2 = try #require(complexResult.firstIndex(of: 2))
        let complexIndex3 = try #require(complexResult.firstIndex(of: 3))
        let complexIndex4 = try #require(complexResult.firstIndex(of: 4))
        let complexIndex5 = try #require(complexResult.firstIndex(of: 5))
        #expect(complexIndex1 < complexIndex3)
        #expect(complexIndex2 < complexIndex3)
        #expect(complexIndex2 < complexIndex4)
        #expect(complexIndex3 < complexIndex5)
        #expect(complexIndex4 < complexIndex5)
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

private func topologicalSort<T: Hashable>(_ vertices: [T], _ graph: [T: [T]]) -> [T] {
    return topologicalSort(vertices, successors: { graph[$0] ?? [] })
}
