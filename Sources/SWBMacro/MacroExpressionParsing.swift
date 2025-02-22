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

/// A parser for string representations of macro expressions.  The parser itself is responsible only for parsing and error detection, and doesn’t perform any other actions such as building expression trees etc.  The delegate, which is required but whose methods are all optional, is informed of everything the parser finds as it advances through the string — this is quite similar to how SAX parsers work (http://www.wikipedia.org/wiki/Simple_API_for_XML).  The parser is as lenient as possible, and tries to recover from errors as well as possible in order to preserve the Xcode semantics.  The delegate is guaranteed to see the entire contents of the input string, regardless of how many errors are discovered (some of that contents might be misparsed as literals after errors have been found, however).
public final class MacroExpressionParser {
    public typealias Input = String.UTF8View.SubSequence

    /// Delegate that gets informed of everything the parser find while traversing the string (including any diagnostics).
    public let delegate: any MacroExpressionParserDelegate

    /// String representation that’s being parsed.  The index that’s accessible through the `position` property is an index into this string.
    public let string: String

    /// Current index into the string expression that’s being parsed.  Starts at `string.startIndex`, and goes to `string.endIndex` by the time we reach end-of-string.
    var currIdx: Input.Index

    /// The UTF8 view of the string being parsed.
    let utf8: Input

    /// Initializes the macro expression parser with the given string and delegate.  How the string is parsed depends on the particular parse method that’s invoked, such as `parseAsString()` or `parseAsStringList()`, and not on the configuration of the parser.
    public init(string: String, delegate: any MacroExpressionParserDelegate) {
        self.delegate = delegate
        self.string = string
        self.utf8 = string.utf8[...]
        self.currIdx = utf8.startIndex
    }


    /// Returns the current position of the scanner, as an index into the input string (which can be accessed through the `string` property).  This is commonly used by custom implementations of the parser delegate function callbacks — the description of each callback function specifies the guaranteed position of the parser in the input string at the time the callback function is invoked.
    private var position: Input.Index { return currIdx }


    /// Parses the contents of the input string as a macro expression using string semantics, i.e. one that doesn’t attach special significance to quotes and whitespace.  The parser’s delegate methods are invoked as the expression is parsed — this includes methods for detecting warnings and errors.  In accordance with historical semantics, parsing tries to recover after errors, so that as many errors as possible can be detected in one parse.
    public func parseAsString() {
        // Check for the edge case of a completely empty string.
        guard !isAtEnd else {
            delegate.foundLiteralStringFragment(utf8[currIdx..<utf8.endIndex], parser: self)
            return
        }

        // We consider the input string to be a sequence of literal fragments and/or substitution expressions.
        while !isAtEnd {
            // Check to see if we are at the start of a substitution subexpression.
            if currChar == UInt8(ascii: "$") {
                // We found a substitution subexpression of some kind.  We parse it, invoking delegate methods and advancing the cursor as we go.
                parseSubstitutionSubexpression(alwaysEvalAsString: true)
            }
            else {
                // Collect literal characters until we either find another substitution subexpression or reach end-of-string.
                if let literal = scanUntil(UInt8(ascii: "$")) {
                    // We found at least one literal character, so tell the delegate about it.
                    delegate.foundLiteralStringFragment(literal, parser: self)
                }
            }
        }

        // At this point, we expect to have seen all of the input string.
        assert(isAtEnd)
    }


    /// Parses the contents of the input string as a macro expression using string list semantics, i.e. one that respects quotes and backslashes, and that treats unquoted whitespace as string list element separators.  The parser’s delegate methods are invoked as the expression is parsed — this includes methods for detecting warnings and errors.  Of special note is that the delegate’s “list element separator” callback is invoked between list elements.  In accordance with historical semantics, parsing tries to recover after errors, so that as many errors as possible can be detected in one parse.
    public func parseAsStringList() {
        // Capture unquoted unescaped whitespace to be emitted only when evaluating as a string.  We don't capture it as a list separator because we never have a separator before the first element of the list.
        parseWhitespace(asListSeparator: false)

        // If we reached the end of the string, we’re done.
        if isAtEnd { return }

        // Otherwise, we found a non-whitespace character (or escaped whitespace).  We parse it as a string element (might be literal or non-literal), stopping immediately after it ends.
        parseQuotedExpressionStringElement()

        // Keep iterating until we reach the end of the string, breaking out when we find unquoted unescaped whitespace.
        while !isAtEnd {
            // Capture unquoted unescaped whitespace to be emitted only when evaluating as a string.  We capture it as a list separator.
            parseWhitespace(asListSeparator: true)

            // If we reached the end of the string, we’re done.
            if isAtEnd { break }

            // We found a non-whitespace character (or escaped whitespace).  We parse it as a string element (might be literal or non-literal), stopping immediately after it ends.
            parseQuotedExpressionStringElement()

            // We expect to have stopped on either whitespace or at end-of-string.
            assert(isAtEnd || isAtWhitespace)
        }

        // At this point, we expect to have seen all of the input string.
        assert(isAtEnd)
    }


    /// Private function that parses a chunk of whitespace, stopping at end-of-string or at the first non-whitespace character.  The cursor is expected to already be positioned at the first whitespace character of the chunk.  The parser’s delegate methods are invoked as the whitespace is traversed — this includes methods for detecting warnings and errors.
    private func parseWhitespace(asListSeparator parseAsListSeparator: Bool) {
        // If we're not at a whitespace character then we return.  (In principle this should never happen.)
        guard isAtWhitespace else { return }

        // Advance past the whitespace, remembering where it started.
        let markIdx = currIdx
        while isAtWhitespace { advance() }

        // If directed to capture the whitespace as a list separator, then we do so - *except* that if the whitespace is at the end of the string, then we don't treat it as a list separator.
        if parseAsListSeparator && !isAtEnd {
            delegate.foundListElementSeparator(utf8[markIdx ..< currIdx], parser: self)
        }
        else {
            delegate.foundStringFormOnlyLiteralStringFragment(utf8[markIdx ..< currIdx], parser: self)
        }
    }


    /// Private function that parses an entire substitution subexpresson, including its delimiters (if any).  This function expects to be called with the cursor positioned at the `$` character that starts the subexpression (this is asserted).  If `alwaysEvalAsString` is true, the delegate will be informed that this subexpression should always evaluate as a string — if it is false, then it should evaluate as either a string or a string list, depending on circumstances.  This does not affect parsing, but the delegate is expected to record this flag to use during macro expression evaluation.  This is used to pass down context about whether or not, for example, a particular substitution expression occurs inside quotes.  The parser’s delegate methods are invoked as the expression is parsed — this includes methods for detecting warnings and errors.  In accordance with historical semantics, parsing tries to recover after errors, so that as many errors as possible can be detected in one parse.
    private func parseSubstitutionSubexpression(alwaysEvalAsString: Bool) {
        // We expect to be called with the cursor positioned at the ‘$’ that starts the substitution expression (this is a private method and that assumption is part of our documented contract).
        precondition(currChar == UInt8(ascii: "$"))
        let origIdx = currIdx

        // Tell the delegate that we’ve found is the start of a macro substitution subexpression (even an escaped expression, such as “$$”, or a single “$” is considered a substitution subexpression).
        delegate.foundStartOfSubstitutionSubexpression(alwaysEvalAsString: alwaysEvalAsString, parser: self)

        // Skip over the ‘$’ character.  This might put us at end-of-string; the logic below handles that correctly.
        advance()

        // How we proceed depends on what follows the ‘$’.
        if isAtEnd {
            // We ran out of characters right after the ‘$’.  We emit an error about that.
            delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: origIdx..<currIdx, kind: .trailingDollarSign, level: .error), parser: self)

            // Also tell the delegate that we’ve found a literal ‘$’ (historically, we’ve treated dangling ‘$’ characters as literal).
            delegate.foundLiteralStringFragment(utf8[origIdx..<currIdx], parser: self)
        }
        else if let closeDelim = getClosingDelimiter(currChar!) {
            // We found the start of a macro subexpression.  We parse it, keeping in mind that it might consist of other subexpressions nested to an arbitrary depth.

            // Check for deprecated delimiters.
            if currChar != UInt8(ascii: "(") {
                // If not an opening parenthesis, it’s deprecated.  We still accept it (for historical reasons), but we want people to start moving away from the deprecated forms so that we can eventually remove support for them.
                delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: origIdx..<utf8.index(after: currIdx), kind: .deprecatedMacroRefSyntax, level: .warning), parser: self)
            }

            // Skip past the open delimiter.  This might put us at end-of-string; the logic below handles that correctly.
            advance()

            // Remember the current character index, so we can detect completely empty macro name expressions.
            let nameIdx = currIdx

            // Tell the delegate that we’ve found the start of a macro name (the “XYZ” part of “$(XYZ:op)”.
            delegate.foundStartOfMacroName(parser: self)

            // Recursively parse the macro name expression.  Note that we always parse it to evaluate as a string.  We pass down the closing delimiter that matches the opening delimiter we saw, and it also stops at the next ‘:’ character as well as end-of-string.
            parseSubstitutionSubexpressionFragment(alwaysEvalAsString: true, delimiter: closeDelim)

            // We expect to have stopped at end-of-string, at a ‘:’, or at a closing delimiter.
            assert(isAtEnd || currChar == UInt8(ascii: ":") || currChar == closeDelim)

            // Check for some common kinds of errors.
            if isAtEnd {
                // We unexpectedly reached end-of-string before we found a closing delimiter, so we emit an error.
                delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: origIdx..<currIdx, kind: .unterminatedMacroSubexpression, level: .error), parser: self)
            }
            else if currIdx == nameIdx {
                // We didn’t reach end-of-string but we also didn’t find a macro name at all, so we emit an error.
                delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: currIdx..<currIdx, kind: .missingMacroName, level: .error), parser: self)
            }

            // Tell the delegate that we’ve found the end of the macro name.
            delegate.foundEndOfMacroName(wasBracketed: true, parser: self)

            // See where we ended up.  If we stopped at a ‘:’, then we parse operators.  We keep parsing them for as long as we end up at a colon.
            while currChar == UInt8(ascii: ":") {
                // Skip past the ‘:’ character.  This might put us at end-of-string, but the logic below handles that correctly.
                advance()

                // Scan the operator name by going until the next ‘=’ or ‘:’ or closing delimiter, or until end-of-string.
                let possibleOperName = scanUntil({ !isValidOperatorNameChar($0) })

                // Check for a variety of error conditions.  We could catch them with fewer tests but want to provide specific error messages.
                if isAtEnd {
                    // We unexpectedly reached end-of-string, so we emit an error.
                    delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: currIdx..<currIdx, kind: .unterminatedMacroSubexpression, level: .error), parser: self)
                }
                else if currChar == UInt8(ascii: ":") || currChar == closeDelim {
                    // We have a retrieval operator, which retrieves a part of the evaluated macro value (e.g. extracts a directory, a file name, or file suffix).

                    // Check if we have an operator name.
                    if let operName = possibleOperName {
                        // We have an operator name, so we tell the delegate that we found a retrieval operator.
                        delegate.foundRetrievalOperator(operName, parser: self)
                    }
                    else {
                        // We don’t have an operator name, so we report an error.
                        delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: currIdx..<currIdx, kind: .missingOperatorName, level: .error), parser: self)
                    }
                }
                else if currChar == UInt8(ascii: "=") {
                    // We have a replacement operator, which replaces a part of the evaluated macro value with a different value (e.g. changes a suffix).

                    // Skip past the ‘=’ character.  This might put us at end-of-string; the logic below handles that correctly.
                    advance()

                    // Check if we have an operator name.
                    if let operName = possibleOperName {
                        // We have an operator name, so we tell the delegate that we found the start of a replacement operator.
                        delegate.foundStartOfReplacementOperator(operName, parser: self)

                        // Recursively parse the operand expression.  Note that we always parse it to evaluate as a string.  We pass down the closing delimiter that matches the opening delimiter we saw, and it also stops at the next ‘:’ character as well as end-of-string.
                        parseSubstitutionSubexpressionFragment(alwaysEvalAsString: alwaysEvalAsString, delimiter: closeDelim)

                        // We expect to have stopped at either end-of-string or the next ‘:’ or closing delimiter.
                        assert(isAtEnd || currChar == UInt8(ascii: ":") || currChar == closeDelim)

                        // Tell the delegate that we found a replacement operator.  While parsing the macro evaluation string that evaluates to the replacement, we’ll have called out to the delegate for all of the parts of it, so it will already have seen it at this point.
                        delegate.foundEndOfReplacementOperator(operName, parser: self)

                        // We also want to check for end-of-string here for diagnostic purposes.
                        if isAtEnd {
                            // We unexpectedly reached end-of-string, so we emit an error.
                            delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: currIdx..<currIdx, kind: .unterminatedMacroSubexpression, level: .error), parser: self)
                        }
                    }
                    else {
                        // We don’t have an operator name, so we report an error.
                        delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: currIdx..<currIdx, kind: .missingOperatorName, level: .error), parser: self)

                        // Skip ahead until the next ‘:’ or closing delimiter, without emitting them as literals.
                        scanUntil(UInt8(ascii: ":"), closeDelim)
                    }
                }
                else {
                    // Otherwise, we have found an invalid character for an operator name.
                    delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: currIdx..<utf8.index(after: currIdx), kind: .invalidOperatorCharacter, level: .error), parser: self)

                    // Skip ahead until the next ‘:’ or closing delimiter, without emitting them as literals.
                    scanUntil(UInt8(ascii: ":"), closeDelim)
                }
            }

            // We expect to have reached either the closing delimiter or the end of the string.
            assert(isAtEnd || currChar == closeDelim)

            // Skip over the closing delimiter, if that’s what stopped us.  This might put us at end-of-string; the logic below handles that correctly.
            if currChar == closeDelim {
                advance()
            }
        }
        else if isValidMacroName1stChar(currChar) {
            // Looks like a valid expression of the deprecated form “$MACRO” (without parentheses).
            let nameIdx = currIdx

            // First of all we tell the delegate about it.
            delegate.foundStartOfMacroName(parser: self)

            // Skip over the first character (which we already recognized in the if-conditional).  This might put us at end-of-string; the logic below handles that correctly.
            advance()

            // Skip ahead until we find a character that isn’t a valid macro name character (or until we reach end-of-string).
            while isValidMacroNameNthChar(currChar) {
                advance()
            }

            // Now the macro name is in the range `macroNamePtr`...`ptr`.  We know that the range isn’t empty; otherwise we wouldn’t even be here.
            assert(currIdx > nameIdx)

            // Tell the delegate about the literal string we found.
            delegate.foundLiteralStringFragment(utf8[nameIdx ..< currIdx], parser: self)

            // Check to see if we stopped at a substitution expression, and if it’s followed by a `(`.  This is kind of a hack for projects that have malformed macro expressions.  See <rdar://problem/12769727> and <rdar://problem/13174585>.
            if currChar == UInt8(ascii: "$") && nextChar == UInt8(ascii: "(") {
                // It is, so parse the macro expression as part of the macro name.  This function will call out to the delegate, as appropriate.
                parseSubstitutionSubexpression(alwaysEvalAsString: true)
            }

            // Tell the delegate that we’ve found the end of the macro name.
            delegate.foundEndOfMacroName(wasBracketed: false, parser: self)
        }
        else {
            // We found a ‘$’ character followed by something other than parentheses or an alphanumeric character.  We treat it as a literal ‘$’.
            let fragment = utf8[origIdx..<currIdx]

            // If we two consecutive ‘$’ characters, we skip the second one of them, so we end up with just a literal ‘$’ (this is because “$$” is an escape for “$”).
            if currChar == UInt8(ascii: "$") {
                advance()
            }
            else {
                // FIXME: Should we also warn about stray ‘$’ characters? Doing so would might cause a lot of noise for expressions that in Xcode work fine today (with the ‘$’ getting treated as a literal).
            }

            // Tell the delegate that we’ve found a literal ‘$’.
            delegate.foundLiteralStringFragment(fragment, parser: self)
        }

        // Tell the delegate that we’ve found the end of a macro substitution expression (even an escaped expression, such as “$$”, or a single ‘$’ is considered a substitution).
        delegate.foundEndOfSubstitutionSubexpression(alwaysEvalAsString: alwaysEvalAsString, parser: self)
    }


    /// Private function that parses a delimited fragment of a substitution subexpresson.  The value of the `alwaysEvalAsString` flag will be passed down to any invocations of parseSubstitutionSubexpression() performed by this function.  This function stops parsing when it reaches the end-of-string or a colon character or the delimiter given as a parameter.  The parser’s delegate methods are invoked as the subexpression fragment is parsed — this includes methods for detecting warnings and errors.  In accordance with historical semantics, parsing tries to recover after errors, so that as many errors as possible can be detected in one parse.
    private func parseSubstitutionSubexpressionFragment(alwaysEvalAsString: Bool, delimiter: UInt8) {
        // Loop over the rest of the string (breaking out if we reach either a colon or the closing delimiter we were given).
        while !isAtEnd {
            // First parse any literal string fragment, stopping at end-of-string, ‘$’, ‘:’, or the closing delimiter we were given).
            if let literal = scanUntil(UInt8(ascii: "$"), UInt8(ascii: ":"), delimiter) {
                // We found at least one literal character.
                delegate.foundLiteralStringFragment(literal, parser: self)
            }

            // We expect to have stopped at either end-of-string, at a “$”, at a “:”, or at the closing delimiter we were given.
            assert(isAtEnd || currChar == UInt8(ascii: "$") || currChar == UInt8(ascii: ":") || currChar == delimiter)

            // Break out of the look if we stopped in any other way than at a `$` character.
            if isAtEnd || currChar != UInt8(ascii: "$") { break }

            // We only get here if we found the start of a substitution expression.  We parse it, invoking delegate methods and updating the pointer as we go.
            parseSubstitutionSubexpression(alwaysEvalAsString: alwaysEvalAsString)
        }

        // At this point, we expect to have reached either end-of-string or one of the stop characters.
        assert(isAtEnd || currChar == UInt8(ascii: ":") || currChar == delimiter)
    }


    /// Private function that parses a single element of a quoted null-terminated string, stopping at end-of-string or at the first unquoted, unescaped whitespace.  The cursor is expected to already be positioned at the first non-whitespace character of the string element.  The parser’s delegate methods are invoked as the subexpression fragment is parsed — this includes methods for detecting warnings and errors.  In accordance with historical semantics, parsing tries to recover after errors, so that as many errors as possible can be detected in one parse.
    private func parseQuotedExpressionStringElement() {
        // We’ll be moving over the input string.  As we do, we keep track of when we’re inside double quotes, single quotes, or no quotes at all.
        enum QuoteState { case noQuotes; case doubleQuotes; case singleQuotes }
        var currentQuotes = QuoteState.noQuotes

        // We expect to be called with the current scanner position on a non-whitespace character (and not at the end-of-string).
        precondition(!isAtEnd && !isAtWhitespace)

        // Mark this position as the start of a literal run of characters.  We’ll move this mark up as we emit fragments of literal string.
        var markIdx = currIdx

        // Scan literal string fragments, handling double-quotes, single-quotes, escape backslashes, and ‘$’ macro expressions.  We stop at end-of-string or at the first unquoted/unescaped whitespace.
        repeat {
            // Check for and handle characters that have semantic meaning.
            if currChar == UInt8(ascii: "\\") {
                // Escape character — we treat the next character literally.
                if markIdx < currIdx { delegate.foundLiteralStringFragment(utf8[markIdx ..< currIdx], parser: self); markIdx = currIdx }
                // Record the escape character itself as a character to be emitted literally when evaluating the expression as a string (rather than a string-list).
                delegate.foundStringFormOnlyLiteralStringFragment(utf8[currIdx ... currIdx], parser: self)
                advance()
                if isAtEnd {
                    // We ran out of characters — emit an error and leave.
                    delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: markIdx..<currIdx, kind: .trailingEscapeCharacter, level: .error), parser: self)
                }
                else {
                    // Otherwise, exclude the backslash from the literal range, and advance past the literal character.  This might put us at the end, which is OK.
                    markIdx = currIdx
                    advance()
                }
            }
            else if currChar == UInt8(ascii: "$") {
                // Dollar character — we parse it as a substitution subexpression.  If we’re inside quotes, the delegate will be asked to always evaluate it as a string.
                if markIdx < currIdx { delegate.foundLiteralStringFragment(utf8[markIdx ..< currIdx], parser: self); markIdx = currIdx }
                parseSubstitutionSubexpression(alwaysEvalAsString:(currentQuotes != .noQuotes))
                markIdx = currIdx
            }
            else if currChar == UInt8(ascii: "\"") && currentQuotes != .singleQuotes {
                // Double quotes — we toggle the quote state and advance to the next character.  But we special-case consecutive quotes to make sure we emit an empty literal.
                if markIdx < currIdx { delegate.foundLiteralStringFragment(utf8[markIdx ..< currIdx], parser: self); markIdx = currIdx }
                assert(currentQuotes == .noQuotes || currentQuotes == .doubleQuotes)
                // Record the quote character itself as a character to be emitted literally when evaluating the expression as a string (rather than a string-list).
                delegate.foundStringFormOnlyLiteralStringFragment(utf8[currIdx ... currIdx], parser: self)
                advance()
                if currentQuotes == .noQuotes && currChar == UInt8(ascii: "\"") {
                    // Deal with a pair of adjacent double-quotes (we emit an empty string fragment, which is important it happens to be a list element).
                    delegate.foundLiteralStringFragment(utf8[currIdx..<currIdx], parser: self)
                    // Record the quote character itself as a character to be emitted literally when evaluating the expression as a string (rather than a string-list).
                    delegate.foundStringFormOnlyLiteralStringFragment(utf8[currIdx ... currIdx], parser: self)
                    advance()
                }
                else {
                    // Toggle the current quote state.
                    currentQuotes = (currentQuotes == .noQuotes) ? .doubleQuotes : .noQuotes
                }
                // Either way, we move up the marked starting index for the next literal fragment.
                markIdx = currIdx
            }
            else if currChar == UInt8(ascii: "\'") && currentQuotes != .doubleQuotes {
                // Single quotes — we toggle the quote state and advance to the next character.  But we special-case consecutive quotes to make sure we emit an empty literal.
                if markIdx < currIdx { delegate.foundLiteralStringFragment(utf8[markIdx ..< currIdx], parser: self); markIdx = currIdx }
                assert(currentQuotes == .noQuotes || currentQuotes == .singleQuotes)
                // Record the quote character itself as a character to be emitted literally when evaluating the expression as a string (rather than a string-list).
                delegate.foundStringFormOnlyLiteralStringFragment(utf8[currIdx ... currIdx], parser: self)
                advance()
                if currentQuotes == .noQuotes && currChar == UInt8(ascii: "\'") {
                    // Deal with a pair of adjacent single-quotes (we emit an empty string fragment, which is important it happens to be a list element).
                    delegate.foundLiteralStringFragment(utf8[currIdx..<currIdx], parser: self)
                    // Record the quote character itself as a character to be emitted literally when evaluating the expression as a string (rather than a string-list).
                    delegate.foundStringFormOnlyLiteralStringFragment(utf8[currIdx ... currIdx], parser: self)
                    advance()
                }
                else {
                    // Toggle the current quote state.
                    currentQuotes = (currentQuotes == .noQuotes) ? .singleQuotes : .noQuotes
                }
                // Either way, we move up the marked starting index for the next literal fragment.
                markIdx = currIdx
            }
            else if currentQuotes == .noQuotes && isAtWhitespace {
                // Unquoted, unescaped whitespace — we’re done with this list element.
                break
            }
            else {
                // Otherwise, just keep advancing until we reach a semantically meaningful character.
                advance()
            }
        }
        while !isAtEnd

        // We expect to have ended up with the current scanner position on either a whitespace character or at end-of-string.
        precondition(isAtEnd || isAtWhitespace)

        // Emit any literal string fragment that we’ve skipped over but haven’t yet emitted.
        if markIdx < currIdx { delegate.foundLiteralStringFragment(utf8[markIdx ..< currIdx], parser: self) }

        // If we’ve reached end-of-string but we’re still inside quotes, we have an unterminated-quote situation.
        if currentQuotes != .noQuotes {
            delegate.handleDiagnostic(MacroExpressionDiagnostic(string: string, range: currIdx..<currIdx, kind: .unterminatedQuotation, level: .error), parser: self)
        }
    }


    /// Returns the character at the current position, or nil if the cursor is currently at the very end of the string.
    private var currChar: UInt8? {
        assert(currIdx <= utf8.endIndex)
        if currIdx == utf8.endIndex { return nil }
        return utf8[currIdx]
    }

    /// Returns the character at the position immediately after the current position, or nil if the cursor is currently at either the very end of the string or the position before the very end.
    private var nextChar: UInt8? {
        assert(currIdx <= utf8.endIndex)
        if utf8.isEmpty { return nil }
        let next = utf8.index(after: currIdx)
        if next == utf8.endIndex { return nil }
        return utf8[next]
    }

    /// Advances the character to the next position, or does nothing if the cursor is currently already at end-of-string.
    private func advance() {
        if !isAtEnd {
            currIdx = utf8.index(after: currIdx)
        }
    }

    /// Returns true if and only if the cursor is currently at end-of-string.
    private var isAtEnd: Bool {
        assert(currIdx <= utf8.endIndex)
        return currIdx == utf8.endIndex
    }

    /// Returns true if and only if the cursor is currently at a whitespace character.
    private var isAtWhitespace: Bool {
        assert(currIdx <= utf8.endIndex)
        guard let c = currChar else { return false }
        return c == UInt8(ascii: " ") || (c >= UInt8(ascii: "\t") && c <= UInt8(ascii: "\r"))
    }

    /// Advances the cursor until it reaches end-of-string or until the block (which is invoked for each character) returns true.  Leaves the cursor at the character (if any) that caused the scan to stop.  Returns the substring from the starting position to (but not including) the stop position, or nil if no characters at all were scanned.
    @discardableResult
    private func scanUntil(_ block: (UInt8) -> Bool) -> Input? {
        // Record the starting index, and advance until we reach end-of-string or one of the specified stop characters.  After that we return the (possibly empty) substring.
        let origIdx = currIdx
        while !(isAtEnd || block(currChar!)) { advance() }
        return currIdx > origIdx ? utf8[origIdx ..< currIdx] : nil
    }

    /// Convenience function that the cursor until it reaches end-of-string or the specified stop character, leaving the cursor at the character (if any) that caused the scan to stop.  Returns the substring from the starting position to (but not including) the stop position, or nil if no characters at all were scanned.
    @discardableResult
    private func scanUntil(_ ch1: UInt8) -> Input? {
        return scanUntil({ $0 == ch1 })
    }

    /// Convenience function that the cursor until it reaches end-of-string or either of the specified stop characters, leaving the cursor at the character (if any) that caused the scan to stop.  Returns the substring from the starting position to (but not including) the stop position, or nil if no characters at all were scanned.
    @discardableResult
    private func scanUntil(_ ch1: UInt8, _ ch2: UInt8) -> Input? {
        return scanUntil({ $0 == ch1 || $0 == ch2 })
    }

    /// Convenience function that the cursor until it reaches end-of-string or any one of the specified stop characters, leaving the cursor at the character (if any) that caused the scan to stop.  Returns the substring from the starting position to (but not including) the stop position, or nil if no characters at all were scanned.
    @discardableResult
    private func scanUntil(_ ch1: UInt8, _ ch2: UInt8, _ ch3: UInt8) -> Input? {
        return scanUntil({ $0 == ch1 || $0 == ch2 || $0 == ch3 })
    }
}


/// Private function that returns the closing delimiter that corresponds to a particular opening delimiter, or nil if `ch` is not, in fact, an opening delimiter.  In addition to the official delimiter pair `(`...`)`, the current implementation of this function supports the deprecated delimiter pairs `{`...`}` and `[`...`]`.  The parser will emit a deprecated-delimiter warning for any delimiter pair other than `(`...`)`.
private func getClosingDelimiter(_ ch: UInt8) -> UInt8? {
    // The set of delimiters we support is historical.  We do emit warnings about delimiters other than ‘(’.
    switch ch {
    case UInt8(ascii: "("): return UInt8(ascii:  ")")
    case UInt8(ascii:  "{"): return UInt8(ascii:  "}")
    case UInt8(ascii:  "["): return UInt8(ascii:  "]")
    default: return nil
    }
}

/// Returns true if and only if `ch` is an English alphabet character (i.e., it matches '[A-Za-z]').
private func isAlpha(_ ch: UInt8) -> Bool {
    return (ch >= UInt8(ascii: "A") && ch <= UInt8(ascii: "Z")) || (ch >= UInt8(ascii: "a") && ch <= UInt8(ascii: "z"))
}

/// Returns true if and only if `ch` is a valid character for the first character of a macro name.  The characters considered valid are `A`...`Z`, `a`...`z`, and `_`.
private func isValidMacroName1stChar(_ chOpt: UInt8?) -> Bool {
    guard let ch = chOpt else { return false }
    return isAlpha(ch) || ch == UInt8(ascii: "_")
}

/// Returns true if and only if `ch` is a valid character for the second and subsequent characters of a macro name.  The characters considered valid are `A`...`Z`, `a`...`z`, `0`...`9`, `.`, and `_`.
private func isValidMacroNameNthChar(_ chOpt: UInt8?) -> Bool {
    guard let ch = chOpt else { return false }
    return isAlpha(ch) || (ch >= UInt8(ascii: "0") && ch <= UInt8(ascii: "9")) || ch == UInt8(ascii: ".") || ch == UInt8(ascii: "_")
}

/// Returns true if and only if `ch` is a valid character for a macro substitution operator name.  The characters considered valid are `A`...`Z`, `a`...`z`, `0`...`9`, `-`, `+`, `.`, and `_`.
private func isValidOperatorNameChar(_ chOpt: UInt8?) -> Bool {
    guard let ch = chOpt else { return false }
    return isAlpha(ch) || (ch >= UInt8(ascii: "0") && ch <= UInt8(ascii: "9")) || ch == UInt8(ascii: "-") || ch == UInt8(ascii: "+") || ch == UInt8(ascii: ".") || ch == UInt8(ascii: "_")
}


/// Encapsulates the callbacks that a macro expression parser invokes during a parse.  All methods are optional.  Separating the actions into a protocol allows the macro expression parser to be used for a variety of tasks, and makes it easier to test and profile.  The parser is passed to each of the delegate methods, and its `position` property can be used to access the current index in the original string.  The parser is as lenient as possible, and tries to recover from errors as well as possible in order to preserve the Xcode semantics.  The delegate is guaranteed to see the entire contents of the input string, regardless of how many errors are discovered (some of that contents might be misparsed as literals after errors have been found, however).
public protocol MacroExpressionParserDelegate {
    typealias Input = MacroExpressionParser.Input

    /// Invoked for each contiguous range of literal characters.  The `string` parameter may be empty — for example, there is always a delegate callback with an empty string literal between any two calls to `foundListElementSeparator()`.  Any given range of literal characters in the input string may result in multiple consecutive `foundLiteralStringFragment()` calls.  This method is always invoked with the parser’s cursor positioned immediately after the literal string fragment.
    func foundLiteralStringFragment(_ string: Input, parser: MacroExpressionParser)

    /// Invoked for each contiguous range of literal characters which should only be included when evaluating the expression as a string (rather than a string-list).  The `string` parameter may be empty.  This method is always invoked with the parser’s cursor positioned immediately after the literal string fragment.
    func foundStringFormOnlyLiteralStringFragment(_ string: Input, parser: MacroExpressionParser)

    /// Invoked at the start of a macro substitution expression of the form `$(XYZ)` or `$XYZ`.  The `alwaysEvalAsString` parameter is true if the subexpression occurs in a context that should always use string evaluation — for example if it occurs in a string that’s being parsed using string semantics, or if it occurs in a string list but within quotes, etc.  This call is always balanced by a later call to `foundEndOfSubstitutionSubexpression()`.  This method is always invoked with the parser’s cursor positioned at the `$` character that starts the substitution subexpression.
    func foundStartOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser)

    /// Invoked at the start of the macro name component inside a macro substitution expression of the form `$(XYZ)` or `$XYZ`.  This call is always balanced by a later call to `foundEndOfMacroName()`.  This method is always invoked with the parser’s cursor positioned at the first character of the macro name.
    func foundStartOfMacroName(parser: MacroExpressionParser)

    /// Invoked at the end of the macro name component inside a macro substitution expression of the form `$(XYZ)` or `$XYZ`.  This call always balances an earlier call to `foundStartOfMacroName()`.  This callback function is always invoked with the parser’s cursor positioned immediately after the macro name.
    func foundEndOfMacroName(wasBracketed: Bool, parser: MacroExpressionParser)

    /// Invoked for each “retrieval” operator found inside a macro substitution expression of the form `$(XYZ)`.  The operator name is always non-empty.  This callback function is always invoked with the parser’s cursor positioned immediately after the operator name.
    func foundRetrievalOperator(_ operatorName: Input, parser: MacroExpressionParser)

    /// Invoked at the start of a “replacement” operator found inside a macro substitution expression of the form `$(XYZ)`.  The operator name is always non-empty.  This call is always balanced by a later call to `foundEndOfReplacementOperator()`.  This callback function is always invoked with the parser’s cursor positioned immediately after the `=` character that follows the operator name; this is the same as the start position of the replacement operand subexpression.
    func foundStartOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser)

    /// Invoked at the end of a “replacement” operator found inside a macro substitution expression of the form `$(XYZ)`.  This call always balances an earlier call to `foundStartOfReplacementOperator()`.  The same operator name is passed in both calls.  This callback function is always invoked with the parser’s cursor positioned immediately after the operand expression.  Note that if the operand expression is empty, the `foundEndOfReplacementOperator()` call will occur immediately after the `foundStartOfReplacementOperator()` call, and the cursor position will be unchanged between the two.
    func foundEndOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser)

    /// Invoked at the end of a macro substitution expression of the form `$(XYZ)` or `$XYZ`.  The `alwaysEvalAsString` parameter is true if the subexpression occurs in a context that should always use string evaluation — for example if it occurs in a string that’s being parsed using string semantics, or if it occurs in a string list but within quotes, etc.  This call is balances an earlier call to `foundStartOfSubstitutionSubexpression()`.  The value of `alwaysEvalAsString` is always the same in both balanced calls.  This callback function is always invoked with the parser’s cursor positioned immediately after the last character of the substitution subexpression.
    func foundEndOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser)

    /// Invoked whenever a “list element separator” is found.  A list element separator indicates where one string element ends and another starts.  This callback function will only be called when parsing a string list — there are no separators in a single atomic string.  This callback function is always invoked with the parser’s cursor positioned immediately after the whitespace that precedes the list element.  The provided string will be emitted when evaluating the expression as a string (rather than a string list) so that whitespace is full preserved in that form.
    func foundListElementSeparator(_ string: Input, parser: MacroExpressionParser)

    /// Invoked for each diagnostic generated while parsing a string.  Every diagnostic has a level, such as warning or error, and a kind that indicates the type of diagnostic.  Some diagnostics denote deprecation issues, and may contain suggestions for changes that should be made to the input string.  For this callback, the `position` property of the parser is not guaranteed to be at any particular spot — rather, the diagnostic contains an index range that specifies the location of the issue.
    func handleDiagnostic(_ diagnostic: MacroExpressionDiagnostic, parser: MacroExpressionParser)
}
