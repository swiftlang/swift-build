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

import struct Foundation.Data

import Testing
import SWBTestSupport
import SWBUtil

@Suite(.performance)
fileprivate struct OutputByteStreamPerfTests: PerfTests {
    @Test
    func test1MBOf16ByteArrays_X100() async {
        let bytes16 = [UInt8](repeating: 0, count: 1 << 4)

        await measure {
            for _ in 0..<100 {
                let stream = OutputByteStream()
                for _ in 0..<(1 << 16) {
                    stream <<< bytes16
                }
                #expect(stream.bytes.count == 1 << 20)
            }
        }
    }

    @Test
    func test1MBOf1KByteArrays_X1000() async {
        let bytes1k = [UInt8](repeating: 0, count: 1 << 10)

        await measure {
            for _ in 0..<1000 {
                let stream = OutputByteStream()
                for _ in 0..<(1 << 10) {
                    stream <<< bytes1k
                }
                #expect(stream.bytes.count == 1 << 20)
            }
        }
    }

    @Test
    func test1MBOf1KByteData_X1000() async {
        let bytes1k = Data([UInt8](repeating: 0, count: 1 << 10))

        await measure {
            for _ in 0..<1000 {
                let stream = OutputByteStream()
                for _ in 0..<(1 << 10) {
                    stream <<< bytes1k
                }
                #expect(stream.bytes.count == 1 << 20)
            }
        }
    }

    @Test
    func test1MBOf16ByteStrings_X10() async {
        let string16 = String(repeating: "X", count: 1 << 4)

        await measure {
            for _ in 0..<10 {
                let stream = OutputByteStream()
                for _ in 0..<(1 << 16) {
                    stream <<< string16
                }
                #expect(stream.bytes.count == 1 << 20)
            }
        }
    }

    @Test
    func test1MBOf1KByteStrings_X100() async {
        let bytes1k = String(repeating: "X", count: 1 << 10)

        await measure {
            for _ in 0..<100 {
                let stream = OutputByteStream()
                for _ in 0..<(1 << 10) {
                    stream <<< bytes1k
                }
                #expect(stream.bytes.count == 1 << 20)
            }
        }
    }

    @Test
    func test1MBOfJSONEncoded16ByteStrings_X10() async {
        let string16 = String(repeating: "X", count: 1 << 4)

        await measure {
            for _ in 0..<10 {
                let stream = OutputByteStream()
                for _ in 0..<(1 << 16) {
                    stream.writeJSONEscaped(string16)
                }
                #expect(stream.bytes.count == 1 << 20)
            }
        }
    }

    @Test
    func formattedJSONOutput() async {
        struct Thing {
            var value: String
            init(_ value: String) { self.value = value }
        }
        let listOfStrings: [String] = (0..<10).map { "This is the number: \($0)!\n" }
        let listOfThings: [Thing] = listOfStrings.map(Thing.init)
        await measure {
            for _ in 0..<10 {
                let stream = OutputByteStream()
                for _ in 0..<(1 << 10) {
                    for string in listOfStrings {
                        stream <<< Format.asJSON(string)
                    }
                    stream <<< Format.asJSON(listOfStrings)
                    stream <<< Format.asJSON(listOfThings, transform: { $0.value })
                }
                #expect(stream.bytes.count > 1000)
            }
        }
    }
}
