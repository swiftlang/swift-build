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

@Suite fileprivate struct ArrayTests {
    @Test
    func nWayMerge() {
        #expect(SWBUtil.nWayMerge([] as [[Int]]) == [])
        #expect(SWBUtil.nWayMerge([[1, 2]]) == [NWayMergeElement(element: 1, elementOf: [0]),
                                        NWayMergeElement(element: 2, elementOf: [0])])
        #expect(SWBUtil.nWayMerge([
            [1, 2, 3],
            [2, 3, 4],
            [3, 4, 5]
        ]) == [
            NWayMergeElement(element: 1, elementOf: [0]),
            NWayMergeElement(element: 2, elementOf: [0, 1]),
            NWayMergeElement(element: 3, elementOf: [0, 1, 2]),
            NWayMergeElement(element: 4, elementOf: [1, 2]),
            NWayMergeElement(element: 5, elementOf: [2])
        ])

        #expect(SWBUtil.nWayMerge([
            [1, 2],
            [3, 4],
            [5]
        ]) == [
            NWayMergeElement(element: 1, elementOf: [0]),
            NWayMergeElement(element: 5, elementOf: [2]),
            NWayMergeElement(element: 3, elementOf: [1]),
            NWayMergeElement(element: 2, elementOf: [0]),
            NWayMergeElement(element: 4, elementOf: [1])
        ])

        #expect(SWBUtil.nWayMerge([
            [1, 6, 3, 4],
            [2, 3, 4],
            [0, 3, 4, 5]
        ]) == [
            NWayMergeElement(element: 1, elementOf: [0]),
            NWayMergeElement(element: 0, elementOf: [2]),
            NWayMergeElement(element: 2, elementOf: [1]),
            NWayMergeElement(element: 6, elementOf: [0]),
            NWayMergeElement(element: 3, elementOf: [0, 1, 2]),
            NWayMergeElement(element: 4, elementOf: [0, 1, 2]),
            NWayMergeElement(element: 5, elementOf: [2]),
        ])

        #expect(SWBUtil.nWayMerge([
            [1, 0, 0, 1],
            [2, 0, 0, 1],
            [0, 0, 0, 2]
        ]) == [
            NWayMergeElement(element: 1, elementOf: [0]),
            NWayMergeElement(element: 2, elementOf: [1]),
            NWayMergeElement(element: 0, elementOf: [0, 1, 2]),
            NWayMergeElement(element: 0, elementOf: [0, 1, 2]),
            NWayMergeElement(element: 0, elementOf: [2]),
            NWayMergeElement(element: 2, elementOf: [2]),
            NWayMergeElement(element: 1, elementOf: [0, 1]),
        ])
    }

}

@Suite fileprivate struct NumericArrayTests {
    @Test
    func sum() {
        #expect(Array<Int>().sum() == 0)
        #expect([3].sum() == 3)

        #expect([4, 5, 6].sum() == 15)
        #expect([2, 4, 9].sum() == 15)

        // Doubles
        #expect(Array<Double>().sum() == 0.0)
        #expect([3.2].sum() as Double == 3.2)

        #expect([4.0, 5.0, 6.0].sum() as Double == 15.0)
        #expect([2.0, 4.0, 9.0].sum() as Double == 15.0)
    }

    @Test
    func average() {
        #expect([3.2].average() == 3.2)

        #expect([4.0, 5.0, 6.0].average() == 5.0)
        #expect([2.0, 4.0, 9.0].average() == 5.0)
    }

    @Test
    func standardDeviation() {
        #expect(Array<Double>().standardDeviation() == 0.0)
        #expect([3.2].standardDeviation() == 0.0)

        #expect([4.0, 5.0, 6.0].standardDeviation() == 1.0)
        // We compare against the variance (stddev-squared) because otherwise we end up with an awkward decimal which I don't trust to always be the same.
        #expect(pow([2.0, 4.0, 9.0].standardDeviation(), 2).rounded(.toNearestOrEven) == 13.0)
    }
}
