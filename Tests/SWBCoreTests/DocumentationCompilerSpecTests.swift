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
@_spi(Testing) import SWBCore
import Testing
import SWBTestSupport
import SWBUtil
import SWBMacro

@Suite fileprivate struct DocumentationCompilerSpecTests: CoreBasedTests {
    // Tests that `DocumentationCompilerSpec.additionalSymbolGraphGenerationArgs` only returns
    // flags that are compatible with the given Swift compiler version.
    @Test(.requireSDKs(.macOS))
    func additionalSymbolGraphGenerationArgs() async throws {
        // Support for the `-symbol-graph-minimum-access-level` flag was first introduced in
        // swiftlang-5.6.0.316.14 (rdar://79099869).
        let swiftVersionsThatSupportMinimumAccessLevel = [
            "5.6.0.316.14",
            "5.6.0.318.15",
            "6.0.0.123.10",
        ]

        // Any version prior to swiftlang-5.6.0.316.14 does not have support for
        // the `-symbol-graph-minimum-access-level` flag.
        let swiftVersionsThatDoNotSupportMinimumAccessLevel = [
            "5.5.0.123.10",
            "5.6.0.0.0",
            "5.6.0.113.6",
            "5.6.0.315.13",
            "5.6.0.316.13",
        ]

        // Confirm that when requesting additional symbol graph generation args for
        // swift versions that _do_ support minimum access level, we
        // get that flag.
        for version in swiftVersionsThatSupportMinimumAccessLevel {
            let symbolGraphGenerationArgs = await DocumentationCompilerSpec.additionalSymbolGraphGenerationArgs(
                try mockApplicationBuildContext(),
                swiftCompilerInfo: try mockSwiftCompilerSpec(swiftVersion: "5.6", swiftLangVersion: version)
            )

            #expect(symbolGraphGenerationArgs == ["-symbol-graph-minimum-access-level", "internal"])
        }

        // Confirm that when requesting additional symbol graph generation args for
        // swift versions that do _not_ support minimum access level, we
        // do not get that flag.
        for version in swiftVersionsThatDoNotSupportMinimumAccessLevel {
            let symbolGraphGenerationArgs = await DocumentationCompilerSpec.additionalSymbolGraphGenerationArgs(
                try mockApplicationBuildContext(),
                swiftCompilerInfo: try mockSwiftCompilerSpec(swiftVersion: "5.6", swiftLangVersion: version)
            )

            #expect(symbolGraphGenerationArgs.isEmpty,
                """
                'swiftlang-\(version)' does not support the minimum-access-level flag that \
                was introduced in 'swiftlang-5.6.0.316.14'.
                """)
        }
    }

    private func mockApplicationBuildContext() async throws -> CommandBuildContext {
        let core = try await getCore()

        let producer = try MockCommandProducer(
            core: core,
            productTypeIdentifier: "com.apple.product-type.application",
            platform: "macosx"
        )

        var mockTable = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        mockTable.push(BuiltinMacros.MACH_O_TYPE, literal: "mh_execute")

        let mockScope = MacroEvaluationScope(table: mockTable)

        return CommandBuildContext(producer: producer, scope: mockScope, inputs: [])
    }

    private func mockSwiftCompilerSpec(swiftVersion: String, swiftLangVersion: String) throws -> DiscoveredSwiftCompilerToolSpecInfo {
        return DiscoveredSwiftCompilerToolSpecInfo(
            toolPath: .root,
            swiftVersion: try Version(swiftVersion),
            swiftlangVersion: try Version(swiftLangVersion),
            swiftABIVersion: nil,
            clangVersion: nil,
            blocklists: SwiftBlocklists(),
            toolFeatures: ToolFeatures([])
        )
    }
}
