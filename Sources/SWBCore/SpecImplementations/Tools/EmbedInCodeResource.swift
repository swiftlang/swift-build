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

import SWBMacro
package import SWBUtil

/// Replaces target-native seed storage with a resource's bytes.
public final class EmbedInCodeResourceSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "org.swift.build-tools.embed-in-code-resource"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        let execDescription = registry.internalMacroNamespace.parseString("Embed $(InputFileName) in code")
        return EmbedInCodeResourceSpec(registry, proxy, execDescription: execDescription, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    package func constructTasks(
        _ cbc: CommandBuildContext,
        _ delegate: any TaskGenerationDelegate,
        objectFormat: EmbeddedResourceObjectFormat,
        sectionName: String,
        dataSymbol: String
    ) {
        precondition(cbc.inputs.count == 2)
        let seedObject = cbc.inputs[0].absolutePath
        let resource = cbc.inputs[1].absolutePath
        let outputNode = delegate.createNode(cbc.output)
        let configuredObjcopy = cbc.scope.evaluate(BuiltinMacros.LLVM_OBJCOPY)
        let objcopy = configuredObjcopy.isEmpty ? Path("llvm-objcopy") : configuredObjcopy
        var commandLine = [resolveExecutablePath(cbc.producer, objcopy).str]

        switch objectFormat {
        case .macho:
            commandLine += [
                "--update-section",
                "__TEXT,\(sectionName)=\(resource.str)",
            ]
        case .elf:
            commandLine += [
                "--add-section",
                "\(sectionName)=\(resource.str)",
                "--set-section-flags",
                "\(sectionName)=alloc,load,readonly,data,contents",
                "--add-symbol",
                "\(dataSymbol)=\(sectionName):0,global,hidden,object",
            ]
        }
        commandLine += [seedObject.str, outputNode.path.str]

        delegate.createTask(
            type: self,
            ruleInfo: ["EmbedInCodeResource", resource.str, outputNode.path.str],
            commandLine: commandLine,
            environment: EnvironmentBindings(),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: cbc.inputs.map { delegate.createNode($0.absolutePath) } + cbc.commandOrderingInputs,
            outputs: [outputNode],
            mustPrecede: [],
            action: nil,
            execDescription: "Embed \(resource.basename) in code",
            preparesForIndexing: false,
            enableSandboxing: enableSandboxing,
            additionalTaskOrderingOptions: [],
            priority: .unblocksDownstreamTasks
        )
    }
}
