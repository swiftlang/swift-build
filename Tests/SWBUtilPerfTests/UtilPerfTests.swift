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

import Testing
import SWBUtil
import SWBTestSupport

@Suite(.performance)
fileprivate struct UtilPerfTests: PerfTests {
    @Test
    func JSONEncoding() async throws {
        let itemToEncode = PropertyListItem.plDict([
            "key0": .plString("value0"),
            "key1": .plArray([.plString("value1.0"), .plString("value1.1"), .plString("value1.2")]),
            "key2": .plDict([
                "value2.key0": .plString("value2.value0"),
                "value2.key1": .plString("value2.value1"),
                "value2.key2": .plString("value2.value2"),
                "value2.key3": .plString("value2.value3")
            ])
        ])

        let iterations = 10000
        var result: String = ""
        try await measure {
            for i in 0..<iterations {
                let encoded = try itemToEncode.asJSONFragment()
                if i == iterations - 1 {
                    result = encoded.bytes.asReadableString()
                }
            }
        }

        // FIXME: Since the order of keys in dictionaries in the encoded string is nondeterministic, this validation check is currently rather fuzzy.
        //        XCTAssertEqual(result, "{\"key0\":\"value0\",\"key1\":[\"value1.0\",\"value1.1\",\"value1.2\"],\"key2\":{\"value2.key2\":\"value2.value2\",\"value2.key3\":\"value2.value3\",\"value2.key0\":\"value2.value0\",\"value2.key1\":\"value2.value1\"}}")
        XCTAssertMatch(result, .contains("\"key0\":\"value0\""))
        XCTAssertMatch(result, .contains("\"key1\":[\"value1.0\",\"value1.1\",\"value1.2\"]"))
        XCTAssertMatch(result, .contains("\"key2\":{"))
        XCTAssertMatch(result, .contains("\"value2.key0\":\"value2.value0\""))
        XCTAssertMatch(result, .contains("\"value2.key1\":\"value2.value1\""))
        XCTAssertMatch(result, .contains("\"value2.key2\":\"value2.value2\""))
        XCTAssertMatch(result, .contains("\"value2.key3\":\"value2.value3\""))
    }
}
