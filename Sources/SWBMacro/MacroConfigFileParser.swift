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

public import SWBUtil
import Foundation

private extension UInt8 {
    var isASCIISpace: Bool {
        switch self {
        case /* ' ' */ 32, /* '\t' */ 9, /* '\v' */ 11, /* '\f' */ 12:
            return true
        default:
            return false
        }
    }
}

/// A parser for .xcconfig files.  The parser itself is responsible only for parsing and error detection, and doesn’t perform any other actions such as parsing individual macro expressions found in assignment statements etc.  The delegate, which is required but whose methods are all optional, is informed of everything the parser finds as it advances through the string — this is quite similar to how SAX parsers work (http://www.wikipedia.org/wiki/Simple_API_for_XML).  The parser is as lenient as possible, and tries to recover from errors as well as possible in order to preserve the Xcode semantics.  The delegate is guaranteed to see the entire contents of the input string, regardless of how many errors are discovered (some of that contents might be misparsed after errors have been found, however).
public final class MacroConfigFileParser {

    /// Delegate that gets informed of everything the parser find while traversing the string (including any diagnostics).
    public var delegate: (any MacroConfigFileParserDelegate)?

    /// UTF-8 byte buffer that’s being parsed.  The byte offset that’s accessible through the `position` property is an index into this byte array.
    public let bytes: Array<UInt8>

    /// The path to the xcconfig file being parsed, for diagnostic purposes.
    public let path: Path

    /// Current index into the UTF-8 byte sequence that’s being parsed.  Starts at zero.  All meaningful characters are in the ASCII range, which is what lets us do this optimization.
    var currIdx: Int

    /// Current line number.  Starts at one.
    var currLine: Int


    /// Initializes the macro expression parser with the given string and delegate.  How the string is parsed depends on the particular parse method that’s invoked, such as `parseAsString()` or `parseAsStringList()`, and not on the configuration of the parser.
    public init(byteString: ByteString, path: Path, delegate: (any MacroConfigFileParserDelegate)?) {
        self.delegate = delegate
        self.bytes = byteString.bytes
        self.path = path
        self.currIdx = 0
        self.currLine = 1
    }

    /// Returns the current line number of the parser.  This is commonly used from the custom implementations of the parser delegate function callbacks.  Line numbers are one-based, and refer only to the source text of the parser itself (not taking into account any source text included using #include directives).
    public var lineNumber: Int { return currLine }

    /*

    Grammar:

      xcconfig:
        line

      line:
        "" // empty
        "#" directive
        assignment ';'?

      directive:
        "include" '\"' string '\"'
        "include?" '\"' string '\"'

      assignment:
        macro '='
        macro '=' value
        macro conditions '=' value

      conditions:
        condition
        conditions condition

      condition:
        '[' condition-parameter '=' condition-pattern ']'

      condition-parameter:
        anything-except-equals-sign-and-right-bracket+

      condition-pattern:
        anything-except-right-bracket+

      comment:
        '/' '/' anything-except-newline '\n'

      end-of-line:
        '\n'
        '\r'
        '\r' '\n'
        <unicode line separator>
        <unicode paragraph separator>

    */


    /// Checks whether the cursor is at the end of a line, i.e. either at a line terminator (\n, \r, \r\n, or a UTF8-coded Unicode Line Separator or Paragraph Separator) or at the end of the entire input.
    private var isAtEndOfLine: Bool {
        return isAtEndOfStream || currChar == /* '\n' */ 10 || currChar == /* '\r' */ 13 || (currChar == 0xE2 && nextChar == 0x80 && (nextNextChar == /* Unicode Line Separator */ 0xA8 || nextNextChar == /* Unicode Paragraph Separator */ 0xA9))
    }


    /// Checks whether the cursor is at the start of a `//` style comment.
    private var isAtStartOfComment: Bool {
        return currChar == /* '/' */ 47 && nextChar == /* '/' */ 47
    }


    /// If the cursor is at an end-of-line (as determined by `isAtEOL()`), it is advanced past the end-of-line and `currLine` is incremented.  Otherwise this function does nothing.  Note that an end-of-line may be one, two, or three bytes in length.
    private func scanEOL() {
        var advancement = 0
        if currChar == /* '\n' */ 10 {
            advancement = 1
        }
        else if currChar == /* '\r' */ 13 {
            advancement = (nextChar == /* '\n' */ 10) ? 2 : 1
        }
        else if currChar == 0xE2 && nextChar == 0x80 && (nextNextChar == 0xA8 || nextNextChar == 0xA9) {
            advancement = 3
        }
        else {
            return
        }
        advance(advancement)
        currLine += 1
    }


    /// Advances the cursor until it reaches the next line terminator or end-of-stream. Does nothing if the cursor is already at the end of a line or of the stream.
    private func skipRestOfLine() {
        while !isAtEndOfLine { advance() }
    }


    /// Advances the cursor past spaces, tabs, and comments (but doesn’t go past an end-of-line).
    private func skipWhitespaceAndComments() {
        while !isAtEndOfStream {
            if currChar.isASCIISpace {
                // Normal whitespace — skip to the next byte.
                advance()
            }
            else if isAtStartOfComment {
                // Start of single-line comment.  Skip the rest of the line.
                skipRestOfLine()
            }
            else {
                break
            }
        }
    }

    private func parseQuotedString() -> String? {
        // We expect to have reached a double quote.
        if currChar == /* '\"' */ 34 {
            // Skip past the doublequote.
            advance()

            // Collect characters until the next double quote.
            // FIXME: We should really handle escapes here too.
            let markIdx = currIdx
            scanUntil({ self.isAtEndOfLine || $0 == /* '\"' */ 34 })
            let fileName = String(decoding: bytes[markIdx ..< currIdx], as: UTF8.self)

            // If we found a doublequote, we have a string, otherwise we have an unterminated quote.
            if currChar == /* '\"' */ 34 {
                // Skip past the doublequote.
                advance()
                return fileName
            } else {
                // We have an unterminated string.
                delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unterminated file name", lineNumber: lineNumber), parser: self)
                skipRestOfLine()
                return nil
            }
        } else {
            // We reached an unexpected character.
            delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unexpected character ‘\(Character(Unicode.Scalar(currChar)))’", lineNumber: lineNumber), parser: self)
            skipRestOfLine()
            return nil
        }
    }

    /// Parses a preprocessor directive of the form `#<keyword>`, where the only keyword currently implemented is `include`.
    private func parsePreprocessorDirective() {
        // First skip over any whitespace and comments.
        skipWhitespaceAndComments()

        // Empty lines are no problem, but if it isn’t empty, the line should start with a '#'.
        if isAtEndOfLine {
            // An empty line.
            return
        }
        else if currChar != /* '#' */ 35 {
            // We stopped at something other than a ‘#’ character.  That’s unexpected.
            delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "expected a preprocessor directive, but found \(Character(Unicode.Scalar(currChar)))", lineNumber: lineNumber), parser: self)
            skipRestOfLine()
            return
        }

        // We’re only suppose to be called with the cursor positioned at the hash mark.
        assert(currChar == /* '#' */ 35)
        advance()

        // Skip over any whitespace between the ‘#’ and the directive keyword.
        skipWhitespaceAndComments()

        // Check for a lone ‘#’, which is a problem.
        if isAtEndOfLine {
            // An empty line.
            delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unexpected end-of-line after ‘#’", lineNumber: lineNumber), parser: self)
            return
        }

        // Collect the directive keyword.
        let markIdx = currIdx
        scanUntil({ self.isAtWhitespace })
        let directive = String(decoding: bytes[markIdx ..< currIdx], as: UTF8.self)

        // Check for known directives.
        var includeIsOptional = false
        switch directive {
        case "include?":
            includeIsOptional = true
            fallthrough
        case "include":
            // Skip over whitespace and comments.
            skipWhitespaceAndComments()

            if let fileName = parseQuotedString() {
                // Skip over whitespace and comments.
                skipWhitespaceAndComments()

                // We expect to be at the end of the line at this point.
                if isAtEndOfLine {
                    // At this point, we finally have a filename to include, so we tell the delegate.  It handles the details of looking up the file and then if all goes well it hands us a new parser.  If there was an error with a non-optional include, the delegate is expected to have already reported the error before returning nil.
                    if let subparser = delegate?.foundPreprocessorInclusion(fileName, optional: includeIsOptional, parser: self) {
                        // We got a subparser, so we invoke it to do the parse.
                        subparser.parse()

                        // In order to detect cycles, we need to keep track of when we complete parsing a config file.
                        delegate?.endPreprocessorInclusion()
                    }
                    else {
                        // We couldn't parse the included file, so we return.  (We expected that the delegate would emit any errors.)
                        skipRestOfLine()
                        return
                    }
                }
                else {
                    // If we have extra stuff at the end of the line, we report an error.
                    delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unexpected character at end of line: ‘\(Character(Unicode.Scalar(currChar)))’", lineNumber: lineNumber), parser: self)
                    skipRestOfLine()
                    return
                }
            }
            else {
                // parseQuotedString has already emitted and error and skipped the rest of the line.
                return
            }
        default:
            // Emit an error if we see any other diagnostic.
            delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unsupported preprocessor directive ‘\(directive)’", lineNumber: lineNumber), parser: self)
            skipRestOfLine()
            return
        }
    }

    // MARK: Parsing of value assignment starts here.
    /// Parses a macro value assignment line of the form MACRONAME [ optional conditions ] ... = VALUE  ';'?
    private func parseMacroValueAssignment() {
        // First skip over any whitespace and comments.
        skipWhitespaceAndComments()

        // Empty lines are no problem, but if it isn’t empty, the line should start with a macro name.
        if isAtEndOfLine {
            // An empty line.
            return
        }
        else if !isValidMacroName1stChar(currChar) {
            // We stopped at something other than a valid macro name.  That’s unexpected.
            delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "expected a macro name, but found \(Character(Unicode.Scalar(currChar)))", lineNumber: lineNumber), parser: self)
            skipRestOfLine()
            return
        }

        // If we get this far, we have at least the start of a valid macro name.
        assert(isValidMacroName1stChar(currChar))
        let markIdx = currIdx
        advance()
        scanUntil({ !isValidMacroNameNthChar($0) })
        let name = String(decoding: bytes[markIdx ..< currIdx], as: UTF8.self)

        // Otherwise, we were able to collect the macro name.  Whitespace is fine at this point.
        skipWhitespaceAndComments()

        // Collect any macro conditions.  We collect them as an array of parameter / pattern tuples, which we then pass to the delegate.
        var conditions = Array<(param: String, pattern: String)>()
        while currChar == /* '[' */ 91 {
            // We skip over the ‘[’.
            advance()

            // Collect condition parameter name.
            func isAtConditionSeparator(_ ch: UInt8) -> Bool {
                // TYPE-INFERENCE: This function is just used to simplify type inference (versus an inline closure).
                return isAtEndOfLine || ch == /* '=' */ 61 || ch == /* ']' */ 93
            }
            let paramMarkIdx = currIdx
            scanUntil(isAtConditionSeparator)
            let param = String(decoding: bytes[paramMarkIdx ..< currIdx], as: UTF8.self)
            if isAtEndOfLine {
                delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unterminated macro condition on line \(lineNumber)", lineNumber: lineNumber), parser: self)
                skipRestOfLine()
                return
            }
            else if currChar == /* ']' */ 93 {
                delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "expected to find ‘=’ in macro condition", lineNumber: lineNumber), parser: self)
                skipRestOfLine()
                return
            }

            // Otherwise we expect to be at the ‘=’ between the parameter and the condition.  We skip over it.
            assert(currChar == /* '=' */ 61)
            advance()

            // Collect the condition parameter pattern.
            let patternMarkIdx = currIdx
            scanUntil({ self.isAtEndOfLine || $0 == /* ']' */ 93 })
            let pattern = String(decoding: bytes[patternMarkIdx ..< currIdx], as: UTF8.self)
            if isAtEndOfLine {
                delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unterminated macro condition", lineNumber: lineNumber), parser: self)
                skipRestOfLine()
                return
            }

            // Otherwise we expect to be at the ‘]’ that ends the condition.  We skip over it.
            assert(currChar == /* ']' */ 93)
            advance()

            // Append a tuple representing the condition, consisting of parameter name and of pattern (a string).
            conditions.append((param, pattern))

            // Now that we’re back outside the condition, whitespace is no longer significant.
            skipWhitespaceAndComments()
        }

        // We expect to have found an equals sign.
        if currChar != /* '=' */ 61 {
            delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .missingEqualsInAssignment, level: .error, message: "expected a ‘=’, but found \(Character(Unicode.Scalar(currChar)))", lineNumber: lineNumber), parser: self)
            skipRestOfLine()
            return
        }

        // Skip over the equals sign.
        assert(currChar == /* '=' */ 61)
        advance()

        var chunks : [String] = []
        while let chunk = parseNonListAssignmentRHS() {
            // we have already ensured chunk doesn't have trailing spaces
            if chunk.hasSuffix("\\") {
                // we should drop the line continuation character from the chunk
                let trimmed = chunk.dropLast().trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { // no need to add empty lines
                    chunks.append(String(trimmed))
                }
                // and then we should read yet another line as the new chunk
                // however we might have already reached the end of file..
                scanEOL()
            } else {
                // this chunk was the last chunk
                chunks.append(chunk)
                // No need to read an extra line!
                break
            }
        }
        // Finally, now that we have the name, conditions, and value, we tell the delegate about it.
        let value = chunks.joined(separator: " ")
        delegate?.foundMacroValueAssignment(name, conditions: conditions, value: value, parser: self)
    }

    public func parseNonListAssignmentRHS() -> String? {
        skipWhitespaceAndComments()

        if isAtEndOfLine {
            return nil
        }
        // MARK: by here we know we are not dealing with purely whitespace line.


        // Now the value. We mostly just collect characters, but one quirk of the Xcode semantics is that `//` will still start a single-line comment.

        let valueMarkIdx = currIdx
        scanUntil({ self.isAtEndOfLine || self.isAtStartOfComment })
        var endIdx = currIdx

        // If we reached the start of a comment, we skip until the end of the line.
        if isAtStartOfComment {
            skipRestOfLine()
        }

        // Trim any trailing whitespace off of the end of the value.
        while endIdx > valueMarkIdx && bytes[endIdx-1].isASCIISpace {
            endIdx -= 1
        }

        // Trim any trailing semicolon (and preceding whitespace).
        if bytes[endIdx-1] == /* ';' */ 59 {
            endIdx -= 1
            while endIdx > valueMarkIdx && bytes[endIdx-1].isASCIISpace {
                endIdx -= 1
            }
        }

        // Make the value into a string.
        let value = String(decoding: bytes[valueMarkIdx ..< endIdx], as: UTF8.self)

        return value
    }


    /// Parses the input string as a sequence of lines.  Each line is terminated by one of: \n, \r, \r\n, Unicode Line Separator, or Unicode Paragraph Separator.  Single-line comments starting with `//` are supported and elided from the input text.  Any remaining non-empty line is expected to be either a preprocessor directive (indicated by a `#` as the first non-whitespace character) or a macro value assignment statement (parsed separately).
    public func parse() {
        // We consider the input string to be a sequence of lines of text.
        while !isAtEndOfStream {
            // A line may start with whitespace or comments.
            skipWhitespaceAndComments()

            // We may have reached the end of the line, or a preprocessor directive, or a macro value assignment.
            if isAtEndOfLine {
                // A completely empty line.
            }
            else if currChar == /* '#' */ 35 {
                // A preprocessor directive.
                parsePreprocessorDirective()
            }
            else if isValidMacroName1stChar(currChar) {
                // A macro value assignment.
                parseMacroValueAssignment()
            }
            else if !isAtEndOfLine {
                // Anything else is an error.
                delegate?.handleDiagnostic(MacroConfigFileDiagnostic(kind: .unexpectedCharacter, level: .error, message: "unexpected character ‘\(Character(Unicode.Scalar(currChar)))’", lineNumber: lineNumber), parser: self)
                skipRestOfLine()
            }

            // At this point we should have reached the end of the line (either a line terminator or the end of the stream; even in case of error, we should have skipped to the end-of-line).
            assert(isAtEndOfLine)
            scanEOL()
        }

        // At this point, we expect to have seen all of the input string.
        assert(isAtEndOfStream)
    }


    /// Returns the UTF-8 byte at the current position, which is zero if the cursor is currently at the very end of the string.
    private var currChar: UInt8 {
        assert(currIdx <= bytes.count)
        return (currIdx < bytes.count) ? bytes[currIdx] : 0
    }

    /// Returns the UTF-8 byte at the position immediately after the current position, which is zero if the cursor is currently at either the very end of the string or the position before the very end.
    private var nextChar: UInt8 {
        assert(currIdx <= bytes.count)
        return (currIdx + 1 < bytes.count) ? bytes[currIdx + 1] : 0
    }

    /// Returns the UTF-8 byte at the position immediately after the position immediately after the current position, which is zero if the cursor is currently at either the very end of the string, at the position before the very end, or at the position before that.
    private var nextNextChar: UInt8 {
        assert(currIdx <= bytes.count)
        return (currIdx + 2 < bytes.count) ? bytes[currIdx + 2] : 0
    }

    /// Advances the character to the next position, or does nothing if the cursor is currently already at end-of-string.
    private func advance(_ offset: Int = 1) {
        assert(currIdx <= bytes.count)
        currIdx = min(currIdx + offset, bytes.count)
    }

    /// Returns true if and only if the cursor is currently at end-of-string.
    private var isAtEndOfStream: Bool {
        assert(currIdx <= bytes.count)
        return currIdx == bytes.count
    }

    /// Returns true if and only if the cursor is currently at a whitespace character.  The characters considered whitespace are the same as the `isspace()` function, i.e. space (` `), horizontal tab (`\t`), vertical tab (`\v`), carriage return (`\r`), newline (`\n`), and form feed (`\f`).
    private var isAtWhitespace: Bool {
        return currChar == /* ' ' */ 32 || (currChar >= /* '\t' */ 9 && currChar <= /* '\r' */ 13)
    }

    /// Advances the cursor until it reaches end-of-string or until the block (which is invoked for each character) returns true.  Leaves the cursor at the character (if any) that caused the scan to stop.  Returns the (possibly empty) substring from the starting position to (but not including) the stop position.
    private func scanUntil(_ block: (UInt8) -> Bool) {
        // Record the starting index, and advance until we reach end-of-string or one of the specified stop characters.  After that we return the (possibly empty) substring.
        while !(isAtEndOfStream || block(currChar)) { advance() }
    }

    private func scanUntil(_ block: () -> Bool) {
        // Record the starting index, and advance until we reach end-of-string or one of the specified stop characters.  After that we return the (possibly empty) substring.
        while !(isAtEndOfStream || block()) { advance() }
    }

    /// Public static function to parse a macro name (with a possible condition set suffix) into a name string and a condition set.
    public static func parseMacroNameAndConditionSet(_ string: String) -> (String?, [(param: String, pattern: String)]?) {
        // We do this using our existing parsing code.
        class SingleMacroNameDelegate : MacroConfigFileParserDelegate {
            var macroName: String?
            var conditions: [(param: String, pattern: String)]?
            func foundPreprocessorInclusion(_ fileName: String, optional: Bool, parser: MacroConfigFileParser) -> MacroConfigFileParser? {
                return nil
            }
            func endPreprocessorInclusion() {
            }
            func foundMacroValueAssignment(_ macroName: String, conditions: [(param: String, pattern: String)], value: String, parser: MacroConfigFileParser) {
                self.macroName = macroName
                self.conditions = conditions.isEmpty ? nil : conditions
            }
            func handleDiagnostic(_ diagnostic: MacroConfigFileDiagnostic, parser: MacroConfigFileParser) {
            }
        }
        let delegate = SingleMacroNameDelegate()
        // FIXME: Passing an empty path here is bogus, but is needed because there are presently clients of this method outside the xcconfig parsing machinery.  Since our delegate never uses the path, this is okay for now.
        let parser = MacroConfigFileParser(byteString: (OutputByteStream() <<< string <<< "=").bytes, path: Path(""), delegate: delegate)
        parser.parse()
        return (delegate.macroName, delegate.conditions)
    }
}


/// Returns true if and only if `ch` is an uppercase or lowercase letter in the ASCII range (i.e., it matches '[A-Za-z]').
private func isAlpha(_ ch: UInt8) -> Bool {
    return (ch >= /* 'A' */ 65 && ch <= /* 'Z' */ 90) || (ch >= /* 'a' */ 97 && ch <= /* 'z' */ 122)
}

/// Returns true if and only if `ch` is a digit character (i.e., it matches '[0-9]').
private func isDigit(_ ch: UInt8) -> Bool {
    return (ch >= /* '0' */ 48 && ch <= /* '9' */ 57)
}

/// Returns true if and only if `ch` is a valid character for the first character of a macro name.  The characters considered valid are `A`...`Z`, `a`...`z`, and `_`.
private func isValidMacroName1stChar(_ ch: UInt8) -> Bool {
    return isAlpha(ch) || ch == /* '_' */ 95
}

/// Returns true if and only if `ch` is a valid character for the second and subsequent characters of a macro name.  The characters considered valid are `A`...`Z`, `a`...`z`, `0`...`9`, and `_`.
private func isValidMacroNameNthChar(_ ch: UInt8) -> Bool {
    return isAlpha(ch) || isDigit(ch) || ch == /* '_' */ 95
}


/// Encapsulates the callbacks that a .xcconfig file parser invokes during a parse.  All methods are optional.  Separating the actions into a protocol allows the .xcconfig parser to be used for a variety of tasks, and makes it easier to test and profile.  The parser is passed to each of the delegate methods, and its `position` property can be used to access the current index in the original string.  The parser is as lenient as possible, and tries to recover from errors as well as possible in order to preserve the Xcode semantics.  The delegate is guaranteed to see the entire contents of the input string, regardless of how many errors are discovered (some of that contents might be misparsed in the wake of errors, however).
public protocol MacroConfigFileParserDelegate {

    /// Invoked once for each #include directive.  Should create and return a newly configured MacroConfigFileParser object containing the contents to be included — in some cases it might be interesting for that parser to use the same delegate as this one, in other cases the client might want to create a separate subdelegate.  The `fileName` is guaranteed to be non-empty.  The `optional` flag set if the directive was marked as optional, i.e. if missing files should silently be skipped instead of causing errors.
    func foundPreprocessorInclusion(_ fileName: String, optional: Bool, parser: MacroConfigFileParser) -> MacroConfigFileParser?

    /// Invoked once for each #include directive. Should pop the path that had just completed parsing from parentPaths. This is used to maintain a list of paths that are still being parsed which helps to detect cycles.
    func endPreprocessorInclusion()

    /// Invoked once for each macro value assignment.  The `macroName` is guaranteed to be non-empty, but `value` may be empty.  Any macro conditions are passed as tuples in the `conditions`; parameters are guaranteed to be non-empty strings, but patterns may be empty.
    mutating func foundMacroValueAssignment(_ macroName: String, conditions: [(param: String, pattern: String)], value: String, parser: MacroConfigFileParser)

    /// Invoked if an error, warning, or other diagnostic is detected.
    func handleDiagnostic(_ diagnostic: MacroConfigFileDiagnostic, parser: MacroConfigFileParser)
}
