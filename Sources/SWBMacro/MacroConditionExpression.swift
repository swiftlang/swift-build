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

import SWBUtil

// MARK: MacroConditionExpression classes


/// A parsed condition which can be evaluated in the context of a scope to return a boolean or string result.  This is used in build options to define conditions under which the option should contribute arguments to a command line.
public class MacroConditionExpression: CustomStringConvertible, @unchecked Sendable
{
    /// Parse a ``MacroConditionExpression`` object from ``string``.
    ///
    /// - parameter string: The string from which the expression will be parsed.
    /// - parameter macroNamespace: If passed, this will be used to parse any strings which might contain build settings.  If not passed, then the ``BuiltinMacros`` namespace will be used.
    /// - parameter diagnosticsHandler: If any errors are encountered during parsing, an error string will be passed to this block.  Defaults to an empty block.
    /// - returns: The parsed expression, or nil if any errors were encountered.
    public class func fromString(_ string: String, macroNamespace: MacroNamespace, diagnosticsHandler: @escaping (((String) -> Void)) = {_ in }) -> MacroConditionExpression?
    {
        // If the string is empty, then so is the expression.
        if(string.isEmpty)
        {
            return MacroConditionStringConstantExpression(macroNamespace.parseString(string))
        }

        // Initialize a scanner state and a parser state for the string contents.
        let scanner = ScannerState(string)
        let parser = ParserState(scanner, macroNamespace)

        // Create an expression tree by parsing the string contents.
        var error: String? = nil
        var expr = parseExpression(parser) { diagnostic in
            error = diagnostic
            diagnosticsHandler(diagnostic)
        }
        if parser.nextToken.type != .eof  &&  error == nil
        {
            // No error was detected but we still have more, unparsed tokens at the end of the string this early termination indicates an error.
            error = "expected operator or end-of-string, but found '\(parser.scanner.stringForToken(parser.nextToken))' at offset \(parser.nextToken.offset)"
            diagnosticsHandler(error!)
            expr = nil
        }

        // Return the expression, or nil if an error occurred.
        return error != nil ? nil : expr
    }

    /// Evaluate the receiver as a string.
    public func evaluateAsString(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String
    {
        fatalError("This method is a subclass responsibility.")
    }

    /// Evaluate the receiver as a boolean.
    public func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        fatalError("This method is a subclass responsibility.")
    }

    /**
        Parse an expression, which has the following format:

            expression:
                ternary-conditional-expression
                ;
    */
    private class func parseExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        return parseTernaryConditionalExpression(parser, diagnosticsHandler)
    }

    /**
        Parse a ternary conditional expression, which has the following format:

            ternary-conditional-expression:
                logical-OR-expression
                | logical-OR-expression '?' expression ':' ternary-conditional-expression
                ;
     */
    private class func parseTernaryConditionalExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        var expr = parseLogicalORExpression(parser, diagnosticsHandler)
        if parser.nextToken.type == .questionMark
        {
            // logical-OR-expression '?' expression ':' ternary-conditional-expression
            parser.step()
            let thenExpr = (parser.nextToken.type == .colon) ? expr : parseExpression(parser, diagnosticsHandler)
            if parser.nextToken.type == .colon
            {
                parser.step()
                let elseExpr = parseExpression(parser, diagnosticsHandler)
                expr = MacroConditionTernaryConditionalExpression(condExpr: expr, thenExpr: thenExpr, elseExpr: elseExpr)
            }
            else
            {
                diagnosticsHandler("expected ':' but found '\(parser.scanner.stringForToken(parser.nextToken))' at offset \(parser.nextToken.offset)")
            }
        }
        return expr
    }

    /**
        Parse a logical-OR expression, which has the following format:

            logical-OR-expression:
                logical-AND-expression
                | logical-OR-expression '||' logical-AND-expression
                ;

        '``or``' is a synonym for '``||``'.
     */
    private class func parseLogicalORExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        var expr = parseLogicalANDExpression(parser, diagnosticsHandler)
        if parser.nextToken.type == .or
        {
            // logical-AND-expression '&&' equality-expression
            repeat
            {
                parser.step()
                expr = MacroConditionLogicalORExpression(leftExpr: expr, rightExpr: parseLogicalANDExpression(parser, diagnosticsHandler))
            } while parser.nextToken.type == .or
        }
        return expr
    }

    /**
        Parse a logical-AND expression, which has the following format:

            logical-AND-expression:
                equality-expression
                | logical-AND-expression '&&' equality-expression
                ;

        '``and``' is a synonym for '``&&``'.
     */
    private class func parseLogicalANDExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        var expr = parseEqualityExpression(parser, diagnosticsHandler)
        if parser.nextToken.type == .and
        {
        // logical-AND-expression '&&' equality-expression
            repeat
            {
                parser.step()
                expr = MacroConditionLogicalANDExpression(leftExpr: expr, rightExpr: parseEqualityExpression(parser, diagnosticsHandler))
            } while parser.nextToken.type == .and
        }
        return expr
    }

    /**
        Parse an equality expression, which has the following format:

            equality-expression:
                relational-expression
                | equality-expression '==' relational-expression
                | equality-expression '!=' relational-expression
                | equality-expression 'contains' relational-expression
                ;

        '``is``' is a synonym for '``==``', and '``isnot``' is a synonym for '``!=``'.
     */
    private class func parseEqualityExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        var expr = parseRelationalExpression(parser, diagnosticsHandler)
        if parser.nextToken.type == .equals  ||  parser.nextToken.type == .notEquals  ||  parser.nextToken.type == .contains
        {
            //   equality-expression '==' relational-expression
            // | equality-expression '!=' relational-expression
            // | equality-expression 'CONTAINS' relational-expression
            repeat
            {
                let tokenType = parser.nextToken.type
                parser.step()
                switch tokenType
                {
                case .equals:
                    expr = MacroConditionEqualityExpression(leftExpr: expr, rightExpr: parseRelationalExpression(parser, diagnosticsHandler))
                case .notEquals:
                    expr = MacroConditionInequalityExpression(leftExpr: expr, rightExpr: parseRelationalExpression(parser, diagnosticsHandler))
                case .contains:
                    expr = MacroConditionContainsExpression(leftExpr: expr, rightExpr: parseRelationalExpression(parser, diagnosticsHandler))
                default:
                    // Kind of an odd default, but it reproduces the original behavior.
                    expr = MacroConditionInequalityExpression(leftExpr: expr, rightExpr: parseRelationalExpression(parser, diagnosticsHandler))
                }
            } while parser.nextToken.type == .equals  ||  parser.nextToken.type == .notEquals  ||  parser.nextToken.type == .contains
        }
        return expr
    }

    /**
        Parse a relational expression, which has the following format:

            relational-expression:
                unary-expression
                | relational-expression '<' unary-expression
                | relational-expression '>' unary-expression
                | relational-expression '<=' unary-expression
                | relational-expression '>=' unary-expression
                ;

        At present relational comparisons are not supported, so this method just calls through to ``parseUnaryExpression()``.
     */
    private class func parseRelationalExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        let expr = parseUnaryExpression(parser, diagnosticsHandler)

        // TODO: Relational expressions were not implemented in the native build system support for macro condition expressions, so they're not implemented here yet either.

        return expr
    }

    /**
        Parse a unary expression, which has the following format:

            unary-expression:
                primary-expression
                | 'not' primary-expression
                ;
     */
    private class func parseUnaryExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        if parser.nextToken.type == .not
        {
            // 'not' primary-expression
            parser.step()
            let expr = parsePrimaryExpression(parser, diagnosticsHandler)
            return expr != nil ? MacroConditionLogicalNOTExpression(expr!) : nil
        }
        else
        {
            // primary-expression
            return parsePrimaryExpression(parser, diagnosticsHandler)
        }
    }

    /**
        Parse a primary expression, which has the following format:

            primary-expression:
                constant
                | '(' expression ')'
                ;

        Note that a quirk in the scanner (carried over from the native build system) requires there to be a space between the last token in ``expression`` and the closing paren ``)``, or else the closing paren will be scanned as part of that last token.
     */
    private class func parsePrimaryExpression(_ parser: ParserState, _ diagnosticsHandler: @escaping ((String) -> Void)) -> MacroConditionExpression?
    {
        var expr: MacroConditionExpression? = nil
        switch parser.nextToken.type
        {
        case .leftParen:
            // '(' expression ')'
            parser.step()       // Skip the '('
            let e = parseExpression(parser, diagnosticsHandler)
            if parser.nextToken.type == .rightParen
            {
                // Found a ')', so the enclosed expression is our expression.
                expr = e
                parser.step()       // Skip the ')'
            }
            else
            {
                diagnosticsHandler("expected ')' but found '\(parser.scanner.stringForToken(parser.nextToken))' at offset \(parser.nextToken.offset)")
            }

        default:
            // constant             (we treat every token other than '(' and EOF as a string constant)
            let nextToken = parser.nextToken
            if nextToken.type != .eof
            {
                // The token string might contain backslashes, which have already served their purpose in not ending quoted strings etc.  But we need to strip them out now.
                var unescapedChars = [UInt8]()
                var i = 0
                while i < nextToken.length
                {
                    var ch = parser.scanner.bytes[nextToken.offset+i]
                    if ch == 92 /* '\\' */  &&  i < nextToken.length-1
                    {
                        i += 1
                        ch = parser.scanner.bytes[nextToken.offset+i]
                    }
                    if i < nextToken.length
                    {
                        unescapedChars.append(ch)
                    }
                    i += 1
                }

                // Create an expression node with the literal string form of the unescaped characters.
                var parseSucceeded = true
                let unescapedString = String(decoding: unescapedChars, as: UTF8.self)
                let parsedString = parser.macroNamespace.parseString(unescapedString) { diagnostic in
                    // The parse failed
                    if diagnostic.level == MacroExpressionDiagnostic.Level.error
                    {
                        parseSucceeded = false
                        diagnosticsHandler("Unable to parse string: \(unescapedString)")
                    }
                }
                // If the parse succeeded, then set the expression to return.
                if parseSucceeded
                {
                    expr = MacroConditionStringConstantExpression(parsedString)
                }

                // Advance to the next token.
                parser.step()
            }
        }
        return expr
    }

    public var description: String
    {
        return "[\(type(of: self))]"
    }
}


// MARK: Concrete subclasses


/// Abstract base class for expressions that whose natural return type is a string.  These can still be converted to booleans using evaluateAsBoolean()
private class MacroConditionStringExpression: MacroConditionExpression, @unchecked Sendable
{
    override func evaluateAsString(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String
    {
        fatalError("This method is a subclass responsibility.")
    }

    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        return evaluateAsString(scope, lookup: lookup).boolValue
    }
}

/// A constant string condition expression.
private final class MacroConditionStringConstantExpression: MacroConditionStringExpression, @unchecked Sendable
{
    let macroExpr: MacroStringExpression

    init(_ macroExpr: MacroStringExpression)
    {
        self.macroExpr = macroExpr
    }

    override func evaluateAsString(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String
    {
        return scope.evaluate(macroExpr, lookup: lookup)
    }

    override var description: String
    {
        return "'\(macroExpr.stringRep)'"
    }
}

/// Abstract base class for expressions that whose natural return type is a boolean.  These can still be converted to strings using evaluateAsString().
private class MacroConditionBooleanExpression: MacroConditionExpression, @unchecked Sendable
{
    override func evaluateAsString(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String
    {
        return evaluateAsBoolean(scope, lookup: lookup) ? "YES" : "NO"
    }

    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        fatalError("This method is a subclass responsibility.")
    }
}

// True and False constant expressions are not presently used.
@available(*, unavailable)
private final class MacroConditionTrueConstantExpression: MacroConditionBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        return true
    }

    override var description: String
    {
        return "YES"
    }
}

// True and False constant expressions are not presently used.
@available(*, unavailable)
private final class MacroConditionFalseConstantExpression: MacroConditionBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        return false
    }

    override var description: String
    {
        return "NO"
    }
}

/// Abstract base class for boolean expressions that operate on a single operand (either boolean or string).
private class MacroConditionUnaryBooleanExpression: MacroConditionExpression, @unchecked Sendable
{
    let expr: MacroConditionExpression?

    init(_ expr: MacroConditionExpression?)
    {
        self.expr = expr
    }

    override var description: String
    {
        return "(\(type(of: self)) \(String(describing: expr)) )"
    }
}

private final class MacroConditionLogicalNOTExpression: MacroConditionUnaryBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        let value = (expr != nil ? expr!.evaluateAsBoolean(scope, lookup: lookup) : false)
        return value == false
    }

    override var description: String
    {
        return "(NOT \(String(describing: expr)) )"
    }
}

/// Abstract base class for boolean expressions that operate on two operands (either booleans or strings).
private class MacroConditionBinaryBooleanExpression: MacroConditionBooleanExpression, @unchecked Sendable
{
    let leftExpr: MacroConditionExpression?
    let rightExpr: MacroConditionExpression?

    init(leftExpr: MacroConditionExpression?, rightExpr: MacroConditionExpression?)
    {
        self.leftExpr = leftExpr
        self.rightExpr = rightExpr
    }

    override var description: String
    {
        return "(\(type(of: self)) \(String(describing: leftExpr)) \(String(describing: rightExpr)))"
    }
}

private final class MacroConditionEqualityExpression: MacroConditionBinaryBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        // We don't know if the left and right expressions are booleans or strings (in fact, each could be different), but string comparison encompasses everything boolean comparison does and also lets us do things like "$(X) == 'YES'", so we go with that here.  Any subexpression that is boolean will be converted to a string for the purposes of the comparison.
        let leftString = leftExpr != nil ? leftExpr!.evaluateAsString(scope, lookup: lookup) : ""
        let rightString = rightExpr != nil ? rightExpr!.evaluateAsString(scope, lookup: lookup) : ""
        return (leftString == rightString)
    }

    override var description: String
    {
        return "(\(String(describing: leftExpr)) EQ \(String(describing: rightExpr)) )"
    }
}

private final class MacroConditionInequalityExpression: MacroConditionBinaryBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        // We don't know if the left and right expressions are booleans or strings (in fact, each could be different), but string comparison encompasses everything boolean comparison does and also lets us do things like "$(X) == 'YES'", so we go with that here.  Any subexpression that is boolean will be converted to a string for the purposes of the comparison.
        let leftString = leftExpr != nil ? leftExpr!.evaluateAsString(scope, lookup: lookup) : ""
        let rightString = rightExpr != nil ? rightExpr!.evaluateAsString(scope, lookup: lookup) : ""
        return (leftString != rightString)
    }

    override var description: String
    {
        return "(\(String(describing: leftExpr)) NEQ \(String(describing: rightExpr)) )"
    }
}

private final class MacroConditionLogicalANDExpression: MacroConditionBinaryBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        // We implicitly treat any subexpressions that are actually strings as boolean evaluations, e.g. "'NO' ^ ( 'X' == 'X')" evaluates to false ('NO' is treated as boolean false).
        let leftBoolValue = leftExpr != nil ? leftExpr!.evaluateAsBoolean(scope, lookup: lookup) : false
        let rightBoolValue = rightExpr != nil ? rightExpr!.evaluateAsBoolean(scope, lookup: lookup) : false
        return leftBoolValue && rightBoolValue
    }

    override var description: String
    {
        return "(\(String(describing: leftExpr)) AND \(String(describing: rightExpr)) )"
    }
}

private final class MacroConditionLogicalORExpression: MacroConditionBinaryBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        // We implicitly treat any subexpressions that are actually strings as boolean evaluations, e.g. "'YES' || ( 'X' == 'X')" evaluates to true ('YES' is treated as boolean true).
        let leftBoolValue = leftExpr != nil ? leftExpr!.evaluateAsBoolean(scope, lookup: lookup) : false
        let rightBoolValue = rightExpr != nil ? rightExpr!.evaluateAsBoolean(scope, lookup: lookup) : false
        return leftBoolValue || rightBoolValue
    }

    override var description: String
    {
        return "(\(String(describing: leftExpr)) OR \(String(describing: rightExpr)) )"
    }
}

// XOR is not presently used.
@available(*, unavailable)
private final class MacroConditionLogicalXORExpression: MacroConditionBinaryBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        // We implicitly treat any subexpressions that are actually strings as boolean evaluations, e.g. "'NO' ^ ( 'X' == 'X')" evaluates to false ('NO' is treated as boolean false).
        let leftBoolValue = leftExpr != nil ? leftExpr!.evaluateAsBoolean(scope, lookup: lookup) : false
        let rightBoolValue = rightExpr != nil ? rightExpr!.evaluateAsBoolean(scope, lookup: lookup) : false
        return leftBoolValue == rightBoolValue
    }

    override var description: String
    {
        return "(\(String(describing: leftExpr)) XOR \(String(describing: rightExpr)) )"
    }
}

private final class MacroConditionContainsExpression: MacroConditionBinaryBooleanExpression, @unchecked Sendable
{
    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        // As the contains operator works on strings, we're assuming that both expressions, left and right, will be strings. Also of note, we currently assume the substring search will be case insensitive. It might be good in the future to allow the user to specify case sensitivity vs. non-sensitivity. As a point of comparison, NSPredicate does this by appending '[c]' to the operator.
        let leftString = leftExpr != nil ? leftExpr!.evaluateAsString(scope, lookup: lookup) : ""
        let rightString = rightExpr != nil ? rightExpr!.evaluateAsString(scope, lookup: lookup) : ""
        return leftString.contains(rightString)
    }

    override var description: String
    {
        return "(\(String(describing: leftExpr)) CONTAINS \(String(describing: rightExpr)) )"
    }
}

/// A ternary conditional expression.
private final class MacroConditionTernaryConditionalExpression: MacroConditionExpression, @unchecked Sendable
{
    let condExpr: MacroConditionExpression?
    let thenExpr: MacroConditionExpression?
    let elseExpr: MacroConditionExpression?

    init(condExpr: MacroConditionExpression?, thenExpr: MacroConditionExpression?, elseExpr: MacroConditionExpression?)
    {
        self.condExpr = condExpr
        self.thenExpr = thenExpr
        self.elseExpr = elseExpr
    }

    override func evaluateAsString(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String
    {
        // We implicitly treat the condition expression as a boolean expression; if it's a string, it will be evaluated as a boolean.  We treat the then or else expression as a string, however, since that is non-lossy while a boolean would be lossy.  If the then or else expression, respectively, is a boolean expression, it will be converted to a string.
        let condBoolValue = condExpr != nil ? condExpr!.evaluateAsBoolean(scope, lookup: lookup) : false
        let resultExpr = condBoolValue ? thenExpr : elseExpr
        return resultExpr != nil ? resultExpr!.evaluateAsString(scope, lookup: lookup) : ""
    }

    override func evaluateAsBoolean(_ scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Bool
    {
        return evaluateAsString(scope, lookup: lookup).boolValue
    }

    override var description: String
    {
        return "(\(String(describing: condExpr)) ? \(String(describing: thenExpr)) : \(String(describing: elseExpr)) )"
    }
}


// MARK: Scanning


private enum TokenType: String
{
    // Not all of these are presently used.
    case invalid
    case string
    case `true`
    case `false`
    case equals
    case notEquals
    case contains
    case matches
    case `in`
    case not
    case and
    case or
    case xor
    case questionMark
    case colon
    case leftParen
    case rightParen
    case eof
}

private struct Token: CustomStringConvertible
{
    /// The token type.
    var type: TokenType

    /// Currently unused, should be zero for now.
    var flags: Int8

    /// Byte offset into the string of token start.
    var offset: Int

    /// Byte length of token in the string.
    var length: Int

    fileprivate var description: String
    {
        return "<\(type.rawValue):o=\(offset),l=\(length)>"
    }
}

private class ScannerState
{
    /// UTF-8 byte buffer that’s being scanned.
    let bytes: [UInt8]

    /// Index of the next character to read in the string.
    var currIdx: Int

    init(_ string: String)
    {
        self.bytes = [UInt8](string.utf8)
        self.currIdx = 0
    }

    /// Scans ``bytes`` until the next token has been created, and returns it.
    func getNextToken() -> Token
    {
        // Skip whitespace.
        scanUntil({ !self.isAtWhitespace })

        // Create and return a Token struct based on what we found (a token is created even if we're at the end of the string).
        var token = Token(type: .invalid, flags: 0, offset: currIdx, length: 0)
        switch currChar
        {
        case 0:         // EOF
            token.type = .eof
            token.length = 0
            break

        case 61:        // '='
            advance()
            if currChar == 61
            {
                // We found a '=='
                token.type = .equals
                token.length = 2
                advance()
            }
            // Otherwise we just found a '='

        case 33:        // '!'
            advance()
            if currChar == 61
            {
                // We found a '!='
                token.type = .notEquals
                token.length = 2
                advance()
            }
            else
            {
                // We found a '!'
                token.type = .not
                token.length = 1
            }

        case 38:        // '&'
            advance()
            if currChar == 38
            {
                // We found a '&&'
                token.type = .and
                token.length = 2
                advance()
            }
            // Otherwise we just found a '&'

        case 124:       // '|'
            advance()
            if currChar == 124
            {
                // We found a '||'
                token.type = .or
                token.length = 2
                advance()
            }
            // Otherwise we just found a '|'

        case 63:        // '?'
            token.type = .questionMark
            token.length = 1
            advance()

        case 58:        // ':'
            token.type = .colon
            token.length = 1
            advance()

        case 40:        // '('
            token.type = .leftParen
            token.length = 1
            advance()

        case 41:        // ')'
            token.type = .rightParen
            token.length = 1
            advance()

        case 39, 34:        // '\'' and '\"'
            // Scanning a quoted string.
            // Save the quote character and advance the token's index beyond it.
            let quoteChar = currChar
            let startIdx = currIdx
            token.offset += 1
            // Scan until the matching quote, if there is one.
            repeat
            {
                advance()
                if currChar == 92 { advance() }     // Skip '\\'
            } while currChar != quoteChar  &&  !isAtEndOfStream
            var endIdx = currIdx
            if currChar == quoteChar
            {
                // Skip over the trailing quote.
                advance()
                endIdx = currIdx
            }
            else
            {
                // unterminated quote... what to do?
                endIdx += 1    // Simulate a quote so that the math works out when setting token.length below
            }
            token.type = .string
            token.length = ((endIdx - 2) - startIdx)   // excludes the leading and trailing quotes

        default:
            // Scan until we reach whitespace or end-of-string.  Then record the range of what we scanned.
            let startIdx = currIdx
            scanUntil({ self.isAtWhitespace })
            token.type = .string
            token.length = (currIdx - startIdx)

            // Recognize keywords
            if token.length == 2  &&  bytes[startIdx ..< currIdx] == "or"
            {
                token.type = .or
            }
            else if token.length == 3  &&  bytes[startIdx ..< currIdx] == "and"
            {
                token.type = .and
            }
            else if token.length == 2  &&  bytes[startIdx ..< currIdx] == "is"
            {
                token.type = .equals
            }
            else if token.length == 5  &&  bytes[startIdx ..< currIdx] == "isnot"
            {
                token.type = .notEquals
            }
            else if token.length == 7  &&  bytes[startIdx ..< currIdx] == "matches"
            {
                token.type = .matches
            }
            else if token.length == 2  &&  bytes[startIdx ..< currIdx] == "in"
            {
                token.type = .in
            }
            else if token.length == 8  &&  bytes[startIdx ..< currIdx] == "contains"
            {
                token.type = .contains
            }
        }

        if token.type == .invalid  &&  token.length == 0
        {
            // Invalid token -- adjust the length so that the error message becomes useful.  We do this by extending the token until the next whitespace character.
            while ((token.offset + token.length) < bytes.count)  &&  bytes[token.offset + token.length] > 32  // ' '
            {
                token.length += 1
            }
        }

        //log( "Parsed token: \(token) -> \(stringForToken(token))")

        return token
    }

    /// Returns the UTF-8 byte at the current position, which is zero if the cursor is currently at the very end of the string.
    private var currChar: UInt8
    {
        assert(currIdx <= bytes.count)
        return (currIdx < bytes.count) ? bytes[currIdx] : 0
    }

    /// Returns the UTF-8 byte at the position immediately after the current position, which is zero if the cursor is currently at either the very end of the string or the position before the very end.
    private var nextChar: UInt8
    {
        assert(currIdx <= bytes.count)
        return (currIdx + 1 < bytes.count) ? bytes[currIdx + 1] : 0
    }

    /// Returns the UTF-8 byte at the position immediately after the position immediately after the current position, which is zero if the cursor is currently at either the very end of the string, at the position before the very end, or at the position before that.
    private var nextNextChar: UInt8
    {
        assert(currIdx <= bytes.count)
        return (currIdx + 2 < bytes.count) ? bytes[currIdx + 2] : 0
    }

    /// Advances the character to the next position, or does nothing if the cursor is currently already at end-of-string.
    private func advance(_ offset: Int = 1)
    {
        assert(currIdx <= bytes.count)
        currIdx = min(currIdx + offset, bytes.count)
    }

    /// Returns true if and only if the cursor is currently at end-of-string.
    private var isAtEndOfStream: Bool
    {
        assert(currIdx <= bytes.count)
        return currIdx == bytes.count
    }

    /// Returns true if and only if the cursor is currently at a whitespace character.  The characters considered whitespace are the same as the `isspace()` function, i.e. space (` `), horizontal tab (`\t`), vertical tab (`\v`), carriage return (`\r`), newline (`\n`), and form feed (`\f`).
    private var isAtWhitespace: Bool
    {
        return currChar == /* ' ' */ 32 || (currChar >= /* '\t' */ 9 && currChar <= /* '\r' */ 13)
    }

    /// Advances the cursor until it reaches end-of-string or until the block (which is invoked for each character) returns true.  Leaves the cursor at the character (if any) that caused the scan to stop.  Returns the (possibly empty) substring from the starting position to (but not including) the stop position.
    private func scanUntil(_ block: (UInt8) -> Bool)
    {
        // Record the starting index, and advance until we reach end-of-string or one of the specified stop characters.  After that we return the (possibly empty) substring.
        while !(isAtEndOfStream || block(currChar)) { advance() }
    }

    private func scanUntil(_ block: () -> Bool)
    {
        // Record the starting index, and advance until we reach end-of-string or one of the specified stop characters.  After that we return the (possibly empty) substring.
        while !(isAtEndOfStream || block()) { advance() }
    }

    func stringForToken(_ token: Token) -> String
    {
        return String(decoding: bytes[token.offset ..< token.offset+token.length], as: UTF8.self)
    }

}


// MARK: Parsing


private class ParserState
{
    var scanner: ScannerState
    var nextToken: Token

    let macroNamespace: MacroNamespace

    init(_ scanner: ScannerState, _ macroNamespace: MacroNamespace)
    {
        self.scanner = scanner
        self.nextToken = scanner.getNextToken()

        self.macroNamespace = macroNamespace
    }

    func step()
    {
        self.nextToken = scanner.getNextToken()
    }
}
