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

@Suite fileprivate struct DictionaryTests {
    @Test
    func contains() {
        #expect(["a": 1].contains("a"))
        #expect(!["a": 1].contains("b"))
    }

    @Test
    func addContentsOf() {
        var firstDict = [ "a": 1, "b": 2, "c": 3 ]

        firstDict.addContents(of:  [ "d": 4, "e": 5 ])
        #expect(firstDict == [ "a": 1, "b": 2, "c": 3 , "d": 4, "e": 5 ])

        firstDict.addContents(of:  [ "b": 6 ] )
        #expect(firstDict == [ "a": 1, "b": 6, "c": 3 , "d": 4, "e": 5 ])

        firstDict.addContents(of:  [ "a": 7, "f": 8 ] )
        #expect(firstDict == [ "a": 7, "b": 6, "c": 3 , "d": 4, "e": 5, "f": 8 ])
    }

    @Test
    func getOrInsert() {
        var z = [Int: Int]()
        #expect(z.getOrInsert(1, { 2 }) == 2)
        #expect(z.getOrInsert(1, { 3 }) == 2)
        #expect(z == [1: 2])
    }

    @Test
    func compactMapValues() {
        let inDict = [
            "CFFoo": 1,
            "CFBaz": 2,
            "NSBar": 3,
            "CFArg": 4,
            "NSBlah": 5,
            "WKBar": 6,
            "WKBaz": 7,
        ]

        let outDict = [
            "CFFoo": "1",
            "CFBaz": "2",
            "CFArg": "4",
        ]

        #expect(outDict == inDict.compactMapValues { k, v in k.hasPrefix("CF") ? String(v) : nil })
        #expect(inDict == inDict.compactMapValues { k, v in v })
        #expect([String: Int]() == inDict.compactMapValues { _, _ -> Int? in nil })
    }

    @Test
    func filterKeys() {
        let inDict = [
            "CFFoo": 1,
            "NSBar": 2
        ]

        let emptyDict: [String: Int] = [:]

        #expect(inDict.filter(keys: ["CFFoo", "NSBar"]) == inDict)
        #expect(inDict.filter(keys: ["NSBar"]) == ["NSBar": 2])
        #expect(inDict.filter(keys: []) == [:])

        #expect(emptyDict.filter(keys: ["CFFoo", "NSBar"]) == [:])
        #expect(emptyDict.filter(keys: []) == [:])
    }
}
