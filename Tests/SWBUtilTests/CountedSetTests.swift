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
import struct SWBUtil.CountedSet

@Suite fileprivate struct CountedSetTests {
    @Test
    func countedSetBasicFunctionality() {
        var cset = SWBUtil.CountedSet<String>()

        #expect(cset.isEmpty)
        #expect(cset.count == 0)
        #expect(cset.totalCount == 0)
        #expect(cset.countOf("apple") == 0)
        #expect(cset.countOf("pear") == 0)
        #expect(cset.countOf("orange") == 0)

        cset.insert("apple")

        #expect(!cset.isEmpty)
        #expect(cset.count == 1)
        #expect(cset.totalCount == 1)
        #expect(cset.countOf("apple") == 1)
        #expect(cset.countOf("pear") == 0)
        #expect(cset.countOf("orange") == 0)

        cset.insert("apple")

        #expect(!cset.isEmpty)
        #expect(cset.count == 1)
        #expect(cset.totalCount == 2)
        #expect(cset.countOf("apple") == 2)
        #expect(cset.countOf("pear") == 0)
        #expect(cset.countOf("orange") == 0)

        cset.insert("pear")

        #expect(!cset.isEmpty)
        #expect(cset.count == 2)
        #expect(cset.totalCount == 3)
        #expect(cset.countOf("apple") == 2)
        #expect(cset.countOf("pear") == 1)
        #expect(cset.countOf("orange") == 0)

        cset.remove("apple")

        #expect(!cset.isEmpty)
        #expect(cset.count == 2)
        #expect(cset.totalCount == 2)
        #expect(cset.countOf("apple") == 1)
        #expect(cset.countOf("pear") == 1)
        #expect(cset.countOf("orange") == 0)

        cset.remove("apple")

        #expect(!cset.isEmpty)
        #expect(cset.count == 1)
        #expect(cset.totalCount == 1)
        #expect(cset.countOf("apple") == 0)
        #expect(cset.countOf("pear") == 1)
        #expect(cset.countOf("orange") == 0)

        cset.remove("apple")

        #expect(!cset.isEmpty)
        #expect(cset.count == 1)
        #expect(cset.totalCount == 1)
        #expect(cset.countOf("apple") == 0)
        #expect(cset.countOf("pear") == 1)
        #expect(cset.countOf("orange") == 0)

        cset.remove("uglyfruit")

        #expect(!cset.isEmpty)
        #expect(cset.count == 1)
        #expect(cset.totalCount == 1)
        #expect(cset.countOf("apple") == 0)
        #expect(cset.countOf("pear") == 1)
        #expect(cset.countOf("orange") == 0)

        cset.remove("pear")

        #expect(cset.isEmpty)
        #expect(cset.count == 0)
        #expect(cset.totalCount == 0)
        #expect(cset.countOf("apple") == 0)
        #expect(cset.countOf("pear") == 0)
        #expect(cset.countOf("orange") == 0)
    }
}
