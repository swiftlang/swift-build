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
import SWBMacro

public final class SetAttributesSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.set-attributes"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return SetAttributesSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    /// Create a task to set the given attributes.
    ///
    /// - owner: The owner to set, if provided.
    /// - group: The group to set, if provided.
    /// - mode: The mode to set, if provided.
    public func constructSetAttributesTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, owner: String?, group: String?, mode: String?) {
        // Compute the input and output path.
        let input = cbc.input

        // Create the `chown` task, if used.
        let chownOutput: (any PlannedNode)? = {
            let ruleType: String, attrs: String, ruleLabel: String, execDescription: String
            switch (owner, group) {
            case (nil, nil):
                return nil
            case (let owner?, let group?):
                ruleType = "SetOwnerAndGroup"
                attrs = owner + ":" + group
                ruleLabel = attrs
                execDescription = "Set Owner and Group"
            case (let owner?, nil):
                ruleType = "SetOwner"
                attrs = owner
                ruleLabel = attrs
                execDescription = "Set Owner"
            case (nil, let group?):
                ruleType = "SetGroup"
                attrs = ":" + group
                ruleLabel = group
                execDescription = "Set Group"
            }

            let args = [cbc.scope.evaluate(BuiltinMacros.CHOWN).str, "-RH", attrs, input.absolutePath.str]

            let commandOutput = delegate.createVirtualNode("SetOwner \(input.absolutePath.str)")
            let outputs: [any PlannedNode] = [delegate.createNode(input.absolutePath), commandOutput]

            delegate.createTask(type: self, ruleInfo: [ruleType, ruleLabel, input.absolutePath.str], commandLine: args, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [delegate.createNode(input.absolutePath)], outputs: outputs, mustPrecede: [], action: nil, execDescription: execDescription, enableSandboxing: enableSandboxing)

            return commandOutput
        }()

        // Create the `chmod` task, if used.
        if let mode {
            // BSD (and therefore Apple) chmod has -H, GNU coreutils chmod does not
            // FIXME: Detect the chmod flavor and conditionalize on BSD vs GNU instead of Apple vs non-Apple
            let flags = cbc.producer.isApplePlatform ? "-RH" : "-R"
            let args = [cbc.scope.evaluate(BuiltinMacros.CHMOD).str, flags, mode, input.absolutePath.str]
            let outputs: [any PlannedNode] = [delegate.createNode(input.absolutePath), delegate.createVirtualNode("SetMode \(input.absolutePath.str)")]

            // Artificially enforce an ordering between chown and chmod, if both are used.
            var inputs: [any PlannedNode] = [delegate.createNode(input.absolutePath)]
            if let chownOutput = chownOutput {
                inputs.append(chownOutput)
            }

            delegate.createTask(type: self, ruleInfo: ["SetMode", mode, input.absolutePath.str], commandLine: args, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, mustPrecede: [], action: nil, execDescription: "Set Mode", enableSandboxing: enableSandboxing)
        }
    }
}
