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

/// A mapping from macro declarations to corresponding macro value assignments, each of which is a linked list of macro expressions in precedence order.  At the moment it doesn’t support conditional assignments, but that functionality will be implemented soon.
public struct MacroValueAssignmentTable: Serializable, Sendable {
    /// Namespace
    public let namespace: MacroNamespace

    /// Maps macro declarations to corresponding linked lists of assignments.
    public var valueAssignments: [MacroDeclaration: MacroValueAssignment]

    private init(namespace: MacroNamespace, valueAssignments: [MacroDeclaration: MacroValueAssignment]) {
        self.namespace = namespace
        self.valueAssignments = valueAssignments
    }

    public init(namespace: MacroNamespace) {
        self.init(namespace: namespace, valueAssignments: [:])
    }

    /// Convenience initializer to create a `MacroValueAssignmentTable` from another instance (i.e., to create a copy).
    public init(copying table: MacroValueAssignmentTable) {
        self.init(namespace: table.namespace, valueAssignments: table.valueAssignments)
    }

    /// Remove all assignments for the given macro.
    public mutating func remove(_ macro: MacroDeclaration) {
        valueAssignments.removeValue(forKey: macro)
    }

    /// Adds a mapping from `macro` to the literal string `value`.
    public mutating func push(_ macro: BooleanMacroDeclaration, literal: Bool, conditions: MacroConditionSet? = nil) {
        assert(namespace.lookupMacroDeclaration(macro.name) === macro)
        push(macro, namespace.parseLiteralString(literal ? "YES" : "NO"), conditions: conditions)
    }

    /// Adds a mapping from `macro` to the literal enumeration value.
    public mutating func push<T: EnumerationMacroType>(_ macro: EnumMacroDeclaration<T>, literal: T, conditions: MacroConditionSet? = nil) {
        assert(namespace.lookupMacroDeclaration(macro.name) === macro)
        push(macro, namespace.parseLiteralString(literal.rawValue), conditions: conditions)
    }

    /// Adds a mapping from `macro` to the literal string `value`.
    public mutating func push(_ macro: StringMacroDeclaration, literal: String, conditions: MacroConditionSet? = nil) {
        assert(namespace.lookupMacroDeclaration(macro.name) === macro)
        push(macro, namespace.parseLiteralString(literal), conditions: conditions)
    }

    /// Adds a mapping from `macro` to the given literal string list `value`.
    public mutating func push(_ macro: StringListMacroDeclaration, literal: [String], conditions: MacroConditionSet? = nil) {
        assert(namespace.lookupMacroDeclaration(macro.name) === macro)
        push(macro, namespace.parseLiteralStringList(literal), conditions: conditions)
    }

    /// Adds a mapping from `macro` to the literal string `value`.
    public mutating func push(_ macro: PathMacroDeclaration, literal: String, conditions: MacroConditionSet? = nil) {
        assert(namespace.lookupMacroDeclaration(macro.name) === macro)
        push(macro, namespace.parseLiteralString(literal), conditions: conditions)
    }

    /// Adds a mapping from `macro` to the given literal string list `value`.
    public mutating func push(_ macro: PathListMacroDeclaration, literal: [String], conditions: MacroConditionSet? = nil) {
        assert(namespace.lookupMacroDeclaration(macro.name) === macro)
        push(macro, namespace.parseLiteralStringList(literal), conditions: conditions)
    }


    /// Adds a mapping from `macro` to `value`, inserting it ahead of any already existing assignment for the same macro.  Unless the value refers to the lower-precedence expression (using `$(inherited)` notation), any existing assignments are shadowed but not removed.
    public mutating func push(_ macro: MacroDeclaration, _ value: MacroExpression, conditions: MacroConditionSet? = nil) {
        assert(namespace.lookupMacroDeclaration(macro.name) === macro)
        // Validate the type.
        assert(macro.type.matchesExpressionType(value))
        valueAssignments[macro] = MacroValueAssignment(expression: value, conditions: conditions, next: valueAssignments[macro])
    }

    /// Adds a mapping from each of the macro-to-value mappings in `otherTable`, inserting them ahead of any already existing assignments in the receiving table.  The other table isn’t affected in any way (in particular, no reference is kept from the receiver to the other table).
    public mutating func pushContentsOf(_ otherTable: MacroValueAssignmentTable) {
        for (macro, firstAssignment) in otherTable.valueAssignments {
            valueAssignments[macro] = insertCopiesOfMacroValueAssignmentNodes(firstAssignment, inFrontOf: valueAssignments[macro])
        }
    }

    /// Looks up and returns the first (highest-precedence) macro value assignment for `macro`, if there is one.
    public func lookupMacro(_ macro: MacroDeclaration) -> MacroValueAssignment? {
        return valueAssignments[macro]
    }

    /// Looks up whether an assignment for the given macro exists.
    public func contains(_ macro: MacroDeclaration) -> Bool {
        return valueAssignments.contains(macro)
    }

    /// Returns `true` if the table contains no entries.
    public var isEmpty: Bool {
        return valueAssignments.isEmpty
    }

    public func bindConditionParameter(_ parameter: MacroConditionParameter, _ conditionValues: [String]) -> MacroValueAssignmentTable {
        return bindConditionParameter(parameter, conditionValues.map { .string($0) })
    }

    public func bindConditionParameter(_ parameter: MacroConditionParameter, _ filter: any CustomConditionParameterCondition) -> MacroValueAssignmentTable {
        return bindConditionParameter(parameter, [.customCondition(filter)])
    }

    public protocol CustomConditionParameterCondition {
        func matches(_ condition: MacroCondition) -> Bool
    }

    private enum ConditionValue {
        case customCondition(_ custom: any CustomConditionParameterCondition)
        case string(_ string: String)

        func evaluate(_ condition: MacroCondition) -> Bool {
            switch self {
            case .customCondition(let customCondition):
                return customCondition.matches(condition)
            case .string(let string):
                return condition.evaluate(string)
            }
        }
    }

    /// Returns a new `MacroValueAssignmentTable` formed by "binding" a condition parameter to a specific value.  Assignments that are conditional on the given parameter and that match one of the given literal values will become unconditional on that parameter.  Assignments that are conditional on the given parameter and that do not match any of the given literal values will be omitted.  All other conditions will be preserved.  If none of the assignments in the receiver are conditional on the given parameter, the resulting macro assignment table will be equal to the receiver.
    private func bindConditionParameter(_ parameter: MacroConditionParameter, _ conditionValues: [ConditionValue]) -> MacroValueAssignmentTable {
        // Go through the assignments
        var table = MacroValueAssignmentTable(namespace: namespace)
        for (macro, firstAssignment) in valueAssignments {
            // The `firstAssignment` is the head of a linked list of assignments, each of which might have a condition set.

            // Local helper function to find the first condition value that matches at least one condition in any of the assignments.  There might not be one (if there are no conditions that match any of the candidate values).
            func findEffectiveConditionValue() -> ConditionValue? {
                // Go through the condition values in order, returning the first one for which any condition of any of the assignments matches.
                for conditionValue in conditionValues {
                    // Iterate over the macro value assignments until we find a conditional that matches the current value.
                    var nextAssignment: MacroValueAssignment? = firstAssignment
                    while let assignment = nextAssignment {
                        // If the assignment is conditioned on the parameter and it matches, we have found the effective condition.
                        if let condition = assignment.conditions?[parameter], conditionValue.evaluate(condition) {
                            return conditionValue
                        }
                        nextAssignment = assignment.next
                    }
                }
                return nil
            }

            // Find the effective condition value for this macro, if there is one.
            guard let effectiveConditionValue = findEffectiveConditionValue() else {
                // None of the assignments are conditioned on the parameter, so there's nothing to bind for this list of assignments.
                table.valueAssignments[macro] = firstAssignment
                continue
            }

            // We only get this far if a condition value matches one of the conditions for the given parameter for at least one of the assignments.  This means that we have some actual binding to do.

            // Local function to push a chain of assignments while evaluating and binding any assignment that is conditioned on the specified parameter.
            func bindAndPushAssignment(_ assignment: MacroValueAssignment) {
                // First deal with the next assignment, so that we end up pushing assignments in the same order as the original list.
                if let nextAssignment = assignment.next {
                    bindAndPushAssignment(nextAssignment)
                }

                // Evaluate the condition for the parameter we're binding (if any).
                if let conditions = assignment.conditions, let condition = conditions[parameter] {
                    // Assignment is conditioned on the specified parameter; we need to evaluate it in order to decide what to do.
                    if effectiveConditionValue.evaluate(condition) == true {
                        // Condition evaluates to true, so we push an assignment with a condition set that excludes the condition.
                        let filteredConditions = conditions.conditions.filter{ $0.parameter != parameter }
                        table.push(macro, assignment.expression, conditions: filteredConditions.isEmpty ? nil : MacroConditionSet(conditions: filteredConditions))
                    }
                    else {
                        // Condition evaluates to false, so we elide the assignment.
                    }
                }
                else {
                    // Assignment isn't conditioned on the specified parameter, so we just push it as-is.
                    table.push(macro, assignment.expression, conditions: assignment.conditions)
                }
            }
            bindAndPushAssignment(firstAssignment)

        }
        return table
    }

    /// Dumps the contents of the receiver, including types and assignments, sorted alphabetically by macro name.
    ///
    /// To pretty-print the result of `dump()` from lldb, use:
    ///
    ///     p print(table.dump())
    public func dump() -> String {
        var result = ""
        for key in valueAssignments.keys.sorted(by: \.name) {
            result += dump(key)
        }
        return result
    }

    /// Dumps the list of assignments for a single macro in the receiver.
    public func dump(_ macro: MacroDeclaration) -> String {
        guard let value = valueAssignments[macro] else {
            return "(none)\n"
        }
        return "'\(macro.name)' := \(value.dump()) (type: \(macro.type))\n"
    }

    // MARK: Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)

        // We don't directly serialize MacroDeclarations, but rather serialize their contents "by hand" so when we deserialize we can re-use existing declarations in our namespace.
        serializer.beginAggregate(valueAssignments.count)
        // NOTE: Do *NOT* use `sorted(byKey:)` here until:
        //   <rdar://problem/49181989> Incredibly slow sort when using what appears to be a trivial Dictionary extension (esp. when using KeyPath)
        // is resolved.
        for (decl, asgn) in valueAssignments.sorted(by: { $0.0.name < $1.0.name }) {
            // Serialize the key-value pair.
            serializer.beginAggregate(2)
            // Serialize the contents of the MacroDeclaration.
            serializer.beginAggregate(2)
            serializer.serialize(decl.name)
            switch decl.type {
            case .boolean: serializer.serialize(0)
            case .string: serializer.serialize(1)
            case .stringList: serializer.serialize(2)
            case .userDefined: serializer.serialize(3)
            case .path: serializer.serialize(4)
            case .pathList: serializer.serialize(5)
            }
            serializer.endAggregate()   // MacroDeclaration key
            // Serialize the MacroValueAssignment.
            serializer.serialize(asgn)
            serializer.endAggregate()   // key-value pair
        }
        serializer.endAggregate()       // valueAssignments

        serializer.endAggregate()       // the whole table
    }

    public init(from deserializer: any Deserializer) throws {
        // Get our namespace from the deserializer's delegate.
        guard let delegate = deserializer.delegate as? (any MacroValueAssignmentTableDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a MacroValueAssignmentTableDeserializerDelegate") }
        self.namespace = delegate.namespace
        self.valueAssignments = [:]

        // Deserialize the table.
        try deserializer.beginAggregate(1)

        // Iterate over all the key-value pairs.
        let count: Int = try deserializer.beginAggregate()
        for _ in 0..<count {
            // Deserialize a key-value pair.
            try deserializer.beginAggregate(2)
            // Deserialize the contents of the MacroDeclaration key.
            try deserializer.beginAggregate(2)
            let name: String = try deserializer.deserialize()
            let typeCode: Int = try deserializer.deserialize()
            // Lookup or declare the declaration in our namespace.
            let decl: MacroDeclaration
            if let aDecl = delegate.namespace.lookupMacroDeclaration(name) {
                // Check that the type of the declaration is what we expect.
                let type: MacroType
                switch typeCode {
                case 0: type = .boolean
                case 1: type = .string
                case 2: type = .stringList
                case 3: type = .userDefined
                case 4: type = .path
                case 5: type = .pathList
                default: throw DeserializerError.deserializationFailed("Unrecognized code for MacroType for MacroDeclaration \(name): \(typeCode)")
                }
                guard aDecl.type == type else { throw DeserializerError.incorrectType("Mismatched type for MacroDeclaration \(name): expected '\(type)', found '\(aDecl.type)' from code '\(typeCode)'.") }
                decl = aDecl
            }
            else {
                // Declare the declaration using the type we deserialized.
                switch typeCode {
                case 0: decl = delegate.namespace.lookupOrDeclareMacro(BooleanMacroDeclaration.self, name)
                case 1: decl = delegate.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, name)
                case 2: decl = delegate.namespace.lookupOrDeclareMacro(StringListMacroDeclaration.self, name)
                case 3: decl = delegate.namespace.lookupOrDeclareMacro(UserDefinedMacroDeclaration.self, name)
                case 4: decl = delegate.namespace.lookupOrDeclareMacro(PathMacroDeclaration.self, name)
                case 5: decl = delegate.namespace.lookupOrDeclareMacro(PathListMacroDeclaration.self, name)
                default: throw DeserializerError.deserializationFailed("Unrecognized code for MacroType for MacroDeclaration \(name): \(typeCode)")
                }
            }

            // Deserialize the MacroValueAssignment.
            let asgn: MacroValueAssignment = try deserializer.deserialize()

            // Add it to the dictionary.
            self.valueAssignments[decl] = asgn
        }
    }
}

/// A delegate which must be used to deserialize a `MacroValueAssignmentTable`.
public protocol MacroValueAssignmentTableDeserializerDelegate: DeserializerDelegate {
    /// The `MacroNamespace` to use to deserialize `MacroDeclaration`s and `MacroConditionParameter`s in a table.
    var namespace: MacroNamespace { get }
}

/// Private class that represents a single node in the linked list of values assigned to a macro in a MacroValueAssignmentTable.
public final class MacroValueAssignment: Serializable, CustomStringConvertible, Sendable {

    /// Parsed macro value expression represented by this node.
    public let expression: MacroExpression

    /// Conditions set, if any.  Unconditional values are always used, but conditionals are only used if the condition parameters evaluate to true.
    public let conditions: MacroConditionSet?

    /// Reference to the next (lower precedence) assignment in the linked list, or nil if this is the last one.
    public let next: MacroValueAssignment?

    /// Initializes the macro value assignment to represent `expression`, with the next existing macro value assignment (if any).
    init(expression: MacroExpression, conditions: MacroConditionSet? = nil, next: MacroValueAssignment?) {
        self.expression = expression
        self.conditions = conditions
        self.next = next
    }

    /// Returns the first macro value assignment that is reachable from the receiver and whose conditions match the given set of parameter values, or nil if there is no such assignment value.  The returned assignment may be the receiver itself, or it may be any assignment that’s downstream in the linked list of macro value assignments, or it may be nil if there is none.  Unconditional macro value assignments are considered to match any conditions.  Conditions that reference parameters that don’t have a value in `paramValues` are only considered to match if the match pattern is `*`, i.e. the “match-anything” pattern (which is effectively a no-op).
    func firstMatchingCondition(_ paramValues: [MacroConditionParameter: [String]]) -> MacroValueAssignment? {
        // Starting with ourself, skip past any assignments that have one or more conditions that evaluate to false with respect to `conditions`.
        var value: MacroValueAssignment? = self
        while let v = value {
            // If there are no conditions at all, we have a match, so we can stop looking.
            guard let c = v.conditions else { break }
            // If we do have conditions we need to check if they all match; if so, we can also stop looking.
            if c.evaluate(paramValues) { break }
            // Otherwise skip this value and go on to the next one (if any).
            value = v.next
        }
        return value
    }

    /// Returns the first macro value assignment that is reachable from the receiver which has exactly the given `MacroConditionSet`.
    func firstMatchingConditionSet(_ set: MacroConditionSet?) -> MacroValueAssignment? {
        var value: MacroValueAssignment? = self
        while let v = value {
            if v.conditions == set { return v }
            value = v.next
        }
        return value
    }

    public var debugDescription: String {
        "\(conditions?.description ?? "")\'\(expression.stringRep)\'"
    }

    public var description: String {
        "MacroValueAssignment<\(debugDescription)>"
    }

    /// Dumps the list of assignments (condition sets and expressions) starting with the receiver.
    ///
    /// - remark: The receiver doesn't know its macro declaration or type.  Only the table it's part of knows that.
    public func dump() -> String {
        var value = self
        var result = "\(value.debugDescription)"
        while let next = value.next {
            value = next
            result += " -> \(value.debugDescription)"
        }
        return result
    }

    // MARK: Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(3)
        serializer.serialize(expression)
        serializer.serialize(conditions)
        serializer.serialize(next)
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.expression = try deserializer.deserialize()
        self.conditions = try deserializer.deserialize()
        self.next = try deserializer.deserialize()
    }
}

/// Private function that inserts a copy of the given linked list of MacroValueAssignments (starting at `srcAsgn`) in front of `dstAsgn` (which is optional).  The order of the copies is the same as the order of the originals, and the last one will have `dstAsgn` as its `next` property.  This function returns the copy that corresponds to `srcAsgn` so the client can add a reference to it wherever it sees fit.
private func insertCopiesOfMacroValueAssignmentNodes(_ srcAsgn: MacroValueAssignment, inFrontOf dstAsgn: MacroValueAssignment?) -> MacroValueAssignment {
    // If we aren't inserting in front of anything, we can preserve the input as is.
    //
    // This is a very important optimization as it ensures that inserting a pre-bound table into an otherwise empty table will avoid duplicating assignments.
    if dstAsgn == nil {
        return srcAsgn
    }

    // If the source list contains a literal, we know evaluation will never look past it -- thus we can bypass the append entirely and share the node.
    if srcAsgn.containsUnconditionalLiteralInChain {
        return srcAsgn
    }

    if let srcNext = srcAsgn.next {
        return MacroValueAssignment(expression: srcAsgn.expression, conditions:srcAsgn.conditions, next: insertCopiesOfMacroValueAssignmentNodes(srcNext, inFrontOf: dstAsgn))
    }
    else {
        return MacroValueAssignment(expression: srcAsgn.expression, conditions:srcAsgn.conditions, next: dstAsgn)
    }
}

private extension MacroValueAssignment {
    /// Returns true if unconditional assignment in the list is a literal.
    var containsUnconditionalLiteralInChain: Bool {
        return (expression.isLiteral && conditions == nil) || (next?.containsUnconditionalLiteralInChain ?? false)
    }
}
