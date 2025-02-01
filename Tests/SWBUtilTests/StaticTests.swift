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
public import SWBUtil

extension Int: StaticStorable {
    public static var staticStorageTable = Dictionary<StaticStorageKey, Int>()
}

@Suite fileprivate struct StaticTests {
    @Test
    func basic() {
        let numConstructCalls = LockedValue(0)

        func foo() -> Int {
            return Static {
                numConstructCalls.withLock { $0 += 1 }
                return 3
            }
        }

        #expect(numConstructCalls.withLock { $0 } == 0)
        #expect(foo() == 3)
        #expect(numConstructCalls.withLock { $0 } == 1)
        #expect(foo() == 3)
        #expect(numConstructCalls.withLock { $0 } == 1)
    }
}
