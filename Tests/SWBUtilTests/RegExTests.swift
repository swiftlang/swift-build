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

@Suite fileprivate struct RegExTests {
    @Test
    func errors() {
        #expect(throws: (any Error).self) {
            try RegEx(pattern: "(")
        }
    }

    @Test
    func firstMatch() throws {
        try #expect(RegEx(pattern: "([a-z]+)([0-9]+)").firstMatch(in: "foo1 foo2 foo3") == ["foo", "1"])
        try #expect(RegEx(pattern: "([a-z]+)([0-9]+)").firstMatch(in: "fooa foob foo3") == ["foo", "3"])
        try #expect(RegEx(pattern: "([a-z]+)([0-9]+)").firstMatch(in: "fooa foob fooc") == nil)
        try #expect(RegEx(pattern: "foo1 foo2 ([a-z]+)([0-9]+)").firstMatch(in: "foo1 foo2 foo3") == ["foo", "3"])
        try #expect(RegEx(pattern: "foo2 ([a-z]+)([0-9]+)").firstMatch(in: "foo1 foo2 foo3") == ["foo", "3"])
    }

    @Test
    func firstMatchResult() throws {
        do {
            let result: RegEx.MatchResult = try #require(RegEx(pattern: "(?<g1>[a-z]+)(?<g2>[0-9]+)").firstMatch(in: "foo1 foo2 foo3"))
            #expect(result["g1"] == "foo")
            #expect(result["g2"] == "1")
            #expect(result["g3"] == nil)
        }

        do {
            let result: RegEx.MatchResult = try #require(RegEx(pattern: "(?<g1>[a-z]+)(?<g2>[0-9]+)").firstMatch(in: "fooa foob foo3"))
            #expect(result["g1"] == "foo")
            #expect(result["g2"] == "3")
            #expect(result["g3"] == nil)
        }

        try #expect(RegEx(pattern: "(?<g1>[a-z]+)(?<g2>[0-9]+)").firstMatch(in: "fooa foob fooc") == nil)

        do {
            let result: RegEx.MatchResult = try #require(RegEx(pattern: "foo1 foo2 (?<g1>[a-z]+)(?<g2>[0-9]+)").firstMatch(in: "foo1 foo2 foo3"))
            #expect(result["g1"] == "foo")
            #expect(result["g2"] == "3")
            #expect(result["g3"] == nil)
        }

        do {
            let result: RegEx.MatchResult = try #require(RegEx(pattern: "foo2 (?<g1>[a-z]+)(?<g2>[0-9]+)").firstMatch(in: "foo1 foo2 foo3"))
            #expect(result["g1"] == "foo")
            #expect(result["g2"] == "3")
            #expect(result["g3"] == nil)
        }
    }

    @Test
    func matchGroups() throws {
        try #expect(RegEx(pattern: "([a-z]+)([0-9]+)").matchGroups(in: "foo1 bar2 baz3") == [["foo", "1"], ["bar", "2"], ["baz", "3"]])
        try #expect(RegEx(pattern: "[0-9]+").matchGroups(in: "foo bar baz") == [])
        try #expect(RegEx(pattern: "[0-9]+").matchGroups(in: "1") == [[]])
    }

    @Test
    func replace() throws {
        let r = try RegEx(pattern: "b(a)(r|z)")
        var s = "foo bar baz"
        #expect(2 == r.replace(in: &s, with: "$1"))
        #expect(s == "foo a a")
    }
}
