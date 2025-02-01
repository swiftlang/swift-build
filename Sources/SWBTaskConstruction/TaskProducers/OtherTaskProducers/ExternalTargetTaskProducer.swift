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

final class ExternalTargetTaskProducer: StandardTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        // An external target task must block its dependencies.
        return [.compilationRequirement, .compilation]
    }

    func generateTasks() async -> [any PlannedTask] {
        let target = context.configuredTarget!.target as! ExternalTarget
        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            ShellScriptTaskProducer.constructTasksForExternalTarget(target, context, cbc: CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: []), delegate: delegate)
        }
        return tasks
    }
}
