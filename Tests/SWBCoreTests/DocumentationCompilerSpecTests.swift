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
    // flags that are compatible with the given context.
    @Test(.requireSDKs(.macOS))
    func additionalSymbolGraphGenerationArgs() async throws {
        let applicationArgs = await DocumentationCompilerSpec.additionalSymbolGraphGenerationArgs(
            try mockApplicationBuildContext(application: true),
            swiftCompilerInfo: try mockSwiftCompilerSpec(swiftVersion: "5.6", swiftTag: "swiftlang-5.6.0.0")
        )
        #expect(applicationArgs == ["-symbol-graph-minimum-access-level", "internal"])

        let frameworkArgs = await DocumentationCompilerSpec.additionalSymbolGraphGenerationArgs(
            try mockApplicationBuildContext(application: false),
            swiftCompilerInfo: try mockSwiftCompilerSpec(swiftVersion: "5.6", swiftTag: "swiftlang-5.6.0.0")
        )
        #expect(frameworkArgs == [])
    }

    private func mockApplicationBuildContext(application: Bool) async throws -> CommandBuildContext {
        let core = try await getCore()

        let producer = try MockCommandProducer(
            core: core,
            productTypeIdentifier: application ? "com.apple.product-type.application" : "com.apple.product-type.framework",
            platform: "macosx"
        )

        var mockTable = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        if application {
            mockTable.push(BuiltinMacros.MACH_O_TYPE, literal: "mh_execute")
        }

        let mockScope = MacroEvaluationScope(table: mockTable)

        return CommandBuildContext(producer: producer, scope: mockScope, inputs: [])
    }

    private func mockSwiftCompilerSpec(swiftVersion: String, swiftTag: String) throws -> DiscoveredSwiftCompilerToolSpecInfo {
        return DiscoveredSwiftCompilerToolSpecInfo(
            toolPath: .root,
            swiftVersion: try Version(swiftVersion),
            swiftTag: swiftTag,
            swiftABIVersion: nil,
            blocklists: SwiftBlocklists(),
            toolFeatures: ToolFeatures([])
        )
    }
}
