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

@Suite fileprivate struct MathTests {
    @Test
    func withoutLSB() {
        #expect(0.withoutLSB() == 0)
        #expect(1.withoutLSB() == 0)
        #expect(2.withoutLSB() == 0)
        #expect(3.withoutLSB() == 2)
        #expect(0xFF.withoutLSB() == 0xFE)
        #expect(0xF0.withoutLSB() == 0xE0)
    }

    @Test
    func isPowerOfTwo() {
        #expect(!0.isPowerOfTwo())
        #expect(1.isPowerOfTwo())
        #expect(2.isPowerOfTwo())
        #expect(!3.isPowerOfTwo())
    }

    @Test
    func nextPowerOfTwo() {
        #expect(0.nextPowerOfTwo() == 1)
        #expect(1.nextPowerOfTwo() == 2)
        #expect(2.nextPowerOfTwo() == 4)
        #expect(3.nextPowerOfTwo() == 4)
        #expect(4.nextPowerOfTwo() == 8)
        #expect(5.nextPowerOfTwo() == 8)
    }

    @Test
    func roundUpToPowerOfTwo() {
        #expect(0.roundUpToPowerOfTwo() == 1)
        #expect(1.roundUpToPowerOfTwo() == 1)
        #expect(2.roundUpToPowerOfTwo() == 2)
        #expect(3.roundUpToPowerOfTwo() == 4)
        #expect(4.roundUpToPowerOfTwo() == 4)
        #expect(5.roundUpToPowerOfTwo() == 8)
    }
}
