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

import Foundation
import Testing
import SWBMacro
import SwiftDriver

@Suite fileprivate struct MacroConditionTripleTests {
    @Test
    func normalizedUnversionedTripleConditionBasicMatching() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        let tripleParam = namespace.declareConditionParameter("__normalized_unversioned_triple")

        // Basics
        do {
            let condition = MacroCondition(
                parameter: tripleParam,
                valuePattern: "arm64-apple-macos"
            )

            #expect(condition.evaluate("arm64-apple-macos"))
            #expect(!condition.evaluate("x86_64-apple-ios"))
            #expect(!condition.evaluate("arm64-apple-ios"))
            #expect(!condition.evaluate("x86_64-unknown-linux-gnu"))
        }

        // Versioning is ignored
        do {
            let condition = MacroCondition(
                parameter: tripleParam,
                valuePattern: "arm64-apple-tvos26.0"
            )

            #expect(condition.evaluate("arm64-apple-tvos"))
            #expect(condition.evaluate("arm64-apple-tvos15.0"))
            #expect(!condition.evaluate("arm64-apple-ios26.0"))
        }

        // Versioning is ignored (Android)
        do {
            let condition = MacroCondition(
                parameter: tripleParam,
                valuePattern: "aarch64-unknown-linux-android"
            )

            #expect(condition.evaluate("aarch64-unknown-linux-android28"))
            #expect(condition.evaluate("aarch64-unknown-linux-android"))
            #expect(!condition.evaluate("aarch64-unknown-linux-foo"))
        }

        // macosx/macos normalization
        do {
            let condition = MacroCondition(
                parameter: tripleParam,
                valuePattern: "arm64-apple-macosx"
            )

            #expect(condition.evaluate("arm64-apple-macosx"))
            #expect(condition.evaluate("arm64-apple-macos"))
        }

        // aarch64/arm64 normalization
        do {
            let condition = MacroCondition(
                parameter: tripleParam,
                valuePattern: "aarch64-unknown-linux-gnu"
            )

            #expect(condition.evaluate("aarch64-unknown-linux-gnu"))
            #expect(condition.evaluate("arm64-unknown-linux-gnu"))
        }

        do {
            let condition = MacroCondition(
                parameter: tripleParam,
                valuePattern: "arm64-apple-ios"
            )

            #expect(condition.evaluate([tripleParam: ["x86_64-apple-macos", "arm64-apple-ios", "x86_64-unknown-linux-gnu"]]))
            #expect(!condition.evaluate([tripleParam: ["x86_64-apple-macos", "arm64-apple-watchos", "x86_64-unknown-linux-gnu"]]))
        }
    }
}
