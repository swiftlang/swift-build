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

public import SWBUtil
public import SWBMacro

public final class SwiftABIGenerationToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, SwiftDiscoveredCommandLineToolSpecInfo, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.swift-abi-generation"

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await (self as (any SwiftDiscoveredCommandLineToolSpecInfo)).discoveredCommandLineToolSpecInfo(producer, scope, delegate)
        } catch {
            delegate.error(error)
            return nil
        }
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }
    public func constructABIGenerationTask(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ baselineFile: Path) async {
        let toolSpecInfo: DiscoveredSwiftCompilerToolSpecInfo
        do {
            toolSpecInfo = try await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
        } catch {
            delegate.error("Unable to discover `swiftc` command line tool info: \(error)")
            return
        }

        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)
        commandLine += ["-o", baselineFile.normalize().str]
        commandLine += cbc.scope.evaluate(BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS).flatMap { ["-F", $0] }
        // Add import search paths
        for searchPath in SwiftCompilerSpec.collectInputSearchPaths(cbc, toolInfo: toolSpecInfo) {
            commandLine += ["-I", searchPath]
        }
        delegate.createTask(type: self,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: cbc.inputs.map { delegate.createNode($0.absolutePath) },
                            outputs: [delegate.createNode(cbc.output)],
                            enableSandboxing: enableSandboxing)
    }
}
