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

public final class ShellScriptToolSpec : CommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.commands.shell-script"

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public func constructShellScriptTasks(
        _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate,
        ruleInfo: [String], commandLine: [String], environment: EnvironmentBindings,
        workingDirectory: Path? = nil, inputs: [any PlannedNode], outputs: [any PlannedNode],
        dependencyData: DependencyDataStyle?, execDescription: String,
        showEnvironment: Bool, alwaysExecuteTask: Bool, enableSandboxing: Bool,
        payload: (any TaskPayload)? = nil, action: (any PlannedTaskAction)? = nil,
        repairViaOwnershipAnalysis: Bool = false
    ) {
        delegate.createTask(
            type: self, dependencyData: dependencyData, payload: payload,
            ruleInfo: ruleInfo, additionalSignatureData: "",
            commandLine: commandLine.map { ByteString(encodingAsUTF8: $0) },
            additionalOutput: [], environment: environment,
            workingDirectory: workingDirectory ?? cbc.producer.defaultWorkingDirectory,
            inputs: inputs, outputs: outputs, mustPrecede: [],
            action: action ?? delegate.taskActionCreationDelegate
                .createDeferredExecutionTaskActionIfRequested(
                    userPreferences: delegate.userPreferences
                ),
            execDescription: execDescription,
            preparesForIndexing: cbc.preparesForIndexing,
            enableSandboxing: enableSandboxing,
            llbuildControlDisabled: true, additionalTaskOrderingOptions: [],
            alwaysExecuteTask: alwaysExecuteTask, showEnvironment: showEnvironment,
            repairViaOwnershipAnalysis: repairViaOwnershipAnalysis
        )
    }

    override public func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        // Unlike other output parsers, shell script output parsers emit all unknown lines of output as notices.
        return ShellScriptOutputParser.self
    }
}
