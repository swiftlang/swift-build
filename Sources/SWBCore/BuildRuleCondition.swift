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

import SWBLibc
import SWBUtil
public import SWBMacro

/// The priority with which a file type matched a build rule.
public enum BuildRuleConditionMatchPriority: Sendable {
    /// Normal priority match - build rules with this priority should be preferred first.
    ///
    /// For file type conditions, indicates that the file type exactly matched one of the file types in the build rule's inputs.
    case normal

    /// Low priority - build rules with this priority should be preferred last.
    ///
    /// For file type conditions, indicates that the file type conformed to one of the file types in the build rule's inputs, but wasn't an exact match.
    case low

    /// The build rule condition did not match at all.
    case none
}

/// Encapsulates a type of condition for a build rule.  A rule set may cache the result of this invocation, so the result should depend only on the values available from a candidate through its protocol methods.
public protocol BuildRuleCondition: CustomStringConvertible, Sendable {

    /// Evaluates the condition against the candidate, returning an appropriate match priority level if there’s a match or `.none` if there is no match.
    ///
    /// A rule set may cache the result of this invocation, so the result should depend only on the values available from the candidate through its protocol methods.
    func match(_ candidate: FileToBuild, _ scope: MacroEvaluationScope) -> BuildRuleConditionMatchPriority

    var description: String { get }
}

/// A condition of a build rule that uses a set of file types as the criterion.  A candidate file type matches if it conforms to any file type in the condition.
public final class BuildRuleFileTypeCondition: BuildRuleCondition {
    let fileTypes: [FileTypeSpec]

    init(fileTypes: [FileTypeSpec]) {
        self.fileTypes = fileTypes
    }

    @_spi(Testing) public convenience init(fileType: FileTypeSpec) {
        self.init(fileTypes: [fileType])
    }

    /// Evaluates the condition against the candidate, returning an appropriate match priority level if there’s a match or `.none` if there is no match.
    ///
    /// We take a two-pass approach: the first pass checks for an exact match, in order to prefer rules whose input file types have a type which is an exact match with the candidate. The second pass then does a conformance check.
    ///
    /// - returns: One of the following values:
    ///   - `.normal` if the candidate file type is an exact match with the file type in the condition
    ///   - `.low` if the candidate file type is compatible with any file type in the condition
    ///   - `.none` if there is no match at all
    public func match(_ candidate: FileToBuild, _ scope: MacroEvaluationScope) -> BuildRuleConditionMatchPriority {
        // First pass: exact match
        if fileTypes.first(where: { fileType in candidate.fileType == fileType }) != nil {
            return .normal
        }

        // Second pass: conformance check
        if fileTypes.first(where: { fileType in candidate.fileType.conformsTo(fileType) }) != nil {
            return .low
        }

        return .none
    }

    public var description: String {
        if fileTypes.count == 1, let fileType = fileTypes.first {
            return "<\(type(of: self)):\(fileType)>"
        }
        else {
            let allFileTypes = fileTypes.map({ $0.identifier }).joined(separator: ":")
            return "<\(type(of: self)):\(allFileTypes)>"
        }
    }
}


/// A condition of a build rule that uses file name pattern as the match criterion.
public final class BuildRuleFileNameCondition: BuildRuleCondition {
    let namePatterns: [MacroStringExpression]

    @_spi(Testing) public init(namePatterns: [MacroStringExpression]) {
        self.namePatterns = namePatterns
    }

    /// Evaluates the condition against the candidate, returning a `.normal` match priority level if its file name matches any of the patterns, or `.none` if there is no match.
    public func match(_ candidate: FileToBuild, _ scope: MacroEvaluationScope) -> BuildRuleConditionMatchPriority {
        for namePattern in namePatterns {
            let evaluatedNamePattern = scope.evaluate(namePattern)
            do {
                if try fnmatch(pattern: evaluatedNamePattern, input: candidate.absolutePath.str) {
                    return .normal
                }
            } catch {
            }
        }
        return .none
    }

    public var description: String {
        return "<\(type(of: self)):\(namePatterns)>"
    }
}
