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

import SWBProtocol
import SWBUtil
public import SWBMacro

public final class RegisterExecutionPolicyExceptionToolSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tasks.register-execution-policy-exception"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return RegisterExecutionPolicyExceptionToolSpec(registry, proxy, ruleInfoTemplate: ["RegisterExecutionPolicyException", .input], commandLineTemplate: [.execPath, .options, .input])
    }

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        return "builtin-RegisterExecutionPolicyException"
    }

    public override func resolveExecutionDescription(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        return cbc.scope.evaluate(cbc.scope.namespace.parseString("Register execution policy exception for $(InputFileName)"), lookup: { self.lookup($0, cbc, delegate, lookup) })
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public func constructRegisterExecutionPolicyExceptionTask(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let input = cbc.input
        let outputs = [delegate.createVirtualNode("RegisterExecutionPolicyException \(input.absolutePath.str)")]

        let action = delegate.taskActionCreationDelegate.createRegisterExecutionPolicyExceptionTaskAction()
        await delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString), environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [delegate.createNode(input.absolutePath)], outputs: outputs, mustPrecede: [], action: action, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }
}
