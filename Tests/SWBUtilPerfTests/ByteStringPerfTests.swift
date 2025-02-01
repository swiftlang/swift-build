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
fileprivate struct ByteStringPerfTests: PerfTests {
    @Test
    func initialization() async {
        let listOfStrings: [String] = (0..<10).map { "This is the number: \($0)!\n" }
        let expectedTotalCount = listOfStrings.map({ $0.utf8.count }).reduce(0, { $0 + $1 })
        await measure {
            var count = 0
            let N = 10000
            for _ in 0..<N {
                for string in listOfStrings {
                    let bs = ByteString(encodingAsUTF8: string)
                    count += bs.count
                }
            }
            #expect(count == expectedTotalCount * N)
        }
    }
}
