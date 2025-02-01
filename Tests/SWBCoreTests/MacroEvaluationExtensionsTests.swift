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
import SWBTestSupport
import SWBCore
import SWBMacro

@Suite fileprivate struct MacroEvaluationExtensionsTests {
    @Test
    func macroEvaluationInPropertyLists() throws {
        let namespace = MacroNamespace(parent: nil, debugDescription: "testMacroEvaluationInPropertyLists()")
        let FOO = try namespace.declareStringMacro("FOO")
        let BAR = try namespace.declareStringMacro("BAR")
        let BAZ = try namespace.declareStringMacro("BAZ")
        let QUUX = try namespace.declareStringMacro("QUUX")
        let ASIDE = try namespace.declareStringMacro("ASIDE")
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(FOO, literal: "One")
        table.push(BAR, literal: "Two")
        table.push(BAZ, literal: "Three")
        table.push(QUUX, literal: "Four")
        let scope = MacroEvaluationScope(table: table)
        let lookup: ((MacroDeclaration) -> MacroExpression?)? = { $0 == ASIDE ? namespace.parseLiteralString("Ay") : nil }

        let plistString = "{ a = \"$(FOO)\"; b = (\"$(FOO)\", \"$(BAR)\"); c = { \"$(FOO)\" = \"$(BAZ)\"; \"$(BAR)\" = \"$(QUUX)\"; }; d = <AABBCCDD>; e = \"$(ASIDE)\"; }"
        let plist = try PropertyList.fromString(plistString)

        // Evaluate only the dictionary values.
        var expectedPlistString = "{ a = One; b = (One, Two); c = { \"$(FOO)\" = Three; \"$(BAR)\" = Four; }; d = <AABBCCDD>; e = Ay; }"
        var expectedPlist = try PropertyList.fromString(expectedPlistString)
        var evaluatedPlist = plist.byEvaluatingMacros(withScope: scope, lookup: lookup)
        #expect(evaluatedPlist == expectedPlist)

        // Evaluate dictionary keys and values.
        expectedPlistString = "{ a = One; b = (One, Two); c = { One = Three; Two = Four; }; d = <AABBCCDD>; e = Ay; }"
        expectedPlist = try PropertyList.fromString(expectedPlistString)
        evaluatedPlist = plist.byEvaluatingMacros(withScope: scope, andDictionaryKeys: true, lookup: lookup)
        #expect(evaluatedPlist == expectedPlist)
    }

    @Test
    func macroEvaluationInPropertyListsPreservingSettings() throws {
        let namespace = MacroNamespace(parent: nil, debugDescription: "testMacroEvaluationInPropertyLists()")
        let FOO = try namespace.declareStringMacro("FOO")
        let BAR = try namespace.declareStringMacro("BAR")
        let PRESERVE = try namespace.declareStringMacro("PRESERVE")
        let KEEP = try namespace.declareStringMacro("KEEP")
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(FOO, literal: "One")
        table.push(BAR, literal: "Two")
        table.push(PRESERVE, literal: "Three")
        let scope = MacroEvaluationScope(table: table)
        let lookup: ((MacroDeclaration) -> MacroExpression?)? = { $0 == KEEP ? namespace.parseLiteralString("Ay") : nil }

        let plistString = "{ a = \"$(FOO) $(PRESERVE) baz\"; b = (\"$(PRESERVE)\", \"$(BAR)\"); \"$(PRESERVE)\" = quux; c = { \"$(FOO)\" = \"$(PRESERVE)\"; \"$(PRESERVE)\" = \"$(BAR)\"; }; d = \"$(KEEP)\"; }"
        let plist = try PropertyList.fromString(plistString)

        // Evaluate only the dictionary values.
        var expectedPlistString = "{ a = \"One $(PRESERVE) baz\"; b = (\"$(PRESERVE)\", Two); \"$(PRESERVE)\" = quux; c = { \"$(FOO)\" = \"$(PRESERVE)\"; \"$(PRESERVE)\" = Two; }; d = Ay; }"
        var expectedPlist = try PropertyList.fromString(expectedPlistString)
        var evaluatedPlist = plist.byEvaluatingMacros(withScope: scope, preserveReferencesToSettings: Set([PRESERVE]), lookup: lookup)
        #expect(evaluatedPlist == expectedPlist)

        // Evaluate dictionary keys and values.
        expectedPlistString = "{ a = \"One $(PRESERVE) baz\"; b = (\"$(PRESERVE)\", Two); \"$(PRESERVE)\" = quux; c = { One = \"$(PRESERVE)\"; \"$(PRESERVE)\" = Two; }; d = Ay; }"
        expectedPlist = try PropertyList.fromString(expectedPlistString)
        evaluatedPlist = plist.byEvaluatingMacros(withScope: scope, andDictionaryKeys: true, preserveReferencesToSettings: Set([PRESERVE]), lookup: lookup)
        #expect(evaluatedPlist == expectedPlist)

        // Confirm that settings we direct to be preserved take precedence over the lookup.
        expectedPlistString = "{ a = \"One $(PRESERVE) baz\"; b = (\"$(PRESERVE)\", Two); \"$(PRESERVE)\" = quux; c = { One = \"$(PRESERVE)\"; \"$(PRESERVE)\" = Two; }; d = \"$(KEEP)\"; }"
        expectedPlist = try PropertyList.fromString(expectedPlistString)
        evaluatedPlist = plist.byEvaluatingMacros(withScope: scope, andDictionaryKeys: true, preserveReferencesToSettings: Set([PRESERVE, KEEP]), lookup: lookup)
        #expect(evaluatedPlist == expectedPlist)
    }
}
