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

/// A diagnostic represents a problem or issue detected during .xcconfig parsing. Every diagnostic has an associated “level”, such as warning, error, etc. Additionally, the diagnostic has a type, which specifies the exact problem to which it refers.
public struct MacroConfigFileDiagnostic: Sendable {

    /// Type of diagnostic: this is orthogonal to the level, though some levels make more sense than others for certain types of diagnostics.
    public let kind: Kind

    /// Diagnostics level, such as note, warning, or error. This is just the “native” level. A parser delegate or other client may still choose, for example, to treat all warnings as errors, or to commute a certain type of error to a warning.
    public let level: Level

    /// Human-readable message describing the problem.
    public let message: String

    /// Line number in the source text. Line numbers are one-based.
    public let lineNumber: Int

    public enum Kind: Sendable {
        /// A syntax error caused by an unexpected character, such as an invalid macro name character or junk at the end of a line.
        case unexpectedCharacter

        /// A missing macro name in an assignment.
        case missingMacroName

        /// A missing ‘=’ character in an assignment.
        case missingEqualsInAssignment

        /// An unterminated condition clause.
        case unterminatedConditionClause

        /// A missing parameter name in a condition clause.
        case missingConditionParameter

        /// A missing ‘=’ character in a condition clause.
        case missingEqualsInCondition

        /// An unterminated filename in a #include directive.
        case unterminatedIncludeDirective

        /// An unknown preprocessor directive.
        case unknownPreprocessorDirective

        /// A required included file which either couldn't be found or couldn't be read.
        case missingIncludedFile

        /// An included file contains a #include that creates a cycle.
        case cyclicIncludeFileDirective
    }

    public enum Level: Sendable {
        // FIXME: There are currently only warnings and errors, but we may end up adding notes as well, and certainly fixits.
        case warning
        case error
    }

    public init(kind: Kind, level: Level, message: String, lineNumber: Int) {
        self.kind = kind
        self.level = level
        self.message = message
        self.lineNumber = lineNumber
    }
}

extension MacroConfigFileDiagnostic: Equatable {
    public static func ==(lhs: MacroConfigFileDiagnostic, rhs: MacroConfigFileDiagnostic) -> Bool {
        if lhs.kind != rhs.kind { return false }
        if lhs.level != rhs.level { return false }
        if lhs.message != rhs.message { return false }
        if lhs.lineNumber != rhs.lineNumber { return false }
        return true
    }
}
