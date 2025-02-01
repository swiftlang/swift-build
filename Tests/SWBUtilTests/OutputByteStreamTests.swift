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

@Suite fileprivate struct OutputByteStreamTests {
    @Test
    func basics() {
        let stream = OutputByteStream()

        stream.write("Hello")
        stream.write(Character(","))
        stream.write(Character(" "))
        stream.write([UInt8]("wor".utf8))
        stream.write([UInt8]("world".utf8)[3..<5])

        let streamable: any TextOutputStreamable = Character("!")
        stream.write(streamable)

        stream.flush()

        #expect(stream.position == "Hello, world!".utf8.count)
        #expect(stream.bytes == "Hello, world!")
    }

    @Test
    func streamOperator() {
        let stream = OutputByteStream()

        let streamable: any TextOutputStreamable = Character("!")
        stream <<< "Hello" <<< Character(",") <<< Character(" ") <<< [UInt8]("wor".utf8) <<< [UInt8]("world".utf8)[3..<5] <<< streamable

        #expect(stream.position == "Hello, world!".utf8.count)
        #expect(stream.bytes == "Hello, world!")

        let stream2 = OutputByteStream()
        stream2 <<< (0..<5)
        #expect(stream2.bytes == [0, 1, 2, 3, 4])
    }

    @Test
    func jSONEncoding() {
        func asJSON(_ value: String) -> ByteString {
            let stream = OutputByteStream()
            stream.writeJSONEscaped(value)
            return stream.bytes
        }
        #expect(asJSON("a'\"\\") == "a'\\\"\\\\")
        #expect(asJSON("\u{0008}") == "\\b")
        #expect(asJSON("\u{000C}") == "\\f")
        #expect(asJSON("\n") == "\\n")
        #expect(asJSON("\r") == "\\r")
        #expect(asJSON("\t") == "\\t")
        #expect(asJSON("\u{0001}") == "\\u0001")
    }

    @Test
    func formattedOutput() {
        do {
            let stream = OutputByteStream()
            stream <<< Format.asJSON("\n")
            #expect(stream.bytes == "\"\\n\"")
        }

        do {
            let stream = OutputByteStream()
            stream <<< Format.asJSON(["hello", "world\n"])
            #expect(stream.bytes == "[\"hello\",\"world\\n\"]")
        }

        do {
            let stream = OutputByteStream()
            stream <<< Format.asJSON([ByteString(encodingAsUTF8: "hello"), ByteString(encodingAsUTF8: "world\n")])
            #expect(stream.bytes == "[\"hello\",\"world\\n\"]")
        }

        do {
            let stream = OutputByteStream()
            stream <<< Format.asJSON(["hello": "world\n"].sorted(byKey: <))
            #expect(stream.bytes == "{\"hello\":\"world\\n\"}")
        }

        do {
            struct MyThing {
                let value: String
                init(_ value: String) { self.value = value }
            }
            let stream = OutputByteStream()
            stream <<< Format.asJSON([MyThing("hello"), MyThing("world\n")], transform: { $0.value })
            #expect(stream.bytes == "[\"hello\",\"world\\n\"]")
        }

        do {
            let stream = OutputByteStream()
            stream <<< Format.asSeparatedList(["hello", "world"], separator: ", ")
            #expect(stream.bytes == "hello, world")
        }

        do {
            let stream = OutputByteStream()
            stream <<< Format.asSeparatedList([ByteString(encodingAsUTF8: "hello"), ByteString(encodingAsUTF8: "world")], separator: ", ")
            #expect(stream.bytes == "hello, world")
        }

        do {
            struct MyThing {
                let value: String
                init(_ value: String) { self.value = value }
            }
            let stream = OutputByteStream()
            stream <<< Format.asSeparatedList([MyThing("hello"), MyThing("world")], transform: { $0.value }, separator: ", ")
            #expect(stream.bytes == "hello, world")
        }
    }
}
