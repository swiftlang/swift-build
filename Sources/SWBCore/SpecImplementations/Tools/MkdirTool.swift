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

public final class MkdirToolSpec : CommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.mkdir"

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let output = cbc.output
        // We must create a virtual output usable for mutable node ordering.
        let outputs: [any PlannedNode] = [delegate.createNode(output), delegate.createVirtualNode("MkDir \(output.str)")]
        delegate.createTask(
            type: self, ruleInfo: ["MkDir", output.str],
            commandLine: ["/bin/mkdir", "-p", output.str],
            environment: EnvironmentBindings(),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: [], outputs: outputs, action: nil,
            execDescription: resolveExecutionDescription(cbc, delegate),
            preparesForIndexing: cbc.preparesForIndexing,
            enableSandboxing: enableSandboxing
        )
    }
}
