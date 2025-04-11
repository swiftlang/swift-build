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

import SWBMacro
import SWBUtil

public final class StripToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.strip"

    /// Custom override to inject an appropriate output path.
    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let input = cbc.input
        let inputs: [any PlannedNode] = [delegate.createNode(input.absolutePath)] + cbc.commandOrderingInputs
        let outputs: [any PlannedNode] = [delegate.createNode(input.absolutePath), delegate.createVirtualNode("Strip \(input.absolutePath.str)")] + cbc.commandOrderingOutputs
        await delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString), environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, mustPrecede: [], action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }

    public func constructStripDebugSymbolsTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let input = cbc.input
        let inputs: [any PlannedNode] = [delegate.createNode(input.absolutePath)] + cbc.commandOrderingInputs
        let outputs: [any PlannedNode] = [delegate.createNode(input.absolutePath), delegate.createVirtualNode("Strip \(input.absolutePath.str)")] + cbc.commandOrderingOutputs
        let lookup: ((MacroDeclaration) -> MacroExpression?) = {
            switch $0 {
            case BuiltinMacros.STRIP_STYLE:
                return cbc.scope.table.namespace.parseLiteralString(StripStyle.debugging.rawValue)
            case BuiltinMacros.STRIP_SWIFT_SYMBOLS:
                return cbc.scope.table.namespace.parseLiteralString("NO")
            case BuiltinMacros.STRIPFLAGS:
                return cbc.scope.table.namespace.parseLiteralStringList([])
            default:
                return nil
            }
        }
        await delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString), environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, mustPrecede: [], action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }
}
