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

private extension MacroValueAssignmentTable {
    /// Perform a table lookup with automatic handling of the optional overrides callback.
    func lookupMacro(_ macro: MacroDeclaration, overrideLookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> MacroValueAssignment? {
        // See if we have an overriding binding.
        if let override = overrideLookup?(macro) {
            return MacroValueAssignment(expression: override, conditions: nil, next: lookupMacro(macro))
        }

        // Otherwise, return the normal lookup.
        return lookupMacro(macro)
    }
}

/// A lightweight parameterized “view” of a MacroValueAssignmentTable, allowing clients to evaluate macro expressions under a particular set of conditions.  In the future a MacroEvaluationScope will also bind conditions to affect the values that are found in the table.  Unlike many of the other classes in the macro evaluation subsystem, MacroEvaluationScope is a prominent class from a client perspective — after declaring macros, parsing macro expressions, and creating macro-to-expression tables, all actual evaluation occurs through a MacroEvaluationScope.
public final class MacroEvaluationScope: Serializable, Sendable {
    static let evaluations = Statistic("MacroEvaluationScope.evaluations",
        "The number of evaluation requests.")
    static let evaluationsComputed = Statistic("MacroEvaluationScope.evaluationsComputed",
        "The number of evaluations which were actually computed (not cached).")
    static let exprEvaluations = Statistic("MacroEvaluationScope.exprEvaluations",
        "The number of expression evaluation requests.")

    private struct SubscopeKey: Hashable {
        let parameter: MacroConditionParameter
        let values: [String]
    }

    /// Macro value assignments.
    public let table: MacroValueAssignmentTable

    /// Convenience accessor to get the namespace for the scope's table, so clients can perform parsing of things they want to evaluate.
    public var namespace: MacroNamespace { return table.namespace }

    /// Mapping of condition parameters to values (affects lookup of conditional macro value assignments in `table`).  The values are an array to accommodate fallback conditional values supplied by base SDKs.
    public let conditionParameterValues: [MacroConditionParameter: [String]]

    /// Cache of evaluated string values.
    private let stringCache = Registry<MacroDeclaration, String>()

    /// Cache of evaluated string list values.
    private let stringListCache = Registry<MacroDeclaration, [String]>()

    /// The cache of subscopes, which are always shared.
    private let subscopes = Registry<SubscopeKey, MacroEvaluationScope>()

    /// Initializes the MacroEvaluationScope with `table` as its set of macro-to-value assignments.  Through this table, the scope is implicitly associated with the table’s MacroNamespace.  In the future, a MacroEvaluationScope will also bind conditions to affect the values that are found in the table.
    public init(table: MacroValueAssignmentTable, conditionParameterValues: [MacroConditionParameter: [String]] = [:]) {
        self.table = table
        self.conditionParameterValues = conditionParameterValues
    }

    /// Get a child scope with the given binding applied.
    ///
    /// The new binding will replace any current binding of the parameter, if present.
    ///
    /// This variant is intended to define a subscope with a binding using fallback condition values, which presently should not be needed.  Hence it is private.
    private func subscope(binding parameter: MacroConditionParameter, to values: [String]) -> MacroEvaluationScope {
        return subscopes.getOrInsert(SubscopeKey(parameter: parameter, values: values)) {
            var combinedConditionParameterValues = self.conditionParameterValues
            combinedConditionParameterValues[parameter] = values
            return MacroEvaluationScope(table: table, conditionParameterValues: combinedConditionParameterValues)
        }
    }

    /// Get a child scope with the given binding applied.
    ///
    /// The new binding will replace any current binding of the parameter, if present.
    public func subscope(binding parameter: MacroConditionParameter, to value: String) -> MacroEvaluationScope {
        return subscope(binding: parameter, to: [value])
    }

    /// Get the values for the macro condition parameter.
    ///
    /// This can be used to determine if the macro evaluation scope has been scoped to a particular condition parameter.
    public func values(for parameter: MacroConditionParameter) -> [String]? {
        return conditionParameterValues[parameter]
    }

    /// Evaluate the given string expression and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    public func evaluate(_ expr: MacroStringExpression, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        // FIXME: We should be able to leverage the cache within the macro evaluation context for expressions: <rdar://problem/31108515> Fix expression evaluation to not bypass scope evaluation cache
        MacroEvaluationScope.exprEvaluations.increment()

        // If the expression is a literal, return it immediately.
        if let literal = expr.asLiteralString {
            return literal
        }

        // Create an evaluation context and return the result of evaluating the expression as a string in that context.
        let resultBuilder = MacroEvaluationResultBuilder()
        expr.evaluate(context: MacroEvaluationContext(scope: self, lookup: lookup), resultBuilder: resultBuilder, alwaysEvalAsString: true)
        return resultBuilder.buildString()
    }

    /// Evaluate the given macro as a string (regardless of type) and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    public func evaluateAsString<T: MacroDeclaration>(_ macro: T, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        MacroEvaluationScope.evaluations.increment()

        func compute() -> String {
            MacroEvaluationScope.evaluationsComputed.increment()

            // Look up the first value, if any, that’s associated with the macro.
            guard let value = table.lookupMacro(macro, overrideLookup: lookup)?.firstMatchingCondition(conditionParameterValues) else {
                // No value, so we return an empty string in accordance with historical semantics.
                return ""
            }

            // If the value is a literal, return it immediately.
            if let literal = value.expression.asLiteralString {
                return literal
            }

            // Otherwise we create an evaluation context and return the result of evaluating the expression as a string in that context.
            let context = MacroEvaluationContext(scope: self, macro: macro, value: value, lookup: lookup)
            let resultBuilder = MacroEvaluationResultBuilder()
            value.expression.evaluate(context: context, resultBuilder: resultBuilder, alwaysEvalAsString: true)
            return resultBuilder.buildString()
        }

        if lookup == nil {
            // FIXME: It would be nice to have a more efficient cache here that used CAS to be more efficient than the current spinlock embedded in this object.
            return stringCache.getOrInsert(macro) {
                return compute()
            }
        }

        return compute()
    }

    /// Evaluate the given boolean macro and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    public func evaluate(_ macro: BooleanMacroDeclaration, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool {
        return evaluateAsString(macro, lookup: lookup).boolValue
    }

    /// Evaluate the given string macro and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    /// - Parameter default: If provided, this value is returned if the macro evaluates to an empty string.
    public func evaluate(_ macro: StringMacroDeclaration, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil, default: String = "") -> String {
        let value = evaluateAsString(macro, lookup: lookup)
        return !value.isEmpty ? value : `default`
    }

    /// Evaluate the given string macro and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    /// - Parameter default: If provided, this value is returned if the macro evaluates to an empty string.
    public func evaluate(_ macro: PathMacroDeclaration, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil, default: String = "") -> Path {
        let value = evaluateAsString(macro, lookup: lookup)
        return Path(!value.isEmpty ? value : `default`).normalize()
    }

    /// Evaluate the given enumeration macro and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    @_disfavoredOverload public func evaluate<T: EnumerationMacroType>(_ macro: EnumMacroDeclaration<T>, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> T? {
        return T(rawValue: evaluateAsString(macro, lookup: lookup))
    }

    /// Evaluate the given enumeration macro and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    public func evaluate<T: EnumerationMacroType>(_ macro: EnumMacroDeclaration<T>, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> T {
        return T(rawValue: evaluateAsString(macro, lookup: lookup)) ?? T.defaultValue
    }

    /// Evaluate the given string list macro expression and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    public func evaluate(_ expr: MacroStringListExpression, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Array<String> {
        // FIXME: We should be able to leverage the cache within the macro evaluation context for expressions: <rdar://problem/31108515> Fix expression evaluation to not bypass scope evaluation cache
        MacroEvaluationScope.exprEvaluations.increment()

        // Create an evaluation context and return the result of evaluating the expression as its native type (string or string list) in that context.
        let resultBuilder = MacroEvaluationResultBuilder()
        expr.evaluate(context: MacroEvaluationContext(scope: self, lookup: lookup), resultBuilder: resultBuilder)
        return resultBuilder.buildStringList()
    }

    /// Evaluate the given string list macro and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    public func evaluate(_ macro: StringListMacroDeclaration, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [String] {
        MacroEvaluationScope.evaluations.increment()

        func compute() -> [String] {
            MacroEvaluationScope.evaluationsComputed.increment()

            // Look up the first value, if any, that’s associated with the macro.
            guard let value = table.lookupMacro(macro, overrideLookup: lookup)?.firstMatchingCondition(conditionParameterValues) else {
                // No value, so we return an empty array in accordance with historical semantics.
                return []
            }
            // Otherwise we create an evaluation context and return the result of evaluating the expression as its native type (string or string list) in that context.
            let context = MacroEvaluationContext(scope: self, macro: macro, value: value, lookup: lookup)
            let resultBuilder = MacroEvaluationResultBuilder()
            value.expression.evaluate(context: context, resultBuilder: resultBuilder)
            return resultBuilder.buildStringList()
        }

        if lookup == nil {
            // FIXME: It would be nice to have a more efficient cache here that used CAS to be more efficient than the current spinlock embedded in this object.
            return stringListCache.getOrInsert(macro) {
                return compute()
            }
        }
        return compute()
    }



    /// Evaluate the given string macro and return the result.
    ///
    /// - Parameter lookup: If provided, this closure will be invoked for each initial macro lookup to potentially supply an alternate expression to evaluate.
    /// - Parameter default: If provided, this value is returned if the macro evaluates to an empty string.
    public func evaluate(_ macro: PathListMacroDeclaration, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil, default: String = "") -> [String] {
        MacroEvaluationScope.evaluations.increment()

        func compute() -> [String] {
            MacroEvaluationScope.evaluationsComputed.increment()

            // Look up the first value, if any, that's associated with the macro.
            guard let value = table.lookupMacro(macro, overrideLookup: lookup)?.firstMatchingCondition(conditionParameterValues) else {
                // No value, so we return an empty array in accordance with historical semantics.
                return []
            }
            // Otherwise we create an evaluation context and return the result of evaluating the expression as its native type (string or string list) in that context.
            let context = MacroEvaluationContext(scope: self, macro: macro, value: value, lookup: lookup)
            let resultBuilder = MacroEvaluationResultBuilder()
            value.expression.evaluate(context: context, resultBuilder: resultBuilder)
            return resultBuilder.buildStringList().map { Path($0).normalize().str }
        }

        if lookup == nil {
            // FIXME: It would be nice to have a more efficient cache here that used CAS to be more efficient than the current spinlock embedded in this object.
            return stringListCache.getOrInsert(macro) {
                return compute()
            }
        }
        return compute()
    }

    // MARK: Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(table)

            // Don't directly serialize the conditionParameterValues, but serialize the key-value pairs with only the names of the condition parameters so they can be looked up in the namespace during deserialization.
            serializer.serializeAggregate(conditionParameterValues.count) {
                for (parm, values) in conditionParameterValues.sorted(by: { $0.0.name < $1.0.name }) {
                    // Serialize the key-value pair.
                    serializer.serializeAggregate(2) {
                        serializer.serialize(parm.name)
                        serializer.serialize(values)
                    }
                }   // key-value pair
            }   // conditionParameterValues
        }   // the whole scope
    }

    public init(from deserializer: any Deserializer) throws {
        // Get the namespace for the table from the deserializer's delegate.
        guard let delegate = deserializer.delegate as? (any MacroValueAssignmentTableDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a MacroValueAssignmentTableDeserializerDelegate") }

        try deserializer.beginAggregate(2)
        self.table = try deserializer.deserialize()

        // Deserialize the conditionParameterValues, looking up each condition parameter in the namespace, and creating it if necessary.
        let count = try deserializer.beginAggregate()
        var conditionParameterValues = [MacroConditionParameter: [String]](minimumCapacity: count)
        for _ in 0..<count {
            // Deserialize a key-value pair
            try deserializer.beginAggregate(2)
            // Deserialize a condition parameter name and look it up or create it.
            let parmName: String = try deserializer.deserialize()
            let parm: MacroConditionParameter
            if let aParm = delegate.namespace.lookupConditionParameter(parmName) {
                parm = aParm
            }
            else {
                parm = delegate.namespace.declareConditionParameter(parmName)
            }

            // Deserialize the parameter values and add them to the dictionary.
            let values: [String] = try deserializer.deserialize()

            conditionParameterValues[parm] = values
        }
        self.conditionParameterValues = conditionParameterValues
    }
}

/// Private object that keeps track of the state of one level of nested macro evaluation.  Evaluation contexts are similar to activation records (stack frames) in a normal computer program, in that each keeps state for one level and that each refers back up to its parent context.  An evaluation context keeps track of the macro definition and macro assignment value (if any) to which it refers, and can return next value of each declaration so that nested `$(inherited)` references work correctly.
final class MacroEvaluationContext {
    /// Scope in which the evaluation is being carried out.
    let scope: MacroEvaluationScope

    /// Reference to the context that invoked this one (used for nested macro expression references).
    let parent: MacroEvaluationContext?

    /// Macro declaration to which this context refers, if any; the outermost evaluation context of a macro expression evaluation won’t have one, for example.
    let macro: MacroDeclaration?

    /// Value whose expression is being evaluated in this context, if any; this is to support recursive macro references, of which `$(inherited)` is a special case.
    let value: MacroValueAssignment?

    /// If provided, a closure used to resolve macro declarations to overriding expressions, which implicitly take precedence over all values in the scope.
    let lookup: ((MacroDeclaration) -> MacroExpression?)?

    /// Initialize the evaluation context with the scope in which evaluation takes place (which is needed for lookup of referenced macros), with the macro being evaluated (if any; in the case of a direct expression evaluation, there isn’t a macro), with `value` as the “current value”, i.e. the value assignment node at which the expression that’s currently being evaluated was found (if any; in the case of a direct expression evaluation, there isn’t any), and with the parent context that caused this one to be invoked (if any; the top-level context doesn’t have a parent).
    init(scope: MacroEvaluationScope, macro: MacroDeclaration? = nil, value: MacroValueAssignment? = nil, parent: MacroEvaluationContext? = nil, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) {
        self.scope = scope
        self.macro = macro
        self.value = value
        self.parent = parent
        self.lookup = lookup
    }

    /// Returns the next inherited macro value (i.e. the next value for the same macro declaration as the context represents, which is what the `$(inherited)` syntax refers to in a macro expression).  Returns nil if there is no next value.
    private func nextInheritedValue() -> MacroValueAssignment? {
        // Just return the next value (if any).
        return value?.next?.firstMatchingCondition(scope.conditionParameterValues)
    }

    /// Returns the next value for `macro` (this works correctly if even `macro` is the same as the macro declaration associated with the context, i.e. the inherited-value case — in this case the result is exactly the same as invoking `nextInheritedValue()`).  Returns nil if there is no next value.
    func nextValueForMacro(_ macro: MacroDeclaration) -> MacroValueAssignment? {
        var currentContext: MacroEvaluationContext = self
        while true {
            // If it’s the same macro as ours, it’s really just an inheritance lookup.
            if macro === currentContext.macro {
                return currentContext.nextInheritedValue()
            }
            // Otherwise, if we have a parent context, we defer the question to it.
            if let parent = currentContext.parent {
                currentContext = parent
            } else {
                // If we get this far, we need to look up in our scope’s table.  We might or might not find it.
                return currentContext.scope.table.lookupMacro(macro, overrideLookup: currentContext.lookup)?.firstMatchingCondition(currentContext.scope.conditionParameterValues)
            }
        }
    }
}

/// Evaluate the given macro assignment as a string (regardless of type) using the given scope and return the result.
/// - remark: This is subtly different from the evaluation methods in `MacroEvaluationScope` and is only used when evaluating for the build settings editor, so it is here so as not to complicate the API of the scope class.
public func evaluateAsString(_ asgn: MacroValueAssignment, macro: MacroDeclaration, scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
    let expr = asgn.expression

    // If the expression is a literal, return it immediately.
    if let literal = expr.asLiteralString {
        return literal
    }

    // Create an evaluation context and return the result of evaluating the expression as its native type (string or string list) in that context.
    let resultBuilder = MacroEvaluationResultBuilder()
    let context = MacroEvaluationContext(scope: scope, macro: macro, value: asgn, lookup: lookup)
    expr.evaluate(context: context, resultBuilder: resultBuilder, alwaysEvalAsString: true)
    return resultBuilder.buildString()
}
