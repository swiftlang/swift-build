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

public import SWBCore
import SWBMacro

public final class SceneKitToolSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.scntool"

    /// Override construction to handle the custom RESOURCE_FLAG value.
    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let input = cbc.input
        let output = cbc.output

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.RESOURCE_FLAG:
                return cbc.scope.table.namespace.parseLiteralString((input.buildFile?.decompress ?? false) ? "--decompress" : "--compress")
            default:
                return nil
            }
        }
        let ruleInfo = defaultRuleInfo(cbc, delegate)
        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)
        let inputs: [any PlannedNode] = [delegate.createNode(input.absolutePath)] + cbc.commandOrderingInputs
        delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: [delegate.createNode(output)], action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }
}
