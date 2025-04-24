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

// Extend Array and ArraySlice to support asReadableString() that auto-decodes UTF8.  Due to <rdar://problem/23320231> we currently need two separate functions and extensions for this.
public protocol EncodableInUTF8Sequence {
    static func fromArrayToDecodedString(_ data: Array<Self>) -> String?
    static func fromArraySliceToDecodedString(_ data: ArraySlice<Self>) -> String?
}
extension UInt8 : EncodableInUTF8Sequence {
    public static func fromArrayToDecodedString(_ data: [UInt8]) -> String? {
        return String(bytes: data, encoding: .utf8)
    }
    public static func fromArraySliceToDecodedString(_ data: ArraySlice<UInt8>) -> String? {
        return String(bytes: data, encoding: .utf8)
    }
}
public extension Array where Element : EncodableInUTF8Sequence {
    /// Convert an array of maybe-UTF8 bytes into a readable representation, if possible.
    ///
    /// This method is only intended for use as a debugging aid -- actual program logic that needs to work with byte sequences and also effect String conversion (for example in comparisons) should (and augment, if necessary) use the ByteString type and properly handle UTF8 decoding issues.
    func asReadableString() -> String {
        return Element.fromArrayToDecodedString(self) ?? String(describing: self)
    }
}
public extension ArraySlice where Element : EncodableInUTF8Sequence {
    /// Convert an array of maybe-UTF8 bytes into a readable representation, if possible.
    ///
    /// This method is only intended for use as a debugging aid -- actual program logic that needs to work with byte sequences and also effect String conversion (for example in comparisons) should (and augment, if necessary) use the ByteString type and properly handle UTF8 decoding issues.
    func asReadableString() -> String {
        return Element.fromArraySliceToDecodedString(self) ?? String(describing: self)
    }
}

public extension Character {
    var isVowel: Bool { return ["a","e","i","o","u","A","E","I","O","U"].contains(self) }
}

public extension String {
    /// The platform newline character sequence: `\r\n` on Windows, `\n` on all other platforms.
    static var newline: String {
        #if os(Windows)
        "\r\n"
        #else
        "\n"
        #endif
    }

    /// Parse the string as an Obj-C style boolean value.
    var boolValue: Bool {
        guard let first = utf8.first else { return false }
        switch first {
        case UInt8(ascii: "y"), UInt8(ascii: "Y"), UInt8(ascii: "t"), UInt8(ascii: "T"), UInt8(ascii: "1")...UInt8(ascii: "9"):
            return true
        default:
            return false
        }
    }

    /// Return the string prepended with the appropriate indefinite article ('a' or 'an').
    var withIndefiniteArticle: String {
        guard let first else { return self }
        // There are some special cases such as 'x-ray' or '8' or '18' that we could handle here.
        let article = (first.isVowel ? "an" : "a")
        return article + " " + self
    }

    /// Split a string into two pieces separated by the 'on' character, if present.
    ///
    /// - returns: A pair of the left and right halves. If the character is not present, the string is in the left half and the right half is empty.
    func split(_ on: Character) -> (String, String) {
        for idx in self.indices {
            if self[idx] == on {
                return (String(self[..<idx]), String(self[index(after: idx)...]))
            }
        }
        return (self, "")
    }

    /// Enumerate the elements of a string separated by the given character.
    @inline(__always)
    func enumerateSplits(of character: Character, _ body: (Substring) -> Void) {
        var str = self[...]
        while !str.isEmpty {
            let (lhs, rhs) = str.split(character)
            if !lhs.isEmpty {
                body(lhs)
            }
            str = rhs
        }
    }

    /// Split a string on the `around` character into a list of strings,
    /// including the instances of `around` character itself.
    /// For example, the input `"hello world  !"` produces
    /// `["hello", " ", "world", " ", " ", "!"]`
    func fragment(around: Character) -> [String] {
        var out = [String]()
        var s = String()

        let complete = {
            if !s.isEmpty {
                out.append(s)
                s.removeAll(keepingCapacity: true)
            }
        }

        for c in self {
            if c == around {
                complete()
                out.append(String(c))
            } else {
                s.append(c)
            }
        }

        complete()

        return out
    }

    /// Remove the given prefix from the string, which must exist.
    func withoutPrefix(_ prefix: String) -> String {
        // Empty prefixes are a special case.
        if prefix.isEmpty {
            return self
        }

        assert(hasPrefix(prefix))
        return String(dropFirst(prefix.count))
    }

    /// Remove the given suffix from the string, which must exist.
    func withoutSuffix(_ suffix: String) -> String {
        // Empty suffixes are a special case.
        if suffix.isEmpty {
            return self
        }

        assert(hasSuffix(suffix))
        return String(dropLast(suffix.count))
    }
}

public extension Substring {
    /// Split a string into two substrings pieces separated by the 'on' character, if present.
    ///
    /// - returns: A pair of the left and right halves. If the character is not present, the string is in the left half and the right half is empty.
    @inline(__always)
    func split(_ on: Character) -> (Substring, Substring) {
        if let idx = self.firstIndex(of: on) {
            return (self[..<idx], self[self.index(after: idx)...])
        }
        return (self[...], self[self.endIndex...])
    }
}

// MARK: Transformations


public extension String {
    /// Escapes the string for use in a Swift string literal.
    var asSwiftStringLiteralContent: String {
        var result = ""
        for us in self.unicodeScalars {
            result += us.escaped(asASCII: false)
        }
        return result
    }

    /// Escapes the string for use in a C string literal.
    var asCStringLiteralContent: String {
        var result = ""
        for us in self.unicodeScalars {
            result += us.escapedForC
        }
        return result
    }

    private enum StringIdentifierManglingType {
        case c
        case rfc1034
        case bundle
    }

    /// Transform the receiver to a legal identifier of the given type and return it.
    private func asIdentifierOfType(_ manglingType: StringIdentifierManglingType) -> String {
        // If the receiver is empty, then return an empty string.
        guard !self.isEmpty else { return "" }

        // Determine what characters are allowed based on the type.
        let allowPeriod = (manglingType == .bundle)
        let allowDash = (manglingType == .bundle) || (manglingType == .rfc1034)
        let allowUnderscore = (manglingType == .c)

        // Team identifiers can start with digit, and the bundle identifiers of some products like login items are required to start with the team identifier.
        let allowLeadingDigit = manglingType == .bundle

        // Iterate over the decomposed string, replacing characters which are not allowed in the mangling type with characters which are allowed.
        var result = ""
        let decomposed = self.decomposedStringWithCanonicalMapping
        for idx in decomposed.indices {
            let ch = decomposed[idx]
            switch ch {
            case "A"..."Z", "a"..."z":
                fallthrough
            case "-" where allowDash:
                fallthrough
            case "_" where allowUnderscore:
                fallthrough
            case "." where allowPeriod:
                fallthrough
            case "0"..."9" where idx != decomposed.startIndex || allowLeadingDigit:
                // Add these characters to the result without change.
                // For digits, we usually only do so if they're not the leading character, since most identifiers can't start with a digit.
                result.append(ch)

            default:
                // Otherwise, replace the character with an underscore '_' if allowed, and otherwise with a dash '-'.
                result.append(allowUnderscore ? "_" : "-")
            }
        }
        return result
    }

    /// Transform the receiver to a legal C identifier and return it.  This will replace characters which are not legal in a C identifier with underscores ('`_`').  C identifiers allow underscores, but not periods or dashes.
    var asLegalCIdentifier: String {
        return asIdentifierOfType(.c)
    }

    /// Transform the receiver to a legal RFC 1034 identifier and return it.  This will replace characters which are not legal in an RFC 1034 identifier with dashes ('`-`').  RFC 1034 identifiers allow dashes but not periods or underscores.
    var asLegalRfc1034Identifier: String {
        return asIdentifierOfType(.rfc1034)
    }

    /// Transform the receiver to a legal bundle identifier and return it.  This will replace characters which are not legal in a bundle identifier with underscores ('`_`').  Bundle identifiers allow periods and dashes but not underscores.
    var asLegalBundleIdentifier: String {
        return asIdentifierOfType(.bundle)
    }

    /// Transform the receiver by escaping characters where necessary and return it.
    ///
    /// This will *not* quote tab or eol characters, or high unicode characters.
    var escaped: String {
        // If the receiver is empty, then return two escaped double quotes.
        guard !self.isEmpty else { return "\"\"" }

        // Iterate over the decomposed string, replacing which should be escaped with a backslash followed by the character.
        var result = ""
        let decomposed = self.decomposedStringWithCanonicalMapping
        for idx in decomposed.indices {
            let ch = decomposed[idx]
            switch ch {
            case "A"..."Z", "a"..."z", "0"..."9", "/", ".", ",", "+", "-", "_", "=":
                // For this set of characters, we don't escape.
                result.append(ch)

            case "\t", "\n", "\r":
                // We presently do not escape tabs or newlines.  In the future we might want to provide an option to do so.
                result.append(ch)
            default:
                // Otherwise, we do escape.
                result.append("\\")
                result.append(ch)
            }
        }
        return result
    }

    var escapedForJSON: String {
        let stream = OutputByteStream()
        stream.writeJSONEscaped(self)
        return String(decoding: stream.bytes, as: UTF8.self)
    }

    /// Convert self to another String which has had the JSON string escape sequences converted back to Unicode code points.
    func unJSONEscaped() throws -> String {
        return try JSONDecoder().decode(String.self, from: Data("\"\(self)\"".utf8))
    }

    enum PadSide: Sendable {
        /// Pad with repeating characters on the left side of the string.
        case left
        /// Pad with repeating characters on the right side of the string.
        case right
    }

    /// Return the string padded with whitespace on the indicated side. If the string is wider than the padding, then no padding will be added.
    func padded(_ width: Int = 0, with char: Character = " ", side: PadSide = .right) -> String {
        let padding = String(repeating: char, count: max(0, width - self.count))
        switch side {
        case .left:
            return padding + self
        case .right:
            return self + padding
        }
    }
}

fileprivate extension Unicode.Scalar {
    // Adapted from `Unicode.Scalar.escaped(forASCII:)`
    var escapedForC: String {
        func lowNibbleAsHex(_ v: UInt32) -> String {
            let nibble = v & 15
            if nibble < 10 {
                return String(Unicode.Scalar(nibble+48)!)    // 48 = '0'
            } else {
                return String(Unicode.Scalar(nibble-10+65)!) // 65 = 'A'
            }
        }

        if self == "\\" {
            return "\\\\"
        } else if self == "\'" {
            return "\\\'"
        } else if self == "\"" {
            return "\\\""
        } else if self == "?" {
            return "\\?" // used to avoid trigraphs
        } else if _isPrintableASCII {
            return String(self)
        } else if self == "\0" {
            return "\\0"
        } else if self == Unicode.Scalar(0x07) {
            return "\\a"
        } else if self == Unicode.Scalar(0x08) {
            return "\\b"
        } else if self == Unicode.Scalar(0x0c) {
            return "\\f"
        } else if self == "\n" {
            return "\\n"
        } else if self == "\r" {
            return "\\r"
        } else if self == "\t" {
            return "\\t"
        } else if self == Unicode.Scalar(0x0b) {
            return "\\v"
        } else if UInt32(self) < 128 {
            return "\\x"
                + lowNibbleAsHex(UInt32(self) >> 4)
                + lowNibbleAsHex(UInt32(self))
        } else if UInt32(self) <= 0xFFFF {
            var result = "\\u"
            result += lowNibbleAsHex(UInt32(self) >> 12)
            result += lowNibbleAsHex(UInt32(self) >> 8)
            result += lowNibbleAsHex(UInt32(self) >> 4)
            result += lowNibbleAsHex(UInt32(self))
            return result
        } else {
            // FIXME: Type checker performance prohibits this from being a
            // single chained "+".
            var result = "\\U"
            result += lowNibbleAsHex(UInt32(self) >> 28)
            result += lowNibbleAsHex(UInt32(self) >> 24)
            result += lowNibbleAsHex(UInt32(self) >> 20)
            result += lowNibbleAsHex(UInt32(self) >> 16)
            result += lowNibbleAsHex(UInt32(self) >> 12)
            result += lowNibbleAsHex(UInt32(self) >> 8)
            result += lowNibbleAsHex(UInt32(self) >> 4)
            result += lowNibbleAsHex(UInt32(self))
            return result
        }
    }

    // Copied from apple/swift: stdlib/public/core/UnicodeScalar.swift
    var _isPrintableASCII: Bool {
        return (self >= Unicode.Scalar(0o040) && self <= Unicode.Scalar(0o176))
    }
}

// MARK: Quoted String List Representation

/// Extension of String for quoted string list representation.  This isn't exactly the same as shell script quoting.
public extension String {
    /// Returns a form of the receiver that escapes whitespace and some special characters.  This isn't exactly the same as shell script quoting.
    var quotedStringListRepresentation : String {
        // Create an output stream and append the quoted string list representation to it.
        let stream = OutputByteStream();
        writeQuotedStringListRepresentation(self, to: stream)

        // Create and return a string from the UTF-8 sequence (which should still be valid, since we never insert an escape in the middle of a UTF-8 character sequence).
        return stream.bytes.asString
    }
}

/// Extension of [String] for quoted string list representation.  This isn't exactly the same as shell script quoting.
public extension Sequence where Iterator.Element == String {
    /// Returns a form of the receiver that escapes whitespace and some special characters.  This isn't exactly the same as shell script quoting.
    var quotedStringListRepresentation : String {
        // Create an output stream and append the quoted string list representations of each of the items to it.
        let stream = OutputByteStream();
        for (i, string) in self.enumerated() {
            if i != 0 { stream <<< UInt8(ascii: " ") }
            writeQuotedStringListRepresentation(string, to: stream)
        }

        // Create and return a string from the UTF-8 sequence (which should still be valid, since we never insert an escape in the middle of a UTF-8 character sequence).
        return stream.bytes.asString
    }
}

// Private function that writes out the quoted string list representation of a string to a stream.  The extension methods are implemented in terms of it.
fileprivate func writeQuotedStringListRepresentation(_ string: String, to stream: OutputByteStream) {
    // Special case for empty strings, which cannot be represented using only escapes.
    if string.isEmpty {
        stream.write(UInt8(ascii: "\""))
        stream.write(UInt8(ascii: "\""))
        return
    }
    // Write the sequence of UTF-8 bytes to the stream, escaping any ones that need it.
    // FIXME: It would be more efficient to skip over whole sequences of bytes that don't need escaping.
    for ch in string.utf8 {
        if ch == UInt8(ascii: " ") || ch == UInt8(ascii: "\t") || ch == UInt8(ascii: "\r") || ch == UInt8(ascii: "\n") || ch == UInt8(ascii: "\\") || ch == UInt8(ascii: "\"") || ch == UInt8(ascii: "\'") {
            stream.write(UInt8(ascii: "\\"))
        }
        stream.write(ch)
    }
}


// MARK: QuotedCustomDescription

/// Extension of String that makes quoted-string-describable.
public extension String {
    /// Quote the string for parsing by a shell.
    var quotedDescription: String {
        return self.quotedStringListRepresentation
    }
}

/// Extension of [String] that makes quoted-string-describable.
public extension Sequence where Iterator.Element == String {
    var quotedDescription: String {
        return self.quotedStringListRepresentation
    }
}

// MARK: Extended C99 identifier (taken from swift-package-manager/Sources/Utility/StringMangling.swift)

/// Extensions to `String` to provide various forms of extended C99 identifier mangling.
extension String {

    /// Returns a form of the string that is valid C99 Extended Identifier (by
    /// replacing any invalid characters in an unspecified but consistent way).
    /// The output string is guaranteed to be non-empty as long as the input
    /// string is non-empty.
    public func mangledToC99ExtendedIdentifier() -> String {
        // Map invalid C99-invalid Unicode scalars to a replacement character.
        let replacementUnichar: Unicode.Scalar = "_"
        var mangledUnichars: [Unicode.Scalar] = self.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            switch $0.value {
            case
            // A-Z
            0x0041...0x005A,
            // a-z
            0x0061...0x007A,
            // 0-9
            0x0030...0x0039,
            // _
            0x005F,
            // Latin (1)
            0x00AA...0x00AA,
            // Special characters (1)
            0x00B5...0x00B5, 0x00B7...0x00B7,
            // Latin (2)
            0x00BA...0x00BA, 0x00C0...0x00D6, 0x00D8...0x00F6,
            0x00F8...0x01F5, 0x01FA...0x0217, 0x0250...0x02A8,
            // Special characters (2)
            0x02B0...0x02B8, 0x02BB...0x02BB, 0x02BD...0x02C1,
            0x02D0...0x02D1, 0x02E0...0x02E4, 0x037A...0x037A,
            // Greek (1)
            0x0386...0x0386, 0x0388...0x038A, 0x038C...0x038C,
            0x038E...0x03A1, 0x03A3...0x03CE, 0x03D0...0x03D6,
            0x03DA...0x03DA, 0x03DC...0x03DC, 0x03DE...0x03DE,
            0x03E0...0x03E0, 0x03E2...0x03F3,
            // Cyrillic
            0x0401...0x040C, 0x040E...0x044F, 0x0451...0x045C,
            0x045E...0x0481, 0x0490...0x04C4, 0x04C7...0x04C8,
            0x04CB...0x04CC, 0x04D0...0x04EB, 0x04EE...0x04F5,
            0x04F8...0x04F9,
            // Armenian (1)
            0x0531...0x0556,
            // Special characters (3)
            0x0559...0x0559,
            // Armenian (2)
            0x0561...0x0587,
            // Hebrew
            0x05B0...0x05B9, 0x05BB...0x05BD, 0x05BF...0x05BF,
            0x05C1...0x05C2, 0x05D0...0x05EA, 0x05F0...0x05F2,
            // Arabic (1)
            0x0621...0x063A, 0x0640...0x0652,
            // Digits (1)
            0x0660...0x0669,
            // Arabic (2)
            0x0670...0x06B7, 0x06BA...0x06BE, 0x06C0...0x06CE,
            0x06D0...0x06DC, 0x06E5...0x06E8, 0x06EA...0x06ED,
            // Digits (2)
            0x06F0...0x06F9,
            // Devanagari and Special character 0x093D.
            0x0901...0x0903, 0x0905...0x0939, 0x093D...0x094D,
            0x0950...0x0952, 0x0958...0x0963,
            // Digits (3)
            0x0966...0x096F,
            // Bengali (1)
            0x0981...0x0983, 0x0985...0x098C, 0x098F...0x0990,
            0x0993...0x09A8, 0x09AA...0x09B0, 0x09B2...0x09B2,
            0x09B6...0x09B9, 0x09BE...0x09C4, 0x09C7...0x09C8,
            0x09CB...0x09CD, 0x09DC...0x09DD, 0x09DF...0x09E3,
            // Digits (4)
            0x09E6...0x09EF,
            // Bengali (2)
            0x09F0...0x09F1,
            // Gurmukhi (1)
            0x0A02...0x0A02, 0x0A05...0x0A0A, 0x0A0F...0x0A10,
            0x0A13...0x0A28, 0x0A2A...0x0A30, 0x0A32...0x0A33,
            0x0A35...0x0A36, 0x0A38...0x0A39, 0x0A3E...0x0A42,
            0x0A47...0x0A48, 0x0A4B...0x0A4D, 0x0A59...0x0A5C,
            0x0A5E...0x0A5E,
            // Digits (5)
            0x0A66...0x0A6F,
            // Gurmukhi (2)
            0x0A74...0x0A74,
            // Gujarti
            0x0A81...0x0A83, 0x0A85...0x0A8B, 0x0A8D...0x0A8D,
            0x0A8F...0x0A91, 0x0A93...0x0AA8, 0x0AAA...0x0AB0,
            0x0AB2...0x0AB3, 0x0AB5...0x0AB9, 0x0ABD...0x0AC5,
            0x0AC7...0x0AC9, 0x0ACB...0x0ACD, 0x0AD0...0x0AD0,
            0x0AE0...0x0AE0,
            // Digits (6)
            0x0AE6...0x0AEF,
            // Oriya and Special character 0x0B3D
            0x0B01...0x0B03, 0x0B05...0x0B0C, 0x0B0F...0x0B10,
            0x0B13...0x0B28, 0x0B2A...0x0B30, 0x0B32...0x0B33,
            0x0B36...0x0B39, 0x0B3D...0x0B43, 0x0B47...0x0B48,
            0x0B4B...0x0B4D, 0x0B5C...0x0B5D, 0x0B5F...0x0B61,
            // Digits (7)
            0x0B66...0x0B6F,
            // Tamil
            0x0B82...0x0B83, 0x0B85...0x0B8A, 0x0B8E...0x0B90,
            0x0B92...0x0B95, 0x0B99...0x0B9A, 0x0B9C...0x0B9C,
            0x0B9E...0x0B9F, 0x0BA3...0x0BA4, 0x0BA8...0x0BAA,
            0x0BAE...0x0BB5, 0x0BB7...0x0BB9, 0x0BBE...0x0BC2,
            0x0BC6...0x0BC8, 0x0BCA...0x0BCD,
            // Digits (8)
            0x0BE7...0x0BEF,
            // Telugu
            0x0C01...0x0C03, 0x0C05...0x0C0C, 0x0C0E...0x0C10,
            0x0C12...0x0C28, 0x0C2A...0x0C33, 0x0C35...0x0C39,
            0x0C3E...0x0C44, 0x0C46...0x0C48, 0x0C4A...0x0C4D,
            0x0C60...0x0C61,
            // Digits (9)
            0x0C66...0x0C6F,
            // Kannada
            0x0C82...0x0C83, 0x0C85...0x0C8C, 0x0C8E...0x0C90,
            0x0C92...0x0CA8, 0x0CAA...0x0CB3, 0x0CB5...0x0CB9,
            0x0CBE...0x0CC4, 0x0CC6...0x0CC8, 0x0CCA...0x0CCD,
            0x0CDE...0x0CDE, 0x0CE0...0x0CE1,
            // Digits (10)
            0x0CE6...0x0CEF,
            // Malayam
            0x0D02...0x0D03, 0x0D05...0x0D0C, 0x0D0E...0x0D10,
            0x0D12...0x0D28, 0x0D2A...0x0D39, 0x0D3E...0x0D43,
            0x0D46...0x0D48, 0x0D4A...0x0D4D, 0x0D60...0x0D61,
            // Digits (11)
            0x0D66...0x0D6F,
            // Thai...including Digits 0x0E50...0x0E59 }
            0x0E01...0x0E3A, 0x0E40...0x0E5B,
            // Lao (1)
            0x0E81...0x0E82, 0x0E84...0x0E84, 0x0E87...0x0E88,
            0x0E8A...0x0E8A, 0x0E8D...0x0E8D, 0x0E94...0x0E97,
            0x0E99...0x0E9F, 0x0EA1...0x0EA3, 0x0EA5...0x0EA5,
            0x0EA7...0x0EA7, 0x0EAA...0x0EAB, 0x0EAD...0x0EAE,
            0x0EB0...0x0EB9, 0x0EBB...0x0EBD, 0x0EC0...0x0EC4,
            0x0EC6...0x0EC6, 0x0EC8...0x0ECD,
            // Digits (12)
            0x0ED0...0x0ED9,
            // Lao (2)
            0x0EDC...0x0EDD,
            // Tibetan (1)
            0x0F00...0x0F00, 0x0F18...0x0F19,
            // Digits (13)
            0x0F20...0x0F33,
            // Tibetan (2)
            0x0F35...0x0F35, 0x0F37...0x0F37, 0x0F39...0x0F39,
            0x0F3E...0x0F47, 0x0F49...0x0F69, 0x0F71...0x0F84,
            0x0F86...0x0F8B, 0x0F90...0x0F95, 0x0F97...0x0F97,
            0x0F99...0x0FAD, 0x0FB1...0x0FB7, 0x0FB9...0x0FB9,
            // Georgian
            0x10A0...0x10C5, 0x10D0...0x10F6,
            // Latin (3)
            0x1E00...0x1E9B, 0x1EA0...0x1EF9,
            // Greek (2)
            0x1F00...0x1F15, 0x1F18...0x1F1D, 0x1F20...0x1F45,
            0x1F48...0x1F4D, 0x1F50...0x1F57, 0x1F59...0x1F59,
            0x1F5B...0x1F5B, 0x1F5D...0x1F5D, 0x1F5F...0x1F7D,
            0x1F80...0x1FB4, 0x1FB6...0x1FBC,
            // Special characters (4)
            0x1FBE...0x1FBE,
            // Greek (3)
            0x1FC2...0x1FC4, 0x1FC6...0x1FCC, 0x1FD0...0x1FD3,
            0x1FD6...0x1FDB, 0x1FE0...0x1FEC, 0x1FF2...0x1FF4,
            0x1FF6...0x1FFC,
            // Special characters (5)
            0x203F...0x2040,
            // Latin (4)
            0x207F...0x207F,
            // Special characters (6)
            0x2102...0x2102, 0x2107...0x2107, 0x210A...0x2113,
            0x2115...0x2115, 0x2118...0x211D, 0x2124...0x2124,
            0x2126...0x2126, 0x2128...0x2128, 0x212A...0x2131,
            0x2133...0x2138, 0x2160...0x2182, 0x3005...0x3007,
            0x3021...0x3029,
            // Hiragana
            0x3041...0x3093, 0x309B...0x309C,
            // Katakana
            0x30A1...0x30F6, 0x30FB...0x30FC,
            // Bopmofo [sic]
            0x3105...0x312C,
            // CJK Unified Ideographs
            0x4E00...0x9FA5,
            // Hangul,
            0xAC00...0xD7A3:
                return $0
            default:
                return replacementUnichar
            }
        }

        // Apply further restrictions to the prefix.
        loop: for (idx, c) in mangledUnichars.enumerated() {
            switch c.value {
            case
            // 0-9
            0x0030...0x0039,
            // Annex D.
            0x0660...0x0669, 0x06F0...0x06F9, 0x0966...0x096F,
            0x09E6...0x09EF, 0x0A66...0x0A6F, 0x0AE6...0x0AEF,
            0x0B66...0x0B6F, 0x0BE7...0x0BEF, 0x0C66...0x0C6F,
            0x0CE6...0x0CEF, 0x0D66...0x0D6F, 0x0E50...0x0E59,
            0x0ED0...0x0ED9, 0x0F20...0x0F33:
                mangledUnichars[idx] = replacementUnichar
                break loop
            default:
                break loop
            }
        }

        // Combine the characters as a string again and return it.
        // FIXME: We should only construct a new string if anything changed.
        // FIXME: There doesn't seem to be a way to create a string from an
        //        array of Unicode scalars; but there must be a better way.
        return mangledUnichars.reduce(""){ $0 + String($1) }
    }

    /// Mangles the contents to a valid C99 Extended Identifier.  This method
    /// is the mutating version of `mangledToC99ExtendedIdentifier()`.
    public mutating func mangleToC99ExtendedIdentifier() {
        self = mangledToC99ExtendedIdentifier()
    }
}

/// Check equality directly between a UTF8 sequence and a string.
public func ==<T: Collection>(lhs: T, rhs: String) -> Bool where T.Iterator.Element == UInt8 {
    let n = lhs.count
    let rhs = rhs.utf8
    if n != rhs.count {
        return false
    }
    var lhsIndex = lhs.startIndex
    var rhsIndex = rhs.startIndex
    let endIndex = lhs.endIndex
    while lhsIndex != endIndex {
        if lhs[lhsIndex] != rhs[rhsIndex] {
            return false
        }
        lhsIndex = lhs.index(after: lhsIndex)
        rhsIndex = rhs.index(after: rhsIndex)
    }
    return true
}

// MARK:- MD5 support

extension String {
    /// Returns MD5 hex string representation.
    public func md5() -> String {
        let context = InsecureHashContext()
        context.add(string: self)
        return context.signature.asString
    }
}

// MARK: - Unicode

extension String {
    /// Decodes a String from the given byte sequence using the specified encoding.
    ///
    /// This is provided as a convenience to allow decoding strings from the raw bits regardless of the code unit width of the specified encoding.
    /// It does a strict decoding, and ONLY returns a valid String if the byte sequence represents a valid sequence of Unicode scalars in the specified encoding.
    /// It does NOT replace invalid byte sequences with the Unicode replacement character (U+FFFD), instead the function simply returns `nil` upon encountering
    /// invalid input or if the input sequence is of invalid length for the specified encoding. An empty input array results in an empty string.
    ///
    /// - parameter decodingBytes: The byte sequence to decode.
    /// - parameter as: The codec used to decode the byte sequence.
    /// - parameter byteSwap: Whether to byte-swap each code unit as it is read. This should be set to `true` when decoding a big-endian UTF-16 or UTF-32 byte stream (host OS endianness does not matter).
    public init?<C, Encoding>(decodingBytes bytes: C, as sourceEncoding: Encoding.Type, byteSwap: Bool = false) where C : RandomAccessCollection, C.Index : SignedInteger, C.Element == UInt8, Encoding : UnicodeCodec {
        guard var codeUnitIterator = BinaryDataIterator<C, Encoding.CodeUnit>(bytes, byteSwap: byteSwap) else {
            return nil // bytes is not a multiple of the encoding's code unit bit width
        }
        var scalars: [Unicode.Scalar] = []
        var decoder = Encoding()
        Decode: while true {
            switch decoder.decode(&codeUnitIterator) {
            case .scalarValue(let v): scalars.append(v)
            case .emptyInput: break Decode
            case .error: return nil
            }
        }

        self.init(String.UnicodeScalarView(scalars))
    }
}

/// Helper type for Unicode string decoding that iterates over an 8-bit byte sequence and returns (possibly byte-swapped) integers specified by the generic parameter `T`, which may be of arbitrary byte width.
fileprivate struct BinaryDataIterator<C, T: UnsignedInteger & FixedWidthInteger> : IteratorProtocol where C : RandomAccessCollection, C.Index : SignedInteger, C.Element == UInt8 {
    typealias Element = T

    private let unitByteWidth = Element.bitWidth / 8
    private let bytes: C
    private let byteSwap: Bool
    private var unitIndex: Int = 0

    /// Initializes the iterator with the specified byte sequence.
    /// Returns `nil` if the length of the byte sequence is not a multiple of the byte width of the integer type specified by the generic parameter `T`.
    ///
    /// - parameter bytes: The byte sequence to enumerate.
    /// - parameter byteSwap: Whether to byte-swap each code unit as it is read (by default, the stream is assumed to be encoded in big-endian, and the host OS endianness does not matter).
    init?(_ bytes: C, byteSwap: Bool = false) {
        if bytes.count % unitByteWidth != 0 {
            return nil
        }
        self.bytes = bytes
        self.byteSwap = byteSwap
    }

    mutating func next() -> T? {
        let currentByteIndex = bytes.startIndex.advanced(by: unitIndex * unitByteWidth)
        if currentByteIndex >= bytes.endIndex {
            return nil
        }
        var result: Element = 0
        for byte in bytes[currentByteIndex..<(currentByteIndex.advanced(by: unitByteWidth))] {
            result <<= C.Element.bitWidth
            result |= Element(byte)
        }
        unitIndex += 1
        return byteSwap ? result.byteSwapped : result
    }
}

#if canImport(Darwin)
public import class CoreFoundation.CFString
public import enum CoreFoundation.CFStringBuiltInEncodings
public import func CoreFoundation.CFStringCreateWithCString
public import func CoreFoundation.CFStringGetCharactersPtr
public import func CoreFoundation.CFStringGetLength
public import func CoreFoundation.CFRangeMake
public import func CoreFoundation.CFStringGetCharacters
public import var CoreFoundation.kCFAllocatorDefault

extension String {
    public init(_ cfString: CFString) {
        #if canImport(Darwin)
        self = cfString as String
        #else
        let count = CFStringGetLength(cfString)
        if let ptr = CFStringGetCharactersPtr(cfString) {
            self.init(utf16CodeUnits: CFStringGetCharactersPtr(cfString), count: count)
        } else {
            let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: count)
            defer { buffer.deallocate() }
            CFStringGetCharacters(cfString, CFRangeMake(0, count), buffer.baseAddress)
            self.init(utf16CodeUnits: buffer.baseAddress!, count: count)
        }
        #endif
    }

    public var asCFString: CFString {
        #if canImport(Darwin)
        return self as CFString
        #else
        var this = self
        return this.withUTF8 { $0.withMemoryRebound(to: CChar.self) { CFStringCreateWithCString(kCFAllocatorDefault, $0.baseAddress, CFStringBuiltInEncodings.UTF8.rawValue) } }
        #endif
    }
}
#endif

/// Convenience for creating fraction strings with "thin space" padding around the slash
public func activityMessageFractionString<T: Numeric>(_ numerator: T, over denominator: T) -> String {
    "\(numerator)\u{2009}/\u{2009}\(denominator)"
}
