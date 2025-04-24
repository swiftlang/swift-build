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

public final class WriteFileSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.write-file"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        let execDescription = registry.internalMacroNamespace.parseString("Write $(OutputFile:file)")
        return WriteFileSpec(registry, proxy, execDescription: execDescription, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    @discardableResult public func constructFileTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, ruleName: String? = nil, contents: ByteString, permissions: Int?, forceWrite: Bool = false, diagnostics: [AuxiliaryFileTaskActionContext.Diagnostic] = [], logContents: Bool = false, preparesForIndexing: Bool, additionalTaskOrderingOptions: TaskOrderingOptions) -> Path {
        let fileContentsPath = delegate.recordAttachment(contents: contents)
        let outputNode = delegate.createNode(cbc.output)
        let execDescription = resolveExecutionDescription(cbc, delegate)
        let action = delegate.taskActionCreationDelegate.createAuxiliaryFileTaskAction(AuxiliaryFileTaskActionContext(output: outputNode.path, input: fileContentsPath, permissions: permissions, forceWrite: forceWrite, diagnostics: diagnostics, logContents: logContents))
        let ruleName = ruleName ?? "WriteAuxiliaryFile"
        delegate.createTask(type: self, ruleInfo: [ruleName, outputNode.path.str], commandLine: ["write-file", outputNode.path.str], environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.commandOrderingInputs, outputs: [ outputNode ], mustPrecede: [], action: action, execDescription: execDescription, preparesForIndexing: preparesForIndexing, enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: additionalTaskOrderingOptions, priority: .unblocksDownstreamTasks)
        return fileContentsPath
    }
}
