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
import SWBTestSupport

@Suite fileprivate struct HashContextTests {
    @Test
    func basics() {
        let first = InsecureHashContext()
        first.add(string: "first")
        let firstSignature = first.signature
        #expect(!firstSignature.isEmpty)

        let second = InsecureHashContext()
        second.add(string: "first")
        second.add(string: "second")
        let secondSignature = second.signature
        #expect(!secondSignature.isEmpty)
        #expect(firstSignature != secondSignature)

        let third = InsecureHashContext()
        third.add(bytes: ByteString("first"))
        third.add(bytes: ByteString("second"))
        let thirdSignature = third.signature
        #expect(!thirdSignature.isEmpty)
        #expect(secondSignature == thirdSignature)
        #expect(thirdSignature == third.signature)
    }

    /// Check against a known hash value.
    @Test(.requireHostOS(.macOS, .windows))
    func value() {
        #expect(InsecureHashContext().signature == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test
    func variations() {
        let first = InsecureHashContext()
        first.add(string: "first")
        let second = InsecureHashContext()
        second.add(bytes: ByteString(encodingAsUTF8: "first"))
        #expect(first.signature == second.signature)
    }

    @Test(.requireHostOS(.macOS, .windows))
    func numbers() {
        do {
            let ctx = InsecureHashContext()
            ctx.add(number: 0x01 as UInt8)
            #expect(ctx.signature == "55a54008ad1ba589aa210d2629c1df41")
        }
        do {
            let ctx = InsecureHashContext()
            ctx.add(number: 0x0102 as UInt16)
            #expect(ctx.signature == "050d144172d916d0846f839e0412e929")
        }
        do {
            let ctx = InsecureHashContext()
            ctx.add(number: 0x01020304 as UInt32)
            #expect(ctx.signature == "c73cabeb6558aba030bba9ca49dcdd75")
        }
        do {
            let ctx = InsecureHashContext()
            ctx.add(number: 0x0102030405060708 as UInt64)
            #expect(ctx.signature == "8a7334bacf760ff26b99fad472ded851")
        }
    }
}
