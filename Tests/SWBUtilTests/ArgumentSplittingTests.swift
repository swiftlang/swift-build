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
@_spi(Testing) import SWBUtil

@Suite fileprivate struct ArgumentSplittingTests {
    private let llvmCodec = LLVMStyleCommandCodec()
    private let unixShellCodecQuotes = UNIXShellCommandCodec(encodingStrategy: .singleQuotes, encodingBehavior: .fullCommandLine)
    private let unixShellCodecQuotesPartial = UNIXShellCommandCodec(encodingStrategy: .singleQuotes, encodingBehavior: .argumentsOnly)
    private let unixShellCodecBackslashes = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .fullCommandLine)
    private let unixShellCodecBackslashesPartial = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .argumentsOnly)

    @Test
    func LLVMCommandOutputParsing() throws {
        #expect(try llvmCodec.decode("") == [])
        #expect(try llvmCodec.decode(" ") == [])
        #expect(try llvmCodec.decode("  ") == [])

        #expect(try llvmCodec.decode("\"\"") == [""])
        #expect(try llvmCodec.decode(" \"\"") == [""])
        #expect(try llvmCodec.decode("\"\" ") == [""])
        #expect(try llvmCodec.decode(" \"\" ") == [""])
        #expect(try llvmCodec.decode("  \"\"  ") == [""])
        #expect(try llvmCodec.decode("     \"\"   \" \"   ") == ["", " "])

        #expect(try llvmCodec.decode("Hello World") == ["Hello", "World"])
        #expect(try llvmCodec.decode("\"Hello\" World") == ["Hello", "World"])
        #expect(try llvmCodec.decode("Hello \"World\"") == ["Hello", "World"])
        #expect(try llvmCodec.decode("Hello  World") == ["Hello", "World"])
        #expect(try llvmCodec.decode(" Hello World") == ["Hello", "World"])
        #expect(try llvmCodec.decode("Hello World ") == ["Hello", "World"])
        #expect(try llvmCodec.decode(" Hello  World ") == ["Hello", "World"])
        #expect(try llvmCodec.decode("  Hello  World  ") == ["Hello", "World"])
        #expect(try llvmCodec.decode(" Hello  World ") == ["Hello", "World"])
        #expect(try llvmCodec.decode(" Hello ' World ") == ["Hello", "'", "World"])

        #expect(try llvmCodec.decode("Hello \"\\$USER!\"") == ["Hello", "$USER!"])

        #expect(try llvmCodec.decode("swift -foo  \"File 1.swift\"   -other-arg") == ["swift", "-foo", "File 1.swift", "-other-arg"])
    }

    @Test
    func LLVMCommandOutputParsingEOF() {
        #expect {
            try llvmCodec.decode("\"Hello World")
        } throws: { error in
            guard let decodingError = error as? LLVMStyleCommandCodec.DecodingError else { return false }
            return decodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEndOfInputInQuotedString && decodingError.errorDescription == "Unterminated quoted string in input"
        }

        #expect {
            try llvmCodec.decode("\"Hello World ")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEndOfInputInQuotedString
        }

        #expect {
            try llvmCodec.decode("\"Hello World \"\"")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEndOfInputInQuotedString
        }

        #expect {
            try llvmCodec.decode("\"Hello World \"\" ")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEndOfInputInQuotedString
        }

        #expect {
            try llvmCodec.decode(" \"Hello World \"\"")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEndOfInputInQuotedString
        }

        #expect {
            try llvmCodec.decode("  \"Hello World \"\" ")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEndOfInputInQuotedString
        }

        #expect {
            try llvmCodec.decode("Hello \"World\\")
        } throws: { error in
            guard let decodingError = error as? LLVMStyleCommandCodec.DecodingError else { return false }
            return decodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEndOfInputInEscapeSequence && decodingError.errorDescription == "Unterminated escape sequence in input"
        }
    }

    @Test
    func LLVMCommandOutputParsingUnexpectedQuote() {
        #expect {
            try llvmCodec.decode("Hello\"foo\"")
        } throws: { error in
            guard let decodingError = error as? LLVMStyleCommandCodec.DecodingError else { return false }
            return decodingError == LLVMStyleCommandCodec.DecodingError.unexpectedQuotedStringToken && decodingError.errorDescription == "Unexpected \" in input; did you mean to add a space before beginning a quoted string?"
        }

        #expect {
            try llvmCodec.decode("Hello\"")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedQuotedStringToken
        }
    }

    @Test
    func LLVMCommandOutputParsingUnexpectedEscape() {
        #expect {
            try llvmCodec.decode("Hello\\")
        } throws: { error in
            guard let decodingError = error as? LLVMStyleCommandCodec.DecodingError else { return false }
            return decodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEscapeSequenceToken && decodingError.errorDescription == "Unexpected \\ in input; escape sequences must appear inside quoted strings"
        }

        #expect {
            try llvmCodec.decode("Hello\\\\")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEscapeSequenceToken
        }

        #expect {
            try llvmCodec.decode("\\$")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEscapeSequenceToken
        }

        #expect {
            try llvmCodec.decode("All is well in Cupert\\ino")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEscapeSequenceToken
        }
    }

    @Test
    func LLVMCommandOutputParsingUnexpectedCharacter() {
        #expect {
            try llvmCodec.decode("Hello \"$USER!\"")
        } throws: { error in
            guard let decodingError = error as? LLVMStyleCommandCodec.DecodingError else { return false }
            return decodingError == LLVMStyleCommandCodec.DecodingError.unexpectedCharacter && decodingError.errorDescription == "Encountered unexpected '$' in input; did you mean '\\$'?"
        }

        #expect {
            try llvmCodec.decode("Hello $USER!")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedCharacter
        }

        #expect {
            try llvmCodec.decode("Hello$USER!")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedCharacter
        }
    }

    @Test
    func LLVMCommandOutputParsingUnnecessaryEscape() {
        #expect {
            try llvmCodec.decode("All is well in \"Cupert\\ino")
        } throws: { error in
            guard let decodingError = error as? LLVMStyleCommandCodec.DecodingError else { return false }
            return decodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEscapeSequence(char: "i") && decodingError.errorDescription == "Encountered unexpected escape sequence '\\i' in input; did you mean 'i'?"
        }

        #expect {
            try llvmCodec.decode("All is well in \"Cupert\\ino\"")
        } throws: { error in
            error as? LLVMStyleCommandCodec.DecodingError == LLVMStyleCommandCodec.DecodingError.unexpectedEscapeSequence(char: "i")
        }
    }

    @Test
    func LLVMCommandOutputEncoding() {
        #expect(llvmCodec.encode([]) == "")
        #expect(llvmCodec.encode([""]) == "\"\"")
        #expect(llvmCodec.encode(["", " "]) == "\"\" \" \"")
        #expect(llvmCodec.encode(["Hello", "World"]) == "Hello World")
        #expect(llvmCodec.encode(["Hello", "'", "World"]) == "Hello ' World")
        #expect(llvmCodec.encode(["Hello", "$USER!"]) == "Hello \"\\$USER!\"")
        #expect(llvmCodec.encode(["swift", "-foo", "File 1.swift", "-other-arg"]) == "swift -foo \"File 1.swift\" -other-arg")
        #expect(llvmCodec.encode(["\"Hello World"]) == "\"\\\"Hello World\"")
        #expect(llvmCodec.encode(["\"Hello", "World"]) == "\"\\\"Hello\" World")
        #expect(llvmCodec.encode(["\"Hello World", " "]) == "\"\\\"Hello World\" \" \"")
        #expect(llvmCodec.encode(["Hello\"foo\""]) == "\"Hello\\\"foo\\\"\"")
        #expect(llvmCodec.encode(["Hello$USER!"]) == "\"Hello\\$USER!\"")
        #expect(llvmCodec.encode(["All is well in", "\"Cupert\\ino\""]) == "\"All is well in\" \"\\\"Cupert\\\\ino\\\"\"")
        #expect(llvmCodec.encode(["All is well in", "Cupert\\ino"]) == "\"All is well in\" \"Cupert\\\\ino\"")
    }

    @Test(arguments: [
        [],
        [""],
        ["", " "],
        ["Hello", "World"],
        ["Hello", "'", "World"],
        ["Hello", "$USER!"],
        ["swift", "-foo", "File 1.swift", "-other-arg"],
        ["\"Hello World"],
        ["\"Hello", "World"],
        ["\"Hello World", " "],
        ["Hello\"foo\""],
        ["Hello$USER!"],
        ["All is well in", "\"Cupert\\ino\""],
    ])
    func LLVMCommandOutputRoundtrip(_ `case`: [String]) throws {
        #expect(try llvmCodec.decode(llvmCodec.encode(`case`)) == `case`)
    }

    @Test
    func UNIXShellEncoding() {
        #expect("Hello''World 'This' is ' great! ".fragment(around: "'") == ["Hello", "'", "'", "World ", "'", "This", "'", " is ", "'", " great! "])

        // Single quoted strings encode single quotes themselves a little oddly,
        // in that a single quote cannot itself be escaped inside a quoted string,
        // but must be escaped on its own between two other quoted strings.
        // For example, the string:
        //     $ello'$orld
        // Would be escaped as:
        //     '$ello'\''$orld'
        // We are conservative here, as a more naive approach might result in:
        //     Hello'World
        // being encoded as:
        //     'Hello'\''World'
        // whereas only:
        //     Hello\'World
        // is needed to treat that string as a single argument.
        #expect(unixShellCodecQuotes.encode(["$ello'$orld"]) == "'$ello'\\''$orld'")
        #expect(unixShellCodecQuotes.encode(["Hello'World"]) == "Hello\\'World")

        var x = ["Hello", "$USER"]
        #expect(unixShellCodecQuotes.encode(x) == "Hello '$USER'")
        #expect(unixShellCodecBackslashes.encode(x) == "Hello \\$USER")

        x = ["Hello", "Not\nANewCommand"]
        #expect(unixShellCodecQuotes.encode(x) == "Hello 'Not\nANewCommand'")
        #expect(unixShellCodecBackslashes.encode(x) == "Hello Not'\n'ANewCommand")

        x = ["That's", "a", "great", "idea!"]
        #expect(unixShellCodecQuotes.encode(x) == "That\\'s a great 'idea!'")
        #expect(unixShellCodecBackslashes.encode(x) == "That\\'s a great idea\\!")

        x = ["\0"]
        #expect(unixShellCodecQuotes.encode(x) == "'\0'")
        #expect(unixShellCodecBackslashes.encode(x) == "\\\0")

        x = ["Hello", "'", "'", "World ", "'", "This", "'", " is ", "'", " great! "]
        #expect(unixShellCodecQuotes.encode(x) == "Hello \\' \\' 'World ' \\' This \\' ' is ' \\' ' great! '")
        #expect(unixShellCodecBackslashes.encode(x) == "Hello \\' \\' World\\  \\' This \\' \\ is\\  \\' \\ great\\!\\ ")

        x = ["🇽🇽"]
        #expect(unixShellCodecQuotes.encode(x) == "🇽🇽")
        #expect(unixShellCodecBackslashes.encode(x) == "🇽🇽")

        x = ["你好"]
        #expect(unixShellCodecQuotes.encode(x) == "你好")
        #expect(unixShellCodecBackslashes.encode(x) == "你好")

        x = ["if", "we try to run this without quoting the first argument", "bad things will happen!"]
        #expect(unixShellCodecQuotes.encode(x) == "'if' 'we try to run this without quoting the first argument' 'bad things will happen!'")
        #expect(unixShellCodecBackslashes.encode(x) == "'if' we\\ try\\ to\\ run\\ this\\ without\\ quoting\\ the\\ first\\ argument bad\\ things\\ will\\ happen\\!")

        #expect(unixShellCodecQuotesPartial.encode(x) == "if 'we try to run this without quoting the first argument' 'bad things will happen!'")
        #expect(unixShellCodecBackslashesPartial.encode(x) == "if we\\ try\\ to\\ run\\ this\\ without\\ quoting\\ the\\ first\\ argument bad\\ things\\ will\\ happen\\!")
    }

    @Test
    func UNIXShellEncodingCustomJoinSequence() {
        #expect(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, joinSequence: "", encodingBehavior: .fullCommandLine) == nil)
        #expect(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, joinSequence: " a", encodingBehavior: .fullCommandLine) == nil)
        #expect(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, joinSequence: "a ", encodingBehavior: .fullCommandLine) == nil)
        #expect(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, joinSequence: "\t", encodingBehavior: .fullCommandLine) == nil)
        #expect(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, joinSequence: "this$seem$deviou$!", encodingBehavior: .fullCommandLine) == nil)
        #expect(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, joinSequence: " ", encodingBehavior: .fullCommandLine)?.encode(["This", "is", "typical"]) == "This is typical")
        #expect(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, joinSequence: "   ", encodingBehavior: .fullCommandLine)?.encode(["This", "is", "apparently", "more", "readable"]) == "This   is   apparently   more   readable")
    }
}
