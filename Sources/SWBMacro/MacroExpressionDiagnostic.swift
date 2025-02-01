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

/// A diagnostic represents a problem or issue detected during macro expression processing (such as parsing or evaluation). Every diagnostic has an associated “level”, such as warning, error, etc. Additionally, the diagnostic has a type, which specifies the exact problem to which it refers.
public struct MacroExpressionDiagnostic: CustomDebugStringConvertible, Sendable {

    /// Original source string to which the diagnostic refers.
    let string: String

    /// Range in original source string to which it refers. There is currently only one; perhaps in the future this should be an array.
    let range: Range<String.UTF8View.Index>

    /// Type of diagnostic: this is orthogonal to the level, though some levels make more sense than others for certain types of diagnostics.
    let kind: Kind

    /// Diagnostics level, such as note, warning, or error. This is just the “native” level. A parser delegate or evaluation delegate may still choose to treat, for example, warnings as errors.
    public let level: Level

    public enum Kind: Sendable {
        case deprecatedMacroRefSyntax
        case trailingDollarSign
        case trailingEscapeCharacter
        case unterminatedQuotation
        case unterminatedMacroSubexpression
        case missingMacroName
        case missingOperatorName
        case invalidOperatorCharacter
        case unknownRetrievalOperator
        case unknownReplacementOperator
    }

    public enum Level: Sendable {
        // FIXME: There are currently only warnings and errors, but we may end up adding notes as well, and certainly fixits.
        case warning
        case error
    }

    public init(string: String, range: Range<String.UTF8View.Index>, kind: Kind, level: Level) {
        self.string = string
        self.range = range
        self.kind = kind
        self.level = level
    }

    private var substring: String {
        return String(string[self.range])
    }

    public var debugDescription: String {
        switch kind {
        case .deprecatedMacroRefSyntax: return "\(level):DeprecatedMacroRefSyntax(\"\(substring)\")"
        case .trailingDollarSign: return "\(level):TrailingDollarSign(\"\(substring)\")"
        case .trailingEscapeCharacter: return "\(level):TrailingEscapeCharacter(\"\(substring)\")"
        case .unterminatedQuotation: return "\(level):UnterminatedQuotation(\"\(substring)\")"
        case .unterminatedMacroSubexpression: return "\(level):UnterminatedMacroSubexpression(\"\(substring)\")"
        case .missingMacroName: return "\(level):MissingMacroName(\"\(substring)\")"
        case .missingOperatorName: return "\(level):MissingOperatorName(\"\(substring)\")"
        case .invalidOperatorCharacter: return "\(level):InvalidOperatorCharacter(\"\(substring)\")"
        case .unknownRetrievalOperator: return "\(level):UnknownRetrievalOperator(\"\(substring)\")"
        case .unknownReplacementOperator: return "\(level):UnknownReplacementOperator(\"\(substring)\")"
        }
    }
}

extension MacroExpressionDiagnostic: Equatable {
    public static func ==(lhs: MacroExpressionDiagnostic, rhs: MacroExpressionDiagnostic) -> Bool {
        if lhs.string != rhs.string { return false }
        if lhs.range != rhs.range { return false }
        if lhs.kind != rhs.kind { return false }
        if lhs.level != rhs.level { return false }
        return true
    }
}
