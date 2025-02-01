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

@Suite fileprivate struct StringTests {
    @Test
    func arrayOfUInt8Init() {
        #expect([UInt8]("foo".utf8).asReadableString() == "foo")
        #expect([UInt8]("foo\u{00}".utf8).asReadableString() == "foo\0")
        #expect([UInt8]([128, 255]).asReadableString() == "[128, 255]")

        #expect([UInt8]("foo".utf8) == "foo")
        #expect(!([UInt8]("fooa".utf8) == "foo"))
        #expect(!([UInt8]("foo".utf8) == "fooa"))
        #expect(!([UInt8]("foo".utf8) == "boo"))
        #expect([UInt8]("foo\u{00}".utf8) == "foo\0")
        #expect(!([UInt8]([128, 255]) == "[128, 255]"))
        #expect(!([UInt8]([128, 255]) == ""))
        #expect(!([UInt8]([128, 255]) == "  "))
        #expect(!([UInt8]([128, 255]) == "   "))
    }

    @Test
    func arraySliceOfUInt8Init() {
        do {
            let array = [UInt8]("ABCDEFGH".utf8)
            let slice = array[1...6]
            #expect(array.asReadableString() == "ABCDEFGH")
            #expect(slice.asReadableString() == "BCDEFG")
        }

        do {
            let array = [UInt8]([0xc3, 0x28]) // invalid UTF-8
            let slice = array[...]
            #expect(array.asReadableString() == "[195, 40]")
            #expect(slice.asReadableString() == "[195, 40]")
        }
    }

    @Test
    func withIndefiniteArticle() {
        #expect("".withIndefiniteArticle == "")
        #expect("Awesome".withIndefiniteArticle.lowercased() == "an awesome")
        #expect("elephant".withIndefiniteArticle == "an elephant")
        #expect("Image".withIndefiniteArticle.lowercased() == "an image")
        #expect("overlord".withIndefiniteArticle == "an overlord")
        #expect("Ultimate".withIndefiniteArticle.lowercased() == "an ultimate")

        #expect("feather".withIndefiniteArticle == "a feather")
        #expect("Yogurt".withIndefiniteArticle.lowercased() == "a yogurt")

        #expect("0-day".withIndefiniteArticle == "a 0-day")
    }

    @Test
    func stringSplit() {
        #expect("lhs".split(".") == ("lhs", ""))
        #expect("lhs.".split(".") == ("lhs", ""))
        #expect("lhs.rhs".split(".") == ("lhs", "rhs"))
    }

    @Test
    func substringSplit() {
        #expect("lhs"[...].split(".") == ("lhs", ""))
        #expect("lhs."[...].split(".") == ("lhs", ""))
        #expect("lhs.rhs"[...].split(".") == ("lhs", "rhs"))
    }

    @Test
    func stringEnumerateSplits() {
        func split(_ string: String, on character: Character) -> [String] {
            var result = [String]()
            string.enumerateSplits(of: character) {
                result.append(String($0))
            }
            return result
        }
        #expect(split("lhs", on: " ") == ["lhs"])
        #expect(split("lhs rhs", on: " ") == ["lhs", "rhs"])
        #expect(split("lhs rhs ", on: " ") == ["lhs", "rhs"])
        #expect(split("lhs rhs  ", on: " ") == ["lhs", "rhs"])
        #expect(split("lhs rhs   end", on: " ") == ["lhs", "rhs", "end"])
    }

    @Test
    func withoutPrefix() {
        #expect("ab".withoutPrefix("") == "ab")
        #expect("ab".withoutPrefix("a") == "b")
        #expect("ab".withoutPrefix("ab") == "")
    }

    @Test
    func withoutSuffix() {
        #expect("ab".withoutSuffix("") == "ab")
        #expect("ab".withoutSuffix("b") == "a")
        #expect("ab".withoutSuffix("ab") == "")
    }

    @Test
    func quoting() {
        #expect(Array<String>().quotedDescription == "")
        #expect([""].quotedDescription == "\"\"")
        #expect(["", ""].quotedDescription == "\"\" \"\"")
        #expect([" "].quotedDescription == "\\ ")
        #expect(["a \""].quotedDescription == "a\\ \\\"")
        #expect(["a", "\\"].quotedDescription == "a \\\\")
    }

    @Test
    func stringListEscapingOfStrings() {
        #expect("".quotedStringListRepresentation == "\"\"")
        #expect(" ".quotedStringListRepresentation == "\\ ")
        #expect("\t \r \n ' \"".quotedStringListRepresentation == "\\\t\\ \\\r\\ \\\n\\ \\\'\\ \\\"")
        #expect("a".quotedStringListRepresentation == "a")
        #expect("\\".quotedStringListRepresentation == "\\\\")
    }

    @Test
    func stringListEscapingOfStringSequences() {
        #expect(Array<String>().quotedStringListRepresentation == "")
        #expect([""].quotedStringListRepresentation == "\"\"")
        #expect(["", ""].quotedStringListRepresentation == "\"\" \"\"")
        #expect([" "].quotedStringListRepresentation == "\\ ")
        #expect(["a \""].quotedStringListRepresentation == "a\\ \\\"")
        #expect(["a", "\\"].quotedStringListRepresentation == "a \\\\")
    }

    @Test
    func asLegalCIdentifier() {
        #expect("".asLegalCIdentifier == "")

        // Test translations which yield the same string.
        #expect("ab".asLegalCIdentifier == "ab")
        #expect("abCD".asLegalCIdentifier == "abCD")
        #expect("ab7".asLegalCIdentifier == "ab7")
        #expect("ab_CD".asLegalCIdentifier == "ab_CD")
        #expect("_ab".asLegalCIdentifier == "_ab")

        // A leading digit is replaced by an underscore.
        #expect("7ab".asLegalCIdentifier == "_ab")
        #expect("78ab".asLegalCIdentifier == "_8ab")

        // Non-alphanumeric, non-underscore characters are replaced by underscores.
        #expect("a.b-c".asLegalCIdentifier == "a_b_c")
        #expect(".ab".asLegalCIdentifier == "_ab")
        #expect("|a^b&c|".asLegalCIdentifier == "_a_b_c_")

        // String with combining characters whose representations differ in NFC and NFD forms.
        #expect(String(bytes: [0x6F, 0x6F, 0xCC, 0x84, 0x6F], encoding: .utf8)?.asLegalCIdentifier == "o_o") // oōo, NFD (decomposed) form
        #expect(String(bytes: [0x6F, 0xC5, 0x8D,       0x6F], encoding: .utf8)?.asLegalCIdentifier == "o_o") // oōo, NFC (precomposed) form
    }

    @Test
    func asLegalRFC1034Identifier() {
        #expect("".asLegalRfc1034Identifier == "")

        // Test translations which yield the same string.
        #expect("ab".asLegalRfc1034Identifier == "ab")
        #expect("abCD".asLegalRfc1034Identifier == "abCD")
        #expect("ab7".asLegalRfc1034Identifier == "ab7")
        #expect("ab-CD".asLegalRfc1034Identifier == "ab-CD")
        #expect("-ab".asLegalRfc1034Identifier == "-ab")

        // A leading digit is replaced by a dash.
        #expect("7ab".asLegalRfc1034Identifier == "-ab")
        #expect("78ab".asLegalRfc1034Identifier == "-8ab")

        // Non-alphanumeric, non-dash characters are replaced by dashes.
        #expect("a.b_c".asLegalRfc1034Identifier == "a-b-c")
        #expect(".ab".asLegalRfc1034Identifier == "-ab")
        #expect("|a^b&c|".asLegalRfc1034Identifier == "-a-b-c-")

        // String with combining characters whose representations differ in NFC and NFD forms.
        #expect(String(bytes: [0x6F, 0x6F, 0xCC, 0x84, 0x6F], encoding: .utf8)?.asLegalRfc1034Identifier == "o-o") // oōo, NFD (decomposed) form
        #expect(String(bytes: [0x6F, 0xC5, 0x8D,       0x6F], encoding: .utf8)?.asLegalRfc1034Identifier == "o-o") // oōo, NFC (precomposed) form
    }

    @Test
    func asLegalBundleIdentifier() {
        #expect("".asLegalBundleIdentifier == "")

        // Translation yields the same string.
        #expect("ab".asLegalBundleIdentifier == "ab")
        #expect("abCD".asLegalBundleIdentifier == "abCD")
        #expect("ab7".asLegalBundleIdentifier == "ab7")
        #expect("ab.CD".asLegalBundleIdentifier == "ab.CD")
        #expect(".ab".asLegalBundleIdentifier == ".ab")
        #expect("-ab".asLegalBundleIdentifier == "-ab")
        #expect("ab.cd-ef".asLegalBundleIdentifier == "ab.cd-ef")

        // A leading digit shouldn't be replaced by a dash.
        #expect("7ab".asLegalBundleIdentifier == "7ab")
        #expect("78ab".asLegalBundleIdentifier == "78ab")

        // Non-alphanumeric, non-dash, non-period characters are replaced by dashes.
        #expect("a_b".asLegalBundleIdentifier == "a-b")
        #expect("?ab".asLegalBundleIdentifier == "-ab")
        #expect("|a^b&c|".asLegalBundleIdentifier == "-a-b-c-")

        // String with combining characters whose representations differ in NFC and NFD forms.
        #expect(String(bytes: [0x6F, 0x6F, 0xCC, 0x84, 0x6F], encoding: .utf8)?.asLegalBundleIdentifier == "o-o") // oōo, NFD (decomposed) form
        #expect(String(bytes: [0x6F, 0xC5, 0x8D,       0x6F], encoding: .utf8)?.asLegalBundleIdentifier == "o-o") // oōo, NFC (precomposed) form
    }

    @Test
    func mangledToC99Identifier() {
        #expect("".mangledToC99ExtendedIdentifier() == "")

        // Translation yields the same string.
        #expect("ab".mangledToC99ExtendedIdentifier() == "ab")
        #expect("abCD".mangledToC99ExtendedIdentifier() == "abCD")
        #expect("ab7".mangledToC99ExtendedIdentifier() == "ab7")
        #expect("ab.CD".mangledToC99ExtendedIdentifier() == "ab_CD")
        #expect(".ab".mangledToC99ExtendedIdentifier() == "_ab")
        #expect("-ab".mangledToC99ExtendedIdentifier() == "_ab")
        #expect("ab.cd-ef".mangledToC99ExtendedIdentifier() == "ab_cd_ef")

        // A leading digit is replaced by a dash.
        #expect("7ab".mangledToC99ExtendedIdentifier() == "_ab")
        #expect("78ab".mangledToC99ExtendedIdentifier() == "_8ab")

        // Non-alphanumeric, non-dash, non-period characters are replaced by dashes.
        #expect("a_b".mangledToC99ExtendedIdentifier() == "a_b")
        #expect("?ab".mangledToC99ExtendedIdentifier() == "_ab")
        #expect("|a^b&c|".mangledToC99ExtendedIdentifier() == "_a_b_c_")

        // String with combining characters whose representations differ in NFC and NFD forms.
        #expect(String(bytes: [0x6F, 0x6F, 0xCC, 0x84, 0x6F], encoding: .utf8)?.mangledToC99ExtendedIdentifier() == "oōo") // oōo, NFD (decomposed) form
        #expect(String(bytes: [0x6F, 0xC5, 0x8D,       0x6F], encoding: .utf8)?.mangledToC99ExtendedIdentifier() == "oōo") // oōo, NFC (precomposed) form

        // Test the mutating version...
        var s = "-ab"
        s.mangleToC99ExtendedIdentifier()
        #expect(s == "_ab")
    }

    @Test
    func escaped() {
        #expect("".escaped == "\"\"")

        // Some strings which we don't expect to be escaped.
        #expect("AlphabeticCharacters".escaped == "AlphabeticCharacters")
        #expect("And012Numeric3456Stuff789".escaped == "And012Numeric3456Stuff789")
        #expect("/Unescaped/Special,characters__/this=that/+file-bar.txt".escaped == "/Unescaped/Special,characters__/this=that/+file-bar.txt")

        // We don't presently escape tab or newline characters.
        #expect("tab\tnewline\nreturn\ryay".escaped == "tab\tnewline\nreturn\ryay")

        // Some strings which we do expect to be escaped.
        #expect("/tmp/Target (framework)/file!.txt".escaped == "/tmp/Target\\ \\(framework\\)/file\\!.txt")
        #expect("/tmp/backslash\\ file.txt".escaped == "/tmp/backslash\\\\\\ file.txt")

        // String with combining characters whose representations differ in NFC and NFD forms.
        // Note that it doesn't matter which form the literal "o\\ōo" that we check against is in;
        // (though it happens to be NFC) that's the whole point of Unicode canonical equivalence.
        #expect(String(bytes: [0x6F, 0x6F, 0xCC, 0x84, 0x6F], encoding: .utf8)?.escaped == "o\\ōo") // oōo, NFD (decomposed) form
        #expect(String(bytes: [0x6F, 0xC5, 0x8D,       0x6F], encoding: .utf8)?.escaped == "o\\ōo") // oōo, NFC (precomposed) form
    }

    @Test
    func padded() {
        #expect("".padded() == "")
        #expect("foo".padded() == "foo")

        #expect("".padded(2) == "  ")
        #expect("foo".padded(2) == "foo")

        #expect("".padded(5) == "     ")
        #expect("foo".padded(5) == "foo  ")
        #expect("foo".padded(5, side: .left) == "  foo")

        #expect("".padded(5, with: "g") == "ggggg")
        #expect("foo".padded(5, with: "g") == "foogg")
        #expect("foo".padded(5, with: "g", side: .left) == "ggfoo")
    }

    @Test
    func unicodeDecoding() {
        #expect(String(decodingBytes: [], as: Unicode.UTF8.self) == "")
        #expect(String(decodingBytes: [], as: Unicode.UTF16.self) == "")
        #expect(String(decodingBytes: [], as: Unicode.UTF32.self) == "")

        // Wrong length
        #expect(String(decodingBytes: [0x00], as: Unicode.UTF16.self) == nil) // not a multiple of UTF16.CodeUnit byte width (2)
        #expect(String(decodingBytes: [0x00], as: Unicode.UTF32.self) == nil) // not a multiple of UTF32.CodeUnit byte width (4)

        // Invalid content
        #expect(String(decodingBytes: [0xD8, 0x00], as: Unicode.UTF16.self) == nil) // unpaired surrogate
        #expect(String(decodingBytes: [0x00, 0x41, 0xD8, 0x00], as: Unicode.UTF16.self) == nil) // unpaired surrogate
        #expect(String(decodingBytes: [0x00, 0x00, 0xD8, 0x00], as: Unicode.UTF32.self) == nil) // unpaired surrogate
        #expect(String(decodingBytes: [0x00, 0x11, 0x00, 0x00], as: Unicode.UTF32.self) == nil) // out of range (max scalar = U+10FFFF)

        // BOMs are still valid text and shouldn't be stripped
        #expect(String(decodingBytes: [0xEF, 0xBB, 0xBF], as: Unicode.UTF8.self) == "\u{FEFF}")
        #expect(String(decodingBytes: [0xFE, 0xFF], as: Unicode.UTF16.self) == "\u{FEFF}")
        #expect(String(decodingBytes: [0xFF, 0xFE], as: Unicode.UTF16.self, byteSwap: true) == "\u{FEFF}")
        #expect(String(decodingBytes: [0xFF, 0xFE], as: Unicode.UTF16.self) == "\u{FFFE}")
        #expect(String(decodingBytes: [0x00, 0x00, 0xFE, 0xFF], as: Unicode.UTF32.self) == "\u{FEFF}")
        #expect(String(decodingBytes: [0xFF, 0xFE, 0x00, 0x00], as: Unicode.UTF32.self, byteSwap: true) == "\u{FEFF}")
        #expect(String(decodingBytes: [0xFF, 0xFE, 0x00, 0x00], as: Unicode.UTF32.self) == nil) // out of Unicode range

        // Trailing NULLs preserved
        #expect(String(decodingBytes: [0x41, 0x00], as: Unicode.UTF8.self) == "A\0")
    }
}
