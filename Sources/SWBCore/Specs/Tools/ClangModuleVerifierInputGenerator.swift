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

public final class ClangModuleVerifierInputGeneratorSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.module-verifier-input-generator"

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, alwaysExecuteTask: Bool, language: String, mainOutput: Path, headerOutput: Path, moduleMapOutput: Path) async {
        var ruleInfo = defaultRuleInfo(cbc, delegate)
        ruleInfo.append(language)
        let specialArguments = [
            "--language", language,
            "--main-output", mainOutput.str,
            "--header-output", headerOutput.str,
            "--module-map-output", moduleMapOutput.str,
        ]
        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), specialArgs: specialArguments).map(\.asString)

        let inputs = cbc.inputs.map{ delegate.createNode($0.absolutePath) } + cbc.commandOrderingInputs
        let outputs = cbc.outputs.map { delegate.createNode($0) } + cbc.commandOrderingOutputs + [
            delegate.createNode(mainOutput),
            delegate.createNode(headerOutput),
            delegate.createNode(moduleMapOutput),
        ]

        delegate.createTask(type: self,
                            ruleInfo: ruleInfo,
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs, outputs: outputs,
                            action: delegate.taskActionCreationDelegate.createClangModuleVerifierInputGeneratorTaskAction(),
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            enableSandboxing: enableSandboxing,
                            alwaysExecuteTask: alwaysExecuteTask)
    }
}
