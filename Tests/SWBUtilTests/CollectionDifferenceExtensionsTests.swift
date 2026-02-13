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
import SWBUtil

@Suite fileprivate struct CollectionDifferenceExtensionsTests {
    @Test
    func stringListDiffs() {
        do {
            let original: [String] = ["a", "b"]
            let modified: [String] = ["a", "b", "c", "d"]
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "inserted 'c', inserted 'd'")
        }

        do {
            let original: [String] = ["a", "b", "c", "d"]
            let modified: [String] = ["a", "b"]
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'd', removed 'c'")
        }

        do {
            let original: [String] = ["a", "b", "c"]
            let modified: [String] = ["c", "a", "b"]
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "moved 'c'")
        }

        do {
            let original: [String] = ["a", "b", "c"]
            let modified: [String] = ["a", "d", "c"]
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'b', inserted 'd'")
        }

        do {
            let original: [String] = ["a", "b"]
            let modified: [String] = ["a", "b"]
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "")
        }

        do {
            let original: [String] = ["a", "b", "c", "d"]
            let modified: [String] = ["d", "c", "b", "a"]
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "moved 'c', moved 'a', moved 'b'")
        }
    }

    @Test
    func stringDiffs() {
        do {
            let original = "abc"
            let modified = "abcd"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "inserted 'd'")
        }

        do {
            let original = "ac"
            let modified = "abxyc"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "inserted 'bxy'")
        }

        do {
            let original = "abcd"
            let modified = "abc"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'd'")
        }

        do {
            let original = "abxyc"
            let modified = "ac"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'bxy'")
        }

        do {
            let original = "abc"
            let modified = "cab"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'c', inserted 'c'")
        }

        do {
            let original = "abcde"
            let modified = "deabc"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'de', inserted 'de'")
        }

        do {
            let original = "hello"
            let modified = "hxllo"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'e', inserted 'x'")
        }

        do {
            let original = "abc"
            let modified = "abc"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "")
        }

        do {
            let original = "ac"
            let modified = "axcy"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "inserted 'x', inserted 'y'")
        }

        do {
            let original = "axcy"
            let modified = "ac"
            let diff = modified.difference(from: original)
            #expect(diff.humanReadableDescription == "removed 'y', removed 'x'")
        }
    }


    @Test
    func environmentDiffs() {
        do {
            let original: [(String, String)] = [("HOME", "/home/user")]
            let modified: [(String, String)] = [("HOME", "/home/user"), ("PATH", "/usr/bin")]
            let diff = modified.difference(from: original) { $0 == $1 }
            #expect(diff.humanReadableEnvironmentDiff == "inserted 'PATH=/usr/bin'")
        }

        do {
            let original: [(String, String)] = [("HOME", "/home/user"), ("PATH", "/usr/bin")]
            let modified: [(String, String)] = [("HOME", "/home/user")]
            let diff = modified.difference(from: original) { $0 == $1 }
            #expect(diff.humanReadableEnvironmentDiff == "removed 'PATH=/usr/bin'")
        }

        do {
            let original: [(String, String)] = [("HOME", "/home/user"), ("OLDVAR", "old")]
            let modified: [(String, String)] = [("HOME", "/home/user"), ("NEWVAR", "new")]
            let diff = modified.difference(from: original) { $0 == $1 }

            let description = diff.humanReadableEnvironmentDiff
            #expect(description.contains("removed 'OLDVAR=old'"))
            #expect(description.contains("inserted 'NEWVAR=new'"))
        }

        do {
            let original: [(String, String)] = [("HOME", "/home/user")]
            let modified: [(String, String)] = [("HOME", "/home/user")]
            let diff = modified.difference(from: original) { $0 == $1 }

            #expect(diff.humanReadableEnvironmentDiff == "")
        }
    }
}
