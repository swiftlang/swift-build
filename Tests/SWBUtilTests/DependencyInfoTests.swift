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
@_spi(Testing) import SWBUtil
import Testing

@Suite fileprivate struct DependencyInfoTests {
    @Test
    func roundTrip() throws {
        let depInfo = DependencyInfo(version: "foo", inputs: ["/bar", "/bazz"], missing: [], outputs: ["/cool-output"])
        let bytes = try depInfo.asBytes()
        #expect(bytes == [0x00, 102, 111, 111, 0,
                          0x10, 47, 98, 97, 114, 0,
                          0x10, 47, 98, 97, 122, 122, 0,
                          0x40, 47, 99, 111, 111, 108, 45, 111, 117, 116, 112, 117, 116, 0])
        #expect(try depInfo == DependencyInfo(bytes: bytes))
    }

    @Test
    func encoding() throws {
        let depInfo1 = DependencyInfo(version: "foo", inputs: ["/bar"])
        #expect(try depInfo1.asBytes() == [0x00, 102, 111, 111, 0,
                                           0x10, 47, 98, 97, 114, 0])
        let depInfo2 = DependencyInfo(version: "foo", missing: ["/bar", "/bar"])
        #expect(try depInfo2.asBytes() == [0x00, 102, 111, 111, 0,
                                           0x11, 47, 98, 97, 114, 0,
                                           0x11, 47, 98, 97, 114, 0])
        let depInfo3 = DependencyInfo(version: "foo", outputs: ["/bar"])
        #expect(try depInfo3.asBytes() == [0x00, 102, 111, 111, 0,
                                           0x40, 47, 98, 97, 114, 0])
    }

    @Test
    func encodingErrors() throws {
        #expect {
            try DependencyInfo(version: "").asBytes()
        } throws: { error in
            (error as? DependencyInfoEncodingError)?.description == DependencyInfoEncodingError.emptyString.description
        }

        #expect {
            try DependencyInfo(version: "d", inputs: ["a", "", "c"]).asBytes()
        } throws: { error in
            (error as? DependencyInfoEncodingError)?.description == DependencyInfoEncodingError.emptyString.description
        }

        #expect {
            try DependencyInfo(version: "a\0b").asBytes()
        } throws: { error in
            (error as? DependencyInfoEncodingError)?.description == DependencyInfoEncodingError.embeddedNullInString(string: "a\0b").description
        }

        #expect {
            try DependencyInfo(version: "ab", missing: ["hey", "evil\0string", "haha"]).asBytes()
        } throws: { error in
            (error as? DependencyInfoEncodingError)?.description == DependencyInfoEncodingError.embeddedNullInString(string: "evil\0string").description
        }
    }

    @Test
    func decoding() throws {
        #expect(try DependencyInfo(bytes: [0x00, 102, 111, 111, 0,
                                           0x10, 47, 98, 97, 114, 0,
                                           0x10, 47, 98, 97, 115, 0]) == DependencyInfo(version: "foo", inputs: ["/bar", "/bas"]))

        #expect(try DependencyInfo(bytes: [0x00, 102, 111, 111, 0,
                                           0x11, 47, 98, 97, 114, 0]) == DependencyInfo(version: "foo", missing: ["/bar"]))

        #expect(try DependencyInfo(bytes: [0x00, 102, 111, 111, 0,
                                           0x40, 47, 98, 97, 114, 0,
                                           0x40, 47, 98, 97, 113, 0]) == DependencyInfo(version: "foo", outputs: ["/bar", "/baq"]))
    }

    @Test
    func decodingErrors() throws {
        #expect {
            try DependencyInfo(bytes: [])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.unexpectedEOF.description
        }

        #expect {
            try DependencyInfo(bytes: [0xFF])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.unknownOpcode(opcode: 0xFF).description
        }

        #expect {
            try DependencyInfo(bytes: [DependencyInfo.Opcode.input.rawValue, 0x00])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.invalidOperand(bytes: nil).description
        }

        #expect {
            try DependencyInfo(bytes: [DependencyInfo.Opcode.input.rawValue, 0x00, 0x00])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.invalidOperand(bytes: nil).description
        }

        #expect {
            try DependencyInfo(bytes: [DependencyInfo.Opcode.input.rawValue])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.unexpectedEOF.description
        }

        #expect {
            try DependencyInfo(bytes: [DependencyInfo.Opcode.input.rawValue, 0xc3, 0x28, 0x00])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.invalidOperand(bytes: [0xc3, 0x28]).description
        }

        // version should appear first
        #expect {
            try DependencyInfo(bytes: [DependencyInfo.Opcode.input.rawValue, UInt8(ascii: "A"), 0x00])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.missingVersion.description
        }

        #expect {
            try DependencyInfo(bytes: [DependencyInfo.Opcode.version.rawValue, UInt8(ascii: "A"), 0x00, DependencyInfo.Opcode.version.rawValue, UInt8(ascii: "A"), 0x00])
        } throws: { error in
            (error as? DependencyInfoDecodingError)?.description == DependencyInfoDecodingError.duplicateVersion.description
        }
    }

    @Test
    func normalization() {
        #expect(DependencyInfo(version: "test", inputs: ["a", "c", "a"], missing: ["b", "d", "b", "b", "b"], outputs: ["z", "l", "l", "l"]).normalized() == DependencyInfo(version: "test", inputs: ["a", "c"], missing: ["b", "d"], outputs: ["l", "z"]))

        #expect(DependencyInfo(version: "test", inputs: ["test"], missing: ["something"], outputs: ["else", "is", "here"]).normalized() == DependencyInfo(version: "test", inputs: ["test"], missing: ["something"], outputs: ["else", "here", "is"]))
    }
}
