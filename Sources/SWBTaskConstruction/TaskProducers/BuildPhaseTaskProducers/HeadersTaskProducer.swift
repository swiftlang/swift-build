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

/// Produces tasks for files in a Copy Headers build phase in an Xcode target.
final class HeadersTaskProducer: FilesBasedBuildPhaseTaskProducerBase, FilesBasedBuildPhaseTaskProducer {
    typealias ManagedBuildPhase = HeadersBuildPhase

    /// If true, allow header copying to run early and out of order with other phases.
    let shouldIgnorePhaseOrdering: Bool

    init(_ context: TargetTaskProducerContext, buildPhase: BuildPhaseWithBuildFiles, phaseStartNodes: [any PlannedNode], phaseEndNode: any PlannedNode, phaseEndTask: any PlannedTask, shouldIgnorePhaseOrdering: Bool) {
        self.shouldIgnorePhaseOrdering = shouldIgnorePhaseOrdering
        super.init(context, buildPhase: buildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
    }

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        // All of these tasks must run before this target considers its modules to be ready.
        return TaskOrderingOptions([.compilationRequirement, .unsignedProductRequirement] + (shouldIgnorePhaseOrdering ? [.ignorePhaseOrdering] : []))
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        // Headers are copied only when the "headers" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("headers") else { return [] }

        if !shouldIgnorePhaseOrdering, !context.settings.globalScope.evaluate(BuiltinMacros.ENABLE_USER_SCRIPT_SANDBOXING) {
            context.emit(.warning, "tasks in '\(self.buildPhase.name)' are delayed by unsandboxed script phases; set ENABLE_USER_SCRIPT_SANDBOXING=YES to enable sandboxing", location: .buildSetting(name: "ENABLE_USER_SCRIPT_SANDBOXING"))
        }

        // Determine if we are honoring build rules (APPLY_RULES_IN_COPY_HEADERS) then lookup and apply them.
        let resolveBuildRules = scope.evaluate(BuiltinMacros.APPLY_RULES_IN_COPY_HEADERS)

        // Delegate to base implementation.
        let buildFilesContext = BuildFilesProcessingContext(scope, resolveBuildRules: resolveBuildRules)
        return await generateTasks(self, scope, buildFilesContext)
    }

    func addTasksForUngroupedFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        if let output = TargetHeaderInfo.outputPath(for: ftb.absolutePath, visibility: ftb.headerVisibility, scope: scope) {
            if scope.evaluate(BuiltinMacros.COPY_HEADERS_RUN_UNIFDEF) {
                // FIXME: We should consider making an actual "CpHeader" tool, then sinking the Unifdef conditional into it.
                let generatedTasks = await appendGeneratedTasks(&tasks) { delegate in
                    await context.unifdefSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [ftb], output: output), delegate)
                }

                // If `-b` was passed we can map directly from the copied header to the original. If it isn't, all the
                // lines will be out of sync and thus we can't add the mapping.
                if let constructedTask = generatedTasks.tasks.only as? ConstructedTask,
                   constructedTask.commandLine.contains(where: { $0 == "-b" }) {
                    context.addCopiedPath(src: ftb.absolutePath.str, dst: output.str)
                }
            } else {
                await appendGeneratedTasks(&tasks) { delegate in
                    await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [ftb], output: output, preparesForIndexing: true), delegate, ruleName: "CpHeader", additionalTaskOrderingOptions: shouldIgnorePhaseOrdering ? [.immediate, .ignorePhaseOrdering] : [.immediate])
                    context.addCopiedPath(src: ftb.absolutePath.str, dst: output.str)
                }
            }
        }
    }
}
