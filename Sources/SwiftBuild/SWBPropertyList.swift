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

public import Foundation

import SWBUtil

public enum SWBPropertyListItem: Hashable, Sendable {
    // Scalar types.
    case plBool(Bool)
    case plInt(Int)
    case plString(String)
    case plData([UInt8])
    case plDate(Date)
    case plDouble(Double)

    // Collection types.
    case plArray([SWBPropertyListItem])
    case plDict([String: SWBPropertyListItem])

    // NOTE: The public API cover type does not support 'plOpaque' objects because we don't expect to have uses of property lists containing these objects.
}

extension SWBPropertyListItem {
    /// Convert a Swift object which is a valid property list into a property list structure.
    ///
    /// - note: This method should be avoided if possible and only used when necessary to interface with Foundation / Objective-C APIs. If constructing a property list in memory, do so directly using the `SWBPropertyListItem` enumeration API.
    /// - throws: `unsafePropertyList` is not a valid property list.
    public init(unsafePropertyList propertyList: Any) throws {
        guard let item = PropertyListItem(unsafePropertyList: propertyList) else {
            throw StubError.error("Input is not a valid property list")
        }
        self = try .init(item)
    }

    /// Convert the property list structure into a Swift object.
    ///
    /// - note: This method should be avoided if possible and only used when necessary to interface with Foundation / Objective-C APIs.
    public var unsafePropertyList: Any {
        propertyListItem.unsafePropertyList
    }
}

extension SWBPropertyListItem: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: BooleanLiteralType) {
        self = .plBool(value)
    }
}

extension SWBPropertyListItem: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: IntegerLiteralType) {
        self = .plInt(value)
    }
}

extension SWBPropertyListItem: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self = .plString(value)
    }
}

extension SWBPropertyListItem: ExpressibleByFloatLiteral {
    public init(floatLiteral value: FloatLiteralType) {
        self = .plDouble(value)
    }
}

extension SWBPropertyListItem: ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = Self

    public init(arrayLiteral elements: ArrayLiteralElement...) {
        self = .plArray(elements)
    }
}

extension SWBPropertyListItem: ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = Self

    public init(dictionaryLiteral elements: (Key, Value)...) {
        self = .plDict(.init(uniqueKeysWithValues: elements))
    }
}

// MARK: SPI used to convert between public and internal representations

extension Dictionary where Key == String, Value == SWBPropertyListItem {
    init(_ propertyList: [String: PropertyListItem]) throws {
        self = try propertyList.mapValues { try .init($0) }
    }

    var propertyList: [String: PropertyListItem] {
        mapValues { $0.propertyListItem }
    }
}

extension SWBPropertyListItem {
    init(_ propertyListItem: PropertyListItem) throws {
        switch propertyListItem {
        case let .plBool(value):
            self = .plBool(value)
        case let .plInt(value):
            self = .plInt(value)
        case let .plString(value):
            self = .plString(value)
        case let .plData(value):
            self = .plData(value)
        case let .plDate(value):
            self = .plDate(value)
        case let .plDouble(value):
            self = .plDouble(value)
        case let .plArray(value):
            self = try .plArray(value.map { try .init($0 ) })
        case let .plDict(value):
            self = try .plDict(value.mapValues { try .init($0) })
        case let .plOpaque(value):
            throw StubError.error("Invalid property list object: \(value)")
        }
    }

    var propertyListItem: PropertyListItem {
        switch self {
        case let .plBool(value):
            return .plBool(value)
        case let .plInt(value):
            return .plInt(value)
        case let .plString(value):
            return .plString(value)
        case let .plData(value):
            return .plData(value)
        case let .plDate(value):
            return .plDate(value)
        case let .plDouble(value):
            return .plDouble(value)
        case let .plArray(value):
            return .plArray(value.map { $0.propertyListItem })
        case let .plDict(value):
            return .plDict(value.mapValues { $0.propertyListItem })
        }
    }
}
