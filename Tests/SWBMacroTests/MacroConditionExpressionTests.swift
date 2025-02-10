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

import Foundation
import Testing
import SWBTestSupport
import SWBUtil
import SWBMacro

@Suite fileprivate struct MacroConditionExpressionTests {
    let scope: MacroEvaluationScope

    init() async throws {
        // Create the mock table.
        let namespace = MacroNamespace(debugDescription: "custom")
        try namespace.declareBooleanMacro("IS_TRUE")
        try namespace.declareBooleanMacro("IS_FALSE")
        try namespace.declareStringMacro("FOO")
        try namespace.declareStringMacro("BAR")
        try namespace.declareStringMacro("BAZ")
        try namespace.declareStringMacro("QUUX")
        try namespace.declareStringMacro("FOOBAR")
        try namespace.declareStringMacro("FOO_BAR")
        try namespace.declareStringMacro("EMPTY")
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(try #require(namespace.lookupMacroDeclaration("IS_TRUE") as? BooleanMacroDeclaration), literal: true)
        table.push(try #require(namespace.lookupMacroDeclaration("IS_FALSE") as? BooleanMacroDeclaration), literal: false)
        table.push(try #require(namespace.lookupMacroDeclaration("FOO") as? StringMacroDeclaration), literal: "foo")
        table.push(try #require(namespace.lookupMacroDeclaration("BAR") as? StringMacroDeclaration), literal: "bar")
        table.push(try #require(namespace.lookupMacroDeclaration("BAZ") as? StringMacroDeclaration), literal: "baz")
        table.push(try #require(namespace.lookupMacroDeclaration("QUUX") as? StringMacroDeclaration), literal: "quux")
        table.push(try #require(namespace.lookupMacroDeclaration("FOOBAR") as? StringMacroDeclaration), namespace.parseString("$(FOO)$(BAR)"))
        table.push(try #require(namespace.lookupMacroDeclaration("FOO_BAR") as? StringMacroDeclaration), namespace.parseString("$(FOO) $(BAR)"))
        table.push(try #require(namespace.lookupMacroDeclaration("EMPTY") as? StringMacroDeclaration), namespace.parseString(""))
        scope = MacroEvaluationScope(table: table)
    }

    @Test
    func constantConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        error = nil
        expr = MacroConditionExpression.fromString("", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "") }
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("const", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "const") }
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("YES", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "YES") }
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("NO", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "NO") }
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("\"YES\"", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "YES") }
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }
    }

    @Test
    func simpleBuildSettingConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        error = nil
        expr = MacroConditionExpression.fromString("$(IS_TRUE)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "YES") }
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(IS_FALSE)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "NO") }
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOOBAR)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "foobar") }
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO_BAR)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "foo bar") }
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO)$(BAR)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsString(scope) == "foobar") }
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }
    }

    @Test
    func equalityConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        // == and !=
        error = nil
        expr = MacroConditionExpression.fromString("this == this", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("this == that", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("this != this", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("this != that", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == foo", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) != bar", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        // CONTAINS
        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) contains $(FOO)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOOBAR) contains $(FOO)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO_BAR) contains $(FOO)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOOBAR) contains $(BAZ)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        // Synonyms
        error = nil
        expr = MacroConditionExpression.fromString("this is this", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("this isnot that", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        // Interesting cases
        error = nil
        expr = MacroConditionExpression.fromString("$(EMPTY) == \"\"", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("foo != \"\"", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }
    }

    @Test
    func unaryConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        // !
        error = nil
        expr = MacroConditionExpression.fromString("!$(IS_FALSE)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("!$(IS_TRUE)", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }
    }

    @Test(.disabled("Relational expressions were not implemented in Xcode's legacy build system support for macro condition expressions, and are not yet implemented in SWBMacro, so we don't test them here."))
    func relationalConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        // < and <=
        error = nil
        expr = MacroConditionExpression.fromString("1 < 2", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("1 < 1", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("2 < 1", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("1 <= 2", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("1 <= 1", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("2 <= 1", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        // > and >=
    }

    @Test
    func logicalConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        // AND
        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == foo  &&  $(BAR) == bar", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == bar  &&  $(BAR) == bar", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == bar  &&  $(BAR) == baz", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        // OR
        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == foo  ||  $(BAR) == bar", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == bar  ||  $(BAR) == bar", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == foo  ||  $(BAR) == baz", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == bar  ||  $(BAR) == baz", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }

        // synonyms
        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == foo  and  $(BAR) == bar", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == bar  or  $(BAR) == bar", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }
    }

    @Test
    func ternaryConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        // ?:
        error = nil
        expr = MacroConditionExpression.fromString("$(IS_TRUE) ? YES : NO", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }

        error = nil
        expr = MacroConditionExpression.fromString("$(IS_FALSE) ? YES : NO", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(!expr!.evaluateAsBoolean(scope)) }
    }

    @Test
    func otherConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        // Parentheses
        // Note that a quirk in the scanner requires there to be a space before the closing ')'.
        error = nil
        expr = MacroConditionExpression.fromString("$(FOO) == foo  &&  ( $(BAR) == baz  ||  $(BAZ) == baz )", diagnosticsHandler: diagnosticsHandler)
        #expect(expr != nil, Comment(rawValue: "Parser error: " + (error ?? "<unknown>")))
        if expr != nil { #expect(expr!.evaluateAsBoolean(scope)) }
    }

    @Test
    func erroneousConditionExpressions() {
        var expr: MacroConditionExpression? = nil
        var error: String? = nil
        let diagnosticsHandler = { diagnostic in error = diagnostic }

        // We don't support relational operators at present
        error = nil
        expr = MacroConditionExpression.fromString("1 < 2", diagnosticsHandler: diagnosticsHandler)
        #expect(expr == nil)
        #expect(error != nil)

        error = nil
        expr = MacroConditionExpression.fromString("1 <= 2", diagnosticsHandler: diagnosticsHandler)
        #expect(expr == nil)
        #expect(error != nil)

        error = nil
        expr = MacroConditionExpression.fromString("1 > 2", diagnosticsHandler: diagnosticsHandler)
        #expect(expr == nil)
        #expect(error != nil)

        error = nil
        expr = MacroConditionExpression.fromString("1 >= 2", diagnosticsHandler: diagnosticsHandler)
        #expect(expr == nil)
        #expect(error != nil)

        // Missing parentheses tests.
        error = nil
        expr = MacroConditionExpression.fromString("$(FOO == foo", diagnosticsHandler: diagnosticsHandler)
        #expect(expr == nil)
        #expect(error != nil)
    }
}

extension MacroConditionExpression {
    class func fromString(_ string: String, diagnosticsHandler: @escaping (((String) -> Void)) = {_ in }) -> MacroConditionExpression? {
        struct Static {
            static let namespace = MacroNamespace(debugDescription: "test")
        }
        return fromString(string, macroNamespace: Static.namespace, diagnosticsHandler: diagnosticsHandler)
    }
}
