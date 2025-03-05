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
import SWBMacro

public final class DsymutilToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.dsymutil"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    /// Override construction to patch the inputs.
    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, dsymBundle: Path, buildVariant: String = "", dsymSearchPaths: [String] = [], quietOperation: Bool = false) async {
        let output = cbc.output

        let templateBuildContext = CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: cbc.inputs, output: dsymBundle)

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.DSYMUTIL_VARIANT_SUFFIX:
                return cbc.scope.table.namespace.parseLiteralString(buildVariant)
            case BuiltinMacros.DSYMUTIL_DSYM_SEARCH_PATHS:
                return cbc.scope.table.namespace.parseLiteralStringList(dsymSearchPaths)
            case BuiltinMacros.DSYMUTIL_QUIET_OPERATION:
                if quietOperation {
                    return cbc.scope.table.namespace.parseLiteralString("YES")
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        let commandLine = await commandLineFromTemplate(templateBuildContext, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)
        let ruleInfo = defaultRuleInfo(templateBuildContext, delegate)

        // Create a virtual output node so any strip task can be ordered after this.
        let orderingOutputNode = delegate.createVirtualNode("GenerateDSYMFile \(output.str)")

        let inputs: [any PlannedNode] = cbc.inputs.map({ delegate.createNode($0.absolutePath) }) + cbc.commandOrderingInputs
        let outputs: [any PlannedNode] = [delegate.createNode(output), orderingOutputNode] + cbc.commandOrderingOutputs
        delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, action: nil, execDescription: resolveExecutionDescription(templateBuildContext, delegate), enableSandboxing: enableSandboxing)
    }
}
