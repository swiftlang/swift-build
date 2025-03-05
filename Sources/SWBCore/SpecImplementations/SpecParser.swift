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

public import SWBUtil
public import SWBMacro

/// Delegate protocol used by the parser to report diagnostics.
public protocol SpecParserDelegate: DiagnosticProducingDelegate, SpecRegistryProvider {
    /// The namespace to parse internal macros into.
    var internalMacroNamespace: MacroNamespace { get }

    func groupingStrategy(name: String, specIdentifier: String) -> (any InputFileGroupingStrategy)?
}

/// This class provides support for parsing spec data into a structured object.
///
/// The class is designed to allow robust validation of the input data, as well as detection of errors and inconsistencies in the spec data.
///
/// The general design of the parser is that we should be able to recover from all errors. Diagnostics will be emitted for each issue, and the client can choose what to do with a spec that had loading errors, but it should always be possible to parse to completion any spec no matter how malformed.
public class SpecParser {
    /// The parser delegate.
    package let delegate: any SpecParserDelegate

    /// The proxy being parsed.
    let proxy: SpecProxy

    /// The list of keys which have been parsed.
    private var parsedKeys: Set<String> = []

    @_spi(Testing) public init(_ delegate: any SpecParserDelegate, _ proxy: SpecProxy) {
        self.delegate = delegate
        self.proxy = proxy
    }

    func warning(_ message: String) {
        delegate.warning(message)
    }

    func error(_ message: String) {
        delegate.error(message)
    }

    /// The set of keys which are parsed by the proxy machinery, and shouldn't count as unused.
    private static let keysParsedByProxy = Set<String>([ "Class", "Domain", "_Domain", "Identifier", "Type", "BasedOn" ])

    @_spi(Testing) public func complete() {
        for key in proxy.data.keys {
            // Ignore keys that were parsed by proxies.
            if SpecParser.keysParsedByProxy.contains(key) {
                continue
            }

            if !parsedKeys.contains(key) {
                warning("unused key '\(key)'")
            }
        }
    }

    @discardableResult
    func parseObject(_ key: String, inherited: Bool = true) -> PropertyListItem? {
        assert(!parsedKeys.contains(key), "attempt to parse key '\(key)' multiple times")
        parsedKeys.insert(key)

        if inherited {
            return proxy.lookupDataForKey(key)
        } else {
            return proxy.data[key]
        }
    }

    @discardableResult
    @_spi(Testing) public func parseString(_ key: String, inherited: Bool = true) -> String? {
        // Get the value for this key.
        guard let value = parseObject(key, inherited: inherited) else { return nil }

        return parseItemAsString(key, value)
    }

    func parseItemAsString(_ key: String, _ value: PropertyListItem) -> String? {
        // Extract the value.
        guard case .plString(let stringValue) = value else {
            error("unexpected item: \(value) while parsing key \(key) (expected string)")
            return nil
        }

        return stringValue
    }

    @_spi(Testing) public func parseRequiredString(_ key: String, inherited: Bool = true) -> String {
        if let value = parseString(key, inherited: inherited) { return value }

        error("missing required value for key: '\(key)'")

        return "<invalid>"
    }

    @discardableResult
    public func parseStringList(_ key: String, inherited: Bool = true) -> [String]? {
        // Get the value for this key.
        guard let value = parseObject(key, inherited: inherited) else { return nil }

        return parseItemAsStringList(key, value)
    }

    func parseItemAsStringList(_ key:String, _ value: PropertyListItem) -> [String]? {
        // Extract the value.
        guard case .plArray(let arrayValue) = value else {
            error("unexpected item: \(value) while parsing key \(key) (expected array of strings)")
            return nil
        }

        return arrayValue.map {
            guard case .plString(let stringValue) = $0 else {
                error("unexpected array member: \($0) while parsing key \(key)")
                return "<invalid>"
            }
            return stringValue
        }
    }

    @_spi(Testing) public func parseRequiredStringList(_ key: String, inherited: Bool = true) -> [String] {
        if let value = parseStringList(key, inherited: inherited) { return value }

        error("missing required value for key: '\(key)'")

        return ["<invalid>"]
    }

    @discardableResult
    @_spi(Testing) public func parseBool(_ key: String, inherited: Bool = true) -> Bool? {
        guard let stringValue = parseString(key, inherited: inherited) else { return nil }

        // Coerce to bool.
        if stringValue == "no" || stringValue == "No" || stringValue == "NO" || stringValue == "0" {
            return false
        } else if stringValue == "yes" || stringValue == "Yes" || stringValue == "YES" || stringValue == "1" {
            return true
        } else {
            error("invalid value: \(stringValue) for key \(key) (expected boolean 'YES' or 'NO')")
            return false
        }
    }

    @_spi(Testing) public func parseRequiredBool(_ key: String, inherited: Bool = true) -> Bool {
        if let value = parseBool(key, inherited: inherited) { return value }

        error("missing required value for key: '\(key)'")

        return false
    }

    /// Parse a string-typed key as a MacroStringExpression.
    func parseMacroString(_ key: String, inherited: Bool = true) -> MacroStringExpression? {
        // Get the value for this key.
        guard let value = parseString(key, inherited: inherited) else { return nil }

        // Parse it as a macro string.
        return delegate.internalMacroNamespace.parseString(value) { diag in
            self.handleMacroDiagnostic(diag, "macro parsing error on '\(key)'")
        }
    }

    func parseBuildSettings(_ key: String, baseSettings: MacroValueAssignmentTable? = nil) -> MacroValueAssignmentTable? {
        guard let value = parseObject(key, inherited: false) else { return baseSettings }
        return parseItemAsBuildSettings(key, value, baseSettings: baseSettings)
    }

    func parseItemAsBuildSettings(_ key:String, _ value: PropertyListItem, baseSettings: MacroValueAssignmentTable? = nil) -> MacroValueAssignmentTable? {
        // This holds our "last-in-wins" values for our macro assignments.
        var values: [String:(macro:MacroDeclaration, conditions:MacroConditionSet?, expression:MacroExpression)] = [:]

        // A helper function to populate the `values` table correctly based on the macro/conditions set.
        func setBuildSetting(macro: MacroDeclaration, conditions: MacroConditionSet?, expr: MacroExpression) {
            let key = "\(macro.name)\(conditions?.description ?? "")"
            values[key] = (macro, conditions, expr)
        }

        guard case .plDict(let dictValue) = value else {
            error("unexpected item: \(value) while parsing key \(key) (expected dictionary)")
            return nil
        }

        // Important implementation note! The way in which settings are built up from .xcspec files is a "last-in-wins" for any given value.

        // Build up the values from the `BasedOn` spec.
        for (macro, value) in baseSettings?.valueAssignments.sorted(byKey: { $0.name < $1.name }) ?? [] {
            setBuildSetting(macro: macro, conditions: value.conditions, expr: value.expression)
        }

        let namespace = delegate.internalMacroNamespace

        // Build up the values based on the current spec that is being parsed.
        for (settingName, settingValue) in dictValue.sorted(byKey: <) {
            // FIXME: There really should be a way for the `BuildConfiguration`, `MacroConfigFileParser`, and `SpecParser` types to leverage a set of common parsing utilities.
            let (name, conditions) = MacroConfigFileParser.parseMacroNameAndConditionSet(settingName)

            guard let macroName = name else {
                self.error("invalid setting name: '\(settingName)'")
                continue
            }

            let conditionSet: MacroConditionSet?
            if let conditions {
                conditionSet = MacroConditionSet(conditions: conditions.map{ MacroCondition(parameter: namespace.declareConditionParameter($0.0), valuePattern: $0.1) })
            }
            else {
                conditionSet = nil
            }

            // In general, the macro is expected to have already been declared on the namespace. However, in the case that it is not, we create one on the internal namespace instead of just error'ing out as there maybe some that are simply unknown to us.
            let macro: MacroDeclaration
            do {
                macro = try {
                    // FIXME: We should really have a way to specify the type here instead of simply defaulting to a string/stringlist based on the plist value type, and then deprecate this behavior. Additionally, OpenStep property lists can't distinguish between booleans and strings, so we'll check against any previous definition's type instead of directly returning the declaration, to avoid inconsistent types when parsing macros from an xcspec.
                    let existingDeclaration = namespace.lookupMacroDeclaration(macroName)
                    switch (existingDeclaration?.type, settingValue) {
                    case (.path, .plString(_)):
                        return try namespace.declarePathMacro(macroName)
                    case (.pathList, .plString(_)),
                         (.pathList, .plArray(_)):
                        return try namespace.declarePathListMacro(macroName)
                    case (.boolean, .plString(_)), // builtin boolean macro + OpenStep plist string => boolean
                         (.boolean, .plBool(_)),
                         (nil, .plBool(_)):
                        return try namespace.declareBooleanMacro(macroName)
                    case (.string, .plString(_)),
                         (nil, .plString(_)):
                        // Both StringMacroDeclaration and EnumMacroDeclaration use the string macro type, but are represented by different classes. If the existing declaration is an enum, it was defined in BuiltinMacros, so prefer it.
                        if let existingDeclaration, existingDeclaration is AnyEnumMacroDeclaration {
                            return existingDeclaration
                        }
                        return try namespace.declareStringMacro(macroName)
                    case (.stringList, .plString(_)), // some string lists are declared as strings in xcspecs
                         (.stringList, .plArray(_)),
                         (nil, .plArray(_)):
                        return try namespace.declareStringListMacro(macroName)
                    case let (macroType, _):
                        // Using .userDefined here in the nil case is not strictly correct since we're not actually attempting to register a user defined macro, but close enough (we just need _some_ value for the error) - if a plist value was a dictionary for example we'd get an error about the 'dictionary' type being inconsistent with the user defined macro type.
                        throw MacroDeclarationError.inconsistentMacroDefinition(name: macroName, type: macroType ?? .userDefined, value: settingValue)
                    }
                }()
            } catch {
                self.error("\(error)")
                continue
            }

            // Parse the expression in a manner consistent with the macro type.
            var hadError = false
            let exprOpt = namespace.parseForMacro(macro, value: settingValue) { diag in
                self.error("macro parsing error for build setting '\(macroName)': \(diag)")
                hadError = true
            }

            // Ignore the expression if there was an error.
            if hadError {
                continue
            }

            // If we didn't get an expression, the plist had an invalid value.
            guard let expr = exprOpt else {
                error("unexpected value for build setting '\(macroName)' while parsing '\(key)'")
                continue
            }

            setBuildSetting(macro: macro, conditions: conditionSet, expr: expr)
        }

        // Finally we create a table with the correct values to push back.
        var table = MacroValueAssignmentTable(namespace: namespace)
        for (_, info) in values.sorted(byKey: <) {
            table.push(info.macro, info.expression, conditions: info.conditions)
        }

        return table
    }

    @_spi(Testing) public func parseRequiredBuildSettings(_ key: String, baseSettings: MacroValueAssignmentTable? = nil) -> MacroValueAssignmentTable {
        if let value = parseBuildSettings(key, baseSettings: baseSettings) { return value }

        // If the key isn't present explicitly, but we have a base table, that satisfies the requirement.
        if let settings = baseSettings { return settings }

        error("missing required value for key: '\(key)'")

        return baseSettings ?? MacroValueAssignmentTable(namespace: delegate.internalMacroNamespace)
    }

    /// Parse a key as a "command-line" string, which can be either an array of individual arguments, or a string which is broken into arguments following the shell string quoting rules.
    @discardableResult
    public func parseCommandLineString(_ key: String, inherited: Bool = true) -> [String]? {
        guard let value = parseObject(key, inherited: inherited) else { return nil }

        return parseItemAsCommandLineString(key, value)
    }

    /// Parse an item as a "command-line" string, which can be either an array of individual arguments, or a string which is broken into arguments following the shell string quoting rules.
    func parseItemAsCommandLineString(_ key: String, _ value: PropertyListItem) -> [String]? {
        if case .plArray = value { return parseItemAsStringList(key, value) }

        guard case .plString(let stringValue) = value else {
            error("unexpected item: \(value) while parsing key '\(key)' (expected string or string list)")
            return nil
        }

        // Parse the string value.
        //
        // FIXME: Add proper support for shell quoting rules: <rdar://problem/29304140> Add support method for splitting a string into arguments according to shell rules
        return stringValue.split(separator: " ").map(String.init)
    }

    /// Looks up `key` and parses the value as an array of dictionaries, invoking `block` for each entry. There is opt-in support for two different structural “shortcuts” commonly used in specifications:
    /// - a single, unwrapped element can be used as a shorthand for a single-element array
    /// - a non-dictionary entity can be used as a shorthand for a single-entry dictionary
    /// The first case is enabled if `allowUnarrayedElement` is true; in this case, if the value is any non-array plist type, it is treated the same as if it were an array with a single element (using the non-array plist value as the single entry).
    /// The second case is enabled if `impliedElementKey` is passed; in this case, if the value is any non-dictionary plist-type, it is treated the same as if it were a dictionary with a single entry (using the passed-in string as the key and the non-dictionary plist value as the value).
    /// - returns: an array of the non-optional values returned by the block, or nil if the key wasn’t found
    @_spi(Testing) public func parseArrayOfDicts<T>(_ key: String, inherited: Bool = true, required: Bool = false, allowUnarrayedElement: Bool = false, impliedElementKey: String? = nil, block: @escaping (PropertyListItem) throws -> T?) rethrows -> [T]? {
        // Get the value for this key.
        guard let value = parseObject(key, inherited: inherited) else { return nil }
        // Declare a function that will invoke the block with either the item or a dictionary wrapped around the item.
        func callBlock(_ item: PropertyListItem) throws -> T? {
            // If the item is already a dictionary, just call it.
            if case .plDict = item {
                return try block(item)
            }
            // Otherwise, if we have an implied-element-key we just wrap the item in a dictionary.
            else if let key = impliedElementKey {
                return try block(.plDict([key: item]))
            }
            // Otherwise, we have an unexpected item.
            else {
                error("unexpected item: \(value) while parsing elements of key '\(key)' (expected dictionary)")
                return nil
            }
        }
        // If we have an array we traverse its entries.
        if case .plArray(let entries) = value {
            return try entries.compactMap{ try callBlock($0) }
        }
        // Otherwise, if we are asked to allow a single unarrayed element, we just invoke the block once.
        else if allowUnarrayedElement {
            return try [value].compactMap{ try callBlock($0) }
        }
        // Otherwise, we have an unexpected item.
        else {
            error("unexpected item: \(value) while parsing key '\(key)' (expected array)")
            return nil
        }
    }

}
