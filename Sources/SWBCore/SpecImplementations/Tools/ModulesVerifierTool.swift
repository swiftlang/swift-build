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

public final class ModulesVerifierToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.modules-verifier"

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public func constructModuleVerifierTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, alwaysExecuteTask: Bool, fileNameMapPath: Path) async {
        let ruleInfo = defaultRuleInfo(cbc, delegate)

        let clangSpec = try! cbc.producer.getSpec() as ClangCompilerSpec
        let clangPath = clangSpec.resolveExecutablePath(cbc, Path("clang"))
        let specialArguments = ["--clang", clangPath.str, "--diagnostic-filename-map", fileNameMapPath.str]

        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), specialArgs: specialArguments).map(\.asString)

        let inputs = cbc.inputs.map{ delegate.createNode($0.absolutePath) } + cbc.commandOrderingInputs
        let outputs = cbc.outputs.map { delegate.createNode($0) } + cbc.commandOrderingOutputs

        delegate.createTask(type: self,
                            ruleInfo: ruleInfo,
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs, outputs: outputs, action: nil,
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            enableSandboxing: enableSandboxing,
                            alwaysExecuteTask: alwaysExecuteTask)
    }
}
