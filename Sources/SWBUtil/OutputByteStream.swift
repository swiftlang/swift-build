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

/// Convert an integer in 0..<16 to its hexadecimal ASCII character.
private func hexdigit(_ value: UInt8) -> UInt8 {
    return value < 10 ? (0x30 + value) : (0x41 + value - 10)
}

public protocol ByteStreamable {
    func writeTo(_ stream: OutputByteStream)
}

public final class JSONOutputStreamer {
    private let stream: OutputByteStream
    private var queuedPairs = [(any ByteStreamable, any ByteStreamable)]()

    fileprivate init(stream: OutputByteStream) {
        self.stream = stream
    }

    fileprivate func writeObject(_ body: ((_ json: JSONOutputStreamer) -> Void)) {
        stream <<< UInt8(ascii: "{")
        let innerStreamer = JSONOutputStreamer(stream: stream)
        body(innerStreamer)
        for (i, pair) in innerStreamer.queuedPairs.enumerated() {
            if i != 0 { stream <<< UInt8(ascii: ",") }
            stream <<< pair.0
            stream <<< UInt8(ascii: ":")
            stream <<< pair.1
        }
        stream <<< UInt8(ascii: "}")
    }

    public subscript(key: String) -> ByteString {
        get { fatalError() }
        set { queuedPairs.append((Format.asJSON(key), Format.asJSON(newValue))) }
    }

    public subscript(key: String) -> String {
        get { fatalError() }
        set { queuedPairs.append((Format.asJSON(key), Format.asJSON(newValue))) }
    }

    public subscript(key: String) -> [String] {
        get { fatalError() }
        set { queuedPairs.append((Format.asJSON(key), Format.asJSON(newValue))) }
    }

    public subscript(key: String) -> [ByteString] {
        get { fatalError() }
        set { queuedPairs.append((Format.asJSON(key), Format.asJSON(newValue))) }
    }

    public subscript(key: String) -> KeyValuePairs<String, String> {
        get { fatalError() }
        set { queuedPairs.append((Format.asJSON(key), Format.asJSON(newValue))) }
    }

    public subscript(key: String) -> [(String, String)] {
        get { fatalError() }
        set { queuedPairs.append((Format.asJSON(key), Format.asJSON(newValue))) }
    }

    public subscript(key: String) -> Bool {
        get { fatalError() }
        set { queuedPairs.append((Format.asJSON(key), newValue ? "true" : "false")) }
    }
}

@available(*, unavailable)
extension JSONOutputStreamer: Sendable { }

// This extension contains methods designed to write JSON to the stream,
// where the *value* (not the key) of the dictionary is pre-encoded JSON bytes.
extension JSONOutputStreamer {
    public func writeMapWithLiteralValues(_ json: KeyValuePairs<String, ByteString>, forKey key: String) {
        queuedPairs.append((Format.asJSON(key), Format.asJSON(json)))
    }

    public func writeMapWithLiteralValues(_ json: [(String, ByteString)], forKey key: String) {
        queuedPairs.append((Format.asJSON(key), Format.asJSON(json)))
    }
}

extension OutputByteStream {
    public func writeJSONObject(_ body: ((_ json: JSONOutputStreamer) -> Void)) {
        JSONOutputStreamer(stream: self).writeObject(body)
    }

    public func writingJSONObject(_ body: ((_ json: JSONOutputStreamer) -> Void)) -> OutputByteStream {
        writeJSONObject(body)
        return self
    }
}

/// An output byte stream.
///
/// This class is designed to be able to support efficient streaming to different output destinations, e.g., a file or an in memory buffer. This is loosely modeled on LLVM's llvm::raw_ostream class.
///
/// The stream is generally used in conjunction with the custom streaming operator '<<<'. For example:
///
///   let stream = OutputByteStream()
///   stream <<< "Hello, world!"
///
/// would write the UTF8 encoding of "Hello, world!" to the stream.
///
/// The stream accepts a number of custom formatting operators which are defined in the `Format` struct (used for namespacing purposes). For example:
///
///   let items = ["hello", "world"]
///   stream <<< Format.asSeparatedList(items, separator: " ")
///
/// would write each item in the list to the stream, separating them with a space.
public final class OutputByteStream: TextOutputStream {
    /// The data buffer.
    private var buffer: [UInt8]

    public init() {
        self.buffer = []
    }

    // MARK: Data Access API

    /// The current offset within the output stream.
    public var position: Int {
        return buffer.count
    }

    /// The contents of the output stream.
    ///
    /// This method implicitly flushes the stream.
    public var bytes: ByteString {
        flush()
        return ByteString(self.buffer)
    }

    // MARK: Data Output API

    public func flush() {
        // Do nothing.
    }

    /// Write an individual byte to the buffer.
    public func write(_ byte: UInt8) {
        buffer.append(byte)
    }

    /// Write a sequence of bytes to the buffer.
    public func write(_ bytes: [UInt8]) {
        buffer += bytes
    }

    /// Write a data chunk to the buffer.
    public func write(_ bytes: Data) {
        // FIXME: [UInt8] has no fast path for Data: <rdar://problem/32069787> [UInt8] += has no fast path for Data
        bytes.withUnsafeBytes {
            buffer += $0
        }
    }

    /// Write a sequence of bytes to the buffer.
    public func write(_ bytes: ArraySlice<UInt8>) {
        buffer += bytes
    }

    /// Write a sequence of bytes to the buffer.
    public func write<S: Sequence>(_ sequence: S) where S.Iterator.Element == UInt8 {
        buffer += sequence
    }

    /// Write a string to the buffer (as UTF8).
    public func write(_ string: String) {
        // FIXME: We used to have a very valuable fast path for contiguous strings. See: <rdar://problem/29208285>
        //
        // For some reason Swift itself doesn't implement this optimization: <rdar://problem/24100375> Missing fast path for [UInt8] += String.UTF8View
        buffer += string.utf8
    }

    /// Write a character to the buffer (as UTF8).
    public func write(_ character: Character) {
        buffer += String(character).utf8
    }

    /// Write an arbitrary byte streamable to the buffer.
    public func write(_ value: any ByteStreamable) {
        value.writeTo(self)
    }

    /// Write an arbitrary streamable to the buffer.
    public func write(_ value: any TextOutputStreamable) {
        // Get a mutable reference.
        var stream: OutputByteStream = self
        value.write(to: &stream)
    }

    /// Write a string (as UTF8) to the buffer, with escaping appropriate for embedding within a JSON document.
    ///
    /// NOTE: This writes the literal data applying JSON string escaping, but does not write any other characters (like the quotes that would surround a JSON string).
    public func writeJSONEscaped(_ string: String) {
        writeJSONEscaped(string: string.utf8)
    }

    /// Write a UTF8 encoded string to the buffer, with escaping appropriate for embedding within a JSON document.
    ///
    /// NOTE: This writes the literal data applying JSON string escaping, but does not write any other characters (like the quotes that would surround a JSON string).
    public func writeJSONEscaped<T: Collection>(
        string sequence: T
    ) where T.Iterator.Element == UInt8 {
        // See RFC7159 for reference.
        for character in sequence {
            switch character {
            // Literal characters.
            case 0x20...0x21, 0x23...0x5B, 0x5D...0xFF:
                buffer.append(character)

                // Single-character escaped characters.
            case 0x22: // '"'
                buffer.append(0x5C) // '\'
                buffer.append(0x22) // '"'
            case 0x5C: // '\\'
                buffer.append(0x5C) // '\'
                buffer.append(0x5C) // '\'
            case 0x08: // '\b'
                buffer.append(0x5C) // '\'
                buffer.append(0x62) // 'b'
            case 0x0C: // '\f'
                buffer.append(0x5C) // '\'
                buffer.append(0x66) // 'f'
            case 0x0A: // '\n'
                buffer.append(0x5C) // '\'
                buffer.append(0x6E) // 'n'
            case 0x0D: // '\r'
                buffer.append(0x5C) // '\'
                buffer.append(0x72) // 'r'
            case 0x09: // '\t'
                buffer.append(0x5C) // '\'
                buffer.append(0x74) // 't'

                // Multi-character escaped characters.
            default:
                buffer.append(0x5C) // '\'
                buffer.append(0x75) // 'u'
                buffer.append(hexdigit(0))
                buffer.append(hexdigit(0))
                buffer.append(hexdigit(character >> 4))
                buffer.append(hexdigit(character & 0xF))
            }
        }
    }
}

@available(*, unavailable)
extension OutputByteStream: Sendable { }

/// Define an output stream operator. We need it to be left associative, so we
/// use `<<<`.
infix operator <<< : StreamingPrecedence
precedencegroup StreamingPrecedence {
    associativity: left
    higherThan: AssignmentPrecedence
}

// MARK: Output Operator Implementations
//
// NOTE: It would be nice to use a protocol here and the adopt it by all the things we can efficiently stream out. However, that doesn't work because we ultimately need to provide a manual overload for, e.g., TextOutputStreamable, but that will then cause ambiguous lookup versus the implementation just using the defined protocol.

@discardableResult
public func <<<(stream: OutputByteStream, value: UInt8) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: [UInt8]) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: Data) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: ArraySlice<UInt8>) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<<S: Sequence>(stream: OutputByteStream, value: S) -> OutputByteStream where S.Iterator.Element == UInt8 {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: String) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: Character) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: any ByteStreamable) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: any TextOutputStreamable) -> OutputByteStream {
    stream.write(value)
    return stream
}

extension UInt8: ByteStreamable {
    public func writeTo(_ stream: OutputByteStream) {
        stream.write(self)
    }
}

extension Character: ByteStreamable {
    public func writeTo(_ stream: OutputByteStream) {
        stream.write(self)
    }
}

extension String: ByteStreamable {
    public func writeTo(_ stream: OutputByteStream) {
        stream.write(self)
    }
}

// MARK: Formatted Streaming Output

// Not nested because it is generic.
private struct SeparatedListStreamable<T: ByteStreamable>: ByteStreamable {
    let items: [T]
    let separator: String

    func writeTo(_ stream: OutputByteStream) {
        for (i, item) in items.enumerated() {
            // Add the separator, if necessary.
            if i != 0 {
                stream <<< separator
            }

            stream <<< item
        }
    }
}

// Not nested because it is generic.
private struct TransformedSeparatedListStreamable<T>: ByteStreamable {
    let items: [T]
    let transform: (T) -> any ByteStreamable
    let separator: String

    func writeTo(_ stream: OutputByteStream) {
        for (i, item) in items.enumerated() {
            if i != 0 { stream <<< separator }
            stream <<< transform(item)
        }
    }
}

// Not nested because it is generic.
private struct JSONEscapedTransformedStringListStreamable<T>: ByteStreamable {
    let items: [T]
    let transform: (T) -> String

    func writeTo(_ stream: OutputByteStream) {
        stream <<< UInt8(ascii: "[")
        for (i, item) in items.enumerated() {
            if i != 0 { stream <<< UInt8(ascii: ",") }
            stream <<< Format.asJSON(transform(item))
        }
        stream <<< UInt8(ascii: "]")
    }
}

/// Provides operations for returning derived streamable objects to implement various forms of formatted output.
public enum Format: Sendable {
    /// Write the input string encoded as a JSON object.
    static public func asJSON(_ string: String) -> any ByteStreamable {
        return JSONEscapedStringStreamable(value: string)
    }
    private struct JSONEscapedStringStreamable: ByteStreamable {
        let value: String

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "\"")
            stream.writeJSONEscaped(value)
            stream <<< UInt8(ascii: "\"")
        }
    }

    /// Write the input byte string encoded as a JSON string.
    static public func asJSON(_ string: ByteString) -> any ByteStreamable {
        return JSONEscapedByteStringStreamable(value: string)
    }
    private struct JSONEscapedByteStringStreamable: ByteStreamable {
        let value: ByteString

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "\"")
            stream.writeJSONEscaped(string: value.bytes)
            stream <<< UInt8(ascii: "\"")
        }
    }

    /// Write the input string list encoded as a JSON object.
    //
    // FIXME: We might be able to make this more generic through the use of a "JSONEncodable" protocol.
    static public func asJSON(_ items: [String]) -> any ByteStreamable {
        return JSONEscapedStringListStreamable(items: items)
    }
    private struct JSONEscapedStringListStreamable: ByteStreamable {
        let items: [String]

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "[")
            for (i, item) in items.enumerated() {
                if i != 0 { stream <<< UInt8(ascii: ",") }
                stream <<< Format.asJSON(item)
            }
            stream <<< UInt8(ascii: "]")
        }
    }

    /// Write the input byte string list encoded as a JSON object.
    //
    // FIXME: We might be able to make this more generic through the use of a "JSONEncodable" protocol.
    static public func asJSON(_ items: [ByteString]) -> any ByteStreamable {
        return JSONEscapedByteStringListStreamable(items: items)
    }
    private struct JSONEscapedByteStringListStreamable: ByteStreamable {
        let items: [ByteString]

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "[")
            for (i, item) in items.enumerated() {
                if i != 0 { stream <<< UInt8(ascii: ",") }
                stream <<< Format.asJSON(item)
            }
            stream <<< UInt8(ascii: "]")
        }
    }

    /// Write the input dictionary encoded as a JSON object.
    static public func asJSON(_ items: KeyValuePairs<String, String>) -> any ByteStreamable {
        return JSONEscapedDictionaryLiteralStreamable(items: items)
    }
    private struct JSONEscapedDictionaryLiteralStreamable: ByteStreamable {
        let items: KeyValuePairs<String, String>

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "{")
            for (offset: i, element: (key: key, value: value)) in items.enumerated() {
                if i != 0 { stream <<< UInt8(ascii: ",") }
                stream <<< Format.asJSON(key) <<< ":" <<< Format.asJSON(value)
            }
            stream <<< UInt8(ascii: "}")
        }
    }

    static public func asJSON(_ items: KeyValuePairs<String, ByteString>) -> any ByteStreamable {
        return JSONEscapedDictionaryByteStringLiteralStreamable(items: items)
    }
    private struct JSONEscapedDictionaryByteStringLiteralStreamable: ByteStreamable {
        let items: KeyValuePairs<String, ByteString>

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "{")
            for (offset: i, element: (key: key, value: value)) in items.enumerated() {
                if i != 0 { stream <<< UInt8(ascii: ",") }
                stream <<< Format.asJSON(key) <<< ":" <<< /*Format.asJSON*/(value) // value is pre-escaped
            }
            stream <<< UInt8(ascii: "}")
        }
    }

    /// Write the input dictionary encoded as a JSON object.
    static public func asJSON(_ items: [(String, String)]) -> any ByteStreamable {
        return JSONEscapedDictionaryStreamable(items: items)
    }
    private struct JSONEscapedDictionaryStreamable: ByteStreamable {
        let items: [(String, String)]

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "{")
            for i in 0..<items.count {
                let (key: key, value: value) = items[i]
                if i != 0 { stream <<< UInt8(ascii: ",") }
                stream <<< Format.asJSON(key) <<< ":" <<< Format.asJSON(value)
            }
            stream <<< UInt8(ascii: "}")
        }
    }

    /// Write the input dictionary encoded as a JSON object.
    static public func asJSON(_ items: [(String, ByteString)]) -> any ByteStreamable {
        return JSONEscapedByteStringPairSequenceStreamable(items: items)
    }
    private struct JSONEscapedByteStringPairSequenceStreamable: ByteStreamable {
        let items: [(String, ByteString)]

        func writeTo(_ stream: OutputByteStream) {
            stream <<< UInt8(ascii: "{")
            for i in 0..<items.count {
                let (key: key, value: value) = items[i]
                if i != 0 { stream <<< UInt8(ascii: ",") }
                stream <<< Format.asJSON(key) <<< ":" <<< /*Format.asJSON*/(value) // value is pre-escaped
            }
            stream <<< UInt8(ascii: "}")
        }
    }

    /// Write the input list (after applying a transform to each item) encoded as a JSON object.
    //
    // FIXME: We might be able to make this more generic through the use of a "JSONEncodable" protocol.
    static public func asJSON<T>(_ items: [T], transform: @escaping (T) -> String) -> any ByteStreamable {
        return JSONEscapedTransformedStringListStreamable(items: items, transform: transform)
    }

    /// Write the input list to the stream with the given separator between items.
    static public func asSeparatedList<T: ByteStreamable>(_ items: [T], separator: String) -> any ByteStreamable {
        return SeparatedListStreamable(items: items, separator: separator)
    }

    /// Write the input list to the stream (after applying a transform to each item) with the given separator between items.
    static public func asSeparatedList<T>(_ items: [T], transform: @escaping (T) -> any ByteStreamable, separator: String) -> any ByteStreamable {
        return TransformedSeparatedListStreamable(items: items, transform: transform, separator: separator)
    }
}
