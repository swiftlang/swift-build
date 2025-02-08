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

import SWBUtil
public import SWBMacro

public final class ValidateEmbeddedBinaryToolSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.validate-embedded-binary-utility"

    public func constructValidateEmbeddedBinaryTask(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) async {
        let input = cbc.input
        let outputPath = input.absolutePath

        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)
        commandLine[0] = resolveExecutablePath(cbc, Path("embeddedBinaryValidationUtility")).str

        let inputs: [any PlannedNode] = [delegate.createNode(input.absolutePath)] + cbc.commandOrderingInputs
        let outputs: [any PlannedNode] = [delegate.createNode(outputPath)] + (cbc.commandOrderingOutputs.isEmpty ? [delegate.createVirtualNode("ValidateEmbeddedBinary \(outputPath.str)")] : cbc.commandOrderingOutputs)
        delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }
}
