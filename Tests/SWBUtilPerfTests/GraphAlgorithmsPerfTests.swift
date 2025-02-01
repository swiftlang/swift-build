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

private struct Point: Hashable {
    let x: Int
    let y: Int

    init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}

@Suite(.performance)
fileprivate struct GraphAlgorithmsPerfTests: PerfTests {
    @Test
    func minimumDistanceIn10kNodeGrid_X10() async {
        let numIterations = 10

        // Create a DAG of a cartesian grid.
        var dependencies = [Point: [Point]]()
        func addDep(from point: Point, to dest: Point) {
            dependencies[point] = (dependencies[point] ?? []) + [dest]
        }
        let N = 100
        let width = N + 1
        let height = N + 1
        for y in 0 ..< height {
            for x in 0 ..< width {
                if x > 0 {
                    addDep(from: Point(x, y), to: Point(x - 1, y))
                }
                if y > 0 {
                    addDep(from: Point(x, y), to: Point(x, y - 1))
                }
            }
        }

        let immutableDependencies = dependencies

        @Sendable func minimumDistance(from origin: Point, to destination: Point) -> Int? {
            return SWBUtil.minimumDistance(from: origin, to: destination, successors: { immutableDependencies[$0] ?? [] })
        }

        await measure {
            var rowCount = 0
            var columnCount = 0
            var diagCount = 0
            for _ in 0 ..< numIterations {
                rowCount += minimumDistance(from: Point(width - 1, 0), to: Point(0, 0))!
                columnCount += minimumDistance(from: Point(0, height - 1), to: Point(0, 0))!
                diagCount += minimumDistance(from: Point(width - 1, height - 1), to: Point(0, 0))!
            }
            #expect(rowCount == numIterations * (width - 1))
            #expect(columnCount == numIterations * (height - 1))
            #expect(diagCount == numIterations * (width - 1 + height - 1))
        }
    }
}
