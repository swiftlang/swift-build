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

import SWBLibc
public import SWBUtil

/// A condition for whether or not to use a particular macro value assignment, consisting of a parameter and a `fnmatch()`-style pattern against which a candidate parameter value should be compared.  The condition parameter is not a string, but rather a MacroConditionParameter, which is created using API in MacroNamespace.  Multiple macro conditions can be associated with a given
public final class MacroCondition: Serializable, Hashable, CustomStringConvertible, Sendable {
    /// Macro condition parameter.
    public let parameter: MacroConditionParameter

    /// Pattern, in the manner of fnmatch(), against which to compare parameter values.
    public let valuePattern: String

    /// Initializes a macro condition; the pattern should be an `fnmatch()`-style pattern.
    public init(parameter: MacroConditionParameter, valuePattern: String) {
        self.parameter = parameter
        self.valuePattern = valuePattern
    }

    /// Returns a hash value based on the identity of the macro condition parameter and the pattern.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(parameter)
        hasher.combine(valuePattern)
    }

    public static func ==(lhs: MacroCondition, rhs: MacroCondition) -> Bool {
        return lhs.parameter == rhs.parameter && lhs.valuePattern == rhs.valuePattern
    }

    /// Evaluates the condition against an arbitrary parameter value, returning `true` if there’s a match and `false` if not.
    public func evaluate(_ value: String) -> Bool {
        do {
            return try fnmatch(pattern: valuePattern, input: value)
        } catch {
            return false
        }
    }

    /// Evaluates the condition against the dictionary of parameter values, returning `true` if there’s a match and `false` if not.  Missing values are interpreted as the empty value, and only match the condition if the `fnmatch()`-style pattern is either `*` (meaning that it matches everything).
    public func evaluate(_ paramValues: [MacroConditionParameter: [String]]) -> Bool {
        // Look up the values for the parameter.  If it’s missing, we evaluate to true iff the pattern is `*` (the “match anything” pattern).
        guard let values = paramValues[parameter], values.count > 0 else { return valuePattern == "*" }
        // Iterate through the values.  For each, we invoke fnmatch() until we find a match or we reach the end of the list.
        for value in values {
            do {
                if try fnmatch(pattern: valuePattern, input: value) {
                    return true
                }
            } catch {
                // ignore errors
            }
        }
        return false
    }

    // Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)

        // Don't serialize the condition parameter, but instead serialize its name so it can be looked up or created in the namespace during deserialization.
        serializer.serialize(parameter.name)
        serializer.serialize(valuePattern)

        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        // Get the namespace for the table from the deserializer's delegate.
        guard let delegate = deserializer.delegate as? (any MacroValueAssignmentTableDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a MacroValueAssignmentTableDeserializerDelegate") }

        try deserializer.beginAggregate(2)

        // Deserialize a condition parameter name and look it up or create it.
        let parmName: String = try deserializer.deserialize()
        if let aParm = delegate.namespace.lookupConditionParameter(parmName) {
            self.parameter = aParm
        }
        else {
            self.parameter = delegate.namespace.declareConditionParameter(parmName)
        }

        self.valuePattern = try deserializer.deserialize()
    }

    /// Returns a description of the macro condition.
    public var description: String {
        return "\(parameter)=\(valuePattern)"
    }
}
