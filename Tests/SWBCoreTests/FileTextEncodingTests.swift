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
import SWBCore
import SWBProtocol
import SWBUtil
import SWBTestSupport

@Suite fileprivate struct FileTextEncodingTests {
    @Test
    func equivalence() {
        #expect(FileTextEncoding.utf8.rawValue == "utf-8")
        #expect(FileTextEncoding.utf8.description == "utf-8")
        #expect(FileTextEncoding("utf-8") == FileTextEncoding.utf8)
        #expect(FileTextEncoding("utf8") != FileTextEncoding.utf8)
    }

    @Test(.skipHostOS(.windows, "feature not available on Windows due to missing CF APIs"),
          .skipHostOS(.linux, "feature not available on Linux due to missing CF APIs"))
    func encoding() throws {
        #expect(FileTextEncoding.utf8.stringEncoding == String.Encoding.utf8)
        #expect(FileTextEncoding.utf16.stringEncoding == String.Encoding.utf16)
        #expect(FileTextEncoding.utf16be.stringEncoding == String.Encoding.utf16BigEndian)
        #expect(FileTextEncoding.utf16le.stringEncoding == String.Encoding.utf16LittleEndian)
        #expect(FileTextEncoding.utf32.stringEncoding == String.Encoding.utf32)
        #expect(FileTextEncoding.utf32be.stringEncoding == String.Encoding.utf32BigEndian)
        #expect(FileTextEncoding.utf32le.stringEncoding == String.Encoding.utf32LittleEndian)
        #expect(FileTextEncoding("utf-64").stringEncoding == nil)
    }

    @Test(.requireHostOS(.macOS)) // crashes on Linux
    func decoding() throws {
        #expect(FileTextEncoding(stringEncoding: String.Encoding.utf8) == FileTextEncoding.utf8)
        #expect(FileTextEncoding(stringEncoding: String.Encoding.utf16) == FileTextEncoding.utf16)
        #expect(FileTextEncoding(stringEncoding: String.Encoding.utf16BigEndian) == FileTextEncoding.utf16be)
        #expect(FileTextEncoding(stringEncoding: String.Encoding.utf16LittleEndian) == FileTextEncoding.utf16le)
        #expect(FileTextEncoding(stringEncoding: String.Encoding.utf32) == FileTextEncoding.utf32)
        #expect(FileTextEncoding(stringEncoding: String.Encoding.utf32BigEndian) == FileTextEncoding.utf32be)
        #expect(FileTextEncoding(stringEncoding: String.Encoding.utf32LittleEndian) == FileTextEncoding.utf32le)
        #expect(FileTextEncoding(stringEncoding: String.Encoding.init(rawValue: 0)) == nil)
    }

    @Test
    func BOMBytes() {
        #expect(FileTextEncoding.utf8.byteOrderMark == [0xEF, 0xBB, 0xBF])
        #expect(FileTextEncoding.utf16.byteOrderMark == [])
        #expect(FileTextEncoding.utf16be.byteOrderMark == [0xFE, 0xFF])
        #expect(FileTextEncoding.utf16le.byteOrderMark == [0xFF, 0xFE])
        #expect(FileTextEncoding.utf32.byteOrderMark == [])
        #expect(FileTextEncoding.utf32be.byteOrderMark == [0x00, 0x00, 0xFE, 0xFF])
        #expect(FileTextEncoding.utf32le.byteOrderMark == [0xFF, 0xFE, 0x00, 0x00])
        #expect(FileTextEncoding("not-a-utf").byteOrderMark == [])
    }

    // This test case is mostly for illustration to help rationalize how Foundation
    // handles BOM and ensure our understanding of copystrings' behavior is correct.
    @Test
    func encodings() throws {
        let bom_utf8 = [UInt8]([0xEF, 0xBB, 0xBF])
        let bom_utf16be = [UInt8]([0xFE, 0xFF])
        let bom_utf16le = [UInt8]([0xFF, 0xFE])
        let bom_utf32be = [UInt8]([0x00, 0x00, 0xFE, 0xFF])
        let bom_utf32le = [UInt8]([0xFF, 0xFE, 0x00, 0x00])

        /*
         Illustration for how to get host ordered UTF information.

         let bom_utf16_host: [UInt8] = {
         switch __CFByteOrder(UInt32(CFByteOrderGetCurrent())) {
         case CFByteOrderBigEndian:
         return bom_utf16be
         case CFByteOrderLittleEndian:
         return bom_utf16le
         default:
         return []
         }
         }()

         let bom_utf32_host: [UInt8] = {
         switch __CFByteOrder(UInt32(CFByteOrderGetCurrent())) {
         case CFByteOrderBigEndian:
         return bom_utf32be
         case CFByteOrderLittleEndian:
         return bom_utf32le
         default:
         return []
         }
         }()
         */

        func XCTAssertDecode(_ lhs: @autoclosure () throws -> (string: String, originalEncoding: FileTextEncoding)?, _ rhs: @autoclosure () throws -> (string: String, originalEncoding: FileTextEncoding)?, sourceLocation: SourceLocation = #_sourceLocation) throws {
            try #require(try lhs()?.string == rhs()?.string, sourceLocation: sourceLocation)
            try #require(try lhs()?.originalEncoding == rhs()?.originalEncoding, sourceLocation: sourceLocation)
        }

        do {
            let utf8: [UInt8] = [0x41]
            let utf8_bom = bom_utf8 + [0x41]

            let utf16be: [UInt8] = [0x00, 0x41]
            let utf16be_bom = bom_utf16be + utf16be

            let utf16le: [UInt8] = [0x41, 0x00]
            let utf16le_bom = bom_utf16le + utf16le

            let utf32be: [UInt8] = [0x00, 0x00, 0x00, 0x41]
            let utf32be_bom = bom_utf32be + utf32be

            let utf32le: [UInt8] = [0x41, 0x00, 0x00, 0x00]
            let utf32le_bom = bom_utf32le + utf32le

            // "There is no "UTF-8 with BOM" encoding, and since the UTF-8 encoding means "no BOM" during encoding,
            // it should mean the same when decoding to prevent data loss, just like the rest of the UTF-16 and UTF-32 encoder behaviors.
            try XCTAssertDecode(FileTextEncoding.string(from: utf8_bom, encoding: .utf8), ("\u{FEFF}A", FileTextEncoding.utf8))

            try XCTAssertDecode(FileTextEncoding.string(from: utf8, encoding: .utf8), ("A", FileTextEncoding.utf8))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16be, encoding: .utf16be), ("A", FileTextEncoding.utf16be))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16be_bom, encoding: .utf16), ("A", FileTextEncoding.utf16))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16le, encoding: .utf16le), ("A", FileTextEncoding.utf16le))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16le_bom, encoding: .utf16), ("A", FileTextEncoding.utf16))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32be, encoding: .utf32be), ("A", FileTextEncoding.utf32be))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32be_bom, encoding: .utf32), ("A", FileTextEncoding.utf32))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32le, encoding: .utf32le), ("A", FileTextEncoding.utf32le))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32le_bom, encoding: .utf32), ("A", FileTextEncoding.utf32))
        }

        do {
            let utf8: [UInt8] = [0xEF, 0xBB, 0xBF]
            let utf8_bom = bom_utf8 + [0xEF, 0xBB, 0xBF]

            let utf16be: [UInt8] = [0xFE, 0xFF]
            let utf16be_bom = bom_utf16be + utf16be

            let utf16le: [UInt8] = [0xFF, 0xFE]
            let utf16le_bom = bom_utf16le + utf16le

            let utf32be: [UInt8] = [0x00, 0x00, 0xFE, 0xFF]
            let utf32be_bom = bom_utf32be + utf32be

            let utf32le: [UInt8] = [0xFF, 0xFE, 0x00, 0x00]
            let utf32le_bom = bom_utf32le + utf32le

            try XCTAssertDecode(FileTextEncoding.string(from: utf8, encoding: .utf8), ("\u{FEFF}", FileTextEncoding.utf8))
            try XCTAssertDecode(FileTextEncoding.string(from: utf8_bom, encoding: .utf8), ("\u{FEFF}\u{FEFF}", FileTextEncoding.utf8))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16be, encoding: .utf16be), ("\u{FEFF}", FileTextEncoding.utf16be))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16be_bom, encoding: .utf16), ("\u{FEFF}", FileTextEncoding.utf16))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16le, encoding: .utf16le), ("\u{FEFF}", FileTextEncoding.utf16le))
            try XCTAssertDecode(FileTextEncoding.string(from: utf16le_bom, encoding: .utf16), ("\u{FEFF}", FileTextEncoding.utf16))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32be, encoding: .utf32be), ("\u{FEFF}", FileTextEncoding.utf32be))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32be_bom, encoding: .utf32), ("\u{FEFF}", FileTextEncoding.utf32))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32le, encoding: .utf32le), ("\u{FEFF}", FileTextEncoding.utf32le))
            try XCTAssertDecode(FileTextEncoding.string(from: utf32le_bom, encoding: .utf32), ("\u{FEFF}", FileTextEncoding.utf32))
        }

        try XCTAssertDecode(FileTextEncoding.string(from: [0xc3, 0x28], encoding: .utf8), nil)
    }
}
