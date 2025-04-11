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
import SWBTaskConstruction
import SWBMacro

class TestEntryPointTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        var tasks: [any PlannedTask] = []
        if context.settings.globalScope.evaluate(BuiltinMacros.GENERATE_TEST_ENTRY_POINT) {
            await self.appendGeneratedTasks(&tasks) { delegate in
                let scope = context.settings.globalScope
                let outputPath = scope.evaluate(BuiltinMacros.GENERATED_TEST_ENTRY_POINT_PATH)
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [], outputs: [outputPath])
                await context.testEntryPointGenerationToolSpec.constructTasks(cbc, delegate)
            }
        }
        return tasks
    }
}

extension TaskProducerContext {
    var testEntryPointGenerationToolSpec: TestEntryPointGenerationToolSpec {
        return workspaceContext.core.specRegistry.getSpec(TestEntryPointGenerationToolSpec.identifier, domain: domain) as! TestEntryPointGenerationToolSpec
    }
}
