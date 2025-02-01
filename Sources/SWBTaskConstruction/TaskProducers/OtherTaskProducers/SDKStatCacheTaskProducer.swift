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

final class SDKStatCacheTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func generateTasks() async -> [any PlannedTask] {
        var tasks = [any PlannedTask]()

        struct CacheDescriptor: Hashable {
            var sdkRoot: String
            var cachePath: Path
            var toolPath: Path
        }

        let cacheDescriptors = await Dictionary(targetContexts.asyncFilter {
            await $0.shouldUseSDKStatCache()
        }.map {
            (CacheDescriptor(sdkRoot: $0.settings.globalScope.evaluate(BuiltinMacros.SDKROOT).str,
                            cachePath: Path($0.settings.globalScope.evaluate(BuiltinMacros.SDK_STAT_CACHE_PATH)).normalize(),
                            toolPath: $0.executableSearchPaths.lookup(Path("clang-stat-cache"))?.normalize() ?? Path("clang-stat-cache")),
                            $0.settings.globalScope.evaluate(BuiltinMacros.SDK_STAT_CACHE_VERBOSE_LOGGING))
        }, uniquingKeysWith: {
            $0 || $1
        })

        await appendGeneratedTasks(&tasks) { delegate in
            for (cacheDescriptor, verbose) in cacheDescriptors {
                var table = MacroValueAssignmentTable(namespace: context.settings.globalScope.namespace)
                table.push(BuiltinMacros.CLANG_STAT_CACHE_EXEC, literal: cacheDescriptor.toolPath.str)
                table.push(BuiltinMacros.SDKROOT, literal: cacheDescriptor.sdkRoot)
                table.push(BuiltinMacros.SDK_STAT_CACHE_VERBOSE_LOGGING, literal: verbose)
                await context.clangStatCacheSpec?.constructTasks(CommandBuildContext(producer: context, scope: MacroEvaluationScope(table: table), inputs: [], output: cacheDescriptor.cachePath), delegate)
            }
        }

        return tasks
    }
}
