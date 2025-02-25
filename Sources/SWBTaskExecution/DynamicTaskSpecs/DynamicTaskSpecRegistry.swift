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

import Foundation
package import SWBCore
import SWBProtocol
public import SWBUtil

/// Static registry that maps between tool identifiers to DynamicTaskSpecs.
package final class DynamicTaskSpecRegistry {
    private static let implementations: [String: any DynamicTaskSpec] = [
        PrecompileClangModuleTaskAction.toolIdentifier: PrecompileClangModuleDynamicTaskSpec(),
        SwiftDriverJobTaskAction.toolIdentifier: SwiftDriverJobDynamicTaskSpec(),
        SwiftDriverTaskAction.toolIdentifier: SwiftDriverPlanningDynamicTaskSpec(),
        ClangCachingMaterializeKeyTaskAction.toolIdentifier: ClangCachingMaterializeKeyDynamicTaskSpec(),
        ClangCachingKeyQueryTaskAction.toolIdentifier: ClangCachingKeyQueryDynamicTaskSpec(),
        ClangCachingOutputMaterializerTaskAction.toolIdentifier: ClangCachingOutputMaterializerDynamicTaskSpec(),
        SwiftCachingMaterializeKeyTaskAction.toolIdentifier: SwiftCachingMaterializeKeyDynamicTaskSpec(),
        SwiftCachingKeyQueryTaskAction.toolIdentifier: SwiftCachingKeyQueryDynamicTaskSpec(),
        SwiftCachingOutputMaterializerTaskAction.toolIdentifier: SwiftCachingOutputMaterializerDynamicTaskSpec(),
    ]

    package static func spec(for toolIdentifier: String) -> (any DynamicTaskSpec)? {
        return implementations[toolIdentifier]
    }
}

package protocol DynamicTaskSpec: TaskTypeDescription {
    func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) throws -> any ExecutableTask

    func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) throws -> TaskAction
}

extension DynamicTaskSpec {
    var payloadType: (any TaskPayload.Type)? { nil }

    var toolBasenameAliases: [String] { [] }

    func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        return []
    }

    func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        return []
    }

    func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] {
        return []
    }

    func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] {
        return []
    }

    package func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
        return []
    }

    func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return nil
    }

    func interestingPath(for task: any ExecutableTask) -> Path? {
        return nil
    }

    func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]? {
        return nil
    }

    var isUnsafeToInterrupt: Bool { false }
}

/// Enum used to serialize known dynamic task keys. This is required since it's not possible to serialize DynamicTask
/// in a generic way.
///
/// Next id to use is 8.
public enum DynamicTaskKey: Serializable, CustomDebugStringConvertible {
    case precompileClangModule(PrecompileClangModuleTaskKey)

    case swiftDriverJob(SwiftDriverJobTaskKey)
    case swiftDriverExplicitDependencyJob(SwiftDriverExplicitDependencyJobTaskKey)
    case swiftDriverPlanning(SwiftDriverPlanningTaskKey)

    case clangCachingMaterializeKey(ClangCachingTaskCacheKey)
    case clangCachingKeyQuery(ClangCachingTaskCacheKey)
    case clangCachingOutputMaterializer(ClangCachingOutputMaterializerTaskKey)

    case swiftCachingMaterializeKey(SwiftCachingKeyQueryTaskKey)
    case swiftCachingKeyQuery(SwiftCachingKeyQueryTaskKey)
    case swiftCachingOutputMaterializer(SwiftCachingOutputMaterializerTaskKey)

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        /// In each case, serialize an id that can be used for mapping to the correct type during deserialization.
        switch self {
        case .precompileClangModule(let key):
            serializer.serialize(0)
            serializer.serialize(key)
        case .swiftDriverJob(let key):
            serializer.serialize(2)
            serializer.serialize(key)
        case .swiftDriverExplicitDependencyJob(let key):
            serializer.serialize(3)
            serializer.serialize(key)
        case .swiftDriverPlanning(let key):
            serializer.serialize(4)
            serializer.serialize(key)
        case .clangCachingMaterializeKey(let key):
            serializer.serialize(5)
            serializer.serialize(key)
        case .clangCachingKeyQuery(let key):
            serializer.serialize(6)
            serializer.serialize(key)
        case .clangCachingOutputMaterializer(let key):
            serializer.serialize(7)
            serializer.serialize(key)
        case .swiftCachingMaterializeKey(let key):
            serializer.serialize(8)
            serializer.serialize(key)
        case .swiftCachingKeyQuery(let key):
            serializer.serialize(9)
            serializer.serialize(key)
        case .swiftCachingOutputMaterializer(let key):
            serializer.serialize(10)
            serializer.serialize(key)
        }
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        let type: Int = try deserializer.deserialize()
        switch type {
        case 0:
            self = .precompileClangModule(try deserializer.deserialize())
        case 2:
            self = .swiftDriverJob(try deserializer.deserialize())
        case 3:
            self = .swiftDriverExplicitDependencyJob(try deserializer.deserialize())
        case 4:
            self = .swiftDriverPlanning(try deserializer.deserialize())
        case 5:
            self = .clangCachingMaterializeKey(try deserializer.deserialize())
        case 6:
            self = .clangCachingKeyQuery(try deserializer.deserialize())
        case 7:
            self = .clangCachingOutputMaterializer(try deserializer.deserialize())
        case 8:
            self = .swiftCachingMaterializeKey(try deserializer.deserialize())
        case 9:
            self = .swiftCachingKeyQuery(try deserializer.deserialize())
        case 10:
            self = .swiftCachingOutputMaterializer(try deserializer.deserialize())
        default:
            throw DeserializerError.incorrectType("Unsupported type \(type)")
        }
    }

    public var debugDescription: String {
        switch self {
        case let .precompileClangModule(key):
            return key.debugDescription
        case let .swiftDriverJob(key):
            return key.debugDescription
        case let .swiftDriverExplicitDependencyJob(key):
            return key.debugDescription
        case let .swiftDriverPlanning(key):
            return key.debugDescription
        case let .clangCachingMaterializeKey(key):
            return key.debugDescription
        case let .clangCachingKeyQuery(key):
            return key.debugDescription
        case let .clangCachingOutputMaterializer(key):
            return key.debugDescription
        case let .swiftCachingMaterializeKey(key):
            return key.debugDescription
        case let .swiftCachingKeyQuery(key):
            return key.debugDescription
        case let .swiftCachingOutputMaterializer(key):
            return key.debugDescription
        }
    }
}

/// Descriptor for a dynamic task.
///
/// This descriptor is serialized into llbuild's CustomTaskKey, so care is needed to not
/// add unnecessary fields to this struct.
package struct DynamicTask: Serializable {
    /// The identifier for the tool that's to execute this dynamic task.
    package let toolIdentifier: String

    /// The tool-specific arguments that the DynamicTaskSpec reads in order to generate an ExecutableTask.
    package let taskKey: DynamicTaskKey

    /// The working directory under which to execute the action.
    package let workingDirectory: Path

    /// The environment variables to set during the action execution.
    package let environment: EnvironmentBindings

    /// The target this dynamic task belongs to. This is needed for mapping the output of the dynamic task to the logs.
    package let target: ConfiguredTarget?

    /// Whether to show the environment in the logs.
    package let showEnvironment: Bool

    package init(
        toolIdentifier: String,
        taskKey: DynamicTaskKey,
        workingDirectory: Path,
        environment: EnvironmentBindings,
        target: ConfiguredTarget?,
        showEnvironment: Bool
    ) {
        self.toolIdentifier = toolIdentifier
        self.taskKey = taskKey
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.target = target
        self.showEnvironment = showEnvironment
    }

    package func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(6)
        serializer.serialize(toolIdentifier)
        serializer.serialize(taskKey)
        serializer.serialize(workingDirectory)
        serializer.serialize(environment)
        serializer.serialize(target)
        serializer.serialize(showEnvironment)
        serializer.endAggregate()
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.toolIdentifier = try deserializer.deserialize()
        self.taskKey = try deserializer.deserialize()
        self.workingDirectory = try deserializer.deserialize()
        self.environment = try deserializer.deserialize()
        self.target = try deserializer.deserialize()
        self.showEnvironment = try deserializer.deserialize()
    }
}
