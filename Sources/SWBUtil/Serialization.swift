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

public import class Foundation.JSONDecoder
public import class Foundation.JSONEncoder
public import struct Foundation.Data
public import struct Foundation.Date
public import protocol Foundation.LocalizedError

// MARK: Serializer and Deserializer protocols


/// A `Serializer` is used to create a serialized `ByteString` representation of a collection of objects or other data, suitable for writing as a single file or otherwise transporting as a single piece of data.  Classes or structs to be serialized by adopt either the `Serializable` or `PolymorphicSerializable` protocols.  Many common built-in types already adopt `Serializable` through extensions.
///
/// An element is serialized by invoking the serializer like so:
///
///     serializer.serialize(element)
///
/// For custom elements such as classes which have multiple elements, serialization of the elements should be bracketed by `beginAggregate()` and `endAggregate()` calls, with the former containing the number of elements.  For example:
///
///     serializer.beginAggregate(3)
///     serializer.serialize(firstElement)
///     serializer.serialize(secondElement)
///     serializer.serialize(thirdElement)
///     serializer.endAggregate()
///
/// For class hierarchies, each subclass should invoke `super.serialize(to:)` as defined in the `Serializable` protocol, and the super invocation should be treated as a separate element (which itself should bracket its elements with `beginAggregate()` and `endAggregate()`), for example:
///
///     serializer.beginAggregate(3)
///     serializer.serialize(firstElement)
///     serializer.serialize(secondElement)
///     super.serialize(to: serializer)
///     serializer.endAggregate()
///
/// A `Serializer` can be instantiated with a `SerializerDelegate` object to provide custom behavior or record information during serialization.
public protocol Serializer
{
    init(delegate: (any SerializerDelegate)?)

    /// The `ByteString` containing the serialized data.
    var byteString: ByteString { get }

    var delegate: (any SerializerDelegate)? { get }

    /// Serialize an `Int`.
    func serialize(_ int: Int)

    /// Serialize a `UInt`.
    func serialize(_ uint: UInt)

    /// Serialize a `UInt8`.
    func serialize(_ byte: UInt8)

    /// Serialize a `Bool`.
    func serialize(_ bool: Bool)

    /// Serialize a `Float32`.
    func serialize(_ float: Float32)

    /// Serialize a `Float64`.
    func serialize(_ float: Float64)

    /// Serialize a `String`.
    func serialize(_ string: String)

    // Serialize an array of bytes.
    func serialize(_ bytes: [UInt8])

    // Serialize a date.
    func serialize(_ date: Date)

    /// Serialize a `Serializable` scalar element.
    func serialize<T: Serializable>(_ object: T)

    /// Serialize an `Array` whose elements are `Serializable`.
    func serialize<T: Serializable>(_ array: [T])

    /// Serialize a `Dictionary` whose keys and values are `Serializable`.
    func serialize<Tk: Serializable & Comparable, Tv: Serializable>(_ dict: [Tk: Tv])

    func serialize<Tk: Serializable & Comparable, Tv: Serializable>(_ dict: [Tk: [Tv]])

    func serialize<Tk: Serializable & Comparable, Tv: Serializable>(_ dict: [Tk?: [Tv]])

    /// Serialize `nil`.
    func serializeNil()

    /// Begin serializing an aggregate element as an array scalar, by noting the number of individual elements that make up the aggregate element.
    func beginAggregate(_ count: Int)

    /// End serializing an aggregate element as an array scalar.
    func endAggregate()
}

public extension Serializer
{
    /// Convenience function for serializing a single value to bytes.
    static func serialize<T: Serializable>(_ value: T, delegate: (any SerializerDelegate)? = nil) -> ByteString
    {
        let serializer = Self.init(delegate: delegate)
        value.serialize(to: serializer)
        return serializer.byteString
    }

    /// Serialize an optional `Serializable` scalar element.
    func serialize<T: Serializable>(_ optional: T?)
    {
        guard let element = optional else { self.serializeNil(); return }
        self.serialize(element)
    }

    /// Serialize an optional array of bytes.
    func serialize(_ optional: [UInt8]?)
    {
        guard let element = optional else { self.serializeNil(); return }
        self.serialize(element)
    }

    // Serialize a date.
    func serialize(_ date: Date)
    {
        self.serialize(date.timeIntervalSinceReferenceDate)
    }

    /// Serialize an optional `Array` whose elements are `Serializable`.
    func serialize<T: Serializable>(_ optional: [T]?)
    {
        guard let array = optional else { self.serializeNil(); return }
        self.serialize(array)
    }

    func serialize<T: Serializable>(_ array: [[T]])
    {
        self.serializeAggregate(2) {
            self.serialize(array.count as Int)
            self.serializeAggregate(array.count) {
                for x in array {
                    self.serialize(x)
                }
            }
        }
    }

    /// Serialize an optional `Dictionary` whose keys and values are `Serializable`.
    func serialize<Tk: Serializable & Comparable, Tv: Serializable>(_ optional: [Tk: Tv]?)
    {
        guard let dict = optional else { self.serializeNil(); return }
        self.serialize(dict)
    }

    /// Serialize a `PolymorphicSerializable` element.
    func serialize<T: PolymorphicSerializable>(_ object: T)
    {
        let wrappedElement = PolymorphicSerializableWrapper<T>(object)
        self.serialize(wrappedElement)
    }

    /// Serialize an `Array` whose elements are `PolymorphicSerializable`.
    func serialize<T: PolymorphicSerializable>(_ array: [T])
    {
        let wrappedElements = array.map { PolymorphicSerializableWrapper<T>($0) }
        self.serialize(wrappedElements)
    }

    /// Serialize a `Dictionary` whose keys are `Serializable` and whose values are `PolymorphicSerializable`.
    func serialize<Tk: Serializable & Comparable, Tv: PolymorphicSerializable>(_ dict: [Tk: Tv])
    {
        var wrappedDict = [Tk: PolymorphicSerializableWrapper<Tv>](minimumCapacity: dict.count)
        for (key, value) in dict.sorted(byKey: <)
        {
            wrappedDict[key] = PolymorphicSerializableWrapper<Tv>(value)
        }
        self.serialize(wrappedDict)
    }

    /// Serialize a `Dictionary` whose keys are `PolymorphicSerializable` and whose values are `Serializable`.
    func serialize<Tk: PolymorphicSerializable & Comparable, Tv: Serializable>(_ dict: [Tk: Tv])
    {
        // In order to do this, we serialize the dictionary as a sequence of key-value pairs, so that we don't need to make PolymorphicSerializableWrapper<Tk> conform to Hashable and Equatable.
        self.beginAggregate(dict.count)
        for (key, value) in dict.sorted(byKey: <)
        {
            // Each pair is encoded as a 2-element sequence.
            self.beginAggregate(2)
            self.serialize(key)
            self.serialize(value)
            self.endAggregate()
        }
        self.endAggregate()
    }

    /// Serialize a `Dictionary` whose keys and values are `PolymorphicSerializable`.
    func serialize<Tk: PolymorphicSerializable & Comparable, Tv: PolymorphicSerializable>(_ dict: [Tk: Tv])
    {
        // In order to do this, we serialize the dictionary as a sequence of key-value pairs, so that we don't need to make PolymorphicSerializableWrapper<Tk> conform to Hashable and Equatable.
        self.beginAggregate(dict.count)
        for (key, value) in dict.sorted(byKey: <)
        {
            // Each pair is encoded as a 2-element sequence.
            self.beginAggregate(2)
            self.serialize(key)
            self.serialize(value)
            self.endAggregate()
        }
        self.endAggregate()
    }

    /// Serialize an optional `PolymorphicSerializable` element.
    func serialize<T: PolymorphicSerializable>(_ optional: T?)
    {
        guard let element = optional else { self.serializeNil(); return }
        self.serialize(element)
    }

    /// Serialize an optional `Array` whose elements are `PolymorphicSerializable`.
    func serialize<T: PolymorphicSerializable>(_ optional: [T]?)
    {
        guard let array = optional else { self.serializeNil(); return }
        self.serialize(array)
    }

    /// Serialize an optional `Dictionary` whose keys are `Serializable` and whose values are `PolymorphicSerializable`.
    func serialize<Tk: Serializable & Comparable, Tv: PolymorphicSerializable>(_ optional: [Tk: Tv]?)
    {
        guard let dict = optional else { self.serializeNil(); return }
        self.serialize(dict)
    }


    /// Serialize an optional `Dictionary` whose keys are `PolymorphicSerializable` and whose values are `Serializable`.
    func serialize<Tk: PolymorphicSerializable & Comparable, Tv: Serializable>(_ optional: [Tk: Tv]?)
    {
        guard let dict = optional else { self.serializeNil(); return }
        self.serialize(dict)
    }

    /// Serialize an optional `Dictionary` whose keys and values are `PolymorphicSerializable`.
    func serialize<Tk: PolymorphicSerializable & Comparable, Tv: PolymorphicSerializable>(_ optional: [Tk: Tv]?)
    {
        guard let dict = optional else { self.serializeNil(); return }
        self.serialize(dict)
    }

    func serialize<T: Serializable>(_ range: Range<T>) {
        self.serializeAggregate(2) {
            self.serialize(range.lowerBound)
            self.serialize(range.upperBound)
        }
    }

    /// Shorthand for { beginAggregate(count); f(); endAggregate() }
    func serializeAggregate(_ count: Int, _ f: () -> Void) {
        self.beginAggregate(count)
        f()
        self.endAggregate()
    }
}

/// Protocol for a delegate to be used by an instance of a `Serializer`.
///
/// Such a delegate will typically be used to record information during the course of serializing an object graph to to be used later in the serialization process.  For example, to associate identifiers with a number of serialized objects so that later serializations of those objects can serialize the identifiers as references to the objects rather than serializing the objects multiple times.
///
/// Typically an object's `serialize(to:)` method will retrieve the delegate like this:
///
///     guard var delegate = serializer.delegate as? ConcreteSerializerDelegate else { fatalError("delegate must be a ConcreteSerializerDelegate") }
///
/// `let` may be used instead of `var` if the object is not modifying the content of the delegate.
public protocol SerializerDelegate: AnyObject
{
}


/// A `Deserializer` is used to unpack a serialized `ByteString` representation of a collection of objects or other data which was serialized with a corresponding `Serializer`.
///
/// An element is deserialized by invoking the deserializer in a context where the type to be deserializer can be inferred by the compiler, like so:
///
///     self.element = try deserializer.deserialize()
///
/// The deserializer will throw a `DeserializerError` if an error is encountered during deserialization.
///
/// For custom elements such as classes which have multiple elements, deserialization should be preceded by a call to `beginAggregate()` with the expected number of elements to be deserialized, for example:
///
///     try deserializer.beginAggregate(3)
///     self.firstElement = try deserializer.deserialize()
///     self.secondElement = try deserializer.deserialize()
///     self.thirdElement = try deserializer.deserialize()
///
/// Unlike serialization, no corresponding `endAggregate()` call is needed.
///
/// Alternately, `beginAggregate()` can be called without a parameter, and it will return the number of elements to be deserialized.  This is useful when deserializing a variable-count aggregate, such as an array of elements.
///
/// For class hierarchies, each subclass should invoke `super.init(from:)` as defined in the `Serializable` protocol, and the super invocation should be treated as a separate element (which itself should start with a call to `beginAggregate()`), for example:
///
///     try deserializer.beginAggregate(3)
///     self.firstElement = try deserializer.deserialize()
///     self.secondElement = try deserializer.deserialize()
///     try super.init(from: deserializer)
///
/// A `Deserializer` can be instantiated with a `DeserializerDelegate` object to provide custom behavior or record information during deserialization.
public protocol Deserializer
{
    init(_ bytes: ArraySlice<UInt8>, delegate: (any DeserializerDelegate)?)

    var delegate: (any DeserializerDelegate)? { get }

    /// Deserialize an `Int`.  Throws if the next item to be deserialized is not an `Int`.
    func deserialize() throws -> Int

    /// Deserialize a `UInt`.  Throws if the next item to be deserialized is not a `UInt`.
    func deserialize() throws -> UInt

    /// Deserialize a `UInt8`.  Throws if the next item to be deserialized is not a `UInt8`.
    func deserialize() throws -> UInt8

    /// Deserialize a `Bool`.  Throws if the next item to be deserialized is not a `Bool`.
    func deserialize() throws -> Bool

    /// Deserialize a `Float32`.  Throws if the next item to be deserialized is not a `Float32`.
    func deserialize() throws -> Float32

    /// Deserialize a `Float64`.  Throws if the next item to be deserialized is not a `Float64`.
    func deserialize() throws -> Float64

    /// Deserialize a `String`.  Throws if the next item to be deserialized is not a `String`.
    func deserialize() throws -> String

    /// Deserialize an array of bytes.  Throws if the next item to be deserialized is not such an array.
    func deserialize() throws -> [UInt8]

    /// Deserialize a date.  Throws if the next item to be deserialized is not such a date.
    func deserialize() throws -> Date

    /// Deserialize a `Serializable` scalar element.
    func deserialize<T: Serializable>() throws -> T

    /// Deserialize an `Array`.  Throws if the next item to be deserialized is not an `Array`, or if the array could not be read.
    func deserialize<T: Serializable>() throws -> [T]

    /// Deserialize a `Dictionary` whose keys and values are `Serializable`.  Throws if the next item to be deserialized is not a `Dictionary`, or if the dictionary could not be read.
    func deserialize<Tk: Serializable, Tv: Serializable>() throws -> [Tk: Tv]

    func deserialize<Tk: Serializable, Tv: Serializable>() throws -> [Tk: [Tv]]

    func deserialize<Tk: Serializable, Tv: Serializable>() throws -> [Tk?: [Tv]]

    /// Deserialize `nil`.  Returns `true` if nil was deserialized.  If `nil` could not be deserialized, then returns `false` and does not consume any data from the byte string.
    func deserializeNil() -> Bool

    /// Begin deserializing an aggregate element.  Throws if the next item to be deserialized is not an aggregate.
    /// - parameter expectedCount: Throws if the number of elements to be deserialized is not in this range.
    ///
    /// This can be used to more conveniently let a `Serializable` type handle older versions with different numbers of fields,
    /// by taking different branches depending on the number of fields present in the serialized data.
    func beginAggregate(_ range: CountableClosedRange<Int>) throws -> Int

    /// Begin deserializing an aggregate element.  Throws if the next item to be deserialized is not an aggregate.
    /// - parameter expectedCount: Throws if the number of elements to be deserialized is not this number.
    func beginAggregate(_ expectedCount: Int) throws

    /// Begin deserializing an aggregate element.  Throws if the next item to be deserialized is not an aggregate.
    /// - returns: The count of elements serialized.
    func beginAggregate() throws -> Int
}


public extension Deserializer
{
    /// Convenience function for serializing a single value from bytes.
    static func deserialize<T: Serializable>(_ bytes: ByteString, delegate: (any DeserializerDelegate)? = nil) throws -> T
    {
        let deserializer = Self.init(bytes, delegate: delegate)
        return try deserializer.deserialize()
    }

    init(_ byteString: ByteString, delegate: (any DeserializerDelegate)? = nil)
    {
        self.init(ArraySlice(byteString.bytes), delegate: delegate)
    }

    /// Deserialize an optional `Serializable` scalar element.
    func deserialize<T: Serializable>() throws -> T?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as T)
    }

    /// Deserialize an optional array of bytes.
    func deserialize() throws -> [UInt8]?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as [UInt8])
    }

    /// Deserialize a date.
    func deserialize() throws -> Date
    {
        return try Date(timeIntervalSinceReferenceDate: self.deserialize())
    }

    /// Deserialize an optional `Array`.  Throws if the next item to be deserialized is not nil or an `Array`, or if the array could not be read.
    func deserialize<T: Serializable>() throws -> [T]?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as [T])
    }

    func deserialize<T: Serializable>() throws -> [[T]]
    {
        try beginAggregate(2)
        let count = try deserialize() as Int
        guard count >= 0 else { throw DeserializerError.unexpectedValue("Expected array count >= 0") }

        try beginAggregate(count)
        var result = [[T]]()
        result.reserveCapacity(count)

        for _ in 0 ..< count {
            result.append(try deserialize())
        }

        return result
    }

    /// Deserialize an optional `Dictionary` whose keys and values are `Serializable`.  Throws if the next item to be deserialized is not nil or a `Dictionary`, or if the dictionary could not be read.
    func deserialize<Tk: Serializable, Tv: Serializable>() throws -> [Tk: Tv]?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as [Tk: Tv])
    }

    /// Deserialize a `PolymorphicSerializable` element.
    func deserialize<T: PolymorphicSerializable>() throws -> T
    {
        let wrappedElement: PolymorphicSerializableWrapper<T> = try self.deserialize()
        return wrappedElement.value
    }

    /// Deserialize an `Array` whose elements are `PolymorphicSerializable`.
    func deserialize<T: PolymorphicSerializable>() throws -> [T]
    {
        let wrappedElements: [PolymorphicSerializableWrapper<T>] = try self.deserialize()
        return wrappedElements.map { $0.value }
    }

    /// Deserialize a `Dictionary` whose keys are `Serializable` and whose values are `PolymorphicSerializable`.
    func deserialize<Tk: Serializable, Tv: PolymorphicSerializable>() throws -> [Tk: Tv]
    {
        let wrappedDict: [Tk: PolymorphicSerializableWrapper<Tv>] = try self.deserialize()
        var dict = [Tk: Tv](minimumCapacity: wrappedDict.count)
        for (key, wrappedValue) in wrappedDict
        {
            dict[key] = wrappedValue.value
        }
        return dict
    }

    /// Deserialize a `Dictionary` whose keys are `PolymorphicSerializable` and whose values are `Serializable`.
    func deserialize<Tk: PolymorphicSerializable, Tv: Serializable>() throws -> [Tk: Tv]
    {
        // The dictionary is serialized as a sequence of key-value pairs.
        let count = try self.beginAggregate()
        guard count > 0 else { return [:] }
        var dict = [Tk: Tv](minimumCapacity: count)
        for _ in 1...count
        {
            // Each pair is encoded as a 2-element sequence.
            try self.beginAggregate(2)
            let key: PolymorphicSerializableWrapper<Tk> = try self.deserialize()
            let value: Tv = try self.deserialize()
            dict[key.value] = value
        }
        return dict
    }

    /// Deserialize a `Dictionary` whose keys and values are `PolymorphicSerializable`.
    func deserialize<Tk: PolymorphicSerializable, Tv: PolymorphicSerializable>() throws -> [Tk: Tv]
    {
        // The dictionary is serialized as a sequence of key-value pairs.
        let count = try self.beginAggregate()
        guard count > 0 else { return [:] }
        var dict = [Tk: Tv](minimumCapacity: count)
        for _ in 1...count
        {
            // Each pair is encoded as a 2-element sequence.
            try self.beginAggregate(2)
            let key: PolymorphicSerializableWrapper<Tk> = try self.deserialize()
            let value: Tv = try self.deserialize()
            dict[key.value] = value
        }
        return dict
    }

    /// Deserialize an optional `PolymorphicSerializable` element.
    func deserialize<T: PolymorphicSerializable>() throws -> T?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as T)
    }

    /// Deserialize an optional `Array` whose elements are `PolymorphicSerializable`.
    func deserialize<T: PolymorphicSerializable>() throws -> [T]?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as [T])
    }

    /// Deserialize an optional `Dictionary` whose keys are `Serializable` and whose values are `PolymorphicSerializable`.
    func deserialize<Tk: Serializable, Tv: PolymorphicSerializable>() throws -> [Tk: Tv]?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as [Tk: Tv])
    }

    /// Deserialize an optional `Dictionary` whose keys are `PolymorphicSerializable` and whose values are `Serializable`.
    func deserialize<Tk: PolymorphicSerializable, Tv: Serializable>() throws -> [Tk: Tv]?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as [Tk: Tv])
    }

    /// Deserialize an optional `Dictionary` whose keys and values are `PolymorphicSerializable`.
    func deserialize<Tk: PolymorphicSerializable, Tv: PolymorphicSerializable>() throws -> [Tk: Tv]?
    {
        return self.deserializeNil() ? nil : (try self.deserialize() as [Tk: Tv])
    }

    func deserialize<T: Serializable>() throws -> Range<T> {
        try self.beginAggregate(2)
        let lower: T = try self.deserialize()
        let upper: T = try self.deserialize()
        return Range(uncheckedBounds: (lower: lower, upper: upper))
    }

    /// Deserializes `nil` and throws DeserializerError.incorrectType if it fails.
    func deserializeNilThrow() throws {
        if !self.deserializeNil() {
            throw DeserializerError.incorrectType("expected nil")
        }
    }
}


/// Protocol for a delegate to be used by an instance of a `Deserializer`.
///
/// Such a delegate typically has two purposes:
///
/// 1. For the creator of the `Deserializer` to provide context objects to be used during deserialization.  For example, to look up objects using identifiers being deserialized in a context outside of the deserializer.
/// 2. To to record information during the course of deserializing an object graph to to be used later in the deserialization process.  For example, to associate identifiers with a number of serialized objects so that when those identifiers are encountered later in deserialization, the previously-deserialized objects can be re-used rather than creating new ones.  If the delegate is used for this purpose, then it should be a class and not a struct.
///
/// Typically an object's `init(from:)` method will retrieve the delegate like this:
///
///     guard var delegate = deserializer.delegate as? ConcreteDeserializerDelegate else { throw DeserializerError.invalidDelegate("delegate must be a ConcreteDeserializerDelegate") }
///
/// `let` may be used instead of `var` if the object is not modifying the content of the delegate.
public protocol DeserializerDelegate
{
}


public enum DeserializerError: Swift.Error, LocalizedError, CustomStringConvertible
{
    /// A class' `init(from:)` method can throw this error if it does not get the type of `DeserializerDelegate` it expects.
    case invalidDelegate(String)
    /// This error is thrown if the type of the next item to be deserialized is not of the expected type.
    case incorrectType(String)
    /// This error is thrown if a value used in the encoding was unexpected (for example, an known type code).
    case unexpectedValue(String)
    /// This error is thrown if deserialization of one or more elements failed.
    case deserializationFailed(String)

    public var description: String {
        switch self {
        case .invalidDelegate(let str):
            return "Invalid deserializer delegate: \(str)"
        case .incorrectType(let str):
            return "Deserialized incorrect type: \(str)"
        case .unexpectedValue(let str):
            return "Deserialized unexpected value: \(str)"
        case .deserializationFailed(let str):
            return "Deserialization failed: \(str)"
        }
    }

    public var errorDescription: String? { description }

    public var errorString: String
    {
        switch self
        {
            case .invalidDelegate(let str): return str
            case .incorrectType(let str): return str
            case .unexpectedValue(let str): return str
            case .deserializationFailed(let str): return str
        }
    }
}


// MARK: Serializable protocol


/// Protocol for simple types which can be serialized.
///
/// Class hierarchies should adopt `PolymorphicSerializable` instead.
public protocol Serializable
{
    /// Serialize the receiver.
    func serialize<T: Serializer>(to serializer: T)

    /// Create a new instance of the receiver from a deserializer.
    init(from deserializer: any Deserializer) throws
}

private enum LegacyDecodingError: Error {
    case legacyDecodingNotImplemented
}

public protocol SerializableCodable: Serializable, Codable {
    init(fromLegacy deserializer: any Deserializer) throws
}

extension SerializableCodable {
    public func serialize<T>(to serializer: T) where T : Serializer {
        try! serializer.serialize(Array(JSONEncoder(outputFormatting: [.sortedKeys, .withoutEscapingSlashes]).encode(self)))
    }

    public init(from deserializer: any Deserializer) throws {
        let data: Data
        do {
            data = try Data(deserializer.deserialize())
        } catch let newError {
            do {
                self = try .init(fromLegacy: deserializer)
                return
            } catch LegacyDecodingError.legacyDecodingNotImplemented {
                // If we didn't implement legacy decoding for this type, throw the original error from the new decoder
                throw newError
            }
        }

        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        throw LegacyDecodingError.legacyDecodingNotImplemented
    }
}

/// May be used to migrate a Serializable type to SerializableCodable without requiring an updated client immediately. Types conforming to this protocol will still use legacy serialization, but support legacy or codable deserialization. Once client versions in use all support deserializing the codable representation, these types can switch to `SerializableCodable`.
public protocol PendingSerializableCodable: Serializable, Codable {
    func legacySerialize<T>(to serializer: T) where T : Serializer
    init(fromLegacy deserializer: any Deserializer) throws
}

extension PendingSerializableCodable {
    public func serialize<T>(to serializer: T) where T : Serializer {
        legacySerialize(to: serializer)
    }

    public init(from deserializer: any Deserializer) throws {
        let data: Data
        do {
            data = try Data(deserializer.deserialize())
        } catch let newError {
            do {
                self = try .init(fromLegacy: deserializer)
                return
            } catch LegacyDecodingError.legacyDecodingNotImplemented {
                // If we didn't implement legacy decoding for this type, throw the original error from the new decoder
                throw newError
            }
        }

        self = try JSONDecoder().decode(Self.self, from: data)
    }
}

// MARK: PolymorphicSerializable protocol.


/// Protocol for types which can be serialized as polymorphic elements, where the type of each element is read during deserialization so the correct class or struct can be instantiated.  The top-level class typically will implement `classForCode()` to return the class to be instantiated based on the code it is passed by the deserializer, while all classes will implement the other methods.  Each class should return a unique value for `serializableTypeCode`, although this is not enforced.
///
/// Elements of these types will be wrapped in a `PolymorphicSerializableWrapper` struct to be serialized.  They should never be serialized directly (which is why this protocol does not adopt `Serializable`).
///
/// `PolymorphicSerializable` does not support serializing multiple types of a given protocol, because deserialization cannot infer the type to instantiate if all it has to work with is the protocol.  A class hierarchy should be used instead.
public protocol PolymorphicSerializable
{
    /// Serialize the receiver.
    func serialize<T: Serializer>(to serializer: T)

    /// Create a new instance of the receiver from a deserializer.
    init(from deserializer: any Deserializer) throws

    /// PolymorphicSerializable requires a closed set of implementations.
    static var implementations: [SerializableTypeCode: any PolymorphicSerializable.Type] { get }
}

extension PolymorphicSerializable {

    public static var serializableTypeCode: SerializableTypeCode {
        for (i, t) in self.implementations {
            if self == t {
                return i
            }
        }

        fatalError("Unknown implementation \(self): every implementation needs to be listed in `implementations`")
    }

    /// Returns the class to use to create a new instance of the receiver based on the type code for that receiver.
    public static func classForCode(_ code: SerializableTypeCode) -> (any PolymorphicSerializable.Type)? {
        return self.implementations[code]
    }

}

public typealias SerializableTypeCode = UInt


/// A wrapper for a user-defined type which can be serialized as aggregate elements.
fileprivate struct PolymorphicSerializableWrapper<T: PolymorphicSerializable>: Serializable
{
    /// The element being wrapped.
    let value: T

    /// Wrap the element for serialization.
    init(_ value: T)
    {
        self.value = value
    }

    /// Serialize the wrapper - including the type code for the element - and the element.
    func serialize<S: Serializer>(to serializer: S)
    {
        serializer.beginAggregate(2)
        type(of: self.value).serializableTypeCode.serialize(to: serializer)
        self.value.serialize(to: serializer)
        serializer.endAggregate()
    }

    /// Create a new instance of the wrapper with an instance of the wrapped element inside it.
    init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        let code: SerializableTypeCode = try deserializer.deserialize()
        guard let classType = T.classForCode(code) else { throw DeserializerError.incorrectType("Unexpected serializable type code for concrete '\(type(of: T.self))': \(code)") }
        self = PolymorphicSerializableWrapper(try classType.init(from: deserializer) as! T)
    }
}


// MARK: Serialization for built-in types


extension Int: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        self = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(self)
    }
}

extension UInt: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        self = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(self)
    }
}

extension Int32: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        // We use `truncatingBitPattern` here because we encode 32-bit values as normal UInts. It is up to the client to never use this in a way which could lose bits.
        self = Int32(try deserializer.deserialize() as Int)
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(Int(self))
    }
}

extension UInt32: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        // We use `truncatingBitPattern` here because we encode 32-bit values as normal UInts. It is up to the client to never use this in a way which could lose bits.
        self = UInt32(truncatingIfNeeded: try deserializer.deserialize() as UInt)
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(UInt(self))
    }
}

extension Int64: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        // We assume that this is a lossless conversion which should have no type checks.
        self = Int64(try deserializer.deserialize() as Int)
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        // Despite the name here, we expect UInt to always be 64-bits and thus this does not truncate.
        assert(Int64(Int(truncatingIfNeeded: self)) == self)
        serializer.serialize(Int(truncatingIfNeeded: self))
    }
}

extension UInt64: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        // We assume that this is a lossless conversion which should have no type checks.
        self = UInt64(try deserializer.deserialize() as UInt)
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        // Despite the name here, we expect UInt to always be 64-bits and thus this does not truncate.
        assert(UInt64(UInt(truncatingIfNeeded: self)) == self)
        serializer.serialize(UInt(truncatingIfNeeded: self))
    }
}

extension Bool: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        self = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(self)
    }
}

extension Float32: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        self = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(self)
    }
}

extension Float64: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        self = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(self)
    }
}

extension String: Serializable
{
    public init(from deserializer: any Deserializer) throws
    {
        self = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serialize(self)
    }
}

extension RawRepresentable where Self: Serializable, RawValue: Serializable {
    public init(from deserializer: any Deserializer) throws {
        let rawValue: RawValue = try deserializer.deserialize()
        guard let r = Self(rawValue: rawValue) else {
            throw DeserializerError.incorrectType("Unexpected raw value \(rawValue) for type \(Self.self)")
        }

        self = r
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serialize(self.rawValue)
    }
}

extension Set: Serializable where Element: Serializable & Comparable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serialize(sorted())
    }

    public init(from deserializer: any Deserializer) throws {
        self.init(try deserializer.deserialize() as [Element])
    }
}

extension OrderedSet: Serializable where Element: Serializable {
    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serialize(elements)
    }

    public init(from deserializer: any Deserializer) throws {
        self.init(try deserializer.deserialize() as [Element])
    }
}

// MARK: Encoder and Decoder protocols


protocol Encoder: AnyObject
{
    /// The byte array containing the encoded data.
    var bytes: [UInt8] { get }

    /// Append an `Int64` to the encoded bytes.
    func append(_ i: Int64)

    /// Append a `UInt64` to the encoded bytes.
    func append(_ i: UInt64)

    /// Append a `UInt8` to the encoded bytes.
    func append(_ i: UInt8)

    /// Append nil to the encoded bytes.
    func appendNil()

    /// Append a `Bool` to the encoded bytes.
    func append(_ b: Bool)

    /// Append a `Float32` to the encoded bytes.
    func append(_ f: Float32)

    /// Append a `Float64` to the encoded bytes.
    func append(_ f: Float64)

    /// Append a `String` to the encoded bytes.
    func append(_ s: String)

    /// Append an array of bytes to the encoded bytes.
    func append(_ dataBytes: [UInt8])

    /// Append an array of elements to the encoded bytes.  `encode` must be a closure which will encode the element passed to it from the `Encoder`.
    func append<T>(_ array: [T], encode: (T) -> Void)

    /// Append a dictionary of keys and values to the encoded bytes.  `encodeKey` and `encodeValue` must be closures which will encode the elements passed to them from the `Encoder`.
    func append<Tk: Comparable, Tv>(_ dict: [Tk: Tv], encodeKey: (Tk) -> Void, encodeValue: (Tv) -> Void)

    /// Append extended data to the encoded bytes.
    func appendExtended(type: Int8, data: [UInt8])

    /// Begin adding an array of elements to the encoded bytes, starting with the number of elements.
    func beginArray(_ count: Int)

    /// End adding an array of elements to the encoded bytes.
    func endArray()
}


protocol Decoder: AnyObject
{
    /// Decode an `Int64` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not an `Int64`.
    func readInt64() -> Int64?

    /// Decode a `UInt64` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not a `UInt64`.
    func readUInt64() -> UInt64?

    /// Decode a `UInt8` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not a `UInt8`.
    func readByte() -> UInt8?

    /// Decode `nil` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not a `nil`.
    func readNil() -> Bool

    /// Decode a `Bool` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not a `Bool`.
    func readBool() -> Bool?

    /// Decode a `Float32` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not a `Float32`.
    func readFloat32() -> Float32?

    /// Decode a `Float64` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not a `Float64`.
    func readFloat64() -> Float64?

    /// Decode a `String` from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not a `String`.
    func readString() -> String?

    /// Decode an array of bytes from the encoded bytes and consume that item.  Returns nil and does not consume the next item if it is not an array of bytes.
    func readBinary() -> [UInt8]?

    /// Decode an array of elements from the encoded bytes and consume them.  Returns nil if the next item is not the beginning of an array or if anything in the array cannot be decoded - however the decoder may be left in a bad state if this happens.
    /// - parameter decodeElement: Called to decode each element of the array. This closure should throw an exception if it fails to decode an element.
    func readArray<T>(_ decodeElement: () throws -> T) -> [T]?

    /// Decode an dictionary of keys and values from the encoded bytes and consume them.  Returns nil if the next item is not the beginning of a dictionary or if anything in the dictionary cannot be decoded - however the decoder may be left in a bad state if this happens.
    /// - parameter decodeKey: Called to decode each key of the dictionary. This closure should throw an exception if it fails to decode a key.
    /// - parameter decodeValue: Called to decode each value of the dictionary. This closure should throw an exception if it fails to decode a value.
    func readDictionary<Tk, Tv>(_ decodeKey: () throws -> Tk, _ decodeValue: () throws -> Tv) -> [Tk: Tv]?

    /// Decode extended data from the encoded bytes, returning the type code for the data, and a byte array of the data itself.
    func readExtended() -> (type: Int8, data: [UInt8])?

    /// Begin reading an array of elements from the encoded bytes, by getting the number of elements.  Returns nil if the next item is not the beginning of an array.
    func readBeginArray() -> Int?
}
