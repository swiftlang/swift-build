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

@Suite fileprivate struct StatisticsTests {
    /// Statistic instances are designed to be statically initialized on demand from arbitrary threads
    @Test
    func threadSafety() async {
        let statGroup = StatisticsGroup("Test")

        let count = 100
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let _ = Statistic("s\(i)", "test", statGroup)
                }
            }
            await group.waitForAll()
        }

        #expect(count == statGroup.statistics.count)
    }
}
