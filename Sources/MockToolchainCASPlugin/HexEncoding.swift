//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// Lossless hex encode/decode for arbitrary digest bytes. `llcas_digest_t` bytes aren't guaranteed
// to be valid UTF8 (e.g. a caller may pass a raw, independently-computed hash), so digest identity
// must go through a byte-for-byte reversible encoding rather than a UTF8 decode, which would
// silently collapse distinct invalid byte sequences to the same replacement character and alias
// unrelated digests onto the same key.

private let hexAlphabet = Array("0123456789abcdef".utf8)

func hexEncodedString(_ bytes: some Sequence<UInt8>) -> String {
    var chars: [UInt8] = []
    for byte in bytes {
        chars.append(hexAlphabet[Int(byte >> 4)])
        chars.append(hexAlphabet[Int(byte & 0x0F)])
    }
    return String(decoding: chars, as: UTF8.self)
}

func hexDecodedBytes(_ hex: String) -> [UInt8]? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else {
        return nil
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else {
            return nil
        }
        bytes.append((hi << 4) | lo)
        i += 2
    }
    return bytes
}

private func hexNibble(_ char: UInt8) -> UInt8? {
    switch char {
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return char - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"):
        return char - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"):
        return char - UInt8(ascii: "A") + 10
    default:
        return nil
    }
}
