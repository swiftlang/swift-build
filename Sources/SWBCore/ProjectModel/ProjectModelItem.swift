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
import SWBProtocol
public import SWBUtil


// MARK: Type definitions


public typealias ProjectModelItemPIF = [String: PropertyListItem]


// MARK: ProjectModelItem protocol


public protocol ProjectModelItem: AnyObject, CustomStringConvertible, Sendable {
}

extension ProjectModelItem {
    public var description: String {
        return "\(type(of: self))<>"
    }
}

@_spi(Testing) public enum PIFParsingError: Error {
    case missingRequiredKey(keyName: String, objectType: any ProjectModelItem.Type)
    case incorrectType(keyName: String, objectType: any ProjectModelItem.Type, expectedType: String, destinationType: String?)
    case incorrectTypeInArray(keyName: String, objectType: any ProjectModelItem.Type, expectedType: String)
    case invalidEnumValue(keyName: String, objectType: any ProjectModelItem.Type, actualValue: String, destinationType: any PIFStringEnum.Type)
    case custom(_ message: String)
}

extension PIFParsingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingRequiredKey(let keyName, let objectType):
            return "Required key '\(keyName)' is missing in \(objectType) dictionary"
        case .incorrectType(let keyName, let objectType, let expectedType, let destinationType):
            if let destinationType {
                return "Key '\(keyName)' for \(destinationType) value in \(objectType) dictionary is not a \(expectedType) value"
            }
            return "Key '\(keyName)' in \(objectType) dictionary is not a \(expectedType) value"
        case .incorrectTypeInArray(let keyName, let objectType, let expectedType):
            return "A value in the Array value for '\(keyName)' in \(objectType) dictionary must be a \(expectedType) but is not"
        case .invalidEnumValue(let keyName, let objectType, let actualValue, let destinationType):
            let values = destinationType.allRawValues.map { "'\($0)'" }.joined(separator: ", ")
            return "Key '\(keyName)' for \(destinationType.logicalTypeName) value in \(objectType) dictionary is unrecognized; must be one of: \(values) (was '\(actualValue)')"
        case let .custom(message):
            return message
        }
    }
}

extension PIFParsingError: LocalizedError {
    /// Provide a better error message when using `localizedDescription` on error types.
    public var errorDescription: String? {
        return description
    }
}

extension ProjectModelItem
{
    // Static methods for parsing a property list to load a PIF.


    /// Parses the value for an optional key in a PIF dictionary as a String.
    /// - returns: A string value if the key is present, `nil` if it is absent.
    @_spi(Testing) public static func parseOptionalValueForKeyAsString(_ key: String, pifDict: ProjectModelItemPIF) throws -> String? {
        guard let value = pifDict[key] else { return nil }
        guard case .plString(let stringValue) = value else {
            throw PIFParsingError.incorrectType(keyName: key, objectType: self, expectedType: "String", destinationType: nil)
        }
        return stringValue
    }

    /// Parses the value for a required key in a PIF dictionary as a String.
    @_spi(Testing) public static func parseValueForKeyAsString(_ key: String, pifDict: ProjectModelItemPIF) throws -> String {
        return try require(key) { try parseOptionalValueForKeyAsString(key, pifDict: pifDict) }
    }

    /// Parses the value for an optional key in a PIF dictionary as an enum which is represented as a string value.
    static func parseOptionalValueForKeyAsStringEnum<T: PIFStringEnum>(_ key: String, pifDict: ProjectModelItemPIF) throws -> T? {
        guard let value = pifDict[key] else { return nil }

        // If the value of the key is not a string then we have an error.
        guard case .plString(let stringValue) = value else {
            throw PIFParsingError.incorrectType(keyName: key, objectType: self, expectedType: "String", destinationType: T.logicalTypeName)
        }

        guard let `case` = T(rawValue: stringValue) else {
            throw PIFParsingError.invalidEnumValue(keyName: key, objectType: self, actualValue: stringValue, destinationType: T.self)
        }

        return `case`
    }

    /// Parses the value for a required key in a PIF dictionary as an enum which is represented as a string value.
    static func parseValueForKeyAsStringEnum<T: PIFStringEnum>(_ key: String, pifDict: ProjectModelItemPIF) throws -> T {
        return try require(key) { try parseOptionalValueForKeyAsStringEnum(key, pifDict: pifDict) }
    }

    /// Parses the value for a key in a PIF dictionary as a Bool.
    /// - returns: `false` if the value for the key is 'false', `true` if the value for the key is 'true'. Returns `defaultValue` if the value is absent.
    @_spi(Testing) public static func parseValueForKeyAsBool(_ key: String, pifDict: ProjectModelItemPIF, defaultValue: Bool = false) throws -> Bool {
        switch try parseOptionalValueForKeyAsStringEnum(key, pifDict: pifDict) as PIFBoolValue? {
        case .true?:
            return true
        case .false?:
            return false
        case nil:
            return defaultValue
        }
    }

    /// Parses the value for an optional key in a PIF dictionary as an Array of PropertyListItem objects.
    /// - returns: An Array value if the key is present, nil if it is absent.
    @_spi(Testing) public static func parseOptionalValueForKeyAsArrayOfPropertyListItems(_ key: String, pifDict: ProjectModelItemPIF) throws -> [PropertyListItem]? {
        guard let value = pifDict[key] else { return nil }
        guard case .plArray(let plArray) = value else {
            throw PIFParsingError.incorrectType(keyName: key, objectType: self, expectedType: "Array", destinationType: nil)
        }
        return plArray
    }

    /// Parses the value for a required key in a PIF dictionary as an Array of PropertyListItem objects.
    @_spi(Testing) public static func parseValueForKeyAsArrayOfPropertyListItems(_ key: String, pifDict: ProjectModelItemPIF) throws -> [PropertyListItem] {
        return try require(key) { try parseOptionalValueForKeyAsArrayOfPropertyListItems(key, pifDict: pifDict) }
    }

    /// Parses the value for an optional key in a PIF dictionary as an Array of objects of the appropriate concrete subclass of ProjectModelItem.
    /// - returns: An Array value if the key is present, nil if it is absent.
    @_spi(Testing) public static func parseOptionalValueForKeyAsArrayOfProjectModelItems<T>(_ key: String, pifDict: ProjectModelItemPIF, pifLoader: PIFLoader, construct: (ProjectModelItemPIF) throws -> T) throws -> [T]? {
        return try parseOptionalValueForKeyAsArrayOfPropertyListItems(key, pifDict: pifDict)?.map { (plItem) -> T in
            guard case .plDict(let pifDict) = plItem else {
                throw PIFParsingError.incorrectTypeInArray(keyName: key, objectType: self, expectedType: "Dictionary")
            }
            return try construct(pifDict)
        }
    }

    /// Parses the value for a required key in a PIF dictionary as an Array of objects of the appropriate concrete subclass of ProjectModelItem.
    @_spi(Testing) public static func parseValueForKeyAsArrayOfProjectModelItems<T>(_ key: String, pifDict: ProjectModelItemPIF, pifLoader: PIFLoader, construct: (ProjectModelItemPIF) throws -> T) throws -> [T] {
        return try require(key) { try parseOptionalValueForKeyAsArrayOfProjectModelItems(key, pifDict: pifDict, pifLoader: pifLoader, construct: construct) }
    }

    // FIXME
    // @available(*, deprecated, message: "This is a shim method, and should be removed. It's used for the binary PIF representation used only by Swift Build's unit tests; we should transition everything to the JSON based API we currently use in production, and to a unified API at that (rather than one based on actual Swift types, one based on raw property lists, and different APIs for the public API and for the tests).")
    static func parseOptionalValueForKeyAsByteString(_ key: String, pifDict: ProjectModelItemPIF) throws -> ByteString? {
        return try (parseOptionalValueForKeyAsArrayOfPropertyListItems(key, pifDict: pifDict)?.map { (plItem) -> UInt8 in
            guard case .plInt(let value) = plItem, let byte = UInt8(exactly: value) else {
                throw PIFParsingError.incorrectTypeInArray(keyName: key, objectType: self, expectedType: "UInt8")
            }
            return byte
        }).map { ByteString($0) }
    }

    /// Parses the value for an optional key in a PIF dictionary as an Array of Strings.
    /// - returns: An Array value if the key is present, nil if it is absent.
    @_spi(Testing) public static func parseOptionalValueForKeyAsArrayOfStrings(_ key: String, pifDict: ProjectModelItemPIF) throws -> [String]? {
        return try parseOptionalValueForKeyAsArrayOfPropertyListItems(key, pifDict: pifDict)?.map { (plItem) -> String in
            guard case .plString(let string) = plItem else {
                throw PIFParsingError.incorrectTypeInArray(keyName: key, objectType: self, expectedType: "String")
            }
            return string
        }
    }

    /// Parses the value for a required key in a PIF dictionary as an Array of Strings.
    @_spi(Testing) public static func parseValueForKeyAsArrayOfStrings(_ key: String, pifDict: ProjectModelItemPIF) throws -> [String] {
        return try require(key) { try parseOptionalValueForKeyAsArrayOfStrings(key, pifDict: pifDict) }
    }

    /// Parses the value for an optional key in a PIF dictionary as a PIF Dictionary (a dictionary of Strings to PropertyListItem objects).
    /// - returns: An Dictionary value if the key is present, nil if it is absent.
    @_spi(Testing) public static func parseOptionalValueForKeyAsPIFDictionary(_ key: String, pifDict: ProjectModelItemPIF) throws -> ProjectModelItemPIF? {
        guard let value = pifDict[key] else { return nil }
        guard case .plDict(let dictValue) = value else {
            throw PIFParsingError.incorrectType(keyName: key, objectType: self, expectedType: "Dictionary", destinationType: nil)
        }
        return dictValue
    }

    /// Parses the value for a required key in a PIF dictionary as a PIF Dictionary (a dictionary of Strings to PropertyListItem objects).
    @_spi(Testing) public static func parseValueForKeyAsPIFDictionary(_ key: String, pifDict: ProjectModelItemPIF) throws -> ProjectModelItemPIF {
        return try require(key) { try parseOptionalValueForKeyAsPIFDictionary(key, pifDict: pifDict) }
    }

    /// Parses the value for an optional key in a PIF dictionary as an object of the appropriate concrete subclass of ProjectModelItem, and recursively parses any arrays or dictionaries appropriately.
    /// - returns: A ProjectModelItem value if the key is present, `nil` if it is absent.
    @_spi(Testing) public static func parseOptionalValueForKeyAsProjectModelItem<T>(_ key: String, pifDict: ProjectModelItemPIF, pifLoader: PIFLoader, construct: (ProjectModelItemPIF) throws -> T) throws -> T? {
        return try parseOptionalValueForKeyAsPIFDictionary(key, pifDict: pifDict).map { try construct($0) }
    }

    /// Parses the value for a required key in a PIF dictionary as an object of the appropriate concrete subclass of ProjectModelItem, and recursively parses any arrays or dictionaries appropriately.
    @_spi(Testing) public static func parseValueForKeyAsProjectModelItem<T>( _ key: String, pifDict: ProjectModelItemPIF, pifLoader: PIFLoader, construct: (ProjectModelItemPIF) throws -> T) throws -> T {
        return try require(key) { try parseOptionalValueForKeyAsProjectModelItem(key, pifDict: pifDict, pifLoader: pifLoader, construct: construct) }
    }

    /// Parses the value for a list of top-level object reference.
    static func parseOptionalValueForKeyAsArrayOfIndirectObjects<T: PIFObject>(_ key: String, pifDict: ProjectModelItemPIF, pifLoader: PIFLoader) throws -> [T]? {
        return try parseOptionalValueForKeyAsArrayOfPropertyListItems(key, pifDict: pifDict)?.map { (plItem) -> T in
            // The item must be a string, then it should be an indirect signature for the item.
            guard case let .plString(signature) = plItem else {
                throw PIFParsingError.incorrectTypeInArray(keyName: key, objectType: self, expectedType: "String")
            }
            return try pifLoader.loadReference(signature: signature, type: T.self)
        }
    }

    /// Parses the value for a required key in a PIF dictionary as an object of the appropriate concrete subclass of ProjectModelItem, and recursively parses any arrays or dictionaries appropriately.
    static func parseValueForKeyAsArrayOfIndirectObjects<T: PIFObject>(_ key: String, pifDict: ProjectModelItemPIF, pifLoader: PIFLoader) throws -> [T] {
        return try require(key) { try parseOptionalValueForKeyAsArrayOfIndirectObjects(key, pifDict: pifDict, pifLoader: pifLoader) }
    }

    static func require<T>(_ key: String, _ block: () throws -> T?) throws -> T {
        guard let value = try block() else {
            throw PIFParsingError.missingRequiredKey(keyName: key, objectType: self)
        }
        return value
    }
}


// MARK: Wrapper for an unowned ProjectModelItem


/// Wrapper for `ProjectModelItem`-conforming objects so they can be placed in arrays and dictionaries without creating string reference loops.
struct UnownedProjectModelItem: Hashable
{
    unowned let value: any ProjectModelItem

    init(_ value: any ProjectModelItem)
    {
        self.value = value
    }

    /// Returns a hash value based on the identity of the wrapped `ProjectModelItem`.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(value))
    }
}

/// Two `UnownedProjectModelItem`s are equal if their wrapped items are the same object.
func ==(lhs: UnownedProjectModelItem, rhs: UnownedProjectModelItem) -> Bool
{
    return ObjectIdentifier(lhs.value) == ObjectIdentifier(rhs.value)
}


// MARK: PIF value constant definitions

public protocol PIFStringEnum {
    init?(rawValue: String)
    static var logicalTypeName: String { get }
    static var allRawValues: [String] { get }
}

// Generic values used by multiple kinds of objects
@_spi(Testing) public enum PIFBoolValue: String, PIFStringEnum, CaseIterable {
    public static let logicalTypeName = "Bool"

    case `true`
    case `false`
}

// Values specific to targets
enum PIFTargetTypeValue: String, PIFStringEnum, CaseIterable {
    static let logicalTypeName = "target type"

    case aggregate
    case external
    case packageProduct
    case standard
}

// Values specific to references
enum PIFReferenceTypeValue: String, PIFStringEnum, CaseIterable {
    static let logicalTypeName = "reference type"

    case group
    case file
    case product
    case versionGroup
    case variantGroup
}

enum PIFReferenceSourceTreeValue: PIFStringEnum {
    init?(rawValue: String) {
        switch rawValue {
        case PIFReferenceSourceTreeValue.absolute.rawValue:
            self = .absolute
        case PIFReferenceSourceTreeValue.group.rawValue:
            self = .group
        default:
            // This is technically unbounded, although build setting names DO
            // have a restricted grammar we could (should?) use to validate on.
            self = .buildSetting(name: rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .absolute:
            return "<absolute>"
        case .group:
            return "<group>"
        case .buildSetting(let name):
            return name
        }
    }

    static let allRawValues: [String] = [
        PIFReferenceSourceTreeValue.absolute.rawValue,
        PIFReferenceSourceTreeValue.group.rawValue,
    ]

    static let logicalTypeName = "source tree"

    case absolute
    case group
    case buildSetting(name: String)
}

// Values specific to build phases
enum PIFBuildPhaseTypeValue: String, PIFStringEnum, CaseIterable {
    static let logicalTypeName = "build phase type"

    case sources = "com.apple.buildphase.sources"
    case frameworks = "com.apple.buildphase.frameworks"
    case headers = "com.apple.buildphase.headers"
    case resources = "com.apple.buildphase.resources"
    case copyfiles = "com.apple.buildphase.copy-files"
    case shellscript = "com.apple.buildphase.shell-script"
    case rez = "com.apple.buildphase.rez"
    case applescript = "com.apple.buildphase.applescript"
    case javaarchive = "com.apple.buildphase.java-archive"
}

// Values specific to rules
enum PIFDependencyFormatValue: String, PIFStringEnum, CaseIterable {
    static let logicalTypeName = "dependency format"

    case dependencyInfo
    case makefile
    case makefiles
}

// Force enable/disable sandboxing for a phase
enum PIFSandboxingOverrideValue: String, PIFStringEnum, CaseIterable {
    static let logicalTypeName = "sandboxing override"

    case forceDisabled
    case forceEnabled
    case basedOnBuildSetting
}

// MARK: - Support for diagnostics which list the possible values for an enum in parsing errors

extension CaseIterable where Self: RawRepresentable {
    /// A collection of all raw values of this type.
    public static var allRawValues: [Self.RawValue] {
        return allCases.map { $0.rawValue }
    }
}
