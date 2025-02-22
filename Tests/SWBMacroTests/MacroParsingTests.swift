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

/// Unit tests of macro parsing (separately from any construction of internal data structures).  There are two main parts to this:  string parsing and string list parsing.  In both cases, the input is a string, but in the former case, whitespace, quotes, and escape characters do not have special meaning.  In the latter case, sequences of unquoted unescaped whitespace are treated as list element separators, and quotes and escape characters are interpreted as well.  There are two main helper functions for testing string and string list parsing — each take an input string and an array of enumeration values representing the "call log" of delegate calls invoked during the parsing.
@Suite fileprivate struct MacroStringParsingTests {
    @Test
    func macroStringExpressionParsing_SimpleLiterals() {
        TestMacroStringParsing("", [
            .literalChars(""),
        ])

        // Simple characters just yield themselves.
        TestMacroStringParsing("X", [
            .literalChars("X"),
        ])

        // Arbitrary Unicode is fine.
        TestMacroStringParsing("😀", [
            .literalChars("😀"),
        ])

        // Whitespace and punctuation are not special.
        TestMacroStringParsing(" ", [
            .literalChars(" "),
        ])

        TestMacroStringParsing("\'", [
            .literalChars("\'"),
        ])

        TestMacroStringParsing("\\", [
            .literalChars("\\"),
        ])
    }


    @Test
    func macroStringExpressionParsing_SimpleSubstitutions() {
        TestMacroStringParsing("$(X)", [
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ])

        TestMacroStringParsing("$($(X))", [
            .startStringSubstSubexpr,
            .startMacroName,
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ])

        // But we also accept some alternate syntaxes (we'd like to start deprecating these).
        TestMacroStringParsing("$X", [
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: false),
            .endStringSubstSubexpr,
        ])

        TestMacroStringParsing("${X}", [
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ],
                               expectedDiagnostics: [
                                (level: MacroExpressionDiagnostic.Level.warning, kind: MacroExpressionDiagnostic.Kind.deprecatedMacroRefSyntax, start: 0, end: 2),
                               ])

        TestMacroStringParsing("$[X]", [
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ],
                               expectedDiagnostics: [
                                (level: MacroExpressionDiagnostic.Level.warning, kind: MacroExpressionDiagnostic.Kind.deprecatedMacroRefSyntax, start: 0, end: 2),
                               ])
    }


    @Test
    func macroStringExpressionParsing_InterestingCases() {
        TestMacroStringParsing("$", [
            .startStringSubstSubexpr,
            .literalChars("$"),
            .endStringSubstSubexpr,
        ],
                               expectedDiagnostics: [
                                (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.trailingDollarSign, start: 0, end: 1),
                               ])

        //  An even number of consecutive "$" characters does not yield a trailing-dollar-sign error — each pair becomes a single "$" sign, leaving none.
        TestMacroStringParsing("$$", [
            .startStringSubstSubexpr,
            .literalChars("$"),
            .endStringSubstSubexpr,
        ])

        TestMacroStringParsing("$$$", [
            .startStringSubstSubexpr,
            .literalChars("$"),
            .endStringSubstSubexpr,
            .startStringSubstSubexpr,
            .literalChars("$"),
            .endStringSubstSubexpr,
        ],
                               expectedDiagnostics: [
                                (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.trailingDollarSign, start: 2, end: 3),
                               ])

        TestMacroStringParsing("$$$$", [
            .startStringSubstSubexpr,
            .literalChars("$"),
            .endStringSubstSubexpr,
            .startStringSubstSubexpr,
            .literalChars("$"),
            .endStringSubstSubexpr
        ])

        TestMacroStringParsing("$()", [
            .startStringSubstSubexpr,
            .startMacroName,
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ],
                               expectedDiagnostics: [
                                (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.missingMacroName, start: 2, end: 2),
                               ])

        TestMacroStringParsing("$X_$(Y)", [
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X_"),
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("Y"),
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
            .endMacroName(wasBracketed: false),
            .endStringSubstSubexpr,
        ])
    }


    @Test
    func macroStringExpressionParsing_Operators() {
        TestMacroStringParsing("$(X:x:y=$(A:r:s:t):z)", [
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .retrievalOp("x"),
            .startReplacementOp("y"),
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("A"),
            .endMacroName(wasBracketed: true),
            .retrievalOp("r"),
            .retrievalOp("s"),
            .retrievalOp("t"),
            .endStringSubstSubexpr,
            .endReplacementOp("y"),
            .retrievalOp("z"),
            .endStringSubstSubexpr,
        ])

        TestMacroStringParsing("$(X:${X})", [
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ],
                               expectedDiagnostics: [
                                (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.invalidOperatorCharacter, start: 4, end: 5),
                               ])
    }
}

@Suite fileprivate struct MacroStringListParsingTests {
    @Test
    func macroStringListExpressionParsing_Empty() {
        TestMacroStringListParsing("", [
            // nothing
        ])
    }


    @Test
    func macroStringListExpressionParsing_WhitespaceOnly() {
        TestMacroStringListParsing(" ", [
            .literalStringFormOnlyChars(" "),
        ])

        TestMacroStringListParsing(" \t\r \n \t", [
            .literalStringFormOnlyChars(" \t\r \n \t"),
        ])

        TestMacroStringListParsing("\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n", [
            .literalStringFormOnlyChars("\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"),
        ])
    }


    @Test
    func macroStringListExpressionParsing_SimpleTests() {
        TestMacroStringListParsing("A", [
            .literalChars("A"),
        ])

        TestMacroStringListParsing("A B", [
            .literalChars("A"),
            .listElementSeparator(" "),
            .literalChars("B"),
        ])
    }


    @Test
    func macroStringListExpressionParsing_Quoting() {
        TestMacroStringListParsing("\"\"", [
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
        ])

        TestMacroStringListParsing("\"\" \"\"", [
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
            .listElementSeparator(" "),
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
        ])

        TestMacroStringListParsing("   \"\" \"\"  \n  ", [
            .literalStringFormOnlyChars("   "),
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
            .listElementSeparator(" "),
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
            .literalStringFormOnlyChars("  \n  "),
        ])

        TestMacroStringListParsing("   \"\" \"\"  \n  \\", [
            .literalStringFormOnlyChars("   "),
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
            .listElementSeparator(" "),
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
            .listElementSeparator("  \n  "),
            .literalStringFormOnlyChars("\\"),
            .literalChars("\\"),
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.trailingEscapeCharacter, start: 13, end: 14),
                                   ])

        TestMacroStringListParsing("   \"\" \"\"  \n  $", [
            .literalStringFormOnlyChars("   "),
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
            .listElementSeparator(" "),
            .literalStringFormOnlyChars("\""),
            .literalChars(""),
            .literalStringFormOnlyChars("\""),
            .listElementSeparator("  \n  "),
            .startSubstSubexpr,
            .literalChars("$"),
            .endSubstSubexpr,
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.trailingDollarSign, start: 13, end: 14),
                                   ])

        TestMacroStringListParsing("\"", [
            .literalStringFormOnlyChars("\""),
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedQuotation, start: 1, end: 1),
                                   ])

        TestMacroStringListParsing("\'", [
            .literalStringFormOnlyChars("\'"),
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedQuotation, start: 1, end: 1),
                                   ])

        TestMacroStringListParsing("   $(", [
            .literalStringFormOnlyChars("   "),
            .startSubstSubexpr,
            .startMacroName,
            .endMacroName(wasBracketed: true),
            .endSubstSubexpr,
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedMacroSubexpression, start: 3, end: 5),
                                   ])

        TestMacroStringListParsing("   \"$(", [
            .literalStringFormOnlyChars("   "),
            .literalStringFormOnlyChars("\""),
            .startStringSubstSubexpr,
            .startMacroName,
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedMacroSubexpression, start: 4, end: 6),
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedQuotation, start: 6, end: 6),
                                   ])

        TestMacroStringListParsing("\n\n\n$(X", [
            .literalStringFormOnlyChars("\n\n\n"),
            .startSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .endSubstSubexpr,
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedMacroSubexpression, start: 3, end: 6),
                                   ])

        TestMacroStringListParsing("\n\n\n'$(X", [
            .literalStringFormOnlyChars("\n\n\n"),
            .literalStringFormOnlyChars("'"),
            .startStringSubstSubexpr,
            .startMacroName,
            .literalChars("X"),
            .endMacroName(wasBracketed: true),
            .endStringSubstSubexpr,
        ],
                                   expectedDiagnostics: [
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedMacroSubexpression, start: 4, end: 7),
                                    (level: MacroExpressionDiagnostic.Level.error, kind: MacroExpressionDiagnostic.Kind.unterminatedQuotation, start: 7, end: 7),
                                   ])
        TestMacroStringListParsing("\"\'\'\"", [
            .literalStringFormOnlyChars("\""),
            .literalChars("\'\'"),
            .literalStringFormOnlyChars("\""),
        ])

        TestMacroStringListParsing("\'\'", [
            .literalStringFormOnlyChars("\'"),
            .literalChars(""),
            .literalStringFormOnlyChars("\'"),
        ])

        TestMacroStringListParsing("\'\"\"\'", [
            .literalStringFormOnlyChars("\'"),
            .literalChars("\"\""),
            .literalStringFormOnlyChars("\'"),
        ])

        TestMacroStringListParsing("\" \"", [
            .literalStringFormOnlyChars("\""),
            .literalChars(" "),
            .literalStringFormOnlyChars("\""),
        ])

        TestMacroStringListParsing("\' \'", [
            .literalStringFormOnlyChars("\'"),
            .literalChars(" "),
            .literalStringFormOnlyChars("\'"),
        ])

        TestMacroStringListParsing("\\ ", [
            .literalStringFormOnlyChars("\\"),
            .literalChars(" "),
        ])
    }
}

@Suite fileprivate struct MacroNameParsingTests {
    @Test
    func macroNameParsing() {
        var macroName: String?
        var macroCond: [(param: String, pattern: String)]?

        (macroName, macroCond) = MacroConfigFileParser.parseMacroNameAndConditionSet("")
        #expect(macroName == nil)
        #expect(macroCond == nil)

        (macroName, macroCond) = MacroConfigFileParser.parseMacroNameAndConditionSet("X")
        #expect(macroName == "X")
        #expect(macroCond == nil)

        (macroName, macroCond) = MacroConfigFileParser.parseMacroNameAndConditionSet("X[arch=*]")
        #expect(macroName == "X")
        #expect(macroCond! == [(param: "arch", pattern: "*")])

        (macroName, macroCond) = MacroConfigFileParser.parseMacroNameAndConditionSet("ABC123[config=Debug][arch=*][sdk=abc]")
        #expect(macroName == "ABC123")
        #expect(macroCond! == [(param: "config", pattern: "Debug"), (param: "arch", pattern: "*"), (param: "sdk", pattern: "abc")])
    }
}


/// Sample Macro Config Files
fileprivate let testFileData = [
    "EnsureOldSingleLineBehavior.xcconfig": """
        A = B
            C
        D = E
        """,
    "Common.xcconfig":
        "// Common Settings\n" +
    "OTHER_CFLAGS = bla bla\n",
    "Debug.xcconfig":
        "// Debug Settings\n" +
    "#include \"Common.xcconfig\"\n" +
    "OTHER_CFLAGS[arch=i386] = $(inherited) more\n",
    "Release.xcconfig":
        "// Release Settings\n" +
    "OTHER_CFLAGS[arch=z80] = $(inherited) 8-bit\n" +
    "OTHER_CFLAGS[arch=CMOS 65816] = $(inherited) 16-bit\n" +
    "OTHER_CFLAGS[arch=m68k] = $(inherited) 32-bit\n",
    "Multiline.xcconfig": """
        FEATURE_DEFINES_A = $(A) $(B) \\
        $(C)
        FEATURE_DEFINES_B = $(D) \\ // comment 1
        $(E) \\
        $(F); // note the trailing optional ';'
        FEATURE_DEFINES_C = \\
            $(G) \\
            \\ // comment 3
            $(H)
        FEATURE_DEFINES_D = \\ // comment 4
            $(I);
        """,
    "MultilineError1.xcconfig": """
        FEATURE_DEFINES_E = // comment 4
        $(I)
        """,

    "LineCntInsideDollarParen.xcconfig": """
        COMPOSE_ME = YES
        MY_VALUE_YES = "DOES THIS WORK?"
        MY_VALUE = $(MY_VALUE_\\
                                   $(COMPOSE_ME))
        """,

    // Non-terminating backslash is not treated as line-continuation symbol
    "NonterminalBackslash.xcconfig": """
        SINGLE_LINE = A \\ B \\ C \\ D
        """,

    // Backslash in conditions is not treated as line-continuation and emits diagnostic messages
    "BackslashInConditions.xcconfig": """
        VALUE[ \\
          sdk=iphoneos*, \\
          arch=arm64 \\
        ] = big spaces
        """,

    "BasicMultilineExampleA.xcconfig": """
        MY_VALUE = -f\\
               -g      \\
        -h
        """,
    "BasicMultilineExampleB.xcconfig": """
        MY_VALUE = -f \\
        -g \\
        -h
        """,
    "BasicMultilineExampleCanonical.xcconfig": """
        MY_VALUE = -f -g -h
        """,

    "TerminatingBackslashInsideStringLiteral.xcconfig": """
        MY_STRING = "Now this is a story \\
               all about how \\
           my life got flipped, turned upside down"
        """,

    "TerminatingBackslashInsideEmptyLine.xcconfig": """
        MY_STRING = "hello \\
          \\
          I really wanted a new line above, and apparently the \\
          works in strings."
        """,

    "BackslashInBothConditionAndRHS.xcconfig": """
        MY_VALUE[ \\
            sdk = iphone* \\
            config = Debug \\
        ] = -DEBUG \\
                -MOREDEBUGZ
        """,

    "Okay.xcconfig": "FEATURE_DEFINES_E = $(I) \\ // comment 4",
    "All.xcconfig":
        "// A sample comment for testing's sake\n" +
    "#include \"Common.xcconfig\"\n" +
    "#include \"Debug.xcconfig\"\n" +
    "#include \"Release.xcconfig\"\n",
]

@Suite fileprivate struct MacroConfigFileParsingTests {
    @Test
    func macroSimpleConfigFileParsing() {
        MacroConfigFileParser(byteString: "", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "//\nA[b=c]=D // bla", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "//\nA[b=  c  ]=    D // bla", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "A123[b=c][b=c][b=c][b=c][b=c][b=c][b=c][b=c][b=c][b=c]=", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "1", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "=", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a[=", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a[", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "[", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "[]", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a[]", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a[=]", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a[a=", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "##", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#//", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#include", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#include\n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#include \"", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#include \"file\"", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#include \"file\"//bla", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#include \"file\" \t", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "#include \"file\" x", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "\n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "\r", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "\r\n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "\r\n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "\u{2028}", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "\u{2029}", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "\n\r\r\n\r\u{2028}\u{2029}", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a=b", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a=[\"b\", \"c\"]\n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "a=b\\\nc\nd=e\n", path: Path(""), delegate: nil).parse()

        MacroConfigFileParser(byteString: "a=b\\\nc\nd=e\n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "A = $(....)", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "A = $(....)\n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....)  ", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....)  \n", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....)\\", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....) \\", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....)\\ ", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....) \\ ", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....)// comment", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(....) // comment", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(...)\\// comment", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(...)\\ // comment", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(...) \\ // comment", path: Path(""), delegate: nil).parse()
        MacroConfigFileParser(byteString: "$(...) \\// comment", path: Path(""), delegate: nil).parse()

        // More targeted tests.
        TestMacroConfigFileParser("ABC123[cpu=z80][sdk=svi318] = $(inherited)  ;  ",
                                  expectedAssignments: [
                                    (macro: "ABC123", conditions: [(param: "cpu", pattern: "z80"), (param: "sdk", pattern: "svi318")], value: "$(inherited)"),
                                  ],
                                  expectedDiagnostics: [
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("A=\nA",
                                  expectedAssignments: [
                                    (macro: "A", conditions: [], value: ""),
                                  ],
                                  expectedDiagnostics: [
                                    (level: .error, kind: .missingEqualsInAssignment, line: 2),
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("",
                                  expectedAssignments: [
                                  ],
                                  expectedDiagnostics: [
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("\n\r",
                                  expectedAssignments: [
                                  ],
                                  expectedDiagnostics: [
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("\r\r\r\r\r\r\r\r\r\r\r//",
                                  expectedAssignments: [
                                  ],
                                  expectedDiagnostics: [
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("\r\r\r\r\r\r\r\r\r\r\r\\",
                                  expectedAssignments: [
                                  ],
                                  expectedDiagnostics: [
                                    (level: .error, kind: .unexpectedCharacter, line: 12),
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("#include \"Missing.xcconfig\"",
                                  expectedAssignments: [
                                  ],
                                  expectedDiagnostics: [
                                    (level: .error, kind: .missingIncludedFile, line: 1),
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("#include? \"Missing.xcconfig\"",
                                  expectedAssignments: [
                                  ],
                                  expectedDiagnostics: [
                                  ],
                                  expectedIncludeDirectivesCount: 0
        )
        TestMacroConfigFileParser("#include \"All.xcconfig\"",
                                  expectedAssignments: [(macro: "OTHER_CFLAGS", conditions: [], value: "bla bla"), (macro: "OTHER_CFLAGS", conditions: [], value: "bla bla"), (macro: "OTHER_CFLAGS", conditions: [(param: "arch", pattern: "i386")], value: "$(inherited) more"), (macro: "OTHER_CFLAGS", conditions: [(param: "arch", pattern: "z80")], value: "$(inherited) 8-bit"), (macro: "OTHER_CFLAGS", conditions: [(param: "arch", pattern: "CMOS 65816")], value: "$(inherited) 16-bit"), (macro: "OTHER_CFLAGS", conditions: [(param: "arch", pattern: "m68k")], value: "$(inherited) 32-bit")],
                                  expectedDiagnostics: [
                                  ],
                                  expectedIncludeDirectivesCount: 5
        )
    }

    @Test
    func ensureOldSingleLineBehavior() {
        TestMacroConfigFileParser("#include \"EnsureOldSingleLineBehavior.xcconfig\"",
                                  expectedAssignments: [(macro: "A", conditions: [], value: "B"), (macro: "D", conditions: [], value: "E")],
                                  expectedDiagnostics: [(level: MacroConfigFileDiagnostic.Level.error, kind: MacroConfigFileDiagnostic.Kind.missingEqualsInAssignment, line: 2)],
                                  expectedIncludeDirectivesCount: 1
        )
    }

    @Test
    func multiline() {
        TestMacroConfigFileParser("#include \"Multiline.xcconfig\"",
                                  expectedAssignments: [
                                    (macro: "FEATURE_DEFINES_A", conditions: [], value: "$(A) $(B) $(C)"),
                                    (macro: "FEATURE_DEFINES_B", conditions: [], value: "$(D) $(E) $(F)"),
                                    (macro: "FEATURE_DEFINES_C", conditions: [], value: "$(G) $(H)"),
                                    (macro: "FEATURE_DEFINES_D", conditions: [], value: "$(I)")
                                  ],
                                  expectedDiagnostics: [],
                                  expectedIncludeDirectivesCount: 1
        )

        TestMacroConfigFileParser("#include \"MultilineError1.xcconfig\"",
                                  expectedAssignments: [(macro: "FEATURE_DEFINES_E", conditions: [], value: "")],
                                  expectedDiagnostics: [(level: MacroConfigFileDiagnostic.Level.error, kind: MacroConfigFileDiagnostic.Kind.unexpectedCharacter, line: 2)],
                                  expectedIncludeDirectivesCount: 1
        )
    }

    @Test
    func lineCntInsideDollarParen() {
        TestMacroConfigFileParser(
            "#include \"LineCntInsideDollarParen.xcconfig\"",
            expectedAssignments: [
                (macro: "COMPOSE_ME", conditions: [], value: "YES"),
                (macro: "MY_VALUE_YES", conditions: [], value: "\"DOES THIS WORK?\""),
                (macro: "MY_VALUE", conditions: [], value: "$(MY_VALUE_ $(COMPOSE_ME))")],
            expectedDiagnostics: [],
            expectedIncludeDirectivesCount: 1
        )
    }

    @Test
    func nonterminalBackslash() {
        TestMacroConfigFileParser(
            "#include \"NonterminalBackslash.xcconfig\"",
            expectedAssignments: [(macro: "SINGLE_LINE", conditions: [], value: "A \\ B \\ C \\ D")],
            expectedDiagnostics: [],
            expectedIncludeDirectivesCount: 1
        )
    }

    @Test
    func backslashInConditions() {
        TestMacroConfigFileParser(
            "#include \"BackslashInConditions.xcconfig\"",
            expectedAssignments: [(macro: "sdk", conditions: [], value: "iphoneos*, arch=arm64 ] = big spaces")],
            expectedDiagnostics:  [
                (level: MacroConfigFileDiagnostic.Level.error,
                 kind: MacroConfigFileDiagnostic.Kind.unexpectedCharacter,
                 line: 1)],
            expectedIncludeDirectivesCount: 1
        )
    }

    @Test
    func basicMultilineExample() {
        TestMacroConfigFileParser(
            "#include \"BasicMultilineExampleA.xcconfig\"",
            expectedAssignments: [(macro: "MY_VALUE", conditions: [], value: "-f -g -h")],
            expectedDiagnostics: [],
            expectedIncludeDirectivesCount: 1
        )

        TestMacroConfigFileParser(
            "#include \"BasicMultilineExampleB.xcconfig\"",
            expectedAssignments: [(macro: "MY_VALUE", conditions: [], value: "-f -g -h")],
            expectedDiagnostics: [],
            expectedIncludeDirectivesCount: 1
        )

        TestMacroConfigFileParser("#include \"BasicMultilineExampleCanonical.xcconfig\"",
                                  expectedAssignments: [(macro: "MY_VALUE", conditions: [], value: "-f -g -h")],
                                  expectedDiagnostics: [],
                                  expectedIncludeDirectivesCount: 1
        )
    }


    @Test
    func terminatingBackslashInsideStringLiteral() {
        TestMacroConfigFileParser(
            "#include \"TerminatingBackslashInsideStringLiteral.xcconfig\"",
            expectedAssignments: [
                (macro: "MY_STRING",
                 conditions: [],
                 value: "\"Now this is a story all about how my life got flipped, turned upside down\"")],
            expectedDiagnostics: [],
            expectedIncludeDirectivesCount: 1
        )
    }

    @Test
    func terminatingBackslashInsideEmptyLine() {
        TestMacroConfigFileParser(
            "#include \"TerminatingBackslashInsideEmptyLine.xcconfig\"",
            expectedAssignments: [
                (macro: "MY_STRING",
                 conditions: [],
                 value: "\"hello I really wanted a new line above, and apparently the works in strings.\"")],
            expectedDiagnostics: [],
            expectedIncludeDirectivesCount: 1
        )
    }


    @Test
    func backslashInBothConditionAndRHS() {
        TestMacroConfigFileParser("#include \"BackslashInBothConditionAndRHS.xcconfig\"",
                                  expectedAssignments:  [(macro: "sdk", conditions: [], value: "iphone* config = Debug ] = -DEBUG -MOREDEBUGZ")],
                                  expectedDiagnostics: [
                                    (level: MacroConfigFileDiagnostic.Level.error,
                                     kind: MacroConfigFileDiagnostic.Kind.unexpectedCharacter,
                                     line: 1)],
                                  expectedIncludeDirectivesCount: 1
        )
    }

    class ParserDelegate : MacroConfigFileParserDelegate {
        var diagnosticMessages = [String]()

        func foundPreprocessorInclusion(_ fileName: String, optional: Bool, parser: MacroConfigFileParser) -> MacroConfigFileParser? {
            return nil
        }
        func endPreprocessorInclusion() {
        }
        func foundMacroValueAssignment(_ macroName: String, conditions: [(param: String, pattern: String)], value: String, parser: MacroConfigFileParser) {
        }

        func handleDiagnostic(_ diagnostic: MacroConfigFileDiagnostic, parser: MacroConfigFileParser) {
            diagnosticMessages.append("\(parser.path.basename):\(diagnostic.lineNumber): \(diagnostic.message)")
        }
    }

    @Test
    func parseControlCharacters() throws {
        let delegate = ParserDelegate()
        MacroConfigFileParser(byteString: "// [-Wnullability-completeness-on-arrays] \t\t\t(on)  Warns about missing nullability annotations on array parameters.", path: Path(""), delegate: delegate).parse()
        #expect(delegate.diagnosticMessages == [String]())
    }
}

// We used typealiased tuples for simplicity and readability.
typealias ConditionInfo = (param: String, pattern: String)
typealias AssignmentInfo = (macro: String, conditions: [ConditionInfo], value: String)
typealias DiagnosticInfo = (level: MacroConfigFileDiagnostic.Level, kind: MacroConfigFileDiagnostic.Kind, line: Int)

private func TestMacroConfigFileParser(_ string: String, expectedAssignments: [AssignmentInfo], expectedDiagnostics: [DiagnosticInfo], expectedIncludeDirectivesCount: Int, sourceLocation: SourceLocation = #_sourceLocation) {

    /// We use a custom delegate to test that we’re getting the expected results, which for the sake of convenience are just kept in (name, conds:[(cond-param, cond-value)], value) tuples, i.e. conditions is an array of two-element tuples.
    class ConfigFileParserTestDelegate : MacroConfigFileParserDelegate {
        var assignments = Array<AssignmentInfo>()
        var diagnostics = Array<DiagnosticInfo>()

        var includeDirectivesCount = 0

        /// Invoked once for each #include directive.  Should create and return a newly configured MacroConfigFileParser object containing the contents to be included.  The `fileName` is guaranteed to never be empty when this method is called.  The `optional` flag set if the directive was marked as optional, i.e. if missing files should silently be skipped instead of causing errors.
        func foundPreprocessorInclusion(_ fileName: String, optional: Bool, parser: MacroConfigFileParser) -> MacroConfigFileParser? {
            // print("#include \"\(fileName)\"")
            guard let contents = testFileData[fileName] else {
                if !optional {
                    handleDiagnostic(MacroConfigFileDiagnostic(kind: .missingIncludedFile, level: .error, message: "unable to read included file", lineNumber: parser.lineNumber), parser: parser)
                }
                return nil
            }
            return MacroConfigFileParser(byteString: ByteString(encodingAsUTF8: contents), path: Path(fileName), delegate: self)
        }
        func endPreprocessorInclusion() {
            self.includeDirectivesCount += 1
        }
        func foundMacroValueAssignment(_ macroName: String, conditions: [(param: String, pattern: String)], value: String, parser: MacroConfigFileParser) {
            // print("\(parser.lineNumber): \(macroName)\(conditions.map({ "[\($0.param)=\($0.pattern)]" }).joinWithSeparator(""))=\(value)")
            assignments.append((macro: macroName, conditions: conditions, value: value))
        }
        func handleDiagnostic(_ diagnostic: MacroConfigFileDiagnostic, parser: MacroConfigFileParser) {
            // print("\(parser.lineNumber): \(diagnostic)")
            diagnostics.append((level: diagnostic.level, kind: diagnostic.kind, line: diagnostic.lineNumber))
        }
    }

    // Create a parser delegate of our special class that records the macro value assignments and diagnostics that it seems, so that we can then compare it against what’s expected.
    let delegate = ConfigFileParserTestDelegate()

    // Create a parser, and do the parse.
    let parser = MacroConfigFileParser(byteString: ByteString(encodingAsUTF8: string), path: Path("TestMacroConfigFileParser().xcconfig"), delegate: delegate)
    parser.parse()

    // Check the assignments that the delegate saw against the expected ones.
    #expect(delegate.assignments == expectedAssignments, "expected assignments \(expectedAssignments), but instead got \(delegate.assignments)", sourceLocation: sourceLocation)

    // Check the diagnostics that the delegate saw against the expected ones.
    #expect(delegate.diagnostics == expectedDiagnostics, "expected parse diagnostics \(expectedDiagnostics), but instead got \(delegate.diagnostics)", sourceLocation: sourceLocation)

    #expect(delegate.includeDirectivesCount == expectedIncludeDirectivesCount, "expected number of configs parsed to be \(expectedIncludeDirectivesCount), but instead got \(delegate.includeDirectivesCount)", sourceLocation: sourceLocation)
}

// A bunch of free functions that let us compare our typealiased tuples.
func ==(lhs: ConditionInfo, rhs: ConditionInfo) -> Bool {
    return (lhs.param == rhs.param) && (lhs.pattern == rhs.pattern)
}

func ==(lhs: [ConditionInfo], rhs: [ConditionInfo]) -> Bool {
    return lhs.count == rhs.count && zip(lhs, rhs).filter({ return !($0.0 == $0.1) }).isEmpty
}

func ==(lhs: AssignmentInfo, rhs: AssignmentInfo) -> Bool {
    return (lhs.macro == rhs.macro) && (lhs.conditions == rhs.conditions) && (lhs.value == rhs.value)
}

func ==(lhs: [AssignmentInfo], rhs: [AssignmentInfo]) -> Bool {
    return lhs.count == rhs.count && zip(lhs, rhs).filter({ return !($0.0 == $0.1) }).isEmpty
}

func ==(lhs: DiagnosticInfo, rhs: DiagnosticInfo) -> Bool {
    return (lhs.level == rhs.level) && (lhs.kind == rhs.kind) && (lhs.line == rhs.line)
}

func ==(lhs: [DiagnosticInfo], rhs: [DiagnosticInfo]) -> Bool {
    return lhs.count == rhs.count && zip(lhs, rhs).filter({ return !($0.0 == $0.1) }).isEmpty
}


/// Private helper function that parses a string representation as either a string or a string list (depending on the parameter), and checks the resulting parser delegate method call sequence and diagnostics (if applicable) against what’s expected.  This is a private function that’s called by the two internal test functions TestMacroStringParsing() and TestMacroStringListParsing().  The original file name and line number are passed in so that Xcode diagnostics will refer to the call site.  Each diagnostic is provided by the unit test as a tuple containing the level, kind, and associated range (expressed as start and end “distances”, in the manner of Int.Distance, into the original string).
private func TestMacroParsing(_ string: String, asList: Bool, expectedCallLogEntries: [ParseDelegateCallLogEntry], expectedDiagnosticInfos: [(level: MacroExpressionDiagnostic.Level, kind: MacroExpressionDiagnostic.Kind, start: Int, end: Int)], sourceLocation: SourceLocation = #_sourceLocation) {
    // Create a parser delegate of our special class that records a "method call log" that we can then compare against what's expected.
    let delegate = TestDelegate()

    // Create a parser, initializing it with the given string and with our test delegate.
    let parser = MacroExpressionParser(string: string, delegate: delegate)

    // Parse the input string as either a string or a list, depending on what we were asked to do.
    if asList {
        parser.parseAsStringList()
    }
    else {
        parser.parseAsString();
    }

    // Check the delegate call sequence, which is a log of the calls that the delegate received.
    #expect(delegate.callLogEntries == expectedCallLogEntries, "expected delegate call sequence \(expectedCallLogEntries), but instead got \(delegate.callLogEntries)", sourceLocation: sourceLocation)

    // Create MacroExpressionDiagnostic objects from the tuples in ‘expectedDiagnosticInfos’ (which are a more convenient form to pass in for the unit tests).
    let expectedDiagnostics = expectedDiagnosticInfos.map { (level: MacroExpressionDiagnostic.Level, kind: MacroExpressionDiagnostic.Kind, start: Int, end: Int) -> MacroExpressionDiagnostic in
        // FIXME: This is really inefficient, I believe.
        return MacroExpressionDiagnostic(string: string, range: string.utf8.index(string.utf8.startIndex, offsetBy: start)..<string.utf8.index(string.utf8.startIndex, offsetBy: end), kind: kind, level: level)
    }
    #expect(delegate.diagnostics == expectedDiagnostics, "expected parse diagnostics \(expectedDiagnostics), but instead got \(delegate.diagnostics)", sourceLocation: sourceLocation)
}


/// Helper function that parses a macro string as a string, and checks the resulting parser delegate method call sequence and diagnostics (if applicable) against what’s expected.
fileprivate func TestMacroStringParsing(_ string: String, _ expectedCallLogEntries: [ParseDelegateCallLogEntry], expectedDiagnostics: [(level: MacroExpressionDiagnostic.Level, kind: MacroExpressionDiagnostic.Kind, start: Int, end: Int)] = [], sourceLocation: SourceLocation = #_sourceLocation) {
    // Just call our “helper helper” function, asking it to parse the input string as a string (as opposed to a string list).
    TestMacroParsing(string, asList: false, expectedCallLogEntries: expectedCallLogEntries, expectedDiagnosticInfos: expectedDiagnostics, sourceLocation: sourceLocation)
}


///  Helper function that parses a macro string as a string list, and checks the result and delegate "method call log" against what's expected.
fileprivate func TestMacroStringListParsing(_ string: String, _ expectedCallLogEntries: [ParseDelegateCallLogEntry], expectedDiagnostics: [(level: MacroExpressionDiagnostic.Level, kind: MacroExpressionDiagnostic.Kind, start: Int, end: Int)] = [], sourceLocation: SourceLocation = #_sourceLocation) {
    // Just call our “helper helper” function, asking it to parse the input string as a string (as opposed to a string list).
    TestMacroParsing(string, asList: true, expectedCallLogEntries: expectedCallLogEntries, expectedDiagnosticInfos: expectedDiagnostics, sourceLocation: sourceLocation)
}


/// For testing purposes. Our delegate (below) keeps a log of the methods that were called, and in what order and with what parameters. Then we can compare that against what was expected.
fileprivate enum ParseDelegateCallLogEntry : Equatable, CustomDebugStringConvertible {
    case literalChars(String)
    case literalStringFormOnlyChars(String)
    case startSubstSubexpr
    case startStringSubstSubexpr
    case startMacroName
    case endMacroName(wasBracketed: Bool)
    case retrievalOp(String)
    case startReplacementOp(String)
    case endReplacementOp(String)
    case endStringSubstSubexpr
    case endSubstSubexpr
    case listElementSeparator(String)

    @_spi(Testing) public var debugDescription: String {
        switch self {
        case .literalChars(let s): return "literalChars(\"\(s)\")"
        case .literalStringFormOnlyChars(let s): return "literalStringFormOnlyChars(\"\(s)\")"
        case .startSubstSubexpr: return "startSubstSubexpr()"
        case .startStringSubstSubexpr: return "startStringSubstSubexpr()"
        case .startMacroName: return ".startMacroName()"
        case .endMacroName: return ".endMacroName()"
        case .retrievalOp(let s): return "retrievalOp(\(s))"
        case .startReplacementOp(let s): return "startReplacementOp(\(s))"
        case .endReplacementOp(let s): return "endReplacementOp(\(s))"
        case .endStringSubstSubexpr: return "endStringSubstSubexpr()"
        case .endSubstSubexpr: return "endSubstSubexpr()"
        case .listElementSeparator(let s): return "listElementSeparator(\(s))"
        }
    }
}

/// Necessary until we have <rdar://problem/15202393> Derived conformances for Equatable, Comparable, Hashable, etc.
fileprivate func ==(lhs: ParseDelegateCallLogEntry, rhs: ParseDelegateCallLogEntry) -> Bool {
    // This is a bit unfortunate, but is necessary due to <rdar://problem/19525557> Enums with associated values should be Equatable if the values are equatable
    switch (lhs, rhs) {
    case (.literalChars(let x), .literalChars(let y)) where x == y: return true
    case (.literalChars, _): return false
    case (.literalStringFormOnlyChars(let x), .literalStringFormOnlyChars(let y)) where x == y: return true
    case (.literalStringFormOnlyChars, _): return false
    case (.startSubstSubexpr, .startSubstSubexpr): return true
    case (.startSubstSubexpr, _): return false
    case (.startStringSubstSubexpr, .startStringSubstSubexpr): return true
    case (.startStringSubstSubexpr, _): return false
    case (.startMacroName, .startMacroName): return true
    case (.startMacroName, _): return false
    case (.endMacroName(let x), .endMacroName(let y)) where x == y: return true
    case (.endMacroName, _): return false
    case (.retrievalOp(let x), .retrievalOp(let y)) where x == y: return true
    case (.retrievalOp, _): return false
    case (.startReplacementOp(let x), .startReplacementOp(let y)) where x == y: return true
    case (.startReplacementOp, _): return false
    case (.endReplacementOp(let x), .endReplacementOp(let y)) where x == y: return true
    case (.endReplacementOp, _): return false
    case (.endStringSubstSubexpr, .endStringSubstSubexpr): return true
    case (.endStringSubstSubexpr, _): return false
    case (.endSubstSubexpr, .endSubstSubexpr): return true
    case (.endSubstSubexpr, _): return false
    case (.listElementSeparator(let x), .listElementSeparator(let y)) where x == y: return true
    case (.listElementSeparator, _): return false
    }
}

///  For testing purposes.  Helper delegate that keeps a log of the methods that were called, and in what order and with what parameters.  Then we can compare that against what was expected.
fileprivate final class TestDelegate : MacroExpressionParserDelegate {
    // Keep an array of call log entries, and add to it whenever we get a call.
    var callLogEntries: [ParseDelegateCallLogEntry] = []
    var diagnostics: [MacroExpressionDiagnostic] = []

    func foundLiteralStringFragment(_ string: Input, parser: MacroExpressionParser) {
        callLogEntries.append(.literalChars(String(string)!))
    }
    func foundStringFormOnlyLiteralStringFragment(_ string: MacroExpressionParserDelegate.Input, parser: MacroExpressionParser) {
        callLogEntries.append(.literalStringFormOnlyChars(String(string)!))
    }
    func foundStartOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {
        callLogEntries.append(alwaysEvalAsString ? .startStringSubstSubexpr : .startSubstSubexpr)
    }
    func foundStartOfMacroName(parser: MacroExpressionParser) {
        callLogEntries.append(.startMacroName)
    }
    func foundEndOfMacroName(wasBracketed: Bool, parser: MacroExpressionParser) {
        callLogEntries.append(.endMacroName(wasBracketed: wasBracketed))
    }
    func foundRetrievalOperator(_ operatorName: Input, parser: MacroExpressionParser) {
        callLogEntries.append(.retrievalOp(String(operatorName)!))
    }
    func foundStartOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {
        callLogEntries.append(.startReplacementOp(String(operatorName)!))
    }
    func foundEndOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {
        callLogEntries.append(.endReplacementOp(String(operatorName)!))
    }
    func foundEndOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {
        callLogEntries.append(alwaysEvalAsString ? .endStringSubstSubexpr : .endSubstSubexpr)
    }
    func foundListElementSeparator(_ string: Input, parser: MacroExpressionParser) {
        callLogEntries.append(.listElementSeparator(String(string)!))
    }
    func handleDiagnostic(_ diagnostic: MacroExpressionDiagnostic, parser: MacroExpressionParser) {
        diagnostics.append(diagnostic)
    }
}
