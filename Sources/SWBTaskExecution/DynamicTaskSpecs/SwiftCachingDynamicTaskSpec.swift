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
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
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
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
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
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
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

final class SwiftCachingCacheDepscanPlanDynamicTaskSpec: DynamicTaskSpec {
    var payloadType: (any TaskPayload.Type)? {
        SwiftDriverPayload.self
    }

    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
        guard case .swiftCachingCacheDepscanPlan(let key) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task: \(dynamicTask)")
        }

        let driverPayload = key.driverPayload

        let cohortArchsSuffix = driverPayload.cohortArchitectures.isEmpty ? "" : ", " + driverPayload.cohortArchitectures.joined(separator: ", ")
        let execDescription = "Caching plan of Swift module \(driverPayload.moduleName) (\(driverPayload.slice)\(cohortArchsSuffix))"
        return Task(
            type: self,
            payload: driverPayload,
            forTarget: dynamicTask.target,
            ruleInfo: ["SwiftCachingCacheDepscanPlan"] + driverPayload.ruleInfo[1...],
            commandLine: driverPayload.commandLine.map { .literal(ByteString(encodingAsUTF8: $0)) },
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: execDescription,
            preparesForIndexing: true,
            isDynamic: true
        )
    }

    func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        return SwiftCachingCacheDepscanPlanTaskAction()
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}
