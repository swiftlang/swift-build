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

final class DevelopmentAssetsTaskProducer: StandardTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        guard scope.evaluate(BuiltinMacros.VALIDATE_DEVELOPMENT_ASSET_PATHS) != .no && !scope.evaluate(BuiltinMacros.DEVELOPMENT_ASSET_PATHS).isEmpty else {
            return []
        }

        var tasks: [any PlannedTask] = []
        await appendGeneratedTasks(&tasks) { delegate in
            await context.developmentAssetsSpec?.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: []), delegate)
        }
        return tasks
    }
}
