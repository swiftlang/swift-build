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

import Testing
import SWBUtil
@_spi(Testing) import SWBCore
import SWBTestSupport
import SWBMacro

fileprivate final class MockMacroExpressionParserDelegate : MacroExpressionParserDelegate {
    func foundLiteralStringFragment(_ string: Input, parser: MacroExpressionParser) {}
    func foundStringFormOnlyLiteralStringFragment(_ string: MacroExpressionParserDelegate.Input, parser: MacroExpressionParser) {}
    func foundStartOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {}
    func foundStartOfMacroName(parser: MacroExpressionParser) {}
    func foundEndOfMacroName(wasBracketed: Bool, parser: MacroExpressionParser) {}
    func foundRetrievalOperator(_ operatorName: Input, parser: MacroExpressionParser) {}
    func foundStartOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {}
    func foundEndOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {}
    func foundEndOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {}
    func foundListElementSeparator(_ string: MacroExpressionParserDelegate.Input, parser: MacroExpressionParser) {}
    func handleDiagnostic(_ diagnostic: MacroExpressionDiagnostic, parser: MacroExpressionParser) {}
}

@Suite(.performance)
fileprivate struct MacroExpressionParsingPerfTests: CoreBasedTests, PerfTests {
    private func runStringParsingTest(_ string: String, iterations: Int) async {
        await measure {
            for _ in 1...iterations {
                let delegate = MockMacroExpressionParserDelegate()
                let parser = MacroExpressionParser(string: string, delegate: delegate)
                parser.parseAsString()
            }
        }
    }

    @Test
    func parsingOfEmptyStrings_X10000() async {
        await runStringParsingTest("", iterations: 10000)
    }

    @Test
    func parsingOfShortLiteralStrings_X10000() async {
        await runStringParsingTest("A short string.", iterations: 10000)
    }

    @Test
    func parsingOfLongLiteralStrings_X10000() async {
        await runStringParsingTest("A long (or at least somewhat long, or perhaps maybe even a little longer) string without any particularly interesting characters (other than, perhaps, parentheses) in it.", iterations: 10000)
    }

    @Test
    func parsingOfSimpleMacroExpressions_X10000() async {
        await runStringParsingTest("$(X)$(Y)$(Z)$($(X)$(Y)$(Z))", iterations: 10000)
    }

    @Test
    func parsingAllSpecMacrosPerf() async throws {
        var stringsToParse = Array<String>()

        // First initialize the core, which includes loading all specs.
        let core = try await Self.makeCore()

        // Build up a list of all the specs we're interested in; here we don't care about domains, etc.
        var propertyDomainSpecs = Array<PropertyDomainSpec>()
        for domainRegistry in core.specRegistry.proxiesByDomain.values {
            for specProxy in domainRegistry.proxiesByIdentifier.values {
                if let spec = specProxy.load(core.specRegistry) as? PropertyDomainSpec {
                    propertyDomainSpecs.append(spec)
                }
            }
        }

        // Create a function to make a parseable string from a command line template specifier.  There are various ways of specifying the command line fragment, but they all resolve down to parsable strings.  We still need to discuss how exactly the command lines will be generated (whether through more general-purpose expressions like this, or through special cases) but in any case this is useful for performance measurement.
        func MakeParseableStringsFromCommandLineTemplateSpec (_ spec: BuildOptionValue.CommandLineTemplateSpecifier) -> [String] {
            switch spec {
            case .empty:               return []
            case .literal:             return ["$(value)"]
            case .args(let exprs):     return [exprs.stringRep]
            case .flag(let str):       return [str.stringRep, "$(value)"]
            case .prefixFlag(let str): return [str.stringRep + "$(value)"]
            }
        }

        // Now go through each property domain spec and extract all the strings to parse as macro expressions.
        for spec in propertyDomainSpecs {
            for buildOptions in spec.buildOptions {
                if let template = buildOptions.emptyValueDefn?.commandLineTemplate {
                    stringsToParse += MakeParseableStringsFromCommandLineTemplateSpec(template)
                }
                if let template = buildOptions.otherValueDefn?.commandLineTemplate {
                    stringsToParse += MakeParseableStringsFromCommandLineTemplateSpec(template)
                }
                if let values = buildOptions.valueDefns?.values {
                    for value in values {
                        if let template = value.commandLineTemplate {
                            stringsToParse += MakeParseableStringsFromCommandLineTemplateSpec(template)
                        }
                    }
                }
            }
        }

        let stringsToParseCopy = stringsToParse

        // Finally, parse the strings.
        await measure {
            final class MockDelegate : MacroExpressionParserDelegate {
                func foundLiteralStringFragment(_ string: Input, parser: MacroExpressionParser) {
                }

                func foundStringFormOnlyLiteralStringFragment(_ string: Input, parser: MacroExpressionParser) {
                }

                func foundStartOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {
                }

                func foundStartOfMacroName(parser: MacroExpressionParser) {
                }

                func foundEndOfMacroName(wasBracketed: Bool, parser: MacroExpressionParser) {
                }

                func foundRetrievalOperator(_ operatorName: Input, parser: MacroExpressionParser) {
                }

                func foundStartOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {
                }

                func foundEndOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {
                }

                func foundEndOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {
                }

                func foundListElementSeparator(_ string: Input, parser: MacroExpressionParser) {
                }

                func handleDiagnostic(_ diagnostic: MacroExpressionDiagnostic, parser: MacroExpressionParser) {
                }
            }
            for str in stringsToParseCopy {
                let delegate = MockDelegate()
                let parser = MacroExpressionParser(string: str, delegate: delegate)
                parser.parseAsString()
            }
        }
    }
}
