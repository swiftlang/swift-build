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

final class ClangCachingMaterializeKeyDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> any ExecutableTask {
        guard case let .clangCachingMaterializeKey(clangCachingTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        let cacheKey = clangCachingTaskKey.cacheKey
        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["ClangCachingMaterializeKey", cacheKey],
            commandLine: ["builtin-clangCachingMaterializeKey", .literal(ByteString(encodingAsUTF8: cacheKey))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "Clang caching materialize key \(cacheKey)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .clangCachingMaterializeKey(clangCachingTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return ClangCachingMaterializeKeyTaskAction(key: clangCachingTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}
