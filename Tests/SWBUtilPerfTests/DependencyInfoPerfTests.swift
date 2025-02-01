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

import struct SWBUtil.DependencyInfo
import SWBTestSupport
import Testing

@Suite(.performance)
fileprivate struct DependencyInfoPerfTests: PerfTests {
    @Test
    func performance_Normalize() async {
        let coolStrings = Array(repeating: "Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here", count: 10000)
        let info = DependencyInfo(version: "cool", inputs: coolStrings, missing: coolStrings, outputs: coolStrings)

        await measure { _ = info.normalized() }
    }

    @Test
    func performance_Encoding() async throws {
        let coolStrings = Array(repeating: "Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here", count: 10000)
        let info = DependencyInfo(version: "cool", inputs: coolStrings, missing: coolStrings, outputs: coolStrings)

        try await measure {
            _ = try info.asBytes()
        }
    }

    @Test
    func performance_Decoding() async throws {
        let coolStrings = Array(repeating: "Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here", count: 10000)
        let info = DependencyInfo(version: "cool", inputs: coolStrings, missing: coolStrings, outputs: coolStrings)

        let bytes = try info.asBytes()

        try await measure {
            _ = try DependencyInfo(bytes: bytes)
        }
    }
}
