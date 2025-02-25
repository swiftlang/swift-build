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
import SWBProtocol
public import SWBUtil

public struct SwiftDriverPlanningTaskKey: Serializable, CustomDebugStringConvertible {
    let swiftPayload: SwiftTaskPayload

    init(swiftPayload: SwiftTaskPayload) {
        self.swiftPayload = swiftPayload
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(1) {
            serializer.serialize(swiftPayload)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.swiftPayload = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<SwiftDriverPlanning ruleInfo=\(swiftPayload.driverPayload?.ruleInfo.joined(separator: " ") ?? "")>"
    }
}

final class SwiftDriverPlanningDynamicTaskSpec: DynamicTaskSpec {
    var payloadType: (any TaskPayload.Type)? {
        SwiftTaskPayload.self
    }

    func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> any ExecutableTask {
        guard case .swiftDriverPlanning(let key) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task: \(dynamicTask)")
        }
        guard let driverPayload = key.swiftPayload.driverPayload else {
            fatalError("Attempted to request a driver planning operation with no driver payload")
        }

        return Task(type: self,
                    payload: key.swiftPayload,
                    forTarget: dynamicTask.target,
                    ruleInfo: driverPayload.ruleInfo,
                    commandLine: driverPayload.commandLine.map { .literal(ByteString(encodingAsUTF8: $0)) },
                    environment: dynamicTask.environment,
                    workingDirectory: dynamicTask.workingDirectory,
                    showEnvironment: dynamicTask.showEnvironment,
                    execDescription: "Planning Swift module \(driverPayload.moduleName) (\(driverPayload.architecture))",
                    preparesForIndexing: true,
                    priority: .unblocksDownstreamTasks,
                    isDynamic: true
                )
    }

    func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        return SwiftDriverTaskAction()
    }
}
