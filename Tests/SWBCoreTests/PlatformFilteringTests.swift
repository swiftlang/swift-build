//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing

@_spi(Testing) import SWBCore
@_spi(Testing) import SWBMacro

@Suite
struct PlatformFilteringTests {
    private func createPlatformFilter(triple: String, swiftPlatformTargetPrefix: String, targetTripleSuffix: String = "") -> PlatformFilter? {
        var table = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)
        table.push(BuiltinMacros.SWIFT_TARGET_TRIPLE, literal: triple)
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: swiftPlatformTargetPrefix)
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX, literal: targetTripleSuffix)
        let scope = MacroEvaluationScope(table: table)
        return PlatformFilter(scope)
    }

    @Test
    func androidFilters() {
        do {
            let filter = createPlatformFilter(triple: "aarch64-none-linux-android24", swiftPlatformTargetPrefix: "linux", targetTripleSuffix: "-android24")
            let expected = PlatformFilter(platform: "linux", environment: "android")
            #expect(filter == expected)
        }

        do {
            let filter = createPlatformFilter(triple: "aarch64-none-linux-android", swiftPlatformTargetPrefix: "linux", targetTripleSuffix: "-android")
            let expected = PlatformFilter(platform: "linux", environment: "android")
            #expect(filter == expected)
        }
    }
}
