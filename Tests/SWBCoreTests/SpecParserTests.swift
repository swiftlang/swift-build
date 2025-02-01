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
@_spi(Testing) import SWBCore

fileprivate final class MockSpecType: SpecType {
    static let typeName = "Mock"
    static let subregistryName = "Mock"
    static let defaultClassType: (any SpecType.Type)? = nil

    static func parseSpec(_ delegate: any SpecParserDelegate, _ proxy: SpecProxy, _ basedOnSpec: Spec?) -> Spec {
        preconditionFailure("should not be used")
    }
}

@Suite fileprivate struct SpecParserTests {
    final class TestDataDelegate : SpecParserDelegate {
        class MockSpecRegistryDelegate : SpecRegistryDelegate {
            private let _diagnosticsEngine: DiagnosticsEngine

            init(_ diagnosticsEngine: DiagnosticsEngine) {
                self._diagnosticsEngine = diagnosticsEngine
            }

            var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                return .init(_diagnosticsEngine)
            }
        }
        let specRegistry: SpecRegistry

        var internalMacroNamespace = MacroNamespace(debugDescription: "internal")

        private let _diagnosticsEngine = DiagnosticsEngine()

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            return .init(_diagnosticsEngine)
        }

        func groupingStrategy(name: String, specIdentifier: String) -> (any SWBCore.InputFileGroupingStrategy)? {
            specRegistry.inputFileGroupingStrategyFactories[name]?.makeStrategy(specIdentifier: specIdentifier)
        }

        var warnings: [String] {
            return _diagnosticsEngine.diagnostics.compactMap {
                if case .warning = $0.behavior {
                    return $0.data.description
                }
                return nil
            }
        }

        var errors: [String] {
            return _diagnosticsEngine.diagnostics.compactMap {
                if case .error = $0.behavior {
                    return $0.data.description
                }
                return nil
            }
        }

        init() async {
            specRegistry = await SpecRegistry(PluginManager(skipLoadingPluginIdentifiers: []), MockSpecRegistryDelegate(_diagnosticsEngine), [])
        }
    }

    /// Helper function for testing the parser, which takes an input dictionary and a block to execute with a configured parser, and returns the result of the block along with any parser warnings and errors.
    private func parserForTestData<T>(_ data: [String: PropertyListItem], body: (SpecParser) -> T) async -> (T, [String], [String]) {
        // Create a mock proxy.
        let proxy = SpecProxy(identifier: "", domain: "", path: Path(""), type: MockSpecType.self, classType: nil, basedOn: nil, data: data, localizedStrings: nil)

        // Create a parser.
        let delegate = await TestDataDelegate()
        let parser = SpecParser(delegate, proxy)

        let result = body(parser)

        // Run the parser completion code.
        parser.complete()

        // Return the parsed spec and any warnings or errors.
        return (result, delegate.warnings, delegate.errors)
    }

    @Test
    func boolType() async {
        let data: [String: PropertyListItem] = [
            "False0": "no", "False1": "No", "False2": "NO", "False3": "0",
            "True0": "yes", "True1": "Yes", "True2": "YES", "True3": "1",
            "Other0": "BOGUS", "Other1": ["x"]
        ]
        let (_,warnings,errors) = await parserForTestData(data) { parser in
            #expect(!parser.parseRequiredBool("False0"))
            #expect(!parser.parseRequiredBool("False1"))
            #expect(!parser.parseRequiredBool("False2"))
            #expect(!parser.parseRequiredBool("False3"))
            #expect(parser.parseRequiredBool("True0"))
            #expect(parser.parseRequiredBool("True1"))
            #expect(parser.parseRequiredBool("True2"))
            #expect(parser.parseRequiredBool("True3"))
            #expect(!parser.parseRequiredBool("Other0"))
            #expect(!parser.parseRequiredBool("Missing0"))
            #expect(parser.parseBool("Missing1") == nil)
            #expect(parser.parseBool("Other1") == nil)
        }
        #expect(warnings == [])
        #expect(errors.count == 3)
        XCTAssertMatch(errors[0], .prefix("invalid value:"))
        XCTAssertMatch(errors[1], .prefix("missing required value"))
        XCTAssertMatch(errors[2], .prefix("unexpected item"))
    }

    @Test
    func stringType() async {
        let data: [String: PropertyListItem] = [
            "A": "aValue",
            "B": "bValue",
            "C": ["x"],
        ]
        let (_,warnings,errors) = await parserForTestData(data) { parser in
            #expect(parser.parseString("A")! == "aValue")
            #expect(parser.parseRequiredString("B") == "bValue")
            #expect(parser.parseString("C") == nil)
            #expect(parser.parseString("Missing0") == nil)
            #expect(parser.parseRequiredString("Missing1") == "<invalid>")
        }
        #expect(warnings == [])
        #expect(errors.count == 2)
        XCTAssertMatch(errors[0], .prefix("unexpected item"))
        XCTAssertMatch(errors[1], .prefix("missing required value"))
    }

    @Test
    func stringList() async {
        let data: [String: PropertyListItem] = [
            "A": ["a", "b", "c"],
            "B": ["a", ["b":"c"], "d"],
            "C": "x"
        ]
        let (_,warnings,errors) = await parserForTestData(data) { parser in
            #expect(parser.parseStringList("A")! == ["a", "b", "c"])
            #expect(parser.parseRequiredStringList("B") == ["a", "<invalid>", "d"])
            #expect(parser.parseStringList("C") == nil)
            #expect(parser.parseStringList("Missing0") == nil)
            #expect(parser.parseRequiredStringList("Missing1") == ["<invalid>"])
        }
        #expect(warnings == [])
        #expect(errors.count == 3)
        XCTAssertMatch(errors[0], .prefix("unexpected array member"))
        XCTAssertMatch(errors[1], .prefix("unexpected item"))
        XCTAssertMatch(errors[2], .prefix("missing required value"))
    }

    @Test
    func commandLineString() async {
        let data: [String: PropertyListItem] = [
            "A": ["a", "b", "c"],
            "B": "a b c",
            "C": ["bad": "bad"],
        ]
        let (_,warnings,errors) = await parserForTestData(data) { parser in
            #expect(parser.parseCommandLineString("A")! == ["a", "b", "c"])
            #expect(parser.parseCommandLineString("B")! == ["a", "b", "c"])
            #expect(parser.parseCommandLineString("C") == nil)
            #expect(parser.parseCommandLineString("D") == nil)
        }
        #expect(warnings == [])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("unexpected item"))
        XCTAssertMatch(errors[0], .suffix("while parsing key 'C' (expected string or string list)"))
    }

    @Test
    func extraKeys() async {
        let data: [String: PropertyListItem] = [ "A": "a", "B": "b" ]
        let (_,warnings,errors) = await parserForTestData(data) { parser in
            #expect(parser.parseString("A") == "a")
        }
        #expect(warnings == ["unused key 'B'"])
        #expect(errors == [])
    }

    @Test
    func buildSettings() async {
        let data: [String: PropertyListItem] = [
            "A": [
                "NAME1": "VALUE",
                "NAME2": "${OK}",
                "NAME3": ["A", "B"] as PropertyListItem,
                "NAME4": "base",
                "NAME4[sdk=macos*]": "macos",
                "NAME4[sdk=iphoneos*][arch=arm7]": "iphoneos arm7",
            ] as PropertyListItem,
            "BAD0": ["NAME2": "$(BAD"] as PropertyListItem,
            "BAD1": ["BAD": ["BAD":"BAD"]] as PropertyListItem,
            "BAD2": ["BAD": ["OK", ["BAD"]] as PropertyListItem] as PropertyListItem,
            "BAD3": ["BAD": ["$(BAD"]] as PropertyListItem,
            "BAD4": ["BAD[sdk=": "bad"] as PropertyListItem
        ]
        let (_,warnings,errors) = await parserForTestData(data) { parser in
            let settings = parser.parseRequiredBuildSettings("A")
            let NAME1 = settings.namespace.lookupMacroDeclaration("NAME1")!
            #expect(settings.lookupMacro(NAME1)?.expression.stringRep == "VALUE")
            let NAME3 = settings.namespace.lookupMacroDeclaration("NAME3")!
            #expect(settings.lookupMacro(NAME3)?.expression.stringRep == "A B")
            let NAME4 = settings.namespace.lookupMacroDeclaration("NAME4")!
            let macro4 = settings.lookupMacro(NAME4)
            #expect(macro4?.expression.stringRep == "macos")
            #expect(macro4?.conditions?.conditions == [
                MacroCondition(parameter: settings.namespace.lookupConditionParameter("sdk")!, valuePattern: "macos*"),
            ])
            #expect(macro4?.next?.expression.stringRep == "iphoneos arm7")
            #expect(macro4?.next?.conditions?.conditions == [
                MacroCondition(parameter: settings.namespace.lookupConditionParameter("sdk")!, valuePattern: "iphoneos*"),
                MacroCondition(parameter: settings.namespace.lookupConditionParameter("arch")!, valuePattern: "arm7"),
            ])
            #expect(macro4?.next?.next?.expression.stringRep == "base")
            #expect(macro4?.next?.next?.conditions?.conditions == nil)

            #expect(parser.parseRequiredBuildSettings("BAD0").valueAssignments.count == 0)
            #expect(parser.parseRequiredBuildSettings("BAD1").valueAssignments.count == 0)
            #expect(parser.parseRequiredBuildSettings("BAD2").valueAssignments.count == 0)
            #expect(parser.parseRequiredBuildSettings("BAD3").valueAssignments.count == 0)
            #expect(parser.parseRequiredBuildSettings("BAD4").valueAssignments.count == 0)
            #expect(parser.parseRequiredBuildSettings("MISSING").valueAssignments.count == 0)
        }
        #expect(warnings == [])
        #expect(errors.count == 7)
        XCTAssertMatch(errors, [
            .prefix("macro parsing error for build setting 'NAME2': warning:DeprecatedMacroRefSyntax"),
            .prefix("macro parsing error for build setting 'NAME2': error:UnterminatedMacroSubexpression"),
            "inconsistentMacroDefinition(name: \"BAD\", type: SWBMacro.MacroType.userDefined, value: PLDict<[\"BAD\": \"BAD\"]>)",
            "unexpected value for build setting \'BAD\' while parsing 'BAD2'",
            .prefix("macro parsing error for build setting 'BAD'"),
            "invalid setting name: 'BAD[sdk='",
            "missing required value for key: 'MISSING'"
        ])
    }

    /// Arrays of dictionaries are a common idiom in .xcspec files. Usually the dictionaries in question represent objects. It’s common to allow single-element arrays to instead be represented as just the single unwrapped element. Similarly, it’s common to allow a dictionary to be represented by just a flat value, which is treated the same as a dictionary with just the value for the "signature" key.  Examples include the build options array, the values array for each build option, the input-file-types array, etc.
    @Test
    func arraysOfDictionaries() async {
        let data: [String: PropertyListItem] = [
            "A": [
                ["a": "1"],
                ["b": "2"],
                ["c": "3", "d": "4", "e": "5"],
            ],
            "B": ["b": "3"],
            "C": "c",
            "D": [
                "d",
                "e",
            ],
            "E": [
                ["1", "2", "3"],
            ],
        ]
        // Create a test parser and do some test lookups.
        let (_,warnings,errors) = await parserForTestData(data) { parser in
            // Check that we’re able to deal with various wrapped and unwrapped combinations.
            #expect(parser.parseArrayOfDicts("A"){ (dict: PropertyListItem) -> (String?) in
                guard case .plDict(let dict) = dict else { return nil }
                return dict.keys.sorted(by: <).reduce(""){ "\($0!)\($1)," }
            }! == ["a,", "b,", "c,d,e,"])
            #expect(parser.parseArrayOfDicts("B", allowUnarrayedElement: true){ (dict: PropertyListItem) -> (String?) in
                guard case .plDict(let dict) = dict else { return nil }
                return dict.keys.sorted(by: <).reduce(""){ "\($0!)\($1)," }
            }! == ["b,"])
            #expect(parser.parseArrayOfDicts("C", allowUnarrayedElement: true, impliedElementKey: "key"){ (dict: PropertyListItem) -> (String?) in
                guard case .plDict(let dict) = dict else { return nil }
                return dict.keys.sorted(by: <).reduce(""){ "\($0!)\($1)," }
            }! == ["key,"])
            #expect(parser.parseArrayOfDicts("D", allowUnarrayedElement: true, impliedElementKey: "key"){ (dict: PropertyListItem) -> (String?) in
                guard case .plDict(let dict) = dict else { return nil }
                return dict.keys.sorted(by: <).reduce(""){ "\($0!)\($1)," }
            }! == ["key,", "key,"])

            // Check the looking up missing keys returns nil.
            #expect(parser.parseArrayOfDicts("MISSING") { return $0.description } == nil)

            // Check that trying to look up unwrapped values without enabling them returns an empty array.
            #expect(parser.parseArrayOfDicts("E"){ return $0.description }! == [])
        }
        #expect(warnings == [])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("unexpected item"))
    }
}
