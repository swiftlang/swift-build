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

public final class DsymutilToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.dsymutil"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public override func environmentFromSpec(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [(String, String)] {
        var env: [(String, String)] = super.environmentFromSpec(cbc, delegate, lookup: lookup)
        // dsymutil may need to lookup lipo, which is not necessarily in the same toolchain.
        env.append(("PATH", cbc.producer.executableSearchPaths.environmentRepresentation))
        return env
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

        let embedResources = cbc.scope.evaluate(BuiltinMacros.DSYMUTIL_EMBED_RESOURCES)
        let inputs: [any PlannedNode] = cbc.inputs.map({ delegate.createNode($0.absolutePath) }) + cbc.commandOrderingInputs + embedResources.compactMap { entry in
            guard let src = entry.split(separator: "=", maxSplits: 1).first else { return nil }
            let path = Path(String(src))
            return delegate.createDirectoryTreeNode(path.isAbsolute ? path : cbc.scope.evaluate(BuiltinMacros.PROJECT_DIR).join(path))
        }
        let outputs: [any PlannedNode] = [delegate.createNode(output), orderingOutputNode] + cbc.commandOrderingOutputs

        var builder = PlannedTaskBuilder(type: self, ruleInfo: ruleInfo, commandLine: commandLine.map { .literal(ByteString(encodingAsUTF8: $0)) }, environment: environmentFromSpec(cbc, delegate), enableSandboxing: enableSandboxing)
        builder.workingDirectory = cbc.producer.defaultWorkingDirectory
        builder.inputs = inputs
        builder.outputs = outputs
        builder.execDescription = resolveExecutionDescription(templateBuildContext, delegate)
        // Track the dSYM bundle for stale file removal so the entire bundle is cleaned up.
        builder.additionalSFRPaths = [dsymBundle]
        delegate.createTask(&builder)
    }
}
