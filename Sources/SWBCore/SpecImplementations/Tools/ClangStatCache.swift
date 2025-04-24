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

final public class ClangStatCacheSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.clang-stat-cache"

    override public var enableSandboxing: Bool {
        return false
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        await delegate.createTask(type: self,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString),
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            // We intentionally specify no inputs because clang-stat-cache always runs uses FSEvents to optimize invalidation so llbuild doesn't need to stat the entire SDK on every build.
                            inputs: [],
                            outputs: [delegate.createNode(cbc.output), delegate.createVirtualNode("ClangStatCache \(cbc.output.str)")],
                            action: nil,
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            preparesForIndexing: true,
                            enableSandboxing: enableSandboxing,
                            alwaysExecuteTask: true)
    }
}
