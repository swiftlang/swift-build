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

import SWBCore
import SWBMacro
import SWBUtil

final class DiffToolSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    static let identifier = "com.apple.build-tools.diff"

    override var enableSandboxing: Bool {
        true
    }

    class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return DiffToolSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    required convenience init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.init(parser, basedOnSpec, isGeneric: false)
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        guard cbc.inputs.count == 2 else {
            delegate.error("Expected exactly 2 inputs to diff task")
            return
        }

        let commandLine = [cbc.scope.evaluate(BuiltinMacros.DIFF).str] + cbc.inputs.map(\.absolutePath.str)

        delegate.createTask(type: self, ruleInfo: ["Diff"] + cbc.inputs.map(\.absolutePath.str), commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map { delegate.createNode($0.absolutePath) } + cbc.commandOrderingInputs, outputs: [delegate.createVirtualNode("Diff \(cbc.inputs[0].absolutePath.str) \(cbc.inputs[1].absolutePath.str)")], action: nil, execDescription: "Diff \(cbc.inputs[0].absolutePath.basename) \(cbc.inputs[1].absolutePath.basename)", enableSandboxing: enableSandboxing)
    }
}
