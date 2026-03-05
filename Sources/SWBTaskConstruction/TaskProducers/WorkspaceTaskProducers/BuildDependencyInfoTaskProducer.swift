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
import Foundation
import SWBProtocol

final class BuildDependencyInfoTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func generateTasks() async -> [any PlannedTask] {
        let components = context.globalProductPlan.planRequest.buildRequest.parameters.action.buildComponents
        guard components.contains("build") else {
            return []
        }

        let output = context.settings.globalScope.evaluate(BuiltinMacros.BUILD_DIR).join("BuildDependencyInfo.json")
        let dumpDependencyPaths: [Path] = targetContexts.compactMap {
            guard let target = $0.configuredTarget?.target as? SWBCore.StandardTarget else {
                return nil
            }
            guard target.sourcesBuildPhase?.buildFiles.isEmpty == false else {
                return nil
            }
            if $0.settings.globalScope.evaluate(BuiltinMacros.DUMP_DEPENDENCIES) {
                return $0.settings.globalScope.evaluate(BuiltinMacros.DUMP_DEPENDENCIES_OUTPUT_PATH)
            } else {
                return nil
            }
        }

        if dumpDependencyPaths.isEmpty {
            return []
        }

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            await context.buildDependencyInfoSpec.createTasks(
                CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: dumpDependencyPaths.map { FileToBuild(context: context, absolutePath: $0) }, output: output, commandOrderingInputs: []),
                delegate,
                dumpDependencyPaths: dumpDependencyPaths
            )
        }
        return tasks
    }
}
