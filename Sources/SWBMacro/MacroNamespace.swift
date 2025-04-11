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
import Synchronization

/// A namespace represents a set of named macro declarations and (in the future) a set of named macro conditions.  MacroNamespace is the starting point for many of the APIs of the macro evaluation subsystem: declaring macros and conditions, parsing macro expressions as strings or string lists, etc.  A namespace can reference an underlying namespace — this can be used to share, for example, built-in macro declarations among various projects, while still allowing each project to declare custom macros that don’t interfere with each other.
///
/// This class *is* thread-safe (macros may be declared and looked up concurrently).
public final class MacroNamespace: CustomDebugStringConvertible, Encodable, Sendable {
    static let parsedStrings = Statistic("MacroNamespace.parsedStrings",
        "The number of strings which were parsed into macro expressions.")
    static let parsedLists = Statistic("MacroNamespace.parsedLists",
        "The number of lists which were parsed into macro expression.")

    /// Parent namespace.  All declarations in the parent namespace are visible to this namespace, and the same rules regarding type conflicts apply.
    let parentNamespace: MacroNamespace?

    /// Maps macro names to declarations.  Each declaration is of one of the concrete subclasses of MacroDeclaration, based on its type.
    private let macroRegistry = LockedValue<Dictionary<String,MacroDeclaration>>([:])

    private enum CodingKeys: String, CodingKey {
        case parentNamespace
    }

    /// Creates a new namespace with an optional parent namespace on which the new namespace will be based.  All declarations in the parent namespace are visible to this namespace, and the same rules regarding type conflicts apply.  Normally the parent namespace should have been completely set up, i.e. had all its intended declarations completed, before other namespaces refer to it as a parent.  If new declarations are made in the parent namespace after other namespaces have already started referencing it as a parent, type conflicts could arise if the same name is declared with different types.
    public init(parent: MacroNamespace? = nil, debugDescription: String? = nil) {
        self.parentNamespace = parent
        self.debugDescription = debugDescription ?? ""
    }

    /// Descriptive label, for diagnostic purposes.
    public let debugDescription: String

    /// Looks up and returns the macro declaration that's associated with ‘name’, if any.  The name is not allowed to be the empty string.
    public func lookupMacroDeclaration(_ name: String) -> MacroDeclaration? {
        return macroRegistry.withLock { macroRegistry in
            return _lookupMacroDeclarationUnlocked(name, in: macroRegistry)
        }
    }

    /// Perform an unlocked macro lookup.
    ///
    /// The macro registry lock must be held while this is called.
    private func _lookupMacroDeclarationUnlocked(_ name: String, in macroRegistry: [String: MacroDeclaration]) -> MacroDeclaration? {
        precondition(name != "")
        if let macroDecl = macroRegistry[name] {
            return macroDecl
        }
        return parentNamespace?.lookupMacroDeclaration(name)
    }

    /// Private function to instantiate a macro declaration of a particular type concrete type.
    private func declareMacro<MacroDeclarationType: MacroDeclaration>(_ name: String) throws -> MacroDeclarationType {
        return try macroRegistry.withLock { macroRegistry in
            // Check if we already have a declaration for that name.  This will also check any ancestor namespaces.
            if let macroDecl = _lookupMacroDeclarationUnlocked(name, in: macroRegistry) {
                // We have one, so check that its type is the same as the new one.
                guard let specificMacroDecl = macroDecl as? MacroDeclarationType else {
                    throw MacroDeclarationError.conflictingMacroDeclarationType(type: MacroDeclarationType(name: name).type, previousType: macroDecl.type, name: name)
                }
                return specificMacroDecl
            }

            // We don’t already have a declaration, so create one and register it.  It will be visible to any of our descendant namespaces.
            let macroDecl = MacroDeclarationType(name: name)
            macroRegistry[name] = macroDecl
            return macroDecl
        }
    }

    /// Declares `name` as a boolean macro, by either returning an existing declaration if one has already been registered, or by registering and returning a new one.  The name is not allowed to be the empty string.  If there is an existing declaration associated with `name` and if it is not a boolean macro declaration, this method throws a ConflictingMacroDeclarationType exception.
    @discardableResult
    public func declareBooleanMacro(_ name: String) throws -> BooleanMacroDeclaration {
        return try declareMacro(name)
    }

    /// Declares `name` as an enumeration macro whose value is of type `T`, by either returning an existing declaration if one has already been registered, or by registering and returning a new one.  The name is not allowed to be the empty string.  If there is an existing declaration associated with `name` and if it is not an enumeration macro declaration, this method throws a ConflictingMacroDeclarationType exception.
    @discardableResult
    public func declareEnumMacro<T: EnumerationMacroType>(_ name: String) throws -> EnumMacroDeclaration<T> {
        return try declareMacro(name)
    }

    /// Declares `name` as a string macro, by either returning an existing declaration if one has already been registered, or by registering and returning a new one.  The name is not allowed to be the empty string.  If there is an existing declaration associated with `name` and if it is not a string macro declaration, this method throws a ConflictingMacroDeclarationType exception.
    @discardableResult
    public func declareStringMacro(_ name: String) throws -> StringMacroDeclaration {
        return try declareMacro(name)
    }

    /// Declares `name` as a string list macro, by either returning an existing declaration if one has already been registered, or by registering and returning a new one.  The name is not allowed to be the empty string.  If there is an existing declaration associated with `name` and if it is not a string list macro declaration, this method throws a ConflictingMacroDeclarationType exception.
    @discardableResult
    public func declareStringListMacro(_ name: String) throws -> StringListMacroDeclaration {
        return try declareMacro(name)
    }

    /// Declares `name` as a path macro, by either returning an existing declaration if one has already been registered, or by registering and returning a new one.  The name is not allowed to be the empty string.  If there is an existing declaration associated with `name` and if it is not a string macro declaration, this method throws a ConflictingMacroDeclarationType exception.
    @discardableResult
    public func declarePathMacro(_ name: String) throws -> PathMacroDeclaration {
        return try declareMacro(name)
    }

    /// Declares `name` as a path list, by either returning an existing declaration if one has already been registered, or by registering and returning a new one.  The name is not allowed to be the empty string.  If there is an existing declaration associated with `name` and if it is not a string macro declaration, this method throws a ConflictingMacroDeclarationType exception.
    @discardableResult
    public func declarePathListMacro(_ name: String) throws -> PathListMacroDeclaration {
        return try declareMacro(name)
    }

    public func lookupOrDeclareMacro<MacroDeclarationType: MacroDeclaration>(_ type: MacroDeclarationType.Type, _ name: String) -> MacroDeclaration {
        return macroRegistry.withLock { macroRegistry in
            // Return the macro, if declared.
            if let macroDecl = _lookupMacroDeclarationUnlocked(name, in: macroRegistry) {
                return macroDecl
            }

            // Otherwise declare it as the specified type.
            let macroDecl = MacroDeclarationType(name: name)
            macroRegistry[name] = macroDecl
            return macroDecl
        }
    }

    /// Declares `name` as a user-defined macro (which currently means that the type isn’t known — in the future we hope to support typed user macros), by either returning an existing declaration if one has already been registered, or by registering and returning a new one.  The name is not allowed to be the empty string.  If there is an existing declaration associated with `name` and if it is not a user-defined macro declaration, this method throws a ConflictingMacroDeclarationType exception.
    @discardableResult
    public func declareUserDefinedMacro(_ name: String) throws -> UserDefinedMacroDeclaration {
        return try declareMacro(name)
    }

    /// Maps condition parameter names to condition parameters.  Each declaration is an instance of MacroConditionParameter.
    private let conditionParameters = LockedValue<Dictionary<String,MacroConditionParameter>>([:])

    /// Looks up and returns the macro condition parameter that's associated with ‘name’, if any.  The name is not allowed to be the empty string.
    public func lookupConditionParameter(_ name: String) -> MacroConditionParameter? {
        conditionParameters.withLock { conditionParameters in
            _lookupConditionParameterUnlocked(name, in: conditionParameters)
        }
    }

    private func _lookupConditionParameterUnlocked(_ name: String, in conditionParameters: [String: MacroConditionParameter]) -> MacroConditionParameter? {
        precondition(name != "")
        if let condParam = conditionParameters[name] {
            return condParam
        }
        return parentNamespace?.lookupConditionParameter(name)
    }

    /// Declares `name` as a condition parameter, which can then be used in conditional macro value assignments.  If the namespace already has a condition with the specified name, this function returns it; otherwise it creates and returns a new MacroConditionParameter object.
    public func declareConditionParameter(_ name: String) -> MacroConditionParameter {
        conditionParameters.withLock { conditionParameters in
            // Check if we already have a condition parameter with that name.  This will also check any ancestor namespaces.
            if let condParam = _lookupConditionParameterUnlocked(name, in: conditionParameters) {
                // We have one, so return it.
                return condParam
            }
            // We don’t already have a condition parameter with that name, so create one and register it.  It will be visible to any of our descendant namespaces.
            let condParam = MacroConditionParameter(name: name)
            conditionParameters[name] = condParam
            return condParam
        }
    }

    // Private parser delegate class that emits “evaluation instructions” to create a “compiled” macro evaluation “program”.  This parser delegate handles both string expressions and string list expressions.
    private final class MacroExpressionInstructionEmitterDelegate: MacroExpressionParserDelegate {
        let programBuilder: MacroEvaluationProgramBuilder
        var alwaysEvalAsStringNestingLevel = 0
        var macroNameNestingLevel = 0
        let diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)?

        init(programBuilder: MacroEvaluationProgramBuilder, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)?) {
            self.programBuilder = programBuilder
            self.diagnosticsHandler = diagnosticsHandler
        }
        func foundLiteralStringFragment(_ string: Input, parser: MacroExpressionParser) {
            // Emit an instruction to append a literal sequence of characters to the result buffer at the top of the buffer stack.  Note that we still emit an instruction even if `string` is the empty string — even though it doesn’t affect the character contents of the result buffer, appending an empty string is still important in order to make any pending list element separator concrete.
            //
            // FIXME: Switch this to building up a UTF8 representation:
            programBuilder.emit(.appendLiteral(String(string)!))
        }
        func foundStringFormOnlyLiteralStringFragment(_ string: MacroExpressionParserDelegate.Input, parser: MacroExpressionParser) {
            // Emit an instruction to append a literal sequence of characters to the result buffer at the top of the buffer stack, but only if the expression is being evaluated as a string (rather than a string-list).  Note that we still emit an instruction even if `string` is the empty string — even though it doesn’t affect the character contents of the result buffer, appending an empty string is still important in order to make any pending list element separator concrete.
            //
            // FIXME: Switch this to building up a UTF8 representation:
            programBuilder.emit(.appendStringFormOnlyLiteral(String(string)!))
        }
        func foundStartOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {
            // Emit an instruction to push a new subresult buffer into which we’ll evaluate the subexpression.  At the end of the subexpression, this subresult buffer will be popped from the buffer stack, and its final contents will be appended to the subresult buffer that then becomes the top-of-stack.
            programBuilder.emit(.beginSubresult)

            // If this substitution subexpression is one in which we should always evaluate a string, we increment the “evaluate-as-string nesting level”.  This affects the flavor of any evaluation instructions we emit.  This increment will be balanced by a decrement in `foundEndOfSubstitutionSubexpression()`.
            if alwaysEvalAsString { alwaysEvalAsStringNestingLevel += 1 }
        }
        func foundStartOfMacroName(parser: MacroExpressionParser) {
            // Emit an instruction to push a new subresult buffer into which we’ll evaluate the macro name to be looked up.  After evaluating the name expression as a string, this subresult buffer will be popped from the buffer stack, and its final contents will be used as a name of a macro to look up and evaluate.
            programBuilder.emit(.beginSubresult)

            // We also increment the macro name nesting level so we know to evaluate macro names as strings, regardless of whether they’re in quotes (this matches the Xcode semantics).  This increment will be balanced by a decrement in `foundEndOfMacroName()`.
            // FIXME: It might be interesting to allow macro names to be evaluated as lists.  This would result in the lookup of each of the named macros in the list, in turn.  But it isn’t clear that this is very useful, given that lists of evaluated values can just as easily be composed.
            macroNameNestingLevel += 1
        }
        func foundEndOfMacroName(wasBracketed: Bool, parser: MacroExpressionParser) {
            // At the end of a macro name subexpression, we first decrement the macro name nesting level, which we incremented in `foundStartOfMacroName()`.
            macroNameNestingLevel -= 1

            // Emit an instruction to pop the current subresult buffer from the top of the buffer stack and use its contents as a macro name, looking up and evaluating the value into the next subresult buffer on the stack.  We use the string form of evaluation if we either have a non-zero “evaluate-as-string nesting level” or if we are evaluating a macro name (which are currently always evaluated as strings).
            programBuilder.emit(.evalNamedMacro(asString: alwaysEvalAsStringNestingLevel > 0 || macroNameNestingLevel > 0, preserveOriginalIfUnresolved: !wasBracketed))
        }
        func foundRetrievalOperator(_ operatorName: Input, parser: MacroExpressionParser) {
            // Emit an instruction to replace the subresult buffer at the top of the buffer stack with the result of applying a ‘retrieval’ operator to it.
            if let op = MacroEvaluationProgram.MacroEvaluationRetrievalOperator(String(operatorName)!) {
                programBuilder.emit(.applyRetrievalOperator(op))
            }
            else {
                // The operator was unrecognized, so emit an error.
                handleDiagnostic(MacroExpressionDiagnostic(string: parser.string, range: parser.currIdx..<parser.currIdx, kind: .unknownRetrievalOperator, level: .error), parser: parser)
            }
        }
        func foundStartOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {
            // Emit an instruction to push a new subresult buffer into which we’ll evaluate the replacement operand subexpression.
            programBuilder.emit(.beginSubresult)
        }
        func foundEndOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {
            // Emit an instruction to pop the current subresult buffer from the top of the buffer stack, using it as the operand for the replacement, and to then replace the subresult buffer at the top of the buffer stack with the result of applying a ‘replacement’ operator to it.
            if let op = MacroEvaluationProgram.MacroEvaluationReplacementOperator(String(operatorName)!) {
                programBuilder.emit(.applyReplacementOperator(op))
            }
            else {
                // The operator was unrecognized, so emit an error.
                handleDiagnostic(MacroExpressionDiagnostic(string: parser.string, range: parser.currIdx..<parser.currIdx, kind: .unknownReplacementOperator, level: .error), parser: parser)
            }
        }
        func foundEndOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {
            // If this substitution subexpression is one in which we should always evaluate a string, we decrement the “evaluate-as-string nesting level” to balance its increment in `foundStartOfSubstitutionSubexpression()`.
             if alwaysEvalAsString { alwaysEvalAsStringNestingLevel -= 1 }

            // Emit and instruction to pop the current subresult buffer from the top of the buffer stack and append it to the next subresult buffer on the stack.
            programBuilder.emit(.mergeSubresult)
        }
        func foundListElementSeparator(_ string: Input, parser: MacroExpressionParser) {
            // Emit an instruction to set a flag in the current subresult buffer noting that it needs a list element separator.  This doesn’t immediately add a list element separator; that doesn’t happen until either a literal string fragment or another subresult buffer is appended.  If the expression is evaluated as a string (rather than a string list) then the value of the associated string will be emitted to the result.
            programBuilder.emit(.setNeedsListSeparator(String(string)!))
        }
        func handleDiagnostic(_ diagnostic: MacroExpressionDiagnostic, parser: MacroExpressionParser) {
            guard let handler = diagnosticsHandler else { return }
            handler(diagnostic)
        }
    }

    /// "Parses" `string` as a literal macro expression string.
    public func parseLiteralString(_ string: String, allowSubstitutionPrefix: Bool = false) -> MacroStringExpression {
        // Use interning, if enabled.
        if let table = MacroNamespace.stringExpressionInterningTable {
            return table.getOrInsert(string) { _parseLiteralString(string, allowSubstitutionPrefix: allowSubstitutionPrefix) }
        }

        return _parseLiteralString(string, allowSubstitutionPrefix: allowSubstitutionPrefix)
    }
    private func _parseLiteralString(_ string: String, allowSubstitutionPrefix: Bool) -> MacroStringExpression {
#if DEBUG
        // We make it an error in debug builds to try and parse '$(' as a literal unless we've explicitly specified it's ok. Otherwise, it is almost certainly (but not necessarily) a programmatic error if it ever does.
        if !allowSubstitutionPrefix, string.contains("$(") {
            fatalError("pushing literal string containing a possible macro reference: \(string)')")
        }
#endif

        let emitter = MacroEvaluationProgramBuilder()
        emitter.emit(MacroEvaluationProgram.EvalInstr.appendLiteral(string))
        return MacroStringExpression(stringRep: string, evalProgram: emitter.build())
    }

    /// "Parses" `strings` as a list of literal strings.
    public func parseLiteralStringList(_ strings: [String]) -> MacroStringListExpression {
#if DEBUG
        for string in strings {
            // We make it an error in debug builds to try and parse '$(' as a literal. This never comes up in our test suite, and it is almost certainly (but not necessarily) a programmatic error when if it ever does.
            if string.contains("$(") {
                fatalError("pushing literal string containing a possible macro reference: \(string)')")
            }
        }
#endif

        let emitter = MacroEvaluationProgramBuilder()
        var needsListSeparator = false
        for str in strings {
            if needsListSeparator { emitter.emit(.setNeedsListSeparator(" ")) }
            emitter.emit(MacroEvaluationProgram.EvalInstr.appendLiteral(str))
            needsListSeparator = true
        }
        // FIXME: We shouldn't need to compute the stringRep here.
        return MacroStringListExpression(stringRep: strings.quotedStringListRepresentation, evalProgram: emitter.build())
    }

    /// Parses `string` as a macro expression string, returning a MacroExpression object to represent it.  The returned macro expression contains a copy of the input string and a compiled representation that can be used to evaluate the expression in a particular context.  The diagnostics handler is invoked once for every issue found during the parsing.  Even in the presence of errors, this method always returns an expression that’s as parsed as possible.
    public func parseString(_ stringRep: String, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroStringExpression {
        MacroNamespace.parsedStrings.increment()

        // Fast path strings which are guaranteed to be literal.
        if !stringRep.contains("$") {
            return parseLiteralString(stringRep)
        }

        // Create a parse delegate and initialize a parser with it.
        let emitter = MacroEvaluationProgramBuilder()
        let delegate = MacroExpressionInstructionEmitterDelegate(programBuilder: emitter, diagnosticsHandler: diagnosticsHandler)
        let parser = MacroExpressionParser(string: stringRep, delegate: delegate)

        // Parse the string representation. The delegate will build up the evaluation instructions during the parse, and will deal with any diagnostics.
        parser.parseAsString()

        // Return a macro expression for the string, and include the macro evaluation program we created while parsing the string.
        return MacroStringExpression(stringRep: stringRep, evalProgram: emitter.build())
    }

    /// Parses `string` as a macro expression string list, returning a MacroExpression object to represent it.  The returned macro expression contains a copy of the input string and a compiled representation that can be used to evaluate the expression in a particular context.  The diagnostics handler is invoked once for every issue found during the parsing.  Even in the presence of errors, this method always returns an expression that’s as parsed as possible.
    public func parseStringList(_ stringRep: String, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroStringListExpression {
        MacroNamespace.parsedLists.increment()

        // Create a parse delegate and initialize a parser with it.
        let emitter = MacroEvaluationProgramBuilder()
        let delegate = MacroExpressionInstructionEmitterDelegate(programBuilder: emitter, diagnosticsHandler: diagnosticsHandler)
        let parser = MacroExpressionParser(string: stringRep, delegate: delegate)

        // Parse the string representation. The delegate will build up the evaluation instructions during the parse, and will deal with any diagnostics.
        parser.parseAsStringList()

        // Return a macro expression for the string list, and include the macro evaluation program we created while parsing the string.
        return MacroStringListExpression(stringRep: stringRep, evalProgram: emitter.build())
    }

    /// Parses `strings` as a macro expression string list, returning a MacroExpression object to represent it.  The returned macro expression contains a copy of the input string and a compiled representation that can be used to evaluate the expression in a particular context.  The diagnostics handler is invoked once for every issue found during the parsing.  Even in the presence of errors, this method always returns an expression that’s as parsed as possible.
    public func parseStringList(_ strings: [String], diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroStringListExpression {
        // FIXME: It would be more efficient to create the macro evaluation program directly instead bridging it through the quoted-string-list form.
        return parseStringList(strings.quotedStringListRepresentation, diagnosticsHandler: diagnosticsHandler)
    }

    /// Parse the value for a macro in a manner consistent with its definition.
    public func parseForMacro(_ macro: MacroDeclaration, value: String, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroExpression {
        switch macro.type {
        case .boolean, .string, .path:
            return parseString(value, diagnosticsHandler: diagnosticsHandler)
        case .stringList, .userDefined, .pathList:
            return parseStringList(value, diagnosticsHandler: diagnosticsHandler)
        }
    }

    /// Parse the value for a macro in a manner consistent with its definition.
    public func parseForMacro(_ macro: MacroDeclaration, value: [String], diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroExpression {
        switch macro.type {
        case .boolean, .string, .path:
            // FIXME: It isn't clear what the right behavior is here. We are parsing a string typed macro and were given a list. For now, we just use the quoted string representation.
            return parseString(value.quotedStringListRepresentation, diagnosticsHandler: diagnosticsHandler)
        case .stringList, .userDefined, .pathList:
            return parseStringList(value, diagnosticsHandler: diagnosticsHandler)
        }
    }

    /// Parse the value for a macro in a manner consistent with its definition.
    ///
    /// - returns: The parsed expression, or nil if the input value type was invalid.
    public func parseForMacro(_ macro: MacroDeclaration, value: PropertyListItem, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroExpression? {
        switch value {
        case .plString(let stringValue):
            return parseForMacro(macro, value: stringValue, diagnosticsHandler: diagnosticsHandler)
        case .plArray(let arrayValue):
            var strings = [String]()
            for item in arrayValue {
                if case .plString(let stringValue) = item {
                    strings.append(stringValue)
                } else {
                    // We found an invalid value.
                    return nil
                }
            }
            return parseForMacro(macro, value:strings, diagnosticsHandler: diagnosticsHandler)

        default:
            return nil
        }
    }

    /// Parse a table of settings in a manner consistent with their definitions.
    ///
    /// - Parameters:
    ///   - allowUserDefined: If true, then unknown settings will be treated as user defined macros. If false, unknown settings will result in a `unknownMacroDeclarationType` error.
    ///   - associatedTypesForKeysMatching: Used to map a `MacroDeclarationType` to the first matching (via substring) setting name rather than creating a `UserDefinedMacroDeclaration`.
    ///      For example, providing an `associatedTypesForKeysMatching` value of ["_DEPLOYMENT_TARGET", StringMacroDeclaration.self] would allow iTOASTER_DEPLOYMENT_TYPE to be defined as a string macro even if it's not "built-in"
    public func parseTable(_ settings: [String: PropertyListItem], allowUserDefined: Bool, associatedTypesForKeysMatching: [String: MacroType]? = nil, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) throws -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: self)
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            /// Helper to get the macro declaration.
            func getMacro(_ macroName: String, _ value: PropertyListItem) throws -> MacroDeclaration {
                // See if we know the macro type.
                if let macro = lookupMacroDeclaration(macroName) {
                    return macro
                }

                // if this setting key is matched by any `associatedTypesForKeysMatching`, use the associatedType provided
                if let associatedType = associatedTypesForKeysMatching?.first(where: { key.contains($0.key) })?.value {
                    switch associatedType {
                        case .boolean: return lookupOrDeclareMacro(BooleanMacroDeclaration.self, macroName)
                        case .string: return lookupOrDeclareMacro(StringMacroDeclaration.self, macroName)
                        case .stringList: return lookupOrDeclareMacro(StringListMacroDeclaration.self, macroName)
                        case .userDefined: return lookupOrDeclareMacro(UserDefinedMacroDeclaration.self, macroName)
                        case .path: return lookupOrDeclareMacro(PathMacroDeclaration.self, macroName)
                        case .pathList: return lookupOrDeclareMacro(PathListMacroDeclaration.self, macroName)
                    }
                // If this is a user defined table, unknown settings should be treated as user defined.
                } else if allowUserDefined {
                    return lookupOrDeclareMacro(UserDefinedMacroDeclaration.self, macroName)
                } else {
                    throw MacroDeclarationError.unknownMacroDeclarationType(name: macroName)
                }
            }

            // Parse the key into a macro name and optional condition set.
            let macroName: String
            let conditionSet: MacroConditionSet?
            // FIXME: We should have a way to do this parsing that isn't explicitly in the xcconfig file parser logic.
            let (parsedName, parsedConditions) = MacroConfigFileParser.parseMacroNameAndConditionSet(key)
            if let parsedMacroName = parsedName {
                macroName = parsedMacroName
                if let conditions = parsedConditions {
                    conditionSet = MacroConditionSet(conditions: conditions.map{ MacroCondition(parameter: declareConditionParameter($0.0), valuePattern: $0.1) })
                }
                else {
                    conditionSet = nil
                }
            }
            else {
                // If we can't parse a name and condition, then use the original key as the name.  c.f. <rdar://problem/29271127>
                macroName = key
                conditionSet = nil
            }
            let macro = try getMacro(macroName, value)

            // Parse the value in a manner consistent with the macro definition.
            guard let expr = parseForMacro(macro, value: value) else {
                throw MacroDeclarationError.inconsistentMacroDefinition(name: macroName, type: macro.type, value: value)
            }

            table.push(macro, expr, conditions: conditionSet)
        }
        return table
    }

    // FIXME: We should eliminate this if possible, as it is rather inefficient, but it is widely used in Settings construction.
    // This was originally part of Settings but was moved here to be available elsewhere.
    //
    /// Parse a table of settings in a manner consistent with their definitions.
    ///
    /// This just takes a `[String: String]` dictionary and marshals the values as `PropertyListItem.string` values, then calls `parseTable([String: PropertyListItem], ...)` to parse the resulting table.
    public func parseTable(_ settings: [String: String], allowUserDefined: Bool, associatedTypesForKeysMatching: [String: MacroType]? = nil, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) throws -> MacroValueAssignmentTable {
        var settingsCopy = [String: PropertyListItem]()
        for (key,value) in settings {
            settingsCopy[key] = .plString(value)
        }
        return try self.parseTable(settingsCopy, allowUserDefined: allowUserDefined, associatedTypesForKeysMatching: associatedTypesForKeysMatching, diagnosticsHandler: diagnosticsHandler)
    }

    // MARK: Parsed Expression Interning

    /// Enable interning of literal strings, for the during of the closure.
    ///
    /// This method is thread safe, and can be called by competing clients of macro namespaces -- interning will take place as long as any active client has requested interning.
    ///
    /// When used appropriate (i.e., when used to wrap a large amount of computation of parsed expressions) this method will allow for cheap, substantial sharing of parsed expressions, without leaking expressions unnecessarily.
    ///
    /// We currently only actual intern literal strings, because non-literal strings need to be careful about the possibility of diagnostics during parsing.
    public static func withExpressionInterningEnabled<T>(body: () throws -> T) rethrows -> T {
        // Install the interning table while active.
        interningState.withLock { interningState in
            interningState.numActiveInterningRequests += 1
            if interningState.numActiveInterningRequests == 1 {
                interningState._stringExpressionInterningTable = Registry()
            }
        }
        defer {
            // Drop the count.
            interningState.withLock { interningState in
                interningState.numActiveInterningRequests -= 1
                if interningState.numActiveInterningRequests == 0 {
                    interningState._stringExpressionInterningTable = nil
                }
            }
        }

        // Execute the body.
        return try body()
    }

    public static func withExpressionInterningEnabled<T>(body: () async throws -> T) async rethrows -> T {
        // Install the interning table while active.
        interningState.withLock { interningState in
            interningState.numActiveInterningRequests += 1
            if interningState.numActiveInterningRequests == 1 {
                interningState._stringExpressionInterningTable = Registry()
            }
        }
        defer {
            // Drop the count.
            interningState.withLock { interningState in
                interningState.numActiveInterningRequests -= 1
                if interningState.numActiveInterningRequests == 0 {
                    interningState._stringExpressionInterningTable = nil
                }
            }
        }

        // Execute the body.
        return try await body()
    }

    struct InterningState: ~Copyable {
        /// The number of active interning requests.
        ///
        /// When this drops to 0 the interning tables will be released.
        var numActiveInterningRequests = 0

        var _stringExpressionInterningTable: Registry<String, MacroStringExpression>? = nil
    }

    /// The lock used to protect access to the shared string interning state.
    static let interningState = SWBMutex<InterningState>(.init())

    /// The table to use for parsed string expression interning, if installed.
    static var stringExpressionInterningTable: Registry<String, MacroStringExpression>? {
        return interningState.withLock{ $0._stringExpressionInterningTable }
    }
}

/// Represents errors that can occur during use of MacroNamespace.
public enum MacroDeclarationError: Swift.Error, Equatable {
    /// This error indicates an attempt to redeclare a macro name as a different type than what’s already been declared.  The existing declaration might come from the same namespace or any inherited namespace.
    case conflictingMacroDeclarationType(type: MacroType, previousType: MacroType, name: String)

    /// This error indicates an attempt to parse a table with an undeclared macro name.
    case unknownMacroDeclarationType(name: String)

    /// Indicates an attempted definition named `name` of `value` inconsistent with `type`.
    case inconsistentMacroDefinition(name: String, type: MacroType, value: PropertyListItem)
}
