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

public import struct Foundation.Data
public import protocol Foundation.DataProtocol

/// A `ByteString` represents a sequence of bytes.
///
/// This struct provides useful operations for working with buffers of bytes. Conceptually it is just a contiguous array of bytes (UInt8), but it contains methods and default behavior suitable for common operations done using bytes strings.
///
/// This struct *is not* intended to be used for significant mutation of byte strings, we wish to retain the flexibility to micro-optimize the memory allocation of the storage (for example, by inlining the storage for small strings or and by eliminating wasted space in growable arrays). For construction of byte arrays, clients should use the `OutputByteStream` class and then convert to a `ByteString` when complete.
@DebugDescription
public struct ByteString: ExpressibleByArrayLiteral, Sendable {
    /// The buffer contents.
    fileprivate let _bytes: [UInt8]

    /// Create an empty byte string.
    public init() {
        _bytes = []
    }

    /// Create a byte string from a byte array literal.
    public init(arrayLiteral contents: UInt8...) {
        _bytes = contents
    }

    /// Create a byte string from an array of bytes.
    public init(_ contents: some Sequence<UInt8>) {
        _bytes = [UInt8](contents)
    }

    /// Create a byte string from the UTF8 encoding of a string.
    public init(encodingAsUTF8 string: String) {
        // FIXME: We used to have a very valuable ast path for contiguous strings. See: <rdar://problem/29208285>
        _bytes = [UInt8](string.utf8)
    }

    /// Access the byte string contents as an array.
    public var bytes: [UInt8] {
        return _bytes
    }

    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<StringData.Element>) throws -> R) rethrows -> R? {
        return try _bytes.withContiguousStorageIfAvailable(body)
    }

    /// Check if the byte string is empty.
    public var isEmpty: Bool {
        return _bytes.isEmpty
    }

    /// Return the byte string size.
    public var count: Int {
        return _bytes.count
    }

    //@available(*, deprecated, renamed: "unsafeStringValue", message: "this method silently replaces invalid UTF-8 sequences with the replacement character (U+FFFD); prefer the failable variant `stringValue` instead")
    public var asString: String {
        return unsafeStringValue
    }

    /// Return the string decoded as a UTF-8 sequence.
    /// Invalid UTF-8 sequences are replaced with the Unicode REPLACEMENT CHARACTER (U+FFFD).
    ///
    /// In most cases, `stringValue` is preferred. Only use this property when you are absolutely certain that the `ByteString` contains valid UTF-8 data, or that potential data loss is acceptable for the use case.
    public var unsafeStringValue: String {
        return String(decoding: _bytes, as: Unicode.UTF8.self)
    }

    /// Return the string decoded as a UTF-8 sequence, if possible.
    public var stringValue: String? {
        return String(bytes: _bytes, encoding: .utf8)
    }

    /// Returns a Boolean value indicating whether the byte string begins with the specified prefix.
    public func hasPrefix(_ prefix: ByteString) -> Bool {
        _bytes.hasPrefix(prefix._bytes)
    }

    /// Returns a Boolean value indicating whether the byte string ends with the specified suffix.
    public func hasSuffix(_ suffix: ByteString) -> Bool {
        _bytes.hasSuffix(suffix._bytes)
    }

    public static func +=(lhs: inout ByteString, rhs: ByteString) {
        lhs = lhs + rhs
    }

    public static func +(lhs: ByteString, rhs: ByteString) -> ByteString {
        return ByteString(lhs._bytes + rhs.bytes)
    }
}

/// Conform to CustomStringConvertible.
extension ByteString: CustomStringConvertible {
    public var description: String {
        // For now, default to the "readable string" representation.
        return "<ByteString:\"\(bytes.asReadableString())\">"
    }
}

/// Hashable conformance for a ByteString.
extension ByteString: Hashable { }

/// Comparison with strings (as UTF8).
public func ==(lhs: ByteString, rhs: String) -> Bool {
    // FIXME: Is Swift's String.UTF8View.count O(1)?
    let utf8 = rhs.utf8
    if lhs.bytes.count != utf8.count {
        return false
    }
    for (i, c) in utf8.enumerated() {
        if lhs.bytes[i] != c {
            return false
        }
    }
    return true
}

/// ByteStreamable conformance for a ByteString.
extension ByteString: ByteStreamable {
    public func writeTo(_ stream: OutputByteStream) {
        stream.write(_bytes)
    }
}

/// StringLiteralConvertible conformance for a ByteString.
extension ByteString: ExpressibleByStringLiteral {
    public typealias UnicodeScalarLiteralType = StringLiteralType
    public typealias ExtendedGraphemeClusterLiteralType = StringLiteralType

    public init(unicodeScalarLiteral value: UnicodeScalarLiteralType) {
        _bytes = [UInt8](value.utf8)
    }
    public init(extendedGraphemeClusterLiteral value: ExtendedGraphemeClusterLiteralType) {
        _bytes = [UInt8](value.utf8)
    }
    public init(stringLiteral value: StringLiteralType) {
        _bytes = [UInt8](value.utf8)
    }
}

/// Serialization
extension ByteString: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serialize(_bytes)
    }

    public init(from deserializer: any Deserializer) throws {
        self._bytes = try deserializer.deserialize()
    }
}

extension ByteString: DataProtocol, Collection {
    public typealias StringData = Array<UInt8>
    public typealias Regions = StringData.Regions
    public typealias Element = StringData.Element
    public typealias Index = StringData.Index
    public typealias SubSequence = StringData.SubSequence
    public typealias Indices = StringData.Indices

    public subscript(position: Self.Index) -> Self.Element {
        _bytes[position]
    }

    public subscript(bounds: Range<Self.Index>) -> Self.SubSequence {
        _bytes[bounds]
    }

    public var regions: StringData.Regions {
        _bytes.regions
    }

    public var startIndex: StringData.Index {
        _bytes.startIndex
    }

    public var endIndex: StringData.Index {
        _bytes.endIndex
    }
}

/// Codable conformance for a ByteString.
extension ByteString: Codable {
    public func encode(to encoder: any Swift.Encoder) throws {
        try Data(_bytes).encode(to: encoder)
    }

    public init(from data: Data) throws {
        if let str = String(data: data, encoding: .utf8) {
            self.init(encodingAsUTF8: str)
        } else {
            throw StubError.error("unable to convert data to string")
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        try self.init(encodingAsUTF8: String(from: decoder))
    }
}
