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

#if canImport(Darwin)
import class CoreFoundation.CFBoolean
import func CoreFoundation.CFBooleanGetTypeID
import func CoreFoundation.CFBooleanGetValue
import func CoreFoundation.CFEqual
import func CoreFoundation.CFGetTypeID
import func CoreFoundation.CFHash
import class CoreFoundation.CFNumber
import func CoreFoundation.CFNumberGetTypeID
import func CoreFoundation.CFNumberIsFloatType
import typealias CoreFoundation.CFTypeRef
#endif

public import struct Foundation.Data
public import protocol Foundation.DataProtocol
public import struct Foundation.Date
public import class Foundation.JSONDecoder
public import class Foundation.JSONSerialization
public import class Foundation.PropertyListDecoder
public import class Foundation.PropertyListEncoder
public import class Foundation.PropertyListSerialization
public import struct Foundation.URL

public import class Foundation.NSArray
public import class Foundation.NSCoder
public import protocol Foundation.NSCopying
public import class Foundation.NSData
public import class Foundation.NSDictionary
public import class Foundation.NSEnumerator
public import class Foundation.NSMutableArray
public import class Foundation.NSMutableDictionary
public import class Foundation.NSNumber
public import class Foundation.NSObject
public import class Foundation.NSString

public enum PropertyListConversionError: Swift.Error, Equatable {
    case encoderError(String)
    case fileError(POSIXError)
    case invalidStream
    case unknown
}

extension PropertyListConversionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .encoderError(string):
            return "Couldn't encode property list: \(string)"
        case .fileError(let error):
            return "Couldn't read property list: \(error)"
        case .invalidStream:
            return "Couldn't parse property list because the input data was in an invalid format"
        case .unknown:
            return "Unknown error parsing property list"
        }
    }
}

public struct OpaquePropertyListItem: Equatable, Hashable, @unchecked Sendable {
#if canImport(Darwin)
    fileprivate var wrappedValue: CFTypeRef

    fileprivate init(_ wrappedValue: CFTypeRef) {
        self.wrappedValue = wrappedValue
    }

    public static func == (lhs: OpaquePropertyListItem, rhs: OpaquePropertyListItem) -> Bool {
        return CFEqual(lhs.wrappedValue, rhs.wrappedValue)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(wrappedValue))
    }
#else
    fileprivate var wrappedValue: NSObject

    fileprivate init(_ wrappedValue: NSObject) {
        self.wrappedValue = wrappedValue
    }

    public static func == (lhs: OpaquePropertyListItem, rhs: OpaquePropertyListItem) -> Bool {
        return lhs.wrappedValue.isEqual(rhs.wrappedValue)
    }

    public func hash(into hasher: inout Hasher) {
        wrappedValue.hash(into: &hasher)
    }
#endif
}

public enum PropertyListItem: Hashable, Sendable {
    // Scalar types.
    case plBool(Bool)
    case plInt(Int)
    case plString(String)
    case plData([UInt8])
    case plDate(Date)
    case plDouble(Double)

    // Collection types.
    case plArray([PropertyListItem])
    case plDict([String: PropertyListItem])

    // Used to pass through opaque implementation-detail values in certain plists,
    // such as CFKeyedArchiverUIDRef which is used by NSKeyedArchiver
    // (this is Foundation IPI not to be used directly).
    case plOpaque(OpaquePropertyListItem)
}

extension PropertyListItem: Encodable {
    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plBool(let bool):
            try container.encode(bool)
        case .plInt(let int):
            try container.encode(int)
        case .plString(let string):
            try container.encode(string)
        case .plData(let array):
            try container.encode(Data(array))
        case .plDate(let date):
            try container.encode(date)
        case .plDouble(let double):
            try container.encode(double)
        case .plArray(let array):
            try container.encode(array)
        case .plDict(let dictionary):
            try container.encode(dictionary)
        case .plOpaque:
            throw DecodingError.typeMismatch(PropertyListItem.self, .init(codingPath: container.codingPath, debugDescription: "Unexpected property list type"))
        }
    }
}

extension PropertyListItem: Decodable {
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            self = .plBool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .plInt(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .plString(stringValue)
        } else if decoder is PropertyListDecoder, let dataValue = try? container.decode(Data.self) {
            self = .plData(Array(dataValue))
        } else if decoder is PropertyListDecoder, let dateValue = try? container.decode(Date.self) {
            self = .plDate(dateValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .plDouble(doubleValue)
        } else if let arrayValue = try? container.decode([PropertyListItem].self) {
            self = .plArray(arrayValue)
        } else if let objectValue = try? container.decode([String: PropertyListItem].self) {
            self = .plDict(objectValue)
        } else if decoder is JSONDecoder, container.decodeNil() {
            throw DecodingError.typeMismatch(PropertyListItem.self, .init(codingPath: container.codingPath, debugDescription: "Property lists cannot store JSON NULL values"))
        } else {
            throw DecodingError.typeMismatch(PropertyListItem.self, .init(codingPath: container.codingPath, debugDescription: "Unexpected property list type"))
        }
    }
}

public extension PropertyListItem {
    // Convenience methods to unwrap property list items where the type is known, and return nil if it's not of that type.  This is useful for doing optional chaining.
    var intValue: Int? {
        guard case .plInt(let value) = self else { return nil }
        return value
    }
    var stringValue: String? {
        guard case .plString(let value) = self else { return nil }
        return value
    }
    var boolValue: Bool? {
        guard case .plBool(let value) = self else { return nil }
        return value
    }

    /// If it quacks like a bool. This getter will get bools out of .plBool, .plInt, and .plString to match the behavior of Foundation's -boolValue.
    var looselyTypedBoolValue: Bool? {
        if let value = self.boolValue {
            return value
        }

        if let stringValue = self.stringValue {
            return stringValue.boolValue
        }

        if let intValue = self.intValue {
            return intValue != 0
        }

        return nil
    }

    var dataValue: [UInt8]? {
        guard case .plData(let value) = self else { return nil }
        return value
    }
    var dateValue: Date? {
        guard case .plDate(let value) = self else { return nil }
        return value
    }
    var floatValue: Double? {
        guard case .plDouble(let value) = self else { return nil }
        return value
    }
    var arrayValue: [PropertyListItem]? {
        guard case .plArray(let value) = self else { return nil }
        return value
    }
    var intArrayValue: [Int]? {
        guard let arrayValue else { return nil }
        let ints = arrayValue.compactMap({ $0.intValue })
        guard ints.count == arrayValue.count else { return nil }
        return ints
    }
    var stringArrayValue: [String]? {
        guard let arrayValue else { return nil }
        let strings = arrayValue.compactMap({ $0.stringValue })
        guard strings.count == arrayValue.count else { return nil }
        return strings
    }
    var dictValue: [String: PropertyListItem]? {
        guard case .plDict(let value) = self else { return nil }
        return value
    }
}

extension PropertyListItem {
    /// Returns the property list with the values of boolean-like keys in dictionaries replaced with actual boolean values.
    ///
    /// If the property list is not a dictionary or contains no keys needing replacements, effectively returns the original dictionary.
    public func withConcreteBooleans(forKeys booleanKeyNames: Set<String>) -> PropertyListItem {
        switch self {
        case .plDict(let d):
            return .plDict(Dictionary<String, PropertyListItem>(uniqueKeysWithValues: d.sorted(byKey: <).map { (key, value) -> (String, PropertyListItem) in
                if case .plDict = value {
                    return (key, value.withConcreteBooleans(forKeys: booleanKeyNames))
                }
                if booleanKeyNames.contains(key), let bool = value.looselyTypedBoolValue {
                    return (key, .plBool(bool))
                }
                return (key, value)
            }))
        default:
            return self
        }
    }
}

extension PropertyListItem: CustomStringConvertible {
    public var description: String {
        switch self {
        case .plBool(let value): return "\(value)"
        case .plInt(let value): return "\(value)"
        case .plString(let value): return "\"\(value)\""
        case .plData(let value): return "PLData<\(value)>"
        case .plDate(let value): return "PLDate<\(value)>"
        case .plDouble(let value): return "\(value)"
        case .plArray(let value): return "PLArray<\(value)>"
        case .plDict(let value): return "PLDict<\(value)>"
        case .plOpaque(let value): return "\(value)"
        }
    }

    /// Returns a textual representation of the receiver with a stable ordering of any content which Swift normally might render in a nondeterministic order, such as dictionaries.
    public var deterministicDescription: String {
        switch self {
        case .plBool(let value): return "\(value)"
        case .plInt(let value): return "\(value)"
        case .plString(let value): return "\"\(value)\""
        case .plData(let value): return "PLData<\(value)>"
        case .plDate(let value): return "PLDate<\(value)>"
        case .plDouble(let value): return "\(value)"
        case .plArray(let value):
            var str = "PLArray<["
            var atLeastOneEntry = false
            for item in value {
                if atLeastOneEntry {
                    str += ", "
                }
                // Call .deterministicDescription for each item in the array, since there may be dictionaries in them.
                str += item.deterministicDescription
                atLeastOneEntry = true
            }
            str += "]>"
            return str
        case .plDict(let value):
            var str = "PLDict<["
            var atLeastOneEntry = false
            for (key, val) in value.sorted(byKey: <) {
                if atLeastOneEntry {
                    str += ", "
                }
                // The key is always a string.  Then we call .deterministicDescription for the value, since it may contain a dictionary itself.
                str += "\"\(key)\": \(val.deterministicDescription)"
                atLeastOneEntry = true
            }
            if !atLeastOneEntry {
                str += ":"
            }
            str += "]>"
            return str
        case .plOpaque(let value): return "\(value)"
        }
    }
}

public protocol PropertyListItemConvertible {
    var propertyListItem: PropertyListItem { get }
}

extension PropertyListItem: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return self }
}

extension Int: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plInt(self) }
}

extension Double: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plDouble(self) }
}

extension Bool: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plBool(self) }
}

extension String: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plString(self) }
}

extension Data: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plData([UInt8](self)) }
}

extension Date: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plDate(self) }
}

extension ByteString: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plData(self.bytes) }
}

extension Array: PropertyListItemConvertible where Element: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plArray(self.map { $0.propertyListItem }) }
}

extension Dictionary: PropertyListItemConvertible where Key == String, Value: PropertyListItemConvertible {
    public var propertyListItem: PropertyListItem { return .plDict(self.mapValues { $0.propertyListItem }) }
}

public extension PropertyListItem {
    init(_ x: any PropertyListItemConvertible) {
        self = x.propertyListItem
    }

    // Will remove this with rdar://problem/44204273
    init(_ x: [any PropertyListItemConvertible]) {
        self = .plArray(x.map{$0.propertyListItem})
    }

    // Will remove this with rdar://problem/44204273
    init(_ x: [String: any PropertyListItemConvertible]) {
        self = .plDict(x.mapValues { $0.propertyListItem })
    }
}

extension PropertyListItem: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: BooleanLiteralType) {
        self = .plBool(value)
    }
}

extension PropertyListItem: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: IntegerLiteralType) {
        self = .plInt(value)
    }
}

extension PropertyListItem: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self = .plString(value)
    }
}

extension PropertyListItem: ExpressibleByFloatLiteral {
    public init(floatLiteral value: FloatLiteralType) {
        self = .plDouble(value)
    }
}

extension PropertyListItem: ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = PropertyListItemConvertible

    public init(arrayLiteral elements: any ArrayLiteralElement...) {
        self = .plArray(elements.map { $0.propertyListItem })
    }
}

extension PropertyListItem: ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = PropertyListItemConvertible

    public init(dictionaryLiteral elements: (Key, any Value)...) {
        self = .plDict(.init(uniqueKeysWithValues: elements.map { ($0.0, $0.1.propertyListItem) }))
    }
}

public extension PropertyListItem {
    /// Encode the item as a JSON fragment.
    ///
    /// It is a programming error to try and encode an item containing a `plData`, `plDate` or `plOpaque` item.
    func asJSONFragment() throws -> ByteString {
        let stream = OutputByteStream()
        try encodeAsJSON(stream)
        return stream.bytes
    }

    /// Encode the item as a JSON fragment into an existing buffer.
    ///
    /// It is a programming error to try and encode an item containing a PLData item.
    func encodeAsJSON(_ stream: OutputByteStream) throws {
        switch self {
        case .plBool(let value):
            stream.write(value ? "true" : "false")

        case .plInt(let value):
            // FIXME: There should be a method on the output buffer stream for this.
            stream.write(String(value))

        case .plString(let value):
            stream.write(UInt8(ascii: "\""))
            stream.writeJSONEscaped(value)
            stream.write(UInt8(ascii: "\""))

        case .plData(let value):
            // FIXME: We should resolve this by eliminating the PLData case in exchange for a custom Array-of-UInt8 case which is automatically converted to.
            throw PropertyListConversionError.encoderError("PLData<\(value.count) bytes> is not representable in JSON")

        case .plDate(let value):
            throw PropertyListConversionError.encoderError("PLDate<\(value)> is not representable in JSON")

        case .plDouble(let value):
            stream.write(String(value))

        case .plArray(let value):
            stream.write(UInt8(ascii: "["))
            var first = true
            for item in value {
                if !first { stream.write(UInt8(ascii: ",")) }
                try item.encodeAsJSON(stream)
                first = false
            }
            stream.write(UInt8(ascii: "]"))

        case .plDict(let value):
            stream.write(UInt8(ascii: "{"))
            var first = true
            let sortedValue = value.sorted(byKey: <)
            for (key,item) in sortedValue {
                if !first { stream.write(UInt8(ascii: ",")) }
                stream.write(UInt8(ascii: "\""))
                stream.writeJSONEscaped(key)
                stream.write(UInt8(ascii: "\""))
                stream.write(UInt8(ascii: ":"))
                try item.encodeAsJSON(stream)
                first = false
            }
            stream.write(UInt8(ascii: "}"))

        case .plOpaque:
            throw PropertyListConversionError.encoderError("opaque objects are not representable in JSON")
        }
    }

    /// Convert a Swift object which is a valid property list into a property list structure.
    init?(unsafePropertyList propertyList: Any) {
        self = convertToPropertyListItem(propertyList)
    }

    /// Convert the PropertyListItem hierarchy into a Cocoa property list.
    var unsafePropertyList: Any {
        switch self {
        case .plBool(let value):
            return value as NSNumber

        case .plInt(let value):
            return value as NSNumber

        case .plString(let value):
            return value as NSString

        case .plData(let value):
            return Data(value)

        case .plDate(let value):
            return value as Date

        case .plDouble(let value):
            return value as Double

        case .plArray(let value):
            let array = NSMutableArray()
            for item in value {
                array.add(item.unsafePropertyList)
            }
            return array

        case .plDict(let value):
            let dict = NSMutableDictionary()
            for (key,item) in value {
                dict.setObject(item.unsafePropertyList, forKey: key as NSString)
            }
            return dict

        case .plOpaque(let value):
            return value.wrappedValue
        }
    }

    /// Convert the receiver to an array of bytes.
    /// - parameter format: The format to which to convert the property list.  Note that Foundation no longer supports writing the OpenStep format.
    func asBytes(_ format: PropertyListSerialization.PropertyListFormat) throws -> [UInt8] {
        // Convert the property list to an NSData.
        let plist = self.unsafePropertyList
        let data = try PropertyListSerialization.swb_stableData(fromPropertyList: plist, format: format, options: 0 /* no options */)
        return [UInt8](data)
    }

    /// Returns `true` if the receiver is empty for its type.  For each possible type, it is empty if the following is true:
    ///     - Bool: Is false.
    ///     - Int: Is zero (0).
    ///     - String: Is the empty string.
    ///     - Data: Is an empty byte array.
    ///     - Array: Is an empty array.
    ///     - Dict: Is an empty dictionary.
    var isEmpty: Bool {
        switch self {
        case .plBool(let value):
            return value == false

        case .plInt(let value):
            return value == 0

        case .plString(let value):
            return value.isEmpty

        case .plData(let value):
            return value.isEmpty

        case .plDate(_):
            return false

        case .plDouble(let value):
            return value == 0

        case .plArray(let value):
            return value.isEmpty

        case .plDict(let value):
            return value.isEmpty

        case .plOpaque:
            return false
        }
    }

    /// Returns `true` if the receiver is a scalar type as opposed to a collection type.
    var isScalarType: Bool {
        switch self {
        case .plBool, .plInt, .plString, .plData, .plDate, .plDouble, .plOpaque:
            return true
        case .plArray, .plDict:
            return false
        }
    }

    /// Returns a string for the type of the receiver suitable for display to the user.
    var typeDisplayString: String {
        switch self {
        case .plBool:
            return "boolean"
        case .plInt:
            return "integer"
        case .plString:
            return "string"
        case .plData:
            return "data"
        case .plDate:
            return "date"
        case .plDouble:
            return "double"
        case .plArray:
            return "array"
        case .plDict:
            return "dictionary"
        case .plOpaque:
            return "opaque"
        }
    }
}

extension PropertyListItem: Equatable {
    public static func ==(lhs: PropertyListItem, rhs: PropertyListItem) -> Bool {
        switch (lhs, rhs) {
        case (.plBool(let lhs), .plBool(let rhs)): return lhs == rhs
        case (.plBool, _): return false
        case (.plInt(let lhs), .plInt(let rhs)): return lhs == rhs
        case (.plInt, _): return false
        case (.plString(let lhs), .plString(let rhs)): return lhs == rhs
        case (.plString, _): return false
        case (.plData(let lhs), .plData(let rhs)): return lhs == rhs
        case (.plData, _): return false
        case (.plDate(let lhs), .plDate(let rhs)): return lhs == rhs
        case (.plDate, _): return false
        case (.plDouble(let lhs), .plDouble(let rhs)): return lhs == rhs
        case (.plDouble, _): return false
        case (.plArray(let lhs), .plArray(let rhs)): return lhs == rhs
        case (.plArray, _): return false
        case (.plDict(let lhs), .plDict(let rhs)): return lhs == rhs
        case (.plDict, _): return false
        case (.plOpaque(let lhs), .plOpaque(let rhs)): return lhs == rhs
        case (.plOpaque, _): return false
        }
    }
}

private func convertToPropertyListItem(_ item: Any) -> PropertyListItem {
    switch(item) {
#if canImport(Darwin)
    case let asBool as CFBoolean where CFGetTypeID(asBool) == CFBooleanGetTypeID():
        return .plBool(CFBooleanGetValue(asBool))

    case let asNumber as NSNumber where CFGetTypeID(asNumber) == CFNumberGetTypeID() && CFNumberIsFloatType(unsafeBitCast(asNumber, to: CFNumber.self)):
        return .plDouble(asNumber as! Double)
#endif

    case let asInt as Int:
        return .plInt(asInt)

    case let asBool as Bool:
        // Expected these to fall into the CFBoolean case (except on non-Darwin), but leaving this here in case that implicit conversion changes unexpectedly. This case needs to land after the Int case, because ints can fall into this case.
        return .plBool(asBool)

    case let asDouble as Double:
        // Expected these to fall into the NSNumber/CFNumber case (except on non-Darwin), but leaving this here in case that implicit conversion changes unexpectedly.
        return .plDouble(asDouble)

    case var asString as String:
        // It is likely that property list decoding has produced a string that
        // is not contiguous UTF-8. While this doesn't break anything, it is a
        // performance footgun for most clients. Eagerly convert it to a native
        // representation to ensure they hit the String fast paths.
        asString.makeContiguousUTF8()
        return .plString(asString)

    case let asData as Data:
        return .plData([UInt8](asData))

    case let asDate as Date:
        return .plDate(asDate)

    case let asArray as NSArray:
        return .plArray(asArray.map { convertToPropertyListItem($0) })

    case let asDict as NSDictionary:
        var result = Dictionary<String, PropertyListItem>(minimumCapacity: asDict.count)
        for (key,value) in asDict {
            let valueItem = convertToPropertyListItem(value)
            result[key as! String] = valueItem
        }
        return .plDict(result)

#if canImport(Darwin)
    case let asCFType as CFTypeRef:
        return .plOpaque(.init(asCFType))
#else
    case let asNSObject as NSObject:
        return .plOpaque(.init(asNSObject))
#endif

    default:
        fatalError("unable to convert \(item) (a `\(type(of: item))` to a `PropertyListItem`")
    }
}

public enum PropertyList: Sendable {

    /// Create a property list from the data in the file at `path`, and return the property list and the format it was read from.
    public static func fromPathWithFormat(_ path: Path, fs: any FSProxy) throws -> (propertyList: PropertyListItem, format: PropertyListSerialization.PropertyListFormat) {
        // Ensure that the file exists before trying to read it.
        // Don't use exists() here because don't want to create our own POSIXError instance.
        do {
            _ = try fs.getFileInfo(path)
        } catch let error as POSIXError {
            throw PropertyListConversionError.fileError(error)
        }
        catch _ {
            throw PropertyListConversionError.unknown
        }

        do {
            let format = UnsafeMutablePointer<PropertyListSerialization.PropertyListFormat>.allocate(capacity: 1)
            defer { format.deallocate() }
            let result = try PropertyListSerialization.propertyList(from: Data(fs.read(path)), format: format)

            // Convert to a native representation.
            //
            // FIXME: Eventually, we want a way to do the loading and not need to copy / traverse all of the data multiple times.
            return (convertToPropertyListItem(result), format.pointee)
        } catch _ {
            throw PropertyListConversionError.invalidStream
        }
    }

    /// Create a property list from the data in the file at `path`.
    public static func fromPath(_ path: Path, fs: any FSProxy) throws -> PropertyListItem {
        return try fromPathWithFormat(path, fs: fs).propertyList
    }

    /// Create a property list from `string`, and return the property list and the format it was read from.
    public static func fromStringWithFormat(_ string: String) throws -> (propertyList: PropertyListItem, format: PropertyListSerialization.PropertyListFormat) {
        do {
            let format = UnsafeMutablePointer<PropertyListSerialization.PropertyListFormat>.allocate(capacity: 1)
            defer { format.deallocate() }
            let result = try PropertyListSerialization.propertyList(from: Data(string.utf8), format: format)

            // Convert to a native representation.
            //
            // FIXME: Eventually, we want a way to do the loading and not need to copy / traverse all of the data multiple times.
            return (convertToPropertyListItem(result), format.pointee)
        } catch _ {
            throw PropertyListConversionError.invalidStream
        }
    }

    /// Create a property list from `string`.
    public static func fromString(_ string: String) throws -> PropertyListItem {
        return try fromStringWithFormat(string).propertyList
    }


    /// Create a property list from `string`, and return the property list and the format it was read from.
    public static func fromBytesWithFormat(_ bytes: [UInt8]) throws -> (propertyList: PropertyListItem, format: PropertyListSerialization.PropertyListFormat) {
        do {
            let format = UnsafeMutablePointer<PropertyListSerialization.PropertyListFormat>.allocate(capacity: 1)
            defer { format.deallocate() }
            let result = try PropertyListSerialization.propertyList(from: Data(bytes), format: format)

            // Convert to a native representation.
            //
            // FIXME: Eventually, we want a way to do the loading and not need to copy / traverse all of the data multiple times.
            return (convertToPropertyListItem(result), format.pointee)
        } catch _ {
            throw PropertyListConversionError.invalidStream
        }
    }

    /// Create a property list from `string`.
    public static func fromBytes(_ bytes: [UInt8]) throws -> PropertyListItem {
        return try fromBytesWithFormat(bytes).propertyList
    }

    /// Create a property list from the JSON-formatted data in `bytes`.
    public static func fromJSONData<D: DataProtocol>(_ bytes: D) throws -> PropertyListItem {
        do {
            // Convert to a native representation.
            //
            // FIXME: Eventually, we want a way to do the loading and not need to copy / traverse all of the data multiple times.
            return convertToPropertyListItem(try JSONSerialization.jsonObject(with: Data(bytes)))
        } catch _ {
            throw PropertyListConversionError.invalidStream
        }
    }
    public static func fromJSONData(_ byteString: ByteString) throws -> PropertyListItem {
        return try fromJSONData(byteString.bytes)
    }

    /// Create a property list from the JSON-formatted data in the file at `path`.
    public static func fromJSONFileAtPath(_ path: Path, fs: any FSProxy) throws -> PropertyListItem {
        do {
            let result = try JSONSerialization.jsonObject(with: Data(fs.read(path)))

            // Convert to a native representation.
            //
            // FIXME: Eventually, we want a way to do the loading and not need to copy / traverse all of the data multiple times.
            return convertToPropertyListItem(result)
        } catch _ {
            throw PropertyListConversionError.invalidStream
        }
    }
}

extension PropertyList {
    public static func encode<Value>(_ value: Value) throws -> PropertyListItem where Value : Encodable {
        // FIXME: Make this more efficient! We should be able to encode directly into the PropertyListItem object rather than first serializing to a binary plist.
        return try PropertyList.fromBytes(Array(PropertyListEncoder().encode(value)))
    }

    public static func decode<T>(_ type: T.Type, from propertyListItem: PropertyListItem) throws -> T where T : Decodable {
        // FIXME: Make this more efficient! We should be able to decode directly from the PropertyListItem object rather than first serializing to a binary plist.
        return try PropertyListDecoder().decode(type, from: Data(propertyListItem.asBytes(.binary)))
    }
}

public struct PropertyListKeyPath: Hashable, Comparable, ExpressibleByStringLiteral, Sendable {
    public enum StringPattern: Hashable, Comparable, Sendable {
        case any
        case equal(String)

        func matches(key: String) -> Bool {
            switch self {
            case .any:
                return true
            case let .equal(value):
                return key == value
            }
        }
    }

    public enum PropertyListKeyPathItem: Hashable, Comparable, Sendable {
        case dict(StringPattern)
        case any(StringPattern)

        func matches(key: String, value: PropertyListItem) -> Bool {
            switch self {
            case let .dict(pattern):
                return pattern.matches(key: key) && value.dictValue != nil
            case let .any(pattern):
                return pattern.matches(key: key)
            }
        }
    }

    let keyPath: [PropertyListKeyPathItem]

    public init(stringLiteral value: String) {
        self.keyPath = [.any(.equal(value))]
    }

    public init(_ keyPath: PropertyListKeyPathItem...) {
        self.keyPath = keyPath
    }

    public init(_ keyPath: [PropertyListKeyPathItem]) {
        self.keyPath = keyPath
    }

    func dropFirst() -> Self {
        Self(Array(keyPath.dropFirst()))
    }

    public static func < (lhs: PropertyListKeyPath, rhs: PropertyListKeyPath) -> Bool {
        lhs.keyPath.description < rhs.keyPath.description
    }
}

public struct PropertyListItemKeyPathValue: Hashable, Sendable {
    public let actualKeyPath: [String]
    public let value: PropertyListItem
}

extension PropertyListItem {
    public subscript(keyPath: PropertyListKeyPath) -> [PropertyListItemKeyPathValue] {
        var values: [PropertyListItemKeyPathValue] = []
        if let first = keyPath.keyPath.first {
            for (key, value) in dictValue?.sorted(byKey: <) ?? [] {
                if first.matches(key: key, value: value) {
                    if keyPath.keyPath.count == 1 {
                        values.append(PropertyListItemKeyPathValue(actualKeyPath: [key], value: value))
                    } else {
                        values.append(contentsOf: value[keyPath.dropFirst()].map {
                            PropertyListItemKeyPathValue(actualKeyPath: [key] + $0.actualKeyPath, value: $0.value)
                        })
                    }
                }
            }
        }
        return values
    }
}

extension PropertyListSerialization {
    /// Serialize the property list using a stable encoding.
    ///
    /// By default, property list serialization does not attempt to force the output to be deterministic; instead it will serialize in hash bucket order and depend on the instance equality among items. This function instead forces the serialization to always sort keys before encoding them, and to use value quality among string items when uniquing serialized results (in the binary plist form).
    ///
    /// rdar://44838677
    fileprivate class func swb_stableData(fromPropertyList plist: Any, format: PropertyListFormat, options: WriteOptions) throws -> Data {
        func GetInternedValue(_ value: Any, _ table: NSMutableDictionary) -> Any {
            if let result = table[value] {
                return result
            }
            #if canImport(Darwin)
            table.setObject(value, forKey: value as! (any NSCopying))
            #else
            table.setObject(value, forKey: value as! AnyHashable)
            #endif
            return value
        }

        func GetStableValueReplacement(_ value: Any, _ memoTable: NSMutableDictionary) -> Any {
            if value is NSString {
                // Strings must go through the memoization table, in order to ensure all equivalent instances are uniqued to a single object in the binary encoding.
                return GetInternedValue(value, memoTable)
            } else if let arrayValue = value as? NSArray {
                let count = arrayValue.count
                let stableArray = NSMutableArray(capacity: count)
                for i in 0..<count {
                    stableArray.add(GetStableValueReplacement(arrayValue[i], memoTable))
                }
                return stableArray
            } else if let dictionaryValue = value as? NSDictionary {
                return SWBStablePropertyListDictionary(dictionary: dictionaryValue, memoTable: memoTable)
            }
            return value
        }

        /// This is a shim NSDictionary implementation which we use to vend a stable (sorted key order) view of an underlying dictionary.
        ///
        /// This is *NOT* intended to be a general purpose NSDictionary subclass, it is only intended to be used with property list serialization.
        final class SWBStablePropertyListDictionary: NSDictionary {
            private var dictionary = NSDictionary()
            private var orderedKeys = NSArray()

            init(dictionary: NSDictionary, memoTable: NSMutableDictionary) {
                // Create the sorted key list.
                orderedKeys = dictionary.allKeys.sorted(by: { lhs, rhs in
                    guard let lhs = lhs as? String, let rhs = rhs as? String else {
                        // This is a rule of property lists in general, not a limitation of the implementation.
                        preconditionFailure("property list dictionaries may only have keys which are strings")
                    }
                    return lhs < rhs
                }) as NSArray

                let count = orderedKeys.count
                let stableCopy = NSMutableDictionary(capacity: count)
                for i in 0..<count {
                    // Replace the entry with a stable copy of the key and value.
                    let key = GetInternedValue(orderedKeys[i], memoTable)
                    #if canImport(Darwin)
                    stableCopy.setObject(GetStableValueReplacement(dictionary[key] as Any, memoTable), forKey: key as! (any NSCopying))
                    #else
                    stableCopy.setObject(GetStableValueReplacement(dictionary[key] as Any, memoTable), forKey: key as! AnyHashable)
                    #endif
                }

                self.dictionary = stableCopy

                #if canImport(Darwin)
                super.init()
                #else
                super.init(objects: nil, forKeys: nil, count: 0)
                #endif
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            #if canImport(Darwin)
            required convenience override init() {
                self.init(objects: nil, forKeys: nil, count: 0)
            }

            override init(objects: UnsafePointer<AnyObject>?, forKeys keys: UnsafePointer<any NSCopying>?, count: Int) {
                super.init(objects: objects, forKeys: keys, count: count)
            }
            #else
            required init(objects: UnsafePointer<AnyObject>!, forKeys keys: UnsafePointer<NSObject>!, count: Int) {
                super.init(objects: objects, forKeys: keys, count: count)
            }
            #endif

            override var count: Int {
                dictionary.count
            }

            override func object(forKey aKey: Any) -> Any? {
                dictionary.object(forKey: aKey)
            }

            override func keyEnumerator() -> NSEnumerator {
                // Return the iterator over the stable key list.
                orderedKeys.objectEnumerator()
            }
        }

        let memoTable = NSMutableDictionary()

        // Not working on Linux
        #if !canImport(Darwin)
        return try data(fromPropertyList: plist, format: format, options: options)
        #else
        // Convert the input property list to something which will have a stable representation when serialized.
        return try data(fromPropertyList: GetStableValueReplacement(plist, memoTable), format: format, options: options)
        #endif
    }
}
