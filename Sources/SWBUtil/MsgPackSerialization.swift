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

// MARK: Serializer


public final class MsgPackSerializer: Serializer
{
    static let bytesEncoded = Statistic("MsgPackSerializer.bytesEncoded",
        "The number of bytes encoded by the serializer.")

    private let encoder: any Encoder
    public let delegate: (any SerializerDelegate)?

    public init(delegate: (any SerializerDelegate)? = nil)
    {
        self.encoder = MsgPackEncoder()
        self.delegate = delegate
    }

    deinit
    {
        MsgPackSerializer.bytesEncoded += encoder.bytes.count
    }

    /// The `ByteString` containing the serialized data.
    public var byteString: ByteString { return ByteString(encoder.bytes) }

    /// Serialize an `Int`.
    public func serialize(_ int: Int)
    {
        encoder.append(Int64(int))
    }

    /// Serialize a `UInt`.
    public func serialize(_ uint: UInt)
    {
        encoder.append(UInt64(uint))
    }

    /// Serialize a `UInt8`.
    public func serialize(_ byte: UInt8)
    {
        encoder.append(byte)
    }

    /// Serialize a `Bool`.
    public func serialize(_ bool: Bool)
    {
        encoder.append(bool)
    }

    /// Serialize a `Float32`.
    public func serialize(_ float: Float32)
    {
        encoder.append(float)
    }

    /// Serialize a `Float64`.
    public func serialize(_ float: Float64)
    {
        encoder.append(float)
    }

    /// Serialize a `String`.
    public func serialize(_ string: String)
    {
        encoder.append(string)
    }

    // Serialize an array of bytes.
    public func serialize(_ bytes: [UInt8])
    {
        encoder.append(bytes)
    }

    /// Serialize a `Serializable` scalar element.
    public func serialize<T: Serializable>(_ element: T)
    {
        element.serialize(to: self)
    }

    /// Serialize an `Array` whose elements are `Serializable`.
    public func serialize<T: Serializable>(_ array: [T])
    {
        encoder.append(array) { (element) in self.serialize(element) }
    }

    /// Serialize a `Dictionary` whose keys and values are `Serializable`.
    public func serialize<Tk: Serializable & Comparable, Tv: Serializable>(_ dict: [Tk: Tv])
    {
        encoder.append(dict, encodeKey: { (key) in self.serialize(key) }, encodeValue: { (value) in self.serialize(value) })
    }

    /// Serialize a `Dictionary` whose keys and values are `[Serializable]`.
    public func serialize<Tk: Serializable & Comparable, Tv: Serializable>(_ dict: [Tk: [Tv]])
    {
        encoder.append(dict, encodeKey: { (key) in self.serialize(key) }, encodeValue: { (value) in self.serialize(value) })
    }

    /// Serialize a `Dictionary` whose keys and values are `[Serializable]`.
    public func serialize<Tk: Serializable & Comparable, Tv: Serializable>(_ dict: [Tk?: [Tv]])
    {
        encoder.append(dict, encodeKey: { (key) in self.serialize(key) }, encodeValue: { (value) in self.serialize(value) })
    }

    /// Serialize `nil`.
    public func serializeNil()
    {
        encoder.appendNil()
    }

    /// Begin serializing an aggregate element as a scalar, by noting the number of individual elements that make up the aggregate element.
    public func beginAggregate(_ count: Int)
    {
        encoder.beginArray(count)
    }

    /// End serializing an aggregate element as a scalar.
    public func endAggregate()
    {
        encoder.endArray()
    }
}

@available(*, unavailable)
extension MsgPackSerializer: Sendable { }

// MARK: Deserializer


// FIXME: The exceptions here could be much more descriptive, e.g. when some nested element couldn't be decoded.  I'm not sure whether that improvement is really worth it, though.


public final class MsgPackDeserializer: Deserializer
{
    static let bytesDecoded = Statistic("MsgPackDeserializer.bytesDecoded",
        "The number of bytes decoded by the deserializer.")

    private var decoder: any Decoder
    public let delegate: (any DeserializerDelegate)?

    public init(_ bytes: ArraySlice<UInt8>, delegate: (any DeserializerDelegate)? = nil)
    {
        // Assume the full stream will be decoded.
        MsgPackDeserializer.bytesDecoded += bytes.count

        self.decoder = MsgPackDecoder(bytes)
        self.delegate = delegate
    }

    /// Deserialize an `Int`.  Throws if the next item to be deserialized is not an `Int`.
    public func deserialize() throws -> Int
    {
        guard let int = decoder.readInt64() else { throw DeserializerError.incorrectType("Could not decode an Int64.") }
        return Int(int)
    }

    /// Deserialize a `UInt`.  Throws if the next item to be deserialized is not a `UInt`.
    public func deserialize() throws -> UInt
    {
        guard let uint = decoder.readUInt64() else { throw DeserializerError.incorrectType("Could not decode a UInt64.") }
        return UInt(uint)
    }

    /// Deserialize a `UInt8`.  Throws if the next item to be deserialized is not a `UInt8`.
    public func deserialize() throws -> UInt8
    {
        guard let byte = decoder.readByte() else { throw DeserializerError.incorrectType("Could not decode a UInt8.") }
        return  byte
    }

    /// Deserialize a `Bool`.  Throws if the next item to be deserialized is not a `Bool`.
    public func deserialize() throws -> Bool
    {
        guard let bool = decoder.readBool() else { throw DeserializerError.incorrectType("Could not decode a Bool") }
        return bool
    }

    /// Deserialize a `Float32`.  Throws if the next item to be deserialized is not a `Float32`.
    public func deserialize() throws -> Float32
    {
        guard let float = decoder.readFloat32() else { throw DeserializerError.incorrectType("Could not decode a Float32") }
        return float
    }

    /// Deserialize a `Float64`.  Throws if the next item to be deserialized is not a `Float64`.
    public func deserialize() throws -> Float64
    {
        guard let float = decoder.readFloat64() else { throw DeserializerError.incorrectType("Could not decode a Float64") }
        return float
    }

    /// Deserialize a `String`.  Throws if the next item to be deserialized is not a `String`.
    public func deserialize() throws -> String
    {
        guard let string = decoder.readString() else { throw DeserializerError.incorrectType("Could not decode a String") }
        return string
    }

    /// Deserialize an array of bytes.  Throws if the next item to be deserialized is not such an array.
    public func deserialize() throws -> [UInt8]
    {
        guard let bytes = decoder.readBinary() else { throw DeserializerError.incorrectType("Could not decode an array of bytes") }
        return bytes
    }

    /// Deserialize a `Serializable` scalar element.
    public func deserialize<T: Serializable>() throws -> T
    {
        return try T.init(from: self)
    }

    /// Deserialize an `Array`.  Throws if the next item to be deserialized is not an `Array`, or if the array could not be read.
    public func deserialize<T: Serializable>() throws -> [T]
    {
        guard let array: [T] = decoder.readArray(
            { return try self.deserialize() }
        ) else { throw DeserializerError.deserializationFailed("Could not deserialize an Array.") }
        return array
    }

    /// Deserialize a `Dictionary`.  Throws if the next item to be deserialized is not a `Dictionary`, or if the dictionary could not be read.
    public func deserialize<Tk: Serializable, Tv: Serializable>() throws -> [Tk: Tv]
    {
        guard let dict: [Tk: Tv] = decoder.readDictionary(
            { return try self.deserialize() },
            { return try self.deserialize() }
        ) else { throw DeserializerError.deserializationFailed("Could not deserialize a Dictionary.") }
        return dict
    }

    public func deserialize<Tk: Serializable, Tv: Serializable>() throws -> [Tk: [Tv]]
    {
        guard let dict: [Tk: [Tv]] = decoder.readDictionary(
            { return try self.deserialize() },
            { return try self.deserialize() }
            ) else { throw DeserializerError.deserializationFailed("Could not deserialize a Dictionary.") }
        return dict
    }

    public func deserialize<Tk: Serializable, Tv: Serializable>() throws -> [Tk?: [Tv]]
    {
        guard let dict: [Tk?: [Tv]] = decoder.readDictionary(
            { return try self.deserialize() },
            { return try self.deserialize() }
            ) else { throw DeserializerError.deserializationFailed("Could not deserialize a Dictionary.") }
        return dict
    }

    /// Deserialize `nil`.  Returns `true` if nil was deserialized.  If `nil` could not be deserialized, then returns `false` and does not consume any data from the byte string.
    public func deserializeNil() -> Bool
    {
        return decoder.readNil()
    }

    private func _beginAggregate(_ range: CountableClosedRange<Int>?) throws -> Int {
        guard let count = decoder.readBeginArray() else {
            throw DeserializerError.incorrectType("Could not decode an aggregate element.")
        }

        if let range, !range.contains(count) {
            if range.lowerBound == range.upperBound {
                throw DeserializerError.deserializationFailed("Unexpected count '\(count)' for aggregate element (expected '\(range.lowerBound)').")
            } else {
                throw DeserializerError.deserializationFailed("Unexpected count '\(count)' for aggregate element (expected '\(range.lowerBound)' to '\(range.upperBound)').")
            }
        }

        return count
    }

    public func beginAggregate(_ range: CountableClosedRange<Int>) throws -> Int {
        return try _beginAggregate(range)
    }

    /// Begin deserializing an aggregate element.  Throws if the next item to be deserialized is not an aggregate.
    /// - parameter: expectedCount: Throws if the number of elements to be deserialized is not this number.
    public func beginAggregate(_ expectedCount: Int) throws
    {
        let _ = try beginAggregate(expectedCount...expectedCount)
    }

    /// Begin deserializing an aggregate element.  Throws if the next item to be deserialized is not an aggregate.
    /// - returns: The count of elements serialized.
    public func beginAggregate() throws -> Int
    {
        return try _beginAggregate(nil)
    }
}

@available(*, unavailable)
extension MsgPackDeserializer: Sendable { }

extension Optional: @retroactive Comparable where Wrapped: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            return lhs < rhs
        case (.none, .some):
            return true
        case (.some, .none), (.none, .none):
            return false
        }
    }
}
