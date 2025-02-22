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

@Suite fileprivate struct MacroNamespaceTests {
    @Test
    func macroTypeParsing() throws {
        let namespace = MacroNamespace(parent: nil)
        let BOOLEAN = try namespace.declareBooleanMacro("BOOLEAN")
        let STRING = try namespace.declareStringMacro("STRING")
        let STRINGLIST = try namespace.declareStringListMacro("STRINGLIST")

        #expect(namespace.parseForMacro(BOOLEAN, value: "hi") == namespace.parseString("hi"))
        #expect(namespace.parseForMacro(STRING, value: "hi") == namespace.parseString("hi"))
        #expect(namespace.parseForMacro(STRINGLIST, value: "hi") == namespace.parseStringList(["hi"]))

        #expect(namespace.parseForMacro(BOOLEAN, value: ["hi", "t h e r e"]) == namespace.parseString("hi t\\ h\\ e\\ r\\ e"))
        #expect(namespace.parseForMacro(STRING, value: ["hi", "t h e r e"]) == namespace.parseString("hi t\\ h\\ e\\ r\\ e"))
        #expect(namespace.parseForMacro(STRINGLIST, value: ["hi", "t h e r e"]) == namespace.parseStringList(["hi", "t h e r e"]))

        #expect(namespace.parseForMacro(STRING, value: .plString("hi")) == namespace.parseString("hi"))
        #expect(namespace.parseForMacro(STRING, value: .plArray([.plString("hi"), .plString("t h e r e")])) == namespace.parseString("hi t\\ h\\ e\\ r\\ e"))

        #expect(namespace.parseForMacro(STRINGLIST, value: .plString("hi")) == namespace.parseStringList("hi"))
        #expect(namespace.parseForMacro(STRINGLIST, value: .plArray([.plString("hi"), .plString("t h e r e")])) == namespace.parseStringList(["hi", "t h e r e"]))
    }

    @Test
    func parseTable() throws {
        let namespace = MacroNamespace(parent: nil)
        let tableData: [String: PropertyListItem] = ["CUSTOM_SETTING": .plString("foo value")]

        // user defined not allowed
        #expect(performing: {
            try namespace.parseTable(tableData, allowUserDefined: false)
        }, throws: { error in
            error as? MacroDeclarationError == .unknownMacroDeclarationType(name: "CUSTOM_SETTING")
        })

        // allow user defined
        _ = try namespace.parseTable(tableData, allowUserDefined: true)
        #expect(namespace.lookupMacroDeclaration("CUSTOM_SETTING")?.type == .userDefined)

        // attempt to overwrite user-defined type with known type
        let tableDataMismatched: [String: PropertyListItem] = ["USER_DEFINED_STRING": .plString("foo value")]
        _ = try namespace.parseTable(tableDataMismatched, allowUserDefined: true)
        #expect(performing: {
            try namespace.declareStringMacro("USER_DEFINED_STRING")
        }, throws: { error in
            error as? MacroDeclarationError == .conflictingMacroDeclarationType(type: .string, previousType: .userDefined, name: "USER_DEFINED_STRING")
        })

        // use associated types to type-map specific macros that would be otherwise user-defined (note these aren't actually treated as user-defined, so we'll set that to false)
        let associatedTypesForKeysMatching: [String: MacroType] = ["_DEFINED_STRING_SETTING": .string]
        let typedExternalStringData: [String: PropertyListItem] = ["BUILT_IN_DEFINED_STRING_SETTING": .plString("foo value")]
        _ = try namespace.parseTable(typedExternalStringData, allowUserDefined: false, associatedTypesForKeysMatching: associatedTypesForKeysMatching)
        let stringMacroDecl = try #require(namespace.lookupMacroDeclaration("BUILT_IN_DEFINED_STRING_SETTING") as? StringMacroDeclaration)
        #expect(stringMacroDecl.type == MacroType.string)
    }

    /// Tests that parsing a macro definition table is deterministic.
    @Test
    func parseTableWithConditions() throws {
        let namespace = MacroNamespace(parent: nil)

        // In a MacroValueAssignmentTable, the keys consist of the setting name only ("SETTING"), while
        // the values are MacroValueAssignments, which are a linked list of values consisting of the
        // condition parameter set and macro expression value. While the keys of the table are enumerated
        // deterministically during serialization, the creation of the MacroValueAssignment linked list
        // must also be deterministic from the input dictionary to ensure they are written deterministically
        // as well.
        let table = try namespace.parseTable([
            "SETTING[sdk=macosx*]": "value",
            "SETTING[sdk=iphoneos*]": "value",
            "SETTING[sdk=appletvos*]": "value",
            "SETTING[sdk=watchos*]": "value",
            "SETTING[sdk=driverkit*]": "value",
        ], allowUserDefined: true)

        #expect(table.dump() == """
            'SETTING' := [sdk=watchos*]'value' -> [sdk=macosx*]'value' -> [sdk=iphoneos*]'value' -> [sdk=driverkit*]'value' -> [sdk=appletvos*]'value' (type: userDefined)

            """)
    }
}
