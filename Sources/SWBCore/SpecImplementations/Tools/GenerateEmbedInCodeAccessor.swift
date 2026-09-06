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

import SWBUtil
import SWBMacro
import SWBProtocol

/// Generates the `embedded_resources.swift` accessor for resources marked `embedInCode`.
public final class GenerateEmbedInCodeAccessorSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "org.swift.build-tools.generate-embed-in-code-accessor"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        let execDescription = registry.internalMacroNamespace.parseString("Generate $(OutputFile:file)")
        return GenerateEmbedInCodeAccessorSpec(registry, proxy, execDescription: execDescription, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) {
        let outputNode = delegate.createNode(cbc.output)
        let resourcePaths = cbc.inputs.map(\.absolutePath)
        let inputNodes = resourcePaths.map(delegate.createNode) + cbc.commandOrderingInputs
        var outputNodes = [outputNode]
        let action = delegate.taskActionCreationDelegate.createGenerateEmbedInCodeAccessorTaskAction()
        let moduleName = cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
        var commandLine = [
            "builtin-generateEmbedInCodeAccessor",
            "--output", outputNode.path.str,
            "--module-name", moduleName,
        ]
        for resource in cbc.inputs {
            switch resource.buildFile?.resourceRule {
            case .embedInCodeAsObject:
                let info = EmbeddedResourceObjectInfo(
                    moduleName: moduleName,
                    path: resource.absolutePath,
                    outputDirectory: cbc.output.dirname
                )
                outputNodes += [delegate.createNode(info.sourcePath), delegate.createNode(info.payloadPath)]
                commandLine += ["--object", resource.absolutePath.str]
            default:
                commandLine += ["--byte-array", resource.absolutePath.str]
            }
        }
        delegate.createTask(
            type: self,
            ruleInfo: ["GenerateEmbedInCodeAccessor", outputNode.path.str],
            commandLine: commandLine,
            environment: EnvironmentBindings(),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputNodes,
            outputs: outputNodes,
            mustPrecede: [],
            action: action,
            execDescription: resolveExecutionDescription(cbc, delegate),
            preparesForIndexing: true,
            enableSandboxing: enableSandboxing,
            additionalTaskOrderingOptions: [.immediate],
            priority: .unblocksDownstreamTasks
        )
    }
}
