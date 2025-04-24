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
import SWBUtil
import SWBMacro

/// A task producer responsible for adding custom tasks specified in the project model to the graph.
final class CustomTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        var tasks: [any PlannedTask] = []

        await appendGeneratedTasks(&tasks) { delegate in
            for customTask in context.configuredTarget?.target.customTasks ?? [] {
                
                let commandLine = customTask.commandLine.map { context.settings.globalScope.evaluate($0) }
                var environmentAssignments = computeScriptEnvironment(.shellScriptPhase, scope: context.settings.globalScope, settings: context.settings, workspaceContext: context.workspaceContext)
                if context.workspaceContext.core.hostOperatingSystem != .macOS {
                    environmentAssignments = environmentAssignments.filter { $0.key.lowercased() != "path" }
                }
                for (key, value) in customTask.environment {
                    environmentAssignments[context.settings.globalScope.evaluate(key)] = context.settings.globalScope.evaluate(value)
                }
                let environment = EnvironmentBindings(environmentAssignments)
                let workingDirectory = customTask.workingDirectory.map { Path(context.settings.globalScope.evaluate($0)).normalize() } ?? context.defaultWorkingDirectory
                let inputPaths = customTask.inputFilePaths.map { Path(context.settings.globalScope.evaluate($0)).normalize() }
                let inputs = inputPaths.map { delegate.createNode($0) }
                var outputs: [any PlannedNode] = customTask.outputFilePaths.map { Path(context.settings.globalScope.evaluate($0)).normalize() }.map { delegate.createNode($0) }
                
                if outputs.isEmpty {
                    // If there are no outputs, create a virtual output that can be wired up to gates
                    let md5Context = InsecureHashContext()
                    for arg in commandLine {
                        md5Context.add(string: arg)
                    }
                    for (key, value) in environment.bindingsDictionary {
                        md5Context.add(string: key)
                        md5Context.add(string: value)
                    }
                    md5Context.add(string: workingDirectory.str)
                    for input in inputPaths {
                        md5Context.add(string: input.str)
                    }
                    outputs.append(delegate.createVirtualNode("CustomTask-\(md5Context.signature.asString)"))
                }
                
                delegate.createTask(
                    type: CustomTaskTypeDescription.only,
                    ruleInfo: ["CustomTask", context.settings.globalScope.evaluate(customTask.executionDescription)],
                    commandLine: commandLine,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    inputs: inputs,
                    outputs: outputs,
                    execDescription: context.settings.globalScope.evaluate(customTask.executionDescription),
                    preparesForIndexing: customTask.preparesForIndexing,
                    enableSandboxing: customTask.enableSandboxing)
            }
        }

        return tasks
    }
}
