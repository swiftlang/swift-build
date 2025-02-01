//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if DONT_HAVE_CUSTOM_EXECUTION_TRAIT
public import Testing

extension Trait where Self == Testing.ConditionTrait {
    public static func flaky(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        disabled("Custom execution traits are not supported in this build")
    }

    public static func knownIssue(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        disabled("Custom execution traits are not supported in this build")
    }
}
#else
@_spi(Experimental) package import Testing

package struct KnownIssueTestTrait: CustomExecutionTrait & TestTrait & SuiteTrait {
    let comment: Comment
    let isIntermittent: Bool
    let sourceLocation: SourceLocation

    package var isRecursive: Bool {
        true
    }

    @Sendable package func execute(_ function: @escaping @Sendable () async throws -> Void, for test: Testing.Test, testCase: Testing.Test.Case?) async throws {
        if testCase == nil || test.isSuite {
            try await function()
        } else {
            await withKnownIssue(comment, isIntermittent: isIntermittent, sourceLocation: sourceLocation) {
                try await function()
            }
        }
    }
}

extension Trait where Self == KnownIssueTestTrait {
    /// Causes a test to be marked as a (nondeterministic) expected failure if it throws any error or records any issue.
    package static func flaky(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        Self(comment: comment, isIntermittent: true, sourceLocation: sourceLocation)
    }

    /// Causes a test to be marked as a (deterministic) expected failure by requiring it to throw an error or record an issue.
    package static func knownIssue(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        Self(comment: comment, isIntermittent: false, sourceLocation: sourceLocation)
    }
}
#endif
