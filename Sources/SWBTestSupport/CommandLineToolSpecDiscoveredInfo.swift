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

package import Testing
package import SWBCore
package import SWBProtocol
import SWBUtil
package import SWBMacro

extension CoreBasedTests {
    package func withSpec<T: DiscoveredCommandLineToolSpecInfo, U: IdentifiedSpecType>(_ identifier: U.Type, _ result: ExternalToolResult, platform: String? = nil, additionalTable: MacroValueAssignmentTable? = nil, _ block: (_ info: T) throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await withSpec(U.identifier, result, platform: platform, additionalTable: additionalTable, block, sourceLocation: sourceLocation)
    }

    package func withSpec<T: DiscoveredCommandLineToolSpecInfo>(_ identifier: String, _ result: ExternalToolResult, platform: String? = nil, additionalTable: MacroValueAssignmentTable? = nil, _ block: (_ info: T) throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let core = try await getCore()
        let spec = try core.specRegistry.getSpec(identifier) as CommandLineToolSpec

        // Create the context to use to discover the info.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        if let additionalTable {
            table.pushContentsOf(additionalTable)
        }
        let scope = MacroEvaluationScope(table: table)

        // Look up the discovered info and examine it.
        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.library.dynamic", platform: platform ?? "macosx", useStandardExecutableSearchPaths: true)

        let delegate = try ToolSpecCapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting, result: result)
        guard let info = await spec.discoveredCommandLineToolSpecInfo(producer, scope, delegate) else {
            let errors = delegate._diagnosticsEngine.diagnostics.filter({ $0.behavior == .error })
            for error in errors {
                Issue.record(Comment(rawValue: error.formatLocalizedDescription(.debugWithoutBehavior)), sourceLocation: sourceLocation)
            }
            if errors.isEmpty {
                throw StubError.error("Failed to obtain command line tool spec info but no errors were emitted")
            }
            return
        }
        guard let info = info as? T else {
            throw StubError.error("Expected tool spec info of type \(type(of: T.self)); found \(type(of: info)))")
        }
        try block(info)
    }
}

private class ToolSpecCapturingTaskGenerationDelegate: CapturingTaskGenerationDelegate {
    let result: ExternalToolResult

    init(producer: any CommandProducer, userPreferences: UserPreferences, result: ExternalToolResult) throws {
        self.result = result
        try super.init(producer: producer, userPreferences: userPreferences)
    }

    override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> ExternalToolResult {
        result
    }
}
