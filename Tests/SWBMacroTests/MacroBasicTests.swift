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

/// Unit tests of basic macro evaluation functionality.  Constructing namespaces, declaring macros of various types, etc.
@Suite fileprivate struct MacroBasicTests {

    @Test
    func macroDeclarations() throws {
        let namespace = MacroNamespace(debugDescription: "test")

        let firstBoolDecl = try namespace.declareBooleanMacro("SomeBooleanMacro")
        #expect(firstBoolDecl.type == .boolean)

        let repeatedBoolDecl = try namespace.declareBooleanMacro("SomeBooleanMacro")
        #expect(repeatedBoolDecl.type == .boolean)
        #expect(repeatedBoolDecl === firstBoolDecl)

        var didCatchExpectedException: Bool = false
        do {
            _ = try namespace.declareStringMacro("SomeBooleanMacro")
        } catch {
            didCatchExpectedException = true
        }
        #expect(didCatchExpectedException)
    }


    @Test
    func macroExpressionCreation() throws {
        let namespace = MacroNamespace(debugDescription: "test")

        let booleanDecl = try namespace.declareBooleanMacro("BooleanMacro")
        #expect(booleanDecl.type == .boolean)

        let stringDecl = try namespace.declareStringMacro("StringMacro")
        #expect(stringDecl.type == .string)

        let stringListDecl = try namespace.declareStringListMacro("StringListMacro")
        #expect(stringListDecl.type == .stringList)

        let userDefinedDecl = try namespace.declareUserDefinedMacro("UserDefinedMacro")
        #expect(userDefinedDecl.type == .userDefined)

        let pathDecl = try namespace.declarePathMacro("PathMacro")
        #expect(pathDecl.type == .path)

        let pathListDecl = try namespace.declarePathListMacro("PathListMacro")
        #expect(pathListDecl.type == .pathList)

        var diags1 = Array<MacroExpressionDiagnostic>()
        let str1 = "$(X"
        let expr1 = namespace.parseString(str1) { diagnostic in
            diags1.append(diagnostic)
        }
        #expect(expr1.stringRep == str1)
        #expect(diags1.count == 1)

        var diags2 = Array<MacroExpressionDiagnostic>()
        let str2 = "$($($(X)))"
        let expr2 = namespace.parseString(str2) { diagnostic in
            diags2.append(diagnostic)
        }
        #expect(expr2.stringRep == str2)
        #expect(diags2.isEmpty)

        // Also try without diagnostics.
        let str3 = "$"
        let expr3 = namespace.parseString(str3)
        #expect(expr3.stringRep == str3)
    }


    @Test
    func macroExpressionEquality() {
        let namespace = MacroNamespace(debugDescription: "test")

        let expr1 = namespace.parseString("something")
        let expr2 = namespace.parseString("something")
        let expr3 = namespace.parseStringList("something")
        let expr4 = namespace.parseString("something else")

        #expect(expr1 == expr2)
        #expect(expr1 != expr3)
        #expect(expr1 != expr4)
        #expect(expr2 != expr3)
    }


    @Test
    func macroNamespaceInheritance() throws {
        let lowerNamespace = MacroNamespace(debugDescription: "lower")

        // Declare a string macro in the lower namespace.
        let lowerStringDecl = try lowerNamespace.declareStringMacro("StringMacro")
        #expect(lowerStringDecl.type == .string)

        // Create the middle of the three namespaces, and make sure we can see the string macro declaration from the lower namespace.
        let middleNamespace = MacroNamespace(parent: lowerNamespace, debugDescription: "middle")
        let middleStringDecl = try middleNamespace.declareStringMacro("StringMacro")
        #expect(middleStringDecl.type == .string)
        #expect(middleStringDecl === lowerStringDecl)

        // Also declare a string list macro in the middle namespace.
        let middleStringListDecl = try middleNamespace.declareStringListMacro("StringListMacro")
        #expect(middleStringListDecl.type == .stringList)

        // Make sure we cannot reach the middle-namespace string list macro declaration if we do the lookup from the lower namespace.
        let lowerStringListDecl = lowerNamespace.lookupMacroDeclaration("StringListMacro")
        #expect(lowerStringListDecl == nil)

        // Create the upper of the three namespaces, and make sure we can see the string macro declaration from the lower namespace.
        let upperNamespace = MacroNamespace(parent: middleNamespace, debugDescription: "upper")
        let upperStringDecl = try upperNamespace.declareStringMacro("StringMacro")
        #expect(upperStringDecl.type == .string)
        #expect(upperStringDecl === lowerStringDecl)

        // Make sure we can also see the string list macro declaration from the middle namespace.
        let upperStringListDecl = try upperNamespace.declareStringListMacro("StringListMacro")
        #expect(upperStringListDecl.type == .stringList)
        #expect(upperStringListDecl === middleStringListDecl)

        // Make sure we can also declare a boolean macro in the upper namespace.
        let upperBooleanDecl = try upperNamespace.declareBooleanMacro("BooleanMacro")
        #expect(upperBooleanDecl.type == .boolean)

        // Make sure we cannot reach the upper-namespace boolean macro declaration if we do the lookup from either the lower or the middle namespace.
        let lowerBooleanDecl = lowerNamespace.lookupMacroDeclaration("BooleanMacro")
        #expect(lowerBooleanDecl == nil)
        let middleBooleanDecl = middleNamespace.lookupMacroDeclaration("BooleanMacro")
        #expect(middleBooleanDecl == nil)

        // Make sure we can also declare a path macro in the upper namespace.
        let upperPathDecl = try upperNamespace.declarePathMacro("PathMacro")
        #expect(upperPathDecl.type == .path)

        // Make sure we cannot reach the upper-namespace path macro declaration if we do the lookup from either the lower or the middle namespace.
        let lowerPathDecl = lowerNamespace.lookupMacroDeclaration("PathMacro")
        #expect(lowerPathDecl == nil)
        let middlePathDecl = middleNamespace.lookupMacroDeclaration("PathMacro")
        #expect(middlePathDecl == nil)


        // Make sure we can also declare a path macro in the upper namespace.
        let upperPathListDecl = try upperNamespace.declarePathListMacro("PathListMacro")
        #expect(upperPathListDecl.type == .pathList)

        // Make sure we cannot reach the upper-namespace path list macro declaration if we do the lookup from either the lower or the middle namespace.
        let lowerPathListDecl = lowerNamespace.lookupMacroDeclaration("PathListMacro")
        #expect(lowerPathListDecl == nil)
        let middlePathListDecl = middleNamespace.lookupMacroDeclaration("PathListMacro")
        #expect(middlePathListDecl == nil)

        // Now declare a macro condition parameter in the lower namespace.
        let lowerCondParam = lowerNamespace.declareConditionParameter("cond")
        #expect(lowerCondParam.name == "cond")

        // Make sure we can see it from the upper namespace.
        let upperInheritedCondParam = upperNamespace.declareConditionParameter("cond")
        #expect(upperInheritedCondParam == lowerCondParam)
        #expect(upperInheritedCondParam.description != "")

        // Now declare a macro condition parameter in the upper namespace.
        let upperCondParam = upperNamespace.declareConditionParameter("upper")
        #expect(upperCondParam.name == "upper")

        // Make sure we cannot reach the upper-namespace condition parameter if we do the lookup from either the lower or the middle namespace
        let lowerLookedupCondParam = lowerNamespace.lookupConditionParameter("upper")
        #expect(lowerLookedupCondParam == nil)
        let middleLookedupCondParam = middleNamespace.lookupConditionParameter("upper")
        #expect(middleLookedupCondParam == nil)
    }
}

