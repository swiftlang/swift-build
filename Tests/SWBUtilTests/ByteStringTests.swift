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

// Allow simple conversion from String, in the tests module.
extension ByteString {
    init(_ string: String) {
        self.init(encodingAsUTF8: string)
    }
}

@Suite fileprivate struct ByteStringTests {
    @Test
    func initializers() {
        do {
            let data: ByteString = [1]
            #expect(data.bytes == [1])
        }

        #expect(ByteString([1]).bytes == [1])

        #expect(ByteString("A").bytes == [65])

        // Test StringLiteralConvertible initialization.
        #expect(ByteString([65]) == "A")
    }

    @Test
    func accessors() {
        #expect(ByteString([]).count == 0)
        #expect(ByteString([]).isEmpty)
        #expect(ByteString([1, 2]).count == 2)
        #expect(!ByteString([1, 2]).isEmpty)
    }

    @Test
    func asString() {
        #expect(ByteString("hello").stringValue == "hello")
        #expect(ByteString([0xFF,0xFF]).unsafeStringValue == "\u{FFFD}\u{FFFD}")
        #expect(ByteString([0xFF,0xFF]).stringValue == nil)
    }

    @Test
    func description() {
        #expect(ByteString("Hello, world!").description == "<ByteString:\"Hello, world!\">")
    }

    @Test
    func hashable() {
        var s = Set([ByteString([1]), ByteString([2])])
        #expect(s.contains(ByteString([1])))
        #expect(s.contains(ByteString([2])))
        #expect(!s.contains(ByteString([3])))

        // Insert a long string which tests overflow in the hash function.
        let long = ByteString([UInt8](0 ..< 100))
        #expect(!s.contains(long))
        s.insert(long)
        #expect(s.contains(long))
    }

    @Test
    func stringComparable() {
        #expect(ByteString("hello") == "hello")
    }

    @Test
    func byteStreamable() {
        let s = OutputByteStream()
        s <<< ByteString([1, 2, 3])
        #expect(s.bytes == [1, 2, 3])
    }

    @Test
    func hasPrefix() {
        let s = ByteString("foobar")
        #expect(s.hasPrefix("foo"))
        #expect(!s.hasPrefix("bar"))
        #expect(s.hasPrefix("foobar"))
        #expect(!s.hasPrefix("foobars"))
        #expect(s.hasPrefix("")) // same behavior as String.hasPrefix
        #expect(!s.hasPrefix("what"))

        let string: String = "foobar"
        #expect(string.hasPrefix(""))
    }

    @Test
    func hasSuffix() {
        let s = ByteString("foobar")
        #expect(s.hasSuffix("bar"))
        #expect(!s.hasSuffix("foo"))
        #expect(s.hasSuffix("foobar"))
        #expect(!s.hasSuffix("afoobar"))
        #expect(s.hasSuffix("")) // same behavior as String.hasSuffix
        #expect(!s.hasSuffix("what"))

        let string: String = "foobar"
        #expect(string.hasSuffix(""))
    }
}
