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

import struct Foundation.CharacterSet

public protocol CommandSequenceEncodable: Sendable {
    func encode(_ sequence: [String]) -> String
}

public protocol CommandSequenceDecodable: Sendable {
    func decode(_ command: String) throws -> [String]
}

/// Command sequence codec for the Bourne/Bash shells on UNIX platforms.
public final class UNIXShellCommandCodec: CommandSequenceEncodable, Sendable {
    /// Enumerates the possible techniques that can be used to encode the substrings of a command sequence.
    /// Each technique may be more or less readable, compact, or "safe" compared to others and should be chosen based on the use case.
    public enum EncodingStrategy: Sendable {
        /// Surround each argument with single quotes.
        /// Single quotes protect every character except single quotes themselves, which are backslash-escaped.
        case singleQuotes

        /// Backslash-escapes all special characters.
        /// Backslashes protect every character except newlines.
        /// Internal newlines (which cannot be escaped using backslashes) are instead escaped by surrounding them with single quotes.
        case backslashes
    }

    /// Enumerates the possible behaviors of the encoder which can affect how the input is processed.
    public enum EncodingBehavior: Sendable {
        /// Indicates that the inputs to the encoder will be treated as full command lines.
        ///
        /// This is mostly equivalent to `argumentsOnly`, but with one key difference: the first argument in the array is subject to additional validations because certain characters are not escapable when used as the first argument (program name) of a command line .
        case fullCommandLine

        /// Indicates that the inputs to the encoder are arguments passed to another program.
        case argumentsOnly
    }

    public let encodingStrategy: EncodingStrategy
    public let encodingBehavior: EncodingBehavior
    public let joinSequence: String

    // Shell keywords according to `compgen -k` - these must be quoted if they're the first item in a shell-quoted string, even if they don't contain any of the characters in `specialShellCharacters`.
    private static let shellKeywords = Set(["if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "in", "function", "time", "{", "}", "!", "[[", "]]"])

    /// Creates a UNIX shell command codec that encodes commands using the given strategy.
    /// - Parameter encodingStrategy: The encoding strategy to use to encode the resulting substrings.
    /// - Parameter encodingBehavior: The input mode to operate in.
    public init(encodingStrategy: EncodingStrategy, encodingBehavior: EncodingBehavior) {
        self.encodingStrategy = encodingStrategy
        self.encodingBehavior = encodingBehavior
        self.joinSequence = " "
    }

    /// Creates a UNIX shell command codec that encodes commands using the given strategy and join sequence.
    /// - Parameter encodingStrategy: The encoding strategy to use to encode the resulting substrings.
    /// - Parameter joinSequence: The string used to join the resulting substrings.
    /// - Parameter encodingBehavior: The input mode to operate in.
    /// Defaults to a single space, and can be any number of spaces if that is desired for readability in a particular context.
    /// An invalid join sequence (one that would affect the interpretation when subsequently decoding the resultant string) will cause the initializer to return nil.
    public init?(encodingStrategy: EncodingStrategy, joinSequence: String, encodingBehavior: EncodingBehavior) {
        // Arguments can be joined by one or more spaces; clients may want to separate with multiple spaces for readability
        guard joinSequence == " " || (!joinSequence.isEmpty && !joinSequence.contains(where: { $0 != " " })) else {
            return nil
        }

        self.encodingStrategy = encodingStrategy
        self.joinSequence = joinSequence
        self.encodingBehavior = encodingBehavior
    }

    /// Tests whether a character is "special" to the shell and thus needs to be escaped or quoted.
    /// This can be context-dependent; we generally take a conservative approach and quote in some places where it *might* not be needed.
    /// - Parameter ch: The character to test for special meaning in shell syntax.
    private func isSpecialShellCharacter(ch: Character) -> Bool {
        // , might be special (according to bash builtin printf %q, but it doesn't seem to be in any context where all
        // other special characters are escaped
        switch ch.unicodeScalars.only?.value {
        case 0...0x24, 0x26...0x2A, 0x3B...0x3F, 0x5B...0x5E, 0x60, 0x7B...0x7F: return true
        default: return false
        }
    }

    private func isShellKeyword(string: String) -> Bool {
        return UNIXShellCommandCodec.shellKeywords.contains(string)
    }

    private func needsShellKeywordEncoding(index: Int, value: String) -> Bool {
        return encodingBehavior == .fullCommandLine && index == 0 && isShellKeyword(string: value)
    }

    public func encode(_ sequence: [String]) -> String {
        // NOTE: If encoding a full command line, and the first character of the first argument is "%",
        // there is no way to escape the % in such a way that Bash does not attempt to interpret it as
        // a special character. This doesn't affect other shells like zsh, and is best avoided by simply
        // not doing this in the first place (or always using a wrapper executable like `env`). It's also
        // an extraordinarily rare case, as it's very unlikely someone will have an executable whose name
        // starts with the % character and expects to execute this command via PATH lookup rather than
        // absolute or relative path like ./
        return { () -> [String] in
            switch encodingStrategy {
            case .singleQuotes:
                return sequence.enumerated().map { (argIndex, arg) in
                    arg.fragment(around: "'").map {
                        if $0 == "'" {
                            return "\\'"
                        } else if needsShellKeywordEncoding(index: argIndex, value: $0) || ($0.contains(where: { isSpecialShellCharacter(ch: $0) })) {
                            return "'\($0)'"
                        } else {
                            return $0
                        }
                    }.joined()
                }
            case .backslashes:
                return sequence.enumerated().map { (argIndex, arg) in
                    if needsShellKeywordEncoding(index: argIndex, value: arg) {
                        return "'\(arg)'"
                    } else {
                        return arg.map {
                            if $0 == "\n" {
                                return "'\n'"
                            } else if isSpecialShellCharacter(ch: $0) {
                               return "\\\($0)"
                            } else {
                                return "\($0)"
                            }
                        }.joined()
                    }
                }
            }
        }().joined(separator: joinSequence)
    }
}

/// LLVM-style command sequence codec.
/// Used by Swift compiler driver for its JSON command messages (escapeAndPrintString from Job.cpp).
public final class LLVMStyleCommandCodec: CommandSequenceEncodable, CommandSequenceDecodable, Sendable {
    @_spi(Testing) public enum DecodingError: Error, Equatable {
        case unexpectedQuotedStringToken
        case unexpectedEscapeSequenceToken
        case unexpectedCharacter
        case unexpectedEscapeSequence(char: Character)
        case unexpectedEndOfInputInQuotedString
        case unexpectedEndOfInputInEscapeSequence

        public var errorDescription: String? {
            switch self {
            case .unexpectedQuotedStringToken:
                return "Unexpected \" in input; did you mean to add a space before beginning a quoted string?"
            case .unexpectedEscapeSequenceToken:
                return "Unexpected \\ in input; escape sequences must appear inside quoted strings"
            case .unexpectedCharacter:
                return "Encountered unexpected '$' in input; did you mean '\\$'?"
            case .unexpectedEscapeSequence(let char):
                return "Encountered unexpected escape sequence '\\\(char)' in input; did you mean '\(char)'?"
            case .unexpectedEndOfInputInQuotedString:
                return "Unterminated quoted string in input"
            case .unexpectedEndOfInputInEscapeSequence:
                return "Unterminated escape sequence in input"
            }
        }
    }

    public enum CommandStringParsingState: Sendable {
        case none
        case inString
        case inQuotedString
        case escapingCharacter
    }

    public init() {
    }

    public func encode(_ sequence: [String]) -> String {
        return sequence.map {
            if $0.isEmpty {
                return String(repeating: LLVMStyleCommandCodec.quote, count: 2)
            }

            guard $0.first(where: { "\(LLVMStyleCommandCodec.space)\(LLVMStyleCommandCodec.quote)\(LLVMStyleCommandCodec.backslash)\(LLVMStyleCommandCodec.dollarSign)".contains($0) }) != nil else {
                return $0
            }

            return String(LLVMStyleCommandCodec.quote) + $0.map { (char: Character) -> String in [LLVMStyleCommandCodec.quote, LLVMStyleCommandCodec.backslash, LLVMStyleCommandCodec.dollarSign].contains(char) ? String(LLVMStyleCommandCodec.backslash) + String(char) : String(char) }.joined() + String(LLVMStyleCommandCodec.quote)
        }.joined(separator: String(LLVMStyleCommandCodec.space))
    }

    public func decode(_ string: String) throws -> [String] {
        if string.isEmpty {
            return []
        }

        var args: [String] = []
        var s = String()
        var state = CommandStringParsingState.none

        let complete = {
            state = .none
            args.append(s)
            s.removeAll(keepingCapacity: true)
        }

        for c in string {
            switch state {
            case .inString:
                switch c {
                case LLVMStyleCommandCodec.quote:
                    throw DecodingError.unexpectedQuotedStringToken
                case LLVMStyleCommandCodec.backslash:
                    throw DecodingError.unexpectedEscapeSequenceToken
                case LLVMStyleCommandCodec.dollarSign:
                    throw DecodingError.unexpectedCharacter
                case LLVMStyleCommandCodec.space:
                    complete()
                default:
                    s.append(c)
                }
            case .inQuotedString:
                switch c {
                case LLVMStyleCommandCodec.quote:
                    complete()
                case LLVMStyleCommandCodec.backslash:
                    state = .escapingCharacter
                case LLVMStyleCommandCodec.dollarSign:
                    throw DecodingError.unexpectedCharacter
                default:
                    s.append(c)
                }
            case .escapingCharacter:
                switch c {
                case LLVMStyleCommandCodec.quote, LLVMStyleCommandCodec.backslash, LLVMStyleCommandCodec.dollarSign:
                    s.append(c)
                    state = .inQuotedString
                default:
                    throw DecodingError.unexpectedEscapeSequence(char: c)
                }
            case .none:
                switch c {
                case LLVMStyleCommandCodec.quote:
                    state = .inQuotedString
                case LLVMStyleCommandCodec.backslash:
                    throw DecodingError.unexpectedEscapeSequenceToken
                case LLVMStyleCommandCodec.dollarSign:
                    throw DecodingError.unexpectedCharacter
                case LLVMStyleCommandCodec.space:
                    break
                default:
                    s.append(c)
                    state = .inString
                }
            }
        }

        switch state {
        case .inString:
            complete()
        case .inQuotedString:
            throw DecodingError.unexpectedEndOfInputInQuotedString
        case .escapingCharacter:
            throw DecodingError.unexpectedEndOfInputInEscapeSequence
        case .none:
            break
        }

        return args
    }

    private static let quote = Character("\"")
    private static let backslash = Character("\\")
    private static let space = Character(" ")
    private static let dollarSign = Character("$")
}
