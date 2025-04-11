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

public import SWBMacro
public import SWBProtocol
import SWBUtil

extension MacroNamespace {
    /// Parses `strings` as a macro expression string list, returning a MacroExpression object to represent it.  The returned macro expression contains a copy of the input string and a compiled representation that can be used to evaluate the expression in a particular context.  The diagnostics handler is invoked once for every issue found during the parsing.  Even in the presence of errors, this method always returns an expression that’s as parsed as possible.
    public func parseStringList(_ source: MacroExpressionSource, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroStringListExpression {
        switch source {
        case .string(let value):
            return parseStringList(value, diagnosticsHandler: diagnosticsHandler)
        case .stringList(let value):
            return parseStringList(value, diagnosticsHandler: diagnosticsHandler)
        }
    }

    /// Parses `string` as a macro expression string, returning a MacroExpression object to represent it.  The returned macro expression contains a copy of the input string and a compiled representation that can be used to evaluate the expression in a particular context.  The diagnostics handler is invoked once for every issue found during the parsing.  Even in the presence of errors, this method always returns an expression that’s as parsed as possible.
    public func parseString(_ source: MacroExpressionSource, diagnosticsHandler: ((MacroExpressionDiagnostic) -> Void)? = nil) -> MacroStringExpression {
        switch source {
        case .string(let value):
            return parseString(value, diagnosticsHandler: diagnosticsHandler)
        case .stringList(let value):
            // FIXME: It isn't clear what the right behavior is here. We are parsing a string typed macro and were given a list. For now, we just use the quoted string representation.
            return parseString(value.quotedStringListRepresentation, diagnosticsHandler: diagnosticsHandler)
        }
    }
}
