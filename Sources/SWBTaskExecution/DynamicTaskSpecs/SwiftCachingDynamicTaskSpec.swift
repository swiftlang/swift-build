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

final class SwiftCachingKeyQueryDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> any ExecutableTask {
        guard case let .swiftCachingKeyQuery(swiftCachingKeyQueryTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["SwiftCachingKeyQuery", swiftCachingKeyQueryTaskKey.cacheKeys.description],
            commandLine: ["builtin-swiftCachingKeyQuery", .literal(ByteString(encodingAsUTF8: swiftCachingKeyQueryTaskKey.cacheKeys.description))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "Swift caching query key \(swiftCachingKeyQueryTaskKey.cacheKeys)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .swiftCachingKeyQuery(swiftCachingKeyQueryTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return SwiftCachingKeyQueryTaskAction(key: swiftCachingKeyQueryTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}

final class SwiftCachingMaterializeKeyDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> any ExecutableTask {
        guard case let .swiftCachingMaterializeKey(swiftCachingTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["SwiftCachingKeyMaterializer", swiftCachingTaskKey.cacheKeys.description],
            commandLine: ["builtin-swiftCachingKeyMaterializer", .literal(ByteString(encodingAsUTF8: swiftCachingTaskKey.cacheKeys.description))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "Swift caching materialize key \(swiftCachingTaskKey.cacheKeys)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .swiftCachingMaterializeKey(swiftCachingTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return SwiftCachingMaterializeKeyTaskAction(key: swiftCachingTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}

final class SwiftCachingOutputMaterializerDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> any ExecutableTask {
        guard case let .swiftCachingOutputMaterializer(outputMaterializerTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        let casID = outputMaterializerTaskKey.casID
        let outputKind = outputMaterializerTaskKey.outputKind
        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["SwiftCachingOutputMaterializer", outputKind, casID],
            commandLine: ["builtin-swiftCachingOutputMaterializer", .literal(ByteString(encodingAsUTF8: casID)), .literal(ByteString(encodingAsUTF8: outputKind))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "Swift caching materialize outputs from \(casID)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .swiftCachingOutputMaterializer(swiftCachingOutputMaterializerTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return SwiftCachingOutputMaterializerTaskAction(key: swiftCachingOutputMaterializerTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}
