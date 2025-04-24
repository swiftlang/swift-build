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

import SWBUtil
public import SWBProtocol

public typealias FileTextEncoding = SWBProtocol.FileTextEncoding

public import struct Foundation.Data
public import class Foundation.NSNumber
public import class Foundation.NSString

#if canImport(Darwin)
import class CoreFoundation.CFString
import var CoreFoundation.kCFStringEncodingInvalidId
import func CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import func CoreFoundation.CFStringConvertEncodingToIANACharSetName
import func CoreFoundation.CFStringConvertIANACharSetNameToEncoding
import func CoreFoundation.CFStringConvertNSStringEncodingToEncoding
#endif

#if canImport(Darwin)
import struct CoreFoundation.ObjCBool
public import struct Foundation.StringEncodingDetectionOptionsKey
#endif

// The naming convention in Foundation is rather unfortunate.
// The explicit-endian encodings do NOT add any BOM, and the non-explicit endian
// encodings (except UTF-8) DO add a BOM based on the host byte order. Be aware.
public extension FileTextEncoding {
    init?(stringEncoding: String.Encoding) {
        #if canImport(Darwin)
        let cfencoding = CFStringConvertNSStringEncodingToEncoding(stringEncoding.rawValue)
        if cfencoding != kCFStringEncodingInvalidId, let name = CFStringConvertEncodingToIANACharSetName(cfencoding).map(String.init) {
            self.init(name)
            return
        }
        #endif
        return nil
    }

    /// Convert the given encoding to an `NSStringEncoding`.
    var stringEncoding: String.Encoding? {
        #if canImport(Darwin)
        let cfencoding = CFStringConvertIANACharSetNameToEncoding(rawValue.asCFString)
        if cfencoding != kCFStringEncodingInvalidId {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfencoding))
        }
        #endif
        return nil
    }

    /// Returns a localized, human-readable name of the encoding.
    var localizedName: String? {
        if let stringEncoding {
            return String.localizedName(of: stringEncoding)
        }
        return nil
    }

    /// Initializes a string from the given byte sequence.
    static func string(from bytes: [UInt8], encoding: FileTextEncoding?) -> (string: String, originalEncoding: FileTextEncoding)? {
        if let encoding {
            guard let string = String(bytes, encoding: encoding) else { return nil }
            return (string, encoding)
        }

        #if canImport(Darwin)
        var convertedString: NSString?
        var usedLossyConversion: ObjCBool = true
        let stringEncoding = String.Encoding(rawValue: NSString.stringEncoding(for: Data(bytes), encodingOptions: [.allowLossyKey: NSNumber(value: false)], convertedString: &convertedString, usedLossyConversion: &usedLossyConversion))
        if let convertedString = convertedString as String?, let discoveredEncoding = FileTextEncoding(stringEncoding: stringEncoding), !usedLossyConversion.boolValue {
            // Always detect ASCII as UTF-8, because we want to prefer Unicode encodings
            return (convertedString, stringEncoding == .ascii ? FileTextEncoding.utf8 : discoveredEncoding)
        }
        #endif

        return nil
    }
}

fileprivate extension String {
    init?<C: RandomAccessCollection>(_ bytes: C, encoding: FileTextEncoding) where C.Index : SignedInteger, C.Element == UInt8 {
        switch encoding {
        case .utf8:
            self.init(decodingBytes: bytes, as: Unicode.UTF8.self)
        case .utf16:
            guard let encoding = [FileTextEncoding]([.utf16be, .utf16le]).first(where: { bytes.starts(with: $0.byteOrderMark) }) else { return nil }
            self.init(bytes.dropFirst(encoding.byteOrderMark.count), encoding: encoding)
        case .utf16be:
            self.init(decodingBytes: bytes, as: Unicode.UTF16.self)
        case .utf16le:
            self.init(decodingBytes: bytes, as: Unicode.UTF16.self, byteSwap: true)
        case .utf32:
            guard let encoding = [FileTextEncoding]([.utf32be, .utf32le]).first(where: { bytes.starts(with: $0.byteOrderMark) }) else { return nil }
            self.init(bytes.dropFirst(encoding.byteOrderMark.count), encoding: encoding)
        case .utf32be:
            self.init(decodingBytes: bytes, as: Unicode.UTF32.self)
        case .utf32le:
            self.init(decodingBytes: bytes, as: Unicode.UTF32.self, byteSwap: true)
        default:
            return nil
        }
    }
}
