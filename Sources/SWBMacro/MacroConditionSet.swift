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

public final class MacroConditionSet : Serializable, CustomStringConvertible, Sendable {
    /// The conditions, ordered from highest to lowest priority.
    public let conditions: Array<MacroCondition>

    public init(conditions: Array<MacroCondition>) {
        // We get a set of conditions as input, and we preserve the order.
        self.conditions = conditions
    }

    /// Returns the condition for the parameter, if any.
    public subscript(_ parameter: MacroConditionParameter) -> MacroCondition? {
        return conditions.first{ $0.parameter === parameter }
    }

    /// Evaluates the condition against the dictionary of parameter values, returning `true` if there’s a match and `false` if not.  Missing values are interpreted as the empty value, and only match the condition if the `fnmatch()`-style pattern is `*` (meaning that it matches everything).
    public func evaluate(_ paramValues: [MacroConditionParameter: [String]]) -> Bool {
        // Return true if and only if all conditions return true.
        return conditions.reduce(true, { $0 && $1.evaluate(paramValues) })
    }

    public var description: String {
        return conditions.map{ "[\($0)]" }.joined(separator: "")
    }

    // Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(conditions)
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.conditions = try deserializer.deserialize()
    }
}

extension MacroConditionSet: Equatable {
    public static func ==(lhs: MacroConditionSet, rhs: MacroConditionSet) -> Bool {
        return lhs.conditions == rhs.conditions
    }
}
