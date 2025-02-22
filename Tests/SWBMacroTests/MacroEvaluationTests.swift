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
import SWBUtil
import SWBMacro
import SWBTestSupport

@Suite fileprivate struct MacroStringEvaluationTests {
    @Test
    func construction() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        let aStringDecl = try namespace.declareStringMacro("A_STRING")

        // Create a macro value assignment table.
        var table1 = MacroValueAssignmentTable(namespace: namespace)

        // Push the assignment A_STRING = “Macros”
        let aStringExpr1 = namespace.parseString("Macros")
        table1.push(aStringDecl, aStringExpr1)
        #expect(table1.lookupMacro(aStringDecl)!.expression === aStringExpr1)
        #expect(table1.lookupMacro(aStringDecl)!.next == nil)

        // Create another macro value assignment table.
        var table2 = MacroValueAssignmentTable(namespace: namespace)

        // Push the assignment A_STRING = “Hello $(inherited)”
        let aStringExpr2 = namespace.parseString("Hello $(inherited)")
        table2.push(aStringDecl, aStringExpr2)
        #expect(table2.lookupMacro(aStringDecl)!.expression === aStringExpr2)
        #expect(table1.lookupMacro(aStringDecl)!.next == nil)

        // Also push the assignment A_STRING = “$(inherited)!”
        let aStringExpr3 = namespace.parseString("$(inherited)!")
        table2.push(aStringDecl, aStringExpr3)
        #expect(table2.lookupMacro(aStringDecl)!.expression === aStringExpr3)
        #expect(table2.lookupMacro(aStringDecl)!.next!.expression === aStringExpr2)
        #expect(table2.lookupMacro(aStringDecl)!.next!.next == nil)

        // Push all assignments from table 1 onto table 2, and then look up some things about them.
        table1.pushContentsOf(table2)
        #expect(table1.lookupMacro(aStringDecl)!.expression === aStringExpr3)
        #expect(table1.lookupMacro(aStringDecl)!.next!.expression === aStringExpr2)
        #expect(table1.lookupMacro(aStringDecl)!.next!.next!.expression === aStringExpr1)
        #expect(table1.lookupMacro(aStringDecl)!.next!.next!.next == nil)

        // Check the table dump.
        let dump = table1.dump()
        let expectedSubstring = "'$(inherited)!' -> 'Hello $(inherited)' -> 'Macros'"
        #expect(dump.contains(expectedSubstring), "could not find expected string \"\(expectedSubstring)\" in dump of table: \(table1.dump())")
    }

    @Test
    func simpleEvaluation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare X, Y, and Z as string macros.
        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")
        let Z = try namespace.declareStringMacro("Z")

        // Push down some basic literal definitions.
        table.push(X, literal: "x")
        table.push(Y, literal: "y")
        table.push(Z, literal: "z")

        // Create some expressions using those macros.
        let exprXYZ = namespace.parseString("$(X)$(Y)$(Z)")
        let exprZZZ = namespace.parseString("$(Z)$(Z)$(Z)")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(X) == "x")
        #expect(scope.evaluate(Y) == "y")
        #expect(scope.evaluate(Z) == "z")
        #expect(scope.evaluate(exprXYZ) == "xyz")
        #expect(scope.evaluate(exprZZZ) == "zzz")

        // Check use of $(inherited) in an expression.
        #expect(scope.evaluate(namespace.parseString("$(inherited)")) == "")
    }

    /// Check that the original spelling is preserved when using the inline macro form.
    @Test
    func originalMacroPreservation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        let table = MacroValueAssignmentTable(namespace: namespace)

        // Create some expressions using those macros.
        _ = try namespace.declareStringMacro("MACRO")
        let nonPreservingExpr = namespace.parseString("A-$(MACRO)-$(UNKNOWNMACRO)-A")
        let preservingExpr = namespace.parseString("A-$MACRO-$UNKNOWNMACRO-A")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(nonPreservingExpr) == "A---A")
        #expect(scope.evaluate(preservingExpr) == "A-$MACRO-$UNKNOWNMACRO-A")
    }

    @Test
    func evaluationOverrides() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare X, Y, and Z as string macros.
        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")

        // Push down some basic literal definitions.
        table.push(X, literal: "x")
        table.push(Y, literal: "y")

        // Create an expression we will use as an override.
        let exprXOverride = namespace.parseString("$(X)-override-$(Y)")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        let lookup = { macro -> MacroExpression? in
            return macro === X ? exprXOverride : nil
        }
        #expect(scope.evaluate(X, lookup: lookup) == "x-override-y")
        #expect(scope.evaluate(namespace.parseString("$(X)"), lookup: lookup) == "x-override-y")
    }

    @Test
    func undefinedMacrosEvaluation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare X and Y as string macros.
        let X = try namespace.declareStringMacro("X")
        let _ = try namespace.declareStringMacro("Y")

        // Push down an expression definitions that refers to a macro without a value, and also to a completely unknown macro.
        table.push(X, namespace.parseString(".$(Y).$(Z)."))

        // Create some expressions that refer to a macro without a value, and to a completely unknown macro.
        let exprY = namespace.parseString("$(Y)")
        let exprZ = namespace.parseString("$(Z)")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(X) == "...")
        #expect(scope.evaluate(exprY) == "")
        #expect(scope.evaluate(exprZ) == "")
    }

    @Test
    func macroNameEvaluation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare X, Y, Z, and XYZ as string macros.
        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")
        let Z = try namespace.declareStringMacro("Z")
        let XYZ = try namespace.declareStringMacro("XYZ")
        let XYZXYZ = try namespace.declareStringMacro("XYZXYZ")

        // Push down some basic literal definitions.
        table.push(X, literal: "X")
        table.push(Y, literal: "Y")
        table.push(Z, literal: "Z")
        table.push(XYZ, literal: "(xyz)")
        table.push(XYZXYZ, literal: "(xyzxyz)")

        // Create some expressions using those macros.
        let exprXYZ = namespace.parseString("$(X)$(Y)$(Z)")
        let exprXYZRef = namespace.parseString("$($(X)$(Y)$(Z))")
        let exprXYZXYZRef = namespace.parseString("$($(X)$(Y)$(Z)$(X)$(Y)$(Z))")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(X) == "X")
        #expect(scope.evaluate(Y) == "Y")
        #expect(scope.evaluate(Z) == "Z")
        #expect(scope.evaluate(exprXYZ) == "XYZ")
        #expect(scope.evaluate(exprXYZRef) == "(xyz)")
        #expect(scope.evaluate(exprXYZXYZRef) == "(xyzxyz)")
    }

    @Test
    func basicInheritance() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare X as a string macro.
        let X = try namespace.declareStringMacro("X")

        // Push down several values that use inheritance in its different forms.
        table.push(X, literal: "a")
        table.push(X, namespace.parseString("($(X))"))
        table.push(X, namespace.parseString("{$(value)}"))
        table.push(X, namespace.parseString("[$(X)]"))
        table.push(X, namespace.parseString("<$(inherited)>"))
        table.push(X, namespace.parseString("$(inherited),$(inherited)"))
        table.push(X, namespace.parseString("$(X)|$(value)|$(inherited)"))

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(X) == "<[{(a)}]>,<[{(a)}]>|<[{(a)}]>,<[{(a)}]>|<[{(a)}]>,<[{(a)}]>")
    }

    @Test
    func interleavedInheritance() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare X and Y as string macros.
        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")

        // Push down several values that use inheritance in its different forms, alternating between X and Y.
        table.push(X, literal: "a")
        table.push(Y, literal: "b")
        table.push(X, namespace.parseString("($(Y))"))
        table.push(Y, namespace.parseString("{$(X)}"))
        table.push(X, namespace.parseString("[$(Y)]"))
        table.push(Y, namespace.parseString("<$(X)>,<$(Y)>"))

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(X) == "[<({a})>,<{(b)}>]")
        #expect(scope.evaluate(Y) == "<[{(b)}]>,<{[b]}>")
    }

    @Test
    func unicodeEvaluation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare some string macros.
        let fee = try namespace.declareStringMacro("FEE")
        let fi = try namespace.declareStringMacro("FI")
        let fo = try namespace.declareStringMacro("FO")
        let fum = try namespace.declareStringMacro("FUM")
        let giant = try namespace.declareStringMacro("GIANT")

        // Push down some value assignments.
        table.push(fee, literal: "𝔉𝔢𝔢")
        table.push(fi, literal: "𝔍𝔦")
        table.push(fo, literal: "𝔍𝔬")
        table.push(fum, literal: "𝔍𝔲𝔪")
        table.push(giant, namespace.parseString("$(FEE), $(FI), $(FO), $(FUM)!"))

        // Also create a freestanding test expression.
        let giantSez = namespace.parseString("“$(GIANT)”, said The Giant.")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(fee) == "𝔉𝔢𝔢")
        #expect(scope.evaluate(fum) == "𝔍𝔲𝔪")
        #expect(scope.evaluate(giant) == "𝔉𝔢𝔢, 𝔍𝔦, 𝔍𝔬, 𝔍𝔲𝔪!")
        #expect(scope.evaluate(giantSez) == "“𝔉𝔢𝔢, 𝔍𝔦, 𝔍𝔬, 𝔍𝔲𝔪!”, said The Giant.")
    }

    @Test
    func lookupWithEmptyMacro() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        let EMPTY = try namespace.declareStringMacro("EMPTY")
        let RECURSIVE = try namespace.declareStringMacro("RECURSIVE")
        table.push(EMPTY, literal: "")
        table.push(RECURSIVE, namespace.parseString("$($(EMPTY))"))

        let scope = MacroEvaluationScope(table: table)
        let result: String = scope.evaluate(RECURSIVE)
        #expect(result == "")
    }

    @Test(.skipHostOS(.windows, "operators need a bunch of work"))
    func operators() throws {
        // Create a namespace and a macro value table.
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare some string macros.
        let simpleString = try namespace.declareStringMacro("SIMPLE_STRING")
        let frameworkPath = try namespace.declareStringMacro("FRAMEWORK_PATH")
        let filename = try namespace.declareStringMacro("FILENAME")
        let bundleNames = try namespace.declareStringListMacro("BUNDLE_NAMES")
        let nonStandardAbsPath = try namespace.declareStringMacro("NON_STANDARD_ABS_PATH")
        let nonStandardRelPath = try namespace.declareStringMacro("NON_STANDARD_REL_PATH")
        let quoteString = try namespace.declareStringMacro("QUOTE_STRING")
        let bestBool = try namespace.declareBooleanMacro("BEST")

        // Push down some value assignments.
        table.push(simpleString, literal: "This")
        table.push(frameworkPath, literal: "/tmp/Products/Anything.framework")
        table.push(filename, literal: "Some File.txt")
        table.push(bundleNames, literal: ["Something.app", "Else.bundle", "Then This.framework"])
        table.push(nonStandardAbsPath, literal: "//foo/./bar/")
        table.push(nonStandardRelPath, literal: "foo/../bar/./baz/")
        table.push(quoteString, literal: "foo bar \" ' \\")
        table.push(bestBool, literal: false)

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(namespace.parseString("$(FILENAME:identifier)")) == "Some_File_txt")
        #expect(scope.evaluate(namespace.parseStringList("$(BUNDLE_NAMES:identifier)")) == ["Something_app", "Else_bundle", "Then_This_framework"])
        #expect(scope.evaluate(namespace.parseString("$(FILENAME:rfc1034identifier)")) == "Some-File-txt")
        #expect(scope.evaluate(namespace.parseStringList("$(BUNDLE_NAMES:rfc1034identifier)")) == ["Something-app", "Else-bundle", "Then-This-framework"])
        #expect(scope.evaluate(namespace.parseString("$(FRAMEWORK_PATH:dir)")) == "/tmp/Products/")
        #expect(scope.evaluate(namespace.parseString("$(SIMPLE_STRING:dir)")) == "./")
        #expect(scope.evaluate(namespace.parseString("$(FRAMEWORK_PATH:file)")) == "Anything.framework")
        #expect(scope.evaluate(namespace.parseString("$(FRAMEWORK_PATH:base)")) == "Anything")
        #expect(scope.evaluate(namespace.parseString("$(FRAMEWORK_PATH:suffix)")) == ".framework")
        #expect(scope.evaluate(namespace.parseString("$(NON_STANDARD_ABS_PATH:standardizepath)")) == "/foo/bar")
        #expect(scope.evaluate(namespace.parseString("$(NON_STANDARD_REL_PATH:standardizepath)")) == "foo/../bar/baz")
        #expect(scope.evaluate(namespace.parseString("$(SIMPLE_STRING:upper)")) == "THIS")
        #expect(scope.evaluate(namespace.parseString("$(SIMPLE_STRING:lower)")) == "this")
        #expect(scope.evaluate(namespace.parseString("$(QUOTE_STRING:quote)")) == "foo\\ bar\\ \\\"\\ \\'\\ \\\\")
        #expect(scope.evaluate(namespace.parseString("$(BEST:not)")) == "YES")
    }

    @Test
    func c99ExtIdentifierOperator() throws {
        func testOperator(_ input: String, _ output: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let namespace = MacroNamespace(debugDescription: "test")
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("INPUT"), literal: input)
            let scope = MacroEvaluationScope(table: table)

            #expect(scope.evaluate(namespace.parseString("$(INPUT:c99extidentifier)")) == output)
        }

        try testOperator("", "")
        try testOperator("ÜTF-8", "ÜTF_8")
        try testOperator("a가가", "a가가")
        try testOperator("٠٠٠", "_٠٠")
        try testOperator("12 3", "_2_3")
    }

    @Test(.skipHostOS(.windows, "operators need a bunch of work"))
    func replacementOperators() throws {
        // Create a namespace and a macro value table.
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare some string macros and assign values.
        table.push(try namespace.declareStringMacro("A_PATH"), literal: "/tmp/dir/file.c")
        table.push(try namespace.declareStringMacro("REPLACEMENT_SUFFIX"), literal: "blabla")
        table.push(try namespace.declareStringMacro("FIVE_SPACES"), literal: "     ")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(namespace.parseString("$(A_PATH:dir=ba ba ba)")) == "ba ba ba/file.c")
        #expect(scope.evaluate(namespace.parseString("$(A_PATH:file=ba ba ba)")) == "/tmp/dir/ba ba ba")
        #expect(scope.evaluate(namespace.parseString("$(A_PATH:base=ba ba ba)")) == "/tmp/dir/ba ba ba.c")
        #expect(scope.evaluate(namespace.parseString("$(A_PATH:suffix=$(REPLACEMENT_SUFFIX))")) == "/tmp/dir/file.blabla")
        #expect(scope.evaluate(namespace.parseString("$(A_PATH:suffix=.o)")) == "/tmp/dir/file.o")
        #expect(scope.evaluate(namespace.parseString("$(A_PATH:suffix=o)")) == "/tmp/dir/file.o")
    }

    @Test(.skipHostOS(.windows, "operators need a bunch of work"))
    func relativeToReplacementOperator() throws {
        func createScope(installPath: String, otherPath: String, block: (inout MacroValueAssignmentTable) throws -> Void = { _ in }) throws -> MacroEvaluationScope {
            // Create a namespace and a macro value table.
            let namespace = MacroNamespace(debugDescription: "test")
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("A_PATH"), literal: otherPath)
            table.push(try namespace.declareStringMacro("INSTALL_PATH"), literal: installPath)
            try block(&table)

            // Create a macro evaluation scope for testing.
            return MacroEvaluationScope(table: table)
        }

        func evaluate(installPath: String, otherPath: String) throws -> String {
            let scope = try createScope(installPath: installPath, otherPath: otherPath)
            return scope.evaluate(scope.namespace.parseString("$(INSTALL_PATH:relativeto=$(A_PATH))"))
        }

        // Relative paths (unsupported) should return the original input.
        #expect(try evaluate(installPath: "", otherPath: "") == "")
        #expect(try evaluate(installPath: "foo", otherPath: "foo") == "foo")
        #expect(try evaluate(installPath: "foo", otherPath: "foo/bar") == "foo")
        #expect(try evaluate(installPath: "/", otherPath: "foo") == "/")
        #expect(try evaluate(installPath: "foo", otherPath: "/") == "foo")

        // Paths which are unrelated should return paths with ../.
        #expect(try evaluate(installPath: "/foo", otherPath: "/bar") == "../bar")
        #expect(try evaluate(installPath: "/foo", otherPath: "/bar/baz") == "../bar/baz")
        #expect(try evaluate(installPath: "/usr/bin", otherPath: "/usr/lib") == "../lib")

        // Equal paths should return the identity path.
        #expect(try evaluate(installPath: "/", otherPath: "/") == ".")
        #expect(try evaluate(installPath: "/foo", otherPath: "/foo") == ".")

        #expect(try evaluate(installPath: "/foo", otherPath: "/") == "..")
        #expect(try evaluate(installPath: "/foo/bar", otherPath: "/") == "../..")
        #expect(try evaluate(installPath: "/foo/bar", otherPath: "/foo") == "..")

        let scope = try createScope(installPath: "/usr/lib", otherPath: "/usr/lib") { table in
            table.push(try table.namespace.declareStringMacro("RPATHS"), table.namespace.parseString("@loader_path/$(INSTALL_PATH:relativeto=$(A_PATH))"))
            table.push(try table.namespace.declareStringMacro("RPATHS"), table.namespace.parseString("$(RPATHS:standardizepath)"))
        }
        #expect(scope.evaluate(scope.namespace.parseString("$(RPATHS)")) == "@loader_path")
    }

    @Test(.skipHostOS(.windows, "operators need a bunch of work"))
    func isAncestorReplacementOperator() throws {
        func createScope(installPath: String, otherPath: String, block: (inout MacroValueAssignmentTable) throws -> Void = { _ in }) throws -> MacroEvaluationScope {
            // Create a namespace and a macro value table.
            let namespace = MacroNamespace(debugDescription: "test")
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("A_PATH"), literal: otherPath)
            table.push(try namespace.declareStringMacro("INSTALL_PATH"), literal: installPath)
            try block(&table)

            // Create a macro evaluation scope for testing.
            return MacroEvaluationScope(table: table)
        }

        func evaluate(installPath: String, otherPath: String) throws -> String {
            let scope = try createScope(installPath: installPath, otherPath: otherPath)
            return scope.evaluate(scope.namespace.parseString("$(INSTALL_PATH:isancestor=$(A_PATH))"))
        }

        // Relative paths (unsupported) should return the original input.
        #expect(try evaluate(installPath: "", otherPath: "") == "NO")
        #expect(try evaluate(installPath: "foo", otherPath: "foo") == "NO")
        #expect(try evaluate(installPath: "foo", otherPath: "foo/bar") == "NO")
        #expect(try evaluate(installPath: "/", otherPath: "foo") == "NO")
        #expect(try evaluate(installPath: "foo", otherPath: "/") == "NO")

        // Paths which are unrelated should return paths with ../.
        #expect(try evaluate(installPath: "/foo", otherPath: "/bar") == "NO")
        #expect(try evaluate(installPath: "/foo", otherPath: "/bar/baz") == "NO")
        #expect(try evaluate(installPath: "/usr/bin", otherPath: "/usr/lib") == "NO")

        // Equal paths should return the identity path.
        #expect(try evaluate(installPath: "/", otherPath: "/") == "NO")
        #expect(try evaluate(installPath: "/foo", otherPath: "/foo") == "NO")

        #expect(try evaluate(installPath: "/foo", otherPath: "/") == "YES")
        #expect(try evaluate(installPath: "/foo/bar", otherPath: "/") == "YES")
        #expect(try evaluate(installPath: "/foo/bar", otherPath: "/foo") == "YES")
        #expect(try evaluate(installPath: "/foo/bar/baz", otherPath: "/foo/bar") == "YES")

        let scope = try createScope(installPath: "/usr/lib", otherPath: "/usr/lib") { table in
            table.push(try table.namespace.declareStringMacro("RPATHS"), table.namespace.parseString("$(INSTALL_PATH:isancestor=$(A_PATH))"))
            table.push(try table.namespace.declareStringMacro("RPATHS"), table.namespace.parseString("$(RPATHS:standardizepath)"))
        }
        #expect(scope.evaluate(scope.namespace.parseString("$(RPATHS)")) == "NO")
    }

    @Test
    func defaultReplacementOperator() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)
        var scope: MacroEvaluationScope

        // Test that the setting being evaluated with a default is undefined.
        table.push(try namespace.declareStringMacro("LLVM_TARGET_TRIPLE_OS_VERSION"), namespace.parseString("macos$(MACOSX_DEPLOYMENT_TARGET:default=10.15)"))
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseString("$(LLVM_TARGET_TRIPLE_OS_VERSION)")) == "macos10.15")

        // Test that the setting being evaluated with a default is explicitly set to empty.  This is semantically the same as being undefined, but may follow a different code path in implementation.
        table.push(try namespace.declareStringMacro("MACOSX_DEPLOYMENT_TARGET"), literal: "")
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseString("$(LLVM_TARGET_TRIPLE_OS_VERSION)")) == "macos10.15")

        // Test that the setting being evaluated with a default is not empty.
        table.push(try namespace.declareStringMacro("MACOSX_DEPLOYMENT_TARGET"), literal: "11.0")
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseString("$(LLVM_TARGET_TRIPLE_OS_VERSION)")) == "macos11.0")

        // Test that the default value can itself be a macro expression.
        table.push(try namespace.declareStringMacro("LLVM_TARGET_TRIPLE_OS_VERSION"), namespace.parseString("macos$(MACOSX_DEPLOYMENT_TARGET:default=$(DEFAULT_DEPLOYMENT_TARGET:default=10.10)"))
        table.push(try namespace.declareStringMacro("MACOSX_DEPLOYMENT_TARGET"), literal: "")
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseString("$(LLVM_TARGET_TRIPLE_OS_VERSION)")) == "macos10.10")
        table.push(try namespace.declareStringMacro("DEFAULT_DEPLOYMENT_TARGET"), literal: "10.14")
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseString("$(LLVM_TARGET_TRIPLE_OS_VERSION)")) == "macos10.14")

        // Test that we can compose a build setting name by evaluating a setting with a default value.
        try namespace.declareBooleanMacro("BOOLEAN")
        table.push(try namespace.declareStringMacro("SETTING_YES"), literal: "true")
        table.push(try namespace.declareStringMacro("SETTING_NO"), literal: "false")
        table.push(try namespace.declareStringMacro("SETTING"), namespace.parseString("$(SETTING_$(BOOLEAN:default=NO))"))
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseString("$(SETTING)")) == "false")
        table.push(try namespace.declareBooleanMacro("BOOLEAN"), literal: true)
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseString("$(SETTING)")) == "true")

        // Test that applying the default value to an empty list-type setting results in a single-item list.
        table.push(try namespace.declareStringListMacro("LIST_SETTING"), namespace.parseStringList("$(UNDEFINED:default=empty)"))
        scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseStringList("$(LIST_SETTING)")) == ["empty"])
    }

    @Test
    func conditions() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)
        let param = namespace.declareConditionParameter("param")

        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")
        table.push(X, literal: "x")
        var conditions = [MacroCondition]()
        let cond1 = MacroCondition(parameter:param, valuePattern:"pattern*")
        #expect(cond1.parameter == param);
        #expect(cond1.valuePattern == "pattern*");
        #expect(cond1.description != "");
        let cond2 = MacroCondition(parameter:param, valuePattern:"pattern*")
        #expect(cond2.parameter == param);
        #expect(cond2.valuePattern == "pattern*");
        #expect(cond2.description != "");
        #expect(cond1 == cond2)
        let cond3 = MacroCondition(parameter:param, valuePattern:"pattern*~")
        #expect(cond3.parameter == param);
        #expect(cond3.valuePattern == "pattern*~");
        #expect(cond3.description != "");
        #expect(cond1 != cond3)
        #expect(cond2 != cond3)
        conditions.append(cond1)
        table.push(X, literal: "ⓧ", conditions:MacroConditionSet(conditions: conditions))
        #expect(table.lookupMacro(X)?.conditions != nil)
        table.push(Y, namespace.parseString("¡$(X)!"))
        table.push(Y, namespace.parseString("$(Y)"))
        table.push(Y, namespace.parseString("$(inherited)"))
        conditions.append(cond2)
        conditions.append(cond3)
        let set = MacroConditionSet(conditions: conditions)
        #expect(set.conditions == conditions)

        let scope = MacroEvaluationScope(table: table)
        let result: String = scope.evaluate(Y)
        #expect(result == "¡x!")
    }
}

@Suite fileprivate struct MacroStringListEvaluationTests {
    @Test
    func simpleEvaluation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare some string list macros.
        let X = try namespace.declareStringListMacro("X")
        let Y = try namespace.declareStringListMacro("Y")
        let Z = try namespace.declareStringListMacro("Z")
        let XYZ = try namespace.declareStringListMacro("XYZ")
        let XYZXYZ = try namespace.declareStringListMacro("XYZXYZ")
        let UVW = try namespace.declareStringListMacro("UVW")
        let EMPTY = try namespace.declareStringListMacro("EMPTY")

        // Push some literal string list assignments.
        table.push(X, literal: ["x"])
        table.push(Y, literal: ["y"])
        table.push(Z, literal: ["z"])
        table.push(XYZ, namespace.parseStringList("$(X) $(Y) $(Z)"))
        table.push(XYZXYZ, namespace.parseStringList("$(XYZ) $(XYZ)"))
        table.push(UVW, namespace.parseStringList("$(EMPTY) $(EMPTY) $(XYZ)$(XYZ) $(EMPTY) $(EMPTY)"))
        table.push(EMPTY, namespace.parseStringList("$(EMPTY)"))

        // Also create a freestanding test expression.
        let spacelessExpr = namespace.parseStringList("$(X)$(Y)$(Z)")
        let spacefulExpr = namespace.parseStringList("$(X) $(Y) $(Z)")
        let mixedExpr = namespace.parseStringList("$(XYZ)$(XYZ)$(XYZ)")
        let complexExpr = namespace.parseStringList("$(XYZ) $(XYZXYZ) $(XYZ)")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(X) == ["x"])
        #expect(scope.evaluate(XYZ) == ["x", "y", "z"])
        #expect(scope.evaluate(XYZXYZ) == ["x", "y", "z", "x", "y", "z"])
        #expect(scope.evaluate(spacelessExpr) == ["xyz"])
        #expect(scope.evaluate(spacefulExpr) == ["x", "y", "z"])
        #expect(scope.evaluate(mixedExpr) == ["x", "y", "zx", "y", "zx", "y", "z"])
        #expect(scope.evaluate(complexExpr) == ["x", "y", "z", "x", "y", "z", "x", "y", "z", "x", "y", "z"])
        #expect(scope.evaluate(UVW) == ["x", "y", "zx", "y", "z"])
    }

    /// Check the handle of string lists with empty string evaluations.
    @Test
    func emptyEvaluation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare a string list macro, and push a parsed expression value.
        let LIST = try namespace.declareStringListMacro("LIST")
        table.push(LIST, namespace.parseStringList("-foo $(STRING)"))

        // Declare a string macro.
        let STRING = try namespace.declareStringMacro("STRING")

        // Declare a string macro for which we will specifically not provide a value.
        let _ = try namespace.declareStringMacro("STRING_WITH_MISSING_VALUE")

        // Declare a list macro for which we will specifically not provide a value.
        let _ = try namespace.declareStringListMacro("LIST_WITH_MISSING_VALUE")

        // Test a literal empty string.
        table.push(STRING, literal:"")
        let scope1 = MacroEvaluationScope(table: table)
        #expect(scope1.evaluate(LIST) == ["-foo", ""])

        // Test a literal empty string parsed as a string expression.
        table.push(STRING, namespace.parseString(""))
        let scope2 = MacroEvaluationScope(table: table)
        #expect(scope2.evaluate(LIST) == ["-foo", ""])

        // Test a string list with a reference to a missing value of a declared string macro.
        #expect(scope2.evaluate(namespace.parseStringList("-foo $(STRING_WITH_MISSING_VALUE)")) == ["-foo", ""])

        // Test a string list with a reference to a missing value of a declared list macro.
        #expect(scope2.evaluate(namespace.parseStringList("-foo $(LIST_WITH_MISSING_VALUE)")) == ["-foo"])

        // Test a string list with a reference to a missing value of an undeclared macro.
        #expect(scope2.evaluate(namespace.parseStringList("-foo $(COMPLETELY_UNKNOWN_MACRO)")) == ["-foo"])
    }

    /// Check the evaluation of string lists when evaluating them as strings.
    ///
    /// The interesting cases here are expressions which contain quotes, spaces and escapes, as those should be preserved when evaluating as a string, whereas they are elided when evaluating as a list.
    @Test
    func asStringEvaluation() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare some string list macros.
        let X = try namespace.declareStringListMacro("X")
        let Y = try namespace.declareStringListMacro("Y")
        let Z = try namespace.declareStringListMacro("Z")

        // Push some literal string list assignments.
        table.push(X, literal: ["x"])
        table.push(Y, literal: ["y"])
        table.push(Z, literal: ["z"])

        /// There isn't API to force a parsed string-list expression to be evaluated as a string, so this utility function will parse a string expression which refers to the string-list expression we want to test.
        var usedMacros = Set<String>()
        func checkStringListEvaluatedAsString(_ macroName: String, _ sourceString: String, _ expectedStringListValue: [String], _ expectedStringValue: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            guard !usedMacros.contains(macroName) else {
                Issue.record("macro \(macroName) has already been used in this test case", sourceLocation: sourceLocation)
                return
            }
            usedMacros.insert(macroName)

            let stringListMacro = try namespace.declareStringListMacro(macroName)
            table.push(stringListMacro, namespace.parseStringList(sourceString))

            let stringExpr = namespace.parseString("$(\(macroName))")

            let scope = MacroEvaluationScope(table: table)

            #expect(scope.evaluate(stringListMacro) == expectedStringListValue)
            #expect(scope.evaluate(stringExpr) == expectedStringValue)
        }

        // Test evaluating various strings both as string lists and as strings.
        try checkStringListEvaluatedAsString("LEADING_TRAILING_SPACES", "   $(X)    ", ["x"], "   x    ")
        try checkStringListEvaluatedAsString("LEADING_TRAILING_WHITESPACE", "\n  $(X)\n\n\n", ["x"], "\n  x\n\n\n")
        try checkStringListEvaluatedAsString("LEADING_TRAILING_ESCAPES", "\\a$(X)\\b", ["axb"], "\\ax\\b")
        try checkStringListEvaluatedAsString("INTERIOR_WHITESPACE", "$(X)   $(Y)\n $(Z)", ["x", "y", "z"], "x   y\n z")
        try checkStringListEvaluatedAsString("DOUBLE_QUOTES", "Expanded value: \"$(X)\"", ["Expanded", "value:", "x"], "Expanded value: \"x\"")
        try checkStringListEvaluatedAsString("SINGLE_QUOTES", "Expanded value: \'$(X)\'", ["Expanded", "value:", "x"], "Expanded value: \'x\'")
    }

    @Test
    func edgeCases() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare a string list macro.
        let EMPTY = try namespace.declareStringListMacro("EMPTY")
        let STRING = try namespace.declareStringListMacro("STRING")

        // Push some macro value assignments.
        table.push(EMPTY, literal: [])
        table.push(STRING, literal: [""])
        table.push(EMPTY, namespace.parseStringList("$(EMPTY)$(EMPTY)"))
        table.push(EMPTY, namespace.parseStringList("$(EMPTY)$(EMPTY)"))

        // Also create a freestanding test expression.
        let expr1 = namespace.parseStringList("$(EMPTY)")
        let expr2 = namespace.parseStringList("$(STRING)")
        let expr3 = namespace.parseStringList("$(STRING)$(EMPTY)$(STRING)")
        let expr4 = namespace.parseStringList("$(EMPTY)$(STRING)$(EMPTY)")
        let expr5 = namespace.parseStringList("$(STRING)$(STRING)$(STRING)")
        let expr6 = namespace.parseStringList("$(EMPTY)$(EMPTY)$(STRING)")
        let expr7 = namespace.parseStringList("$(EMPTY)$(EMPTY)")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(expr1) == [])
        #expect(scope.evaluate(expr2) == [""])
        #expect(scope.evaluate(expr3) == [""])
        #expect(scope.evaluate(expr4) == [""])
        #expect(scope.evaluate(expr5) == [""])
        #expect(scope.evaluate(expr6) == [""])
        #expect(scope.evaluate(expr7) == [])
    }

    @Test
    func basicInheritance() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare a string list macro.
        let X = try namespace.declareStringListMacro("X")

        // Push some macro value assignments.
        table.push(X, literal: ["x"])
        table.push(X, namespace.parseStringList("$(X) $(X) $(X)"))
        table.push(X, namespace.parseStringList("-I $(X)"))
        table.push(X, namespace.parseStringList("$(inherited) -D A"))
        table.push(X, namespace.parseStringList("$(value) -D B"))

        // Also create a freestanding test expression.
        let expr = namespace.parseStringList("-Wnone $(X) -D C")

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Test the evaluation results.
        #expect(scope.evaluate(X) == ["-I", "x", "x", "x", "-D", "A", "-D", "B"])
        #expect(scope.evaluate(expr) == ["-Wnone", "-I", "x", "x", "x", "-D", "A", "-D", "B", "-D", "C"])
    }

    /// Check the corner case seen in: <rdar://problem/31544015> Unexpected -D of empty string
    @Test
    func computedMacroTogglingAsStringFlag() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Check an expression which references a missing macro, but via a recursive evaluation against a string-typed macro.
        let LIST = try namespace.declareStringListMacro("LIST")
        _ = try namespace.declareStringMacro("STRING")
        table.push(LIST, namespace.parseStringList("A $(MISSING_$(STRING)) B"))
        let scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(LIST) == ["A", "B"])
    }

    /// Check handling of string list evaluation of string values.
    @Test(.bug("rdar://67131014"))
    func typeCoercion() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Expand a string list which references a string.
        let LIST = try namespace.declareStringListMacro("LIST")
        let STR = try namespace.declareStringMacro("STR")

        // Push some macro value assignments.
        table.push(STR, namespace.parseString("$(inherited) VALUE1 VALUE2"))
        table.push(LIST, namespace.parseStringList("$(STR)"))

        // Test the evaluation results.
        let scope = MacroEvaluationScope(table: table)

        // fails
        withKnownIssue("Macro evaluation issue with string referenced from string list") {
            #expect(scope.evaluate(LIST) == ["VALUE1", "VALUE2"])
        }
    }

    /// Check the behavior of parsing lists of string lists with quotes.
    @Test
    func listsAsStringListParsing() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)
        let LIST = try namespace.declareStringListMacro("LIST")
        table.push(LIST, namespace.parseStringList("\"a\" \\\"a\\\" a\"b\" a\\\"b\\\" 'a' a'b' a\\'b\\'"))
        let scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(LIST) == ["a", "\"a\"", "ab", "a\"b\"", "a", "ab", "a'b'"])
    }

    @Test
    func contains() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)
        let KEY = try namespace.declareStringMacro("KEY")
        table.push(KEY, namespace.parseString("VALUE"))

        #expect(table.contains(KEY))
        #expect(!table.contains(namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, "blah")))
    }

    @Test
    func combingGraphemeClusters() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        let X = try namespace.declareStringListMacro("X")
        let Y = try namespace.declareStringListMacro("Y")
        let Z = try namespace.declareStringListMacro("Z")

        // The macro evaluation result builders store their state in a String so combining grapheme clusters at the end of one and the start of another will combine them.
        // The evaluation should still handle that correctly.
        // 🇺+🇸 => 🇺🇸
        table.push(X, literal: ["🇺"])
        table.push(Y, literal: ["🇸", ""])
        table.push(Z, literal: ["a", "🇺", "🇸", ""])

        let scope = MacroEvaluationScope(table: table)
        #expect(scope.evaluate(namespace.parseStringList("$(X) $(Y)")) == ["🇺", "🇸", ""])
        #expect(scope.evaluate(namespace.parseStringList("$(X)")) == ["🇺"])
        #expect(scope.evaluate(namespace.parseStringList("$(Y)")) == ["🇸", ""])
        #expect(scope.evaluate(namespace.parseStringList("🇺$(Y)")) == ["🇺🇸", ""])
        #expect(scope.evaluate(namespace.parseStringList("🇺 $(Y)")) == ["🇺", "🇸", ""])
        #expect(scope.evaluate(namespace.parseStringList("alpha beta charlie $(Y)")) == ["alpha", "beta", "charlie", "🇸", ""])
        #expect(scope.evaluate(namespace.parseStringList("$(Z)")) == ["a", "🇺", "🇸", ""])
        #expect(scope.evaluate(namespace.parseStringList("$(Z) $(Z)")) == ["a", "🇺", "🇸", "", "a", "🇺", "🇸", ""])
    }

    @Test
    func buildStringList() throws {
        enum TestCase: ExpressibleByArrayLiteral, ExpressibleByStringLiteral {
            case literal([String])
            case string(String)

            init(stringLiteral value: String) {
                self = .string(value)
            }

            init(arrayLiteral elements: TestCase...) {
                self = .literal(elements.compactMap({ value in
                    guard case .string(let str) = value else { return nil }
                    return str
                }))
            }
        }

        let testCases: [TestCase] = [
            [],
            ["f", "o", "o"],
            [""],
            ["foo"],
            ["a", "", "", "B"],
            ["a", "🇺", "🇸", ""],
            "foo bar",
            "/f//o",
            "🤪 𝛂",
            "😱\u{200D}🤩",
            "😱\u{200D}a",
            TestCase(stringLiteral: Array(repeating: "a", count: 1_000_000).joined(separator: " ")),
            TestCase.literal(Array(repeating: "a", count: 1_000_000)),
            "caf\u{E9}", // café with pre-composed é
            "caf\u{65}\u{301}", // café with decomposed é
            ["caf\u{E9}", "caf\u{65}\u{301}"],
            ["caf\u{65}\u{301}", "caf\u{E9}"],
        ]

        for test in testCases {
            let namespace = MacroNamespace()
            var table = MacroValueAssignmentTable(namespace: namespace)

            let X = try namespace.declareStringListMacro("X")

            let expected: [String]
            switch test {
            case .literal(let literal):
                table.push(X, literal: literal)
                expected = literal
            case .string(let str):
                table.push(X, namespace.parseStringList(str))
                expected = str.components(separatedBy: " ")
            }

            let scope = MacroEvaluationScope(table: table)
            #expect(scope.evaluate(X) == expected)
        }
    }

    /// Test that MacroEvaluationResultBuilder works correctly with UTF-16 encoded bridged NSStrings (which the "StringWithMapping" APIs return).
    @Test
    func macroResultBuilderNormalizationAndBridging() {
        func check(path: String) {
            // This string contains no characters with varying normal forms.
            let originalUTF8 = Data(path.utf8)
            #expect(originalUTF8 == Data(path.decomposedStringWithCanonicalMapping.utf8))
            #expect(originalUTF8 == Data(path.decomposedStringWithCompatibilityMapping.utf8))
            #expect(originalUTF8 == Data(path.precomposedStringWithCanonicalMapping.utf8))
            #expect(originalUTF8 == Data(path.precomposedStringWithCompatibilityMapping.utf8))

            // ...and therefore normalization should not have an effect.
            let scope = MacroEvaluationScope(table: MacroValueAssignmentTable(namespace: MacroNamespace()))
            let paths = Array(repeating: path, count: 2)
            #expect(scope.roundtrip(paths) == paths)
            #expect(scope.roundtrip(paths.map(\.decomposedStringWithCanonicalMapping)) == paths)
            #expect(scope.roundtrip(paths.map(\.decomposedStringWithCompatibilityMapping)) == paths)
            #expect(scope.roundtrip(paths.map(\.precomposedStringWithCanonicalMapping)) == paths)
            #expect(scope.roundtrip(paths.map(\.precomposedStringWithCompatibilityMapping)) == paths)
        }

        do {
            let path = String(decoding: [0x20, 0x20, 0xe2, 0x80, 0x93, 0x20, 0x20], as: UTF8.self)
            #expect(path == "  –  ")
            check(path: path)
        }

        do {
            let path = String(decoding: [0x20, 0xe2, 0x80, 0x93, 0x20], as: UTF8.self)
            #expect(path == " – ")
            check(path: path)
        }
    }
}

extension MacroEvaluationScope {
    func roundtrip(_ strings: [String]) -> [String] {
        return evaluate(table.namespace.parseLiteralStringList(strings))
    }
}

@Suite fileprivate struct MacroPropertyListEvaluationTests {
    let namespace: MacroNamespace

    init() async throws {
        namespace = MacroNamespace(parent: nil, debugDescription: "MacroPropertyListEvaluationTests")
    }

    @Test
    func propertyListValueBoolean() throws {
        var table = MacroValueAssignmentTable(namespace: namespace)
        let BOOLEAN = try namespace.declareBooleanMacro("BOOLEAN")
        table.push(BOOLEAN, literal: true)
        let scope = MacroEvaluationScope(table: table)
        #expect(BOOLEAN.propertyListValue(in: scope) == .plBool(true))
    }

    @Test
    func propertyListValueString() throws {
        var table = MacroValueAssignmentTable(namespace: namespace)
        let STRING = try namespace.declareStringMacro("STRING")
        table.push(STRING, literal: "String")
        let scope = MacroEvaluationScope(table: table)
        #expect(STRING.propertyListValue(in: scope) == .plString("String"))
    }

    @Test
    func propertyListValueStringList() throws {
        var table = MacroValueAssignmentTable(namespace: namespace)
        let STRINGLIST = try namespace.declareStringListMacro("STRINGLIST")
        table.push(STRINGLIST, literal: ["StringList1", "StringList2"])
        let scope = MacroEvaluationScope(table: table)
        #expect(STRINGLIST.propertyListValue(in: scope) == .plArray([.plString("StringList1"), .plString("StringList2")]))
    }

    @Test
    func propertyListValueEnum() throws {
        enum SimpleEnum: String, Equatable, Hashable, EnumerationMacroType {
            static let defaultValue = SimpleEnum.DefaultValue
            case DefaultValue = "DefaultValue"
            case OverrideValue = "OverrideValue"
        }

        var table = MacroValueAssignmentTable(namespace: namespace)
        let ENUM = try namespace.declareEnumMacro("ENUM") as EnumMacroDeclaration<SimpleEnum>
        table.push(ENUM, namespace.parseForMacro(ENUM, value: "OverrideValue"))
        let scope = MacroEvaluationScope(table: table)
        #expect(ENUM.propertyListValue(in: scope) == .plString("OverrideValue"))
    }

    @Test
    func propertyListValueUserDefinedProducesNil() throws {
        var table = MacroValueAssignmentTable(namespace: namespace)
        let USERDEFINED = try namespace.declareUserDefinedMacro("USERDEFINED")
        table.push(USERDEFINED, namespace.parseStringList("UserDefined"))
        let scope = MacroEvaluationScope(table: table)
        #expect(USERDEFINED.propertyListValue(in: scope) == nil)
    }
}

@Suite fileprivate struct MacroPathAndPathListEvaluationTests {
    enum TestPathError: Error {
        case componentSeparatorLengthMismatch
    }

    struct Expectations {
        let stringEvaluated: String
        let macroEvaluated: String
        let base: String?
        let file: String?
        let dir: String?
    }

    struct TestPath: Error {
        let root: String
        let components: [String]
        let separators: [String]
        let expectations: Expectations


        init(root: String, components: [String], separators: [String], expectations: Expectations) throws {
            if components.count != separators.count {
                throw TestPathError.componentSeparatorLengthMismatch
            }
            self.root = root
            self.components = components
            self.separators = separators
            self.expectations = expectations
        }

        var path: String {
            var cPath = self.root
            for (componentIndex, component) in components.enumerated() {
                cPath.append("\(componentIndex != 0 ? separators[componentIndex]: "")\(component)")
            }
            return cPath
        }
    }

    var testPaths: [TestPath] {
        var tps: [TestPath] = []
        do {
            #if !os(Windows)
            tps = try [
                TestPath(root: "/", components: [ "this", "is", "a", "path" ], separators: ["/", "/", "/", "/"],
                         expectations: Expectations(stringEvaluated: "/this/is/a/path", macroEvaluated: "/this/is/a/path", base: nil, file: nil, dir: "/this/is/a")),
                TestPath(root: "/", components: [ "this", "is", "..", "path" ], separators: ["/", "/", "/", "/"],
                         expectations: Expectations(stringEvaluated: "/this/is/../path", macroEvaluated: "/this/path", base: nil, file: nil, dir: "/this")),
                TestPath(root: "", components: [ "I", "have", "no", "root" ], separators: ["/", "/", "/", "/"],
                         expectations: Expectations(stringEvaluated: "I/have/no/root", macroEvaluated: "I/have/no/root", base: nil, file: nil, dir: "I/have/no" )),
                TestPath(root: "/", components: [ "I", "have", "a", "trailing", "" ], separators: ["/", "/", "/", "/", "/"],
                         expectations: Expectations(stringEvaluated: "/I/have/a/trailing/", macroEvaluated: "/I/have/a/trailing", base: nil, file: nil, dir: "/I/have/a/trailing")),
                TestPath(root: "/", components: [ "this", "is", "a", "file", "file1.txt" ], separators: ["/", "/", "/", "/", "/"],
                         expectations: Expectations(stringEvaluated: "/this/is/a/file/file1.txt", macroEvaluated: "/this/is/a/file/file1.txt", base: "file1", file: "file1.txt", dir: nil))
            ]
            #else
            tps = try [
                TestPath(root: "C:\\", components: [ "this", "is", "a", "path" ], separators: ["\\", "\\", "\\", "\\"],
                         expectations: Expectations(stringEvaluated: "C:\\this\\is\\a\\path", macroEvaluated: "C:\\this\\is\\a\\path", base: nil, file: nil, dir: "C:\\this\\is\\a")),
                TestPath(root: "C:\\", components: [ "this", "is", "a", "path" ], separators: ["\\", "\\", "/", "/"],
                         expectations: Expectations(stringEvaluated: "C:\\this\\is/a/path", macroEvaluated: "C:\\this\\is\\a\\path", base: nil, file: nil, dir: "C:\\this\\is\\a")),
                TestPath(root: "C:\\", components: [ "this", "is", "..", "path" ], separators: ["\\", "\\", "\\", "\\"],
                         expectations: Expectations(stringEvaluated: "C:\\this\\is\\..\\path", macroEvaluated: "C:\\this\\path", base: nil, file: nil, dir: "C:\\this")),
                TestPath(root: "C:\\", components: [ "I", "have", "a", "trailing", "" ], separators: ["\\", "\\", "\\", "\\", "\\"],
                         expectations: Expectations(stringEvaluated: "C:\\I\\have\\a\\trailing\\", macroEvaluated: "C:\\I\\have\\a\\trailing", base: nil, file: nil, dir: "C:\\I\\have\\a"))
            ]
            #endif
        } catch {
            #expect(Bool(false), "Failed to load test paths: \(error)")
        }
        return tps
    }

    @Test
    func simplePathMacros() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        for testPath in testPaths {
            let rootPath = try namespace.declarePathMacro("ROOT_PATH")
            // Root macro
            table.push(rootPath, literal: testPath.root)
            // Path component macros
            var expressionPathString = "$(ROOT_PATH)"
            for (componentIndex, component) in testPath.components.enumerated() {
                let pathMacro = try namespace.declarePathMacro("PATH_\(componentIndex)")
                table.push(pathMacro, literal: component)
                expressionPathString.append("\(componentIndex != 0 ? testPath.separators[componentIndex]: "")$(PATH_\(componentIndex))")
            }

            // Combined Path
            let macroPath = try namespace.declarePathMacro("MACRO_PATH")
            let expressionPath  = namespace.parseString(expressionPathString)
            table.push(macroPath, expressionPath)

            // Macro Operators
            // :standardize
            let macroPathStandardized = try namespace.declarePathMacro("MACRO_PATH_STANDARDIZED")
            let expressionPathStandardized = namespace.parseString("$(MACRO_PATH:standardizepath)")
            table.push(macroPathStandardized, expressionPathStandardized)
            //:file
            let macroPathFile = try namespace.declarePathMacro("MACRO_PATH_FILE")
            let expressionPathFile = namespace.parseString("$(MACRO_PATH:file)")
            table.push(macroPathFile, expressionPathFile)
            //:base
            let macroPathBase = try namespace.declarePathMacro("MACRO_PATH_BASE")
            let expressionPathBase = namespace.parseString("$(MACRO_PATH:base)")
            table.push(macroPathBase, expressionPathBase)
            //:dir
            let macroPathDir = try namespace.declarePathMacro("MACRO_PATH_DIR")
            let expressionPathDir = namespace.parseString("$(MACRO_PATH:dir)")
            table.push(macroPathDir, expressionPathDir)

            // Create a macro evaluation scope for testing.
            let scope = MacroEvaluationScope(table: table)

            // Test the string evaluation
            #expect(scope.evaluate(expressionPath) == testPath.expectations.stringEvaluated)
            // Test the macro evaluation, which should be normalized
            #expect(scope.evaluate(macroPath).str == testPath.expectations.macroEvaluated)

            // Test macro operators
            #expect(scope.evaluate(macroPathStandardized).str == testPath.expectations.macroEvaluated) //Should be already standardized/normalized
            if testPath.expectations.file != nil {
                #expect(scope.evaluate(macroPathFile).str == testPath.expectations.file)
            }
            if testPath.expectations.base != nil {
                #expect(scope.evaluate(macroPathBase).str == testPath.expectations.base)
            }
            if testPath.expectations.dir != nil {
                #expect(scope.evaluate(macroPathDir).str == testPath.expectations.dir)
            }
         }
    }

    @Test
    func simplePathListMacros() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        let macroPathList = try namespace.declarePathListMacro("MACRO_PATH_LIST")
        table.push(macroPathList, literal: testPaths.map{$0.path})

        //Macro Operators
        //:standardize
        let macroPathListStandardize = try namespace.declarePathListMacro("MACRO_PATH_LIST_STANDARDIZE")
        let expressionPathListStandardize = namespace.parseStringList("$(MACRO_PATH_LIST:standardizepath)")
        table.push(macroPathListStandardize, expressionPathListStandardize)
        //:base
        let macroPathListBase = try namespace.declarePathListMacro("MACRO_PATH_LIST_BASE")
        let expressionPathListBase = namespace.parseStringList("$(MACRO_PATH_LIST:base)")
        table.push(macroPathListBase, expressionPathListBase)
        //:file
        let macroPathListFile = try namespace.declarePathListMacro("MACRO_PATH_LIST_FILE")
        let expressionPathListFile = namespace.parseStringList("$(MACRO_PATH_LIST:file)")
        table.push(macroPathListFile , expressionPathListFile)
        //:dir
        let macroPathListDir = try namespace.declarePathListMacro("MACRO_PATH_LIST_DIR")
        let expressionPathListDir = namespace.parseStringList("$(MACRO_PATH_LIST:dir)")
        table.push(macroPathListDir , expressionPathListDir)


        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table)

        // Check that all paths have been normalized
        #expect(scope.evaluate(macroPathList) == testPaths.map{$0.expectations.macroEvaluated})

        // Check macro operators function as expected, order is same as testPaths
        for (testPathIndex, testPath) in testPaths.enumerated() {
            #expect(scope.evaluate(macroPathListStandardize)[testPathIndex] == testPath.expectations.macroEvaluated)
            if testPath.expectations.base != nil {
                #expect(scope.evaluate(macroPathListBase)[testPathIndex] == testPath.expectations.base)
            }
            if testPath.expectations.file != nil {
                #expect(scope.evaluate(macroPathListFile)[testPathIndex] == testPath.expectations.file)
            }
            if testPath.expectations.dir != nil {
                #expect(scope.evaluate(macroPathListDir)[testPathIndex] == testPath.expectations.dir)
            }
        }
    }
}
