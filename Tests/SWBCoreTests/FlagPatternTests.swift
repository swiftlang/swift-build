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
import SWBTestSupport
import SWBUtil
import SWBCore

/// Unit tests of build rules and rule matching.
@Suite fileprivate struct FlagPatternTests {
    @Test
    func basics() {
        func checkPattern(_ pattern: String, on string: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let fnmatchResult = (try? SWBUtil.fnmatch(pattern: pattern, input: string)) == true
            let flagPatternResult = FlagPattern.fromFnmatch(pattern).matches(string)
            #expect(fnmatchResult == flagPatternResult, sourceLocation: sourceLocation)
        }

        checkPattern("a", on: "a")
        checkPattern("a", on: "b")

        checkPattern("*", on: "")
        checkPattern("*", on: "a")
        checkPattern("*", on: "a/b")

        checkPattern("a*", on: "")
        checkPattern("a*", on: "a")
        checkPattern("a*", on: "b")
        checkPattern("a*", on: "aa")
        checkPattern("a*", on: "ba")
        checkPattern("a*", on: "a/b")
        checkPattern("a*", on: "b/a")

        checkPattern("a\\*", on: "a")
        checkPattern("a\\*", on: "a\\*")

        checkPattern("a?", on: "a")
        checkPattern("a?", on: "ab")

        checkPattern("a[b]", on: "ab")
    }
}
