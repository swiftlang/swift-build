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

#if compiler(<6.1)
public import Testing

extension Trait where Self == Testing.ConditionTrait {
    public static func userDefaults(_ userDefaults: [String: String], clean: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        disabled("Custom execution traits are not supported in this build")
    }
}
#else
package import Testing
@_spi(Testing) import SWBUtil
import Foundation

package struct UserDefaultsTestTrait: TestTrait & SuiteTrait & TestScoping {
    let userDefaults: [String: String]
    let clean: Bool

    package var isRecursive: Bool {
        true
    }

    package func provideScope(for test: Testing.Test, testCase: Testing.Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        if testCase == nil || test.isSuite {
            try await function()
        } else {
            try await UserDefaults.withEnvironment(userDefaults, clean: clean) {
                try await function()
            }
        }
    }
}

extension Trait where Self == UserDefaultsTestTrait {
    /// Causes a test to be executed while the specified user defaults are applied.
    package static func userDefaults(_ userDefaults: [String: String], clean: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        Self(userDefaults: userDefaults, clean: clean)
    }
}
#endif
