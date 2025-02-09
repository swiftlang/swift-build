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

public import SWBUtil
public import struct Foundation.Date
public import struct Foundation.Data

// MARK: Shared Types

public struct BuildOperationProjectInfo: SerializableCodable, Equatable, Sendable {
    /// The name of the project.
    public let name: String

    /// The path of the project wrapper (.xcodeproj).
    public let path: String

    /// If this project is a package.
    public let isPackage: Bool

    /// Whether the project's name is unique across the whole workspace.
    public let isNameUniqueInWorkspace: Bool

    public init(name: String, path: String, isPackage: Bool, isNameUniqueInWorkspace: Bool) {
        self.name = name
        self.path = path
        self.isPackage = isPackage
        self.isNameUniqueInWorkspace = isNameUniqueInWorkspace
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.name = try deserializer.deserialize()
        self.path = try deserializer.deserialize()
        self.isPackage = try deserializer.deserialize()
        self.isNameUniqueInWorkspace = false
    }
}

public enum BuildOperationTargetType: SerializableCodable, Equatable, Sendable {
    case aggregate
    case external
    case packageProduct
    case standard

    private enum CodingKeys: String, CodingKey {
        case aggregate = "Aggregate"
        case external = "External"
        case packageProduct = "Package Product"
        case standard = "Native"
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = CodingKeys(rawValue: rawValue) else {
            throw StubError.error("Could not decode target type '\(rawValue)'")
        }
        self = {
            switch value {
            case .aggregate:
                return .aggregate
            case .external:
                return .external
            case .packageProduct:
                return .packageProduct
            case .standard:
                return .standard
            }
        }()
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode({ () -> CodingKeys in
            switch self {
            case .aggregate:
                return .aggregate
            case .external:
                return .external
            case .packageProduct:
                return .packageProduct
            case .standard:
                return .standard
            }
        }().rawValue)
    }
}

/// Descriptive information on a target appearing in a build.
public struct BuildOperationTargetInfo: SerializableCodable, Equatable, Sendable {
    /// The name of the target.
    public let name: String

    /// The target type.
    public let typeName: BuildOperationTargetType

    /// The project information.
    public let projectInfo: BuildOperationProjectInfo

    /// The name of the configuration chosen to build.
    public let configurationName: String

    /// Whether or not the configuration was the default one.
    public let configurationIsDefault: Bool

    /// The identifier of the SDK in use, if any.
    public let sdkroot: String?

    /// Create a bridged instance from `info`.
    public init(name: String, type: BuildOperationTargetType, projectInfo: BuildOperationProjectInfo, configurationName: String, configurationIsDefault: Bool, sdkCanonicalName: String?) {
        self.name = name
        self.typeName = type
        self.projectInfo = projectInfo
        self.configurationName = configurationName
        self.configurationIsDefault = configurationIsDefault
        self.sdkroot = sdkCanonicalName
    }
}

public enum BuildOperationTaskSignature: RawRepresentable, Sendable, Hashable, Codable, CustomDebugStringConvertible {
    case taskIdentifier(ByteString)
    case activitySignature(ByteString)
    case subtaskSignature(ByteString)

    public init?(rawValue: ByteString) {
        switch rawValue.bytes.first {
        case 0:
            self = .taskIdentifier(ByteString(rawValue.bytes.dropFirst()))
        case 1:
            self = .activitySignature(ByteString(rawValue.bytes.dropFirst()))
        case 2:
            self = .subtaskSignature(ByteString(rawValue.bytes.dropFirst()))
        default:
            return nil
        }
    }

    public var rawValue: ByteString {
        switch self {
        case .taskIdentifier(let identifier):
            return ByteString([0]) + identifier
        case .activitySignature(let signature):
            return ByteString([1]) + signature
        case .subtaskSignature(let signature):
            return ByteString([2]) + signature
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = BuildOperationTaskSignature(rawValue: ByteString(try container.decode([UInt8].self))) else {
            throw StubError.error("Could not decode signature bytes")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.bytes)
    }

    public var debugDescription: String {
        switch self {
        case .activitySignature(let byteString), .subtaskSignature(let byteString), .taskIdentifier(let byteString):
            return byteString.asString
        }
    }
}

/// Descriptive information on a task appearing in a build.
public struct BuildOperationTaskInfo: Serializable, Equatable, Sendable {
    /// The name of the task, typically the value from the spec for the task.
    public let taskName: String

    /// The signature of the task (for associating with `wasUpToDate` messages).
    private let internalSignature: BuildOperationTaskSignature
    public var signature: ByteString {
        internalSignature.rawValue
    }

    /// The rule info of the task.
    public let ruleInfo: String

    /// The execution description, if any.
    public let executionDescription: String

    /// Any interesting path related to the task, for e.g. the file being compiled.
    public let interestingPath: Path?

    /// The string to display describing the command line, if any.
    public let commandLineDisplayString: String?

    /// The paths to clang-format serialized diagnostics files, if used.
    public let serializedDiagnosticsPaths: [Path]

    public init(taskName: String, signature: BuildOperationTaskSignature, ruleInfo: String, executionDescription: String, commandLineDisplayString: String?, interestingPath: Path?, serializedDiagnosticsPaths: [Path]) {
        self.taskName = taskName
        self.internalSignature = signature
        self.ruleInfo = ruleInfo
        self.executionDescription = executionDescription
        self.commandLineDisplayString = commandLineDisplayString
        self.interestingPath = interestingPath
        self.serializedDiagnosticsPaths = serializedDiagnosticsPaths
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        self.taskName = try deserializer.deserialize()
        guard let signature = BuildOperationTaskSignature(rawValue: try deserializer.deserialize()) else {
            throw StubError.error("Could not decode BuildOperationTaskSignature from raw value")
        }
        self.internalSignature = signature
        self.ruleInfo = try deserializer.deserialize()
        self.executionDescription = try deserializer.deserialize()
        self.commandLineDisplayString = try deserializer.deserialize()
        self.interestingPath = try deserializer.deserialize()
        self.serializedDiagnosticsPaths = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(7) {
            serializer.serialize(self.taskName)
            serializer.serialize(self.internalSignature.rawValue)
            serializer.serialize(self.ruleInfo)
            serializer.serialize(self.executionDescription)
            serializer.serialize(self.commandLineDisplayString)
            serializer.serialize(self.interestingPath)
            serializer.serialize(self.serializedDiagnosticsPaths)
        }
    }
}

// MARK: Build operation messages

/// Create a high-level build operation.
public struct CreateBuildRequest: SessionChannelBuildMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = BuildCreated

    public static let name = "CREATE_BUILD"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// The request itself.
    public let request: BuildRequestMessagePayload

    /// If true, the build operation will be completed after the build description is created and reported.
    public let onlyCreateBuildDescription: Bool

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload, onlyCreateBuildDescription: Bool) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
        self.onlyCreateBuildDescription = onlyCreateBuildDescription
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.request = try deserializer.deserialize()
        self.onlyCreateBuildDescription = try deserializer.deserialize()
    }
}

public struct BuildStartRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse
    
    public static let name = "BUILD_START"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The ID of the build operation.
    public let id: Int

    public init(sessionHandle: String, id: Int) {
        self.sessionHandle = sessionHandle
        self.id = id
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.id = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.sessionHandle)
            serializer.serialize(self.id)
        }
    }
}

public struct BuildCancelRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "BUILD_CANCEL"

    /// The identifier for the session to initiate the request in.
    public var sessionHandle: String

    /// The ID of the build operation.
    public let id: Int

    public init(sessionHandle: String, id: Int) {
        self.sessionHandle = sessionHandle
        self.id = id
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.id = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.sessionHandle)
            serializer.serialize(self.id)
        }
    }
}

/// Inform the client that a build has been created (in response to a build request).
public struct BuildCreated: Message, Equatable {
    public static let name = "BUILD_CREATED"

    /// The ID of the build operation.
    public let id: Int

    public init(id: Int) {
        self.id = id
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.id = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.id)
        }
    }
}

public struct BuildOperationReportBuildDescription: Message, Equatable {
    public static let name = "BUILD_OPERATION_REPORT_BUILD_DESCRIPTION_ID"

    public let buildDescriptionID: String

    public init(buildDescriptionID: String) {
        self.buildDescriptionID = buildDescriptionID
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.buildDescriptionID = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.buildDescriptionID)
        }
    }
}

public struct BuildOperationStarted: Message, Equatable {
    public static let name = "BUILD_OPERATION_STARTED"

    public let id: Int

    public init(id: Int) {
        self.id = id
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.id = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.id)
        }
    }
}

public struct BuildOperationReportPathMap: Message, Equatable {
    public static let name = "BUILD_OPERATION_REPORT_PATH_MAP"

    public let copiedPathMap: [String: String]
    public let generatedFilesPathMap: [String: String]

    public init(copiedPathMap: [String: String], generatedFilesPathMap: [String: String]) {
        self.copiedPathMap = copiedPathMap
        self.generatedFilesPathMap = generatedFilesPathMap
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.copiedPathMap = try deserializer.deserialize()
        self.generatedFilesPathMap = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.copiedPathMap)
            serializer.serialize(self.generatedFilesPathMap)
        }
    }
}

/// Declares a minimalistic (unique) definition of a target in a build graph. The `guid` should be based on the `ConfiguredTarget`'s `guid`.
public struct TargetDescription: Serializable, Codable, Equatable, Sendable, Hashable {
    /// The name of the target, does not need to be unique
    public let name: String
    /// An identifier which is unique in a build graph
    public let guid: String

    public init(name: String, guid: String? = nil) {
        self.name = name
        self.guid = guid ?? name
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        name = try deserializer.deserialize()
        guid = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(name)
            serializer.serialize(guid)
        }
    }
}

/// This struct describes the dependency relationship from one target to its
/// dependencies. All targets are uniquely referenced using their guid.
public struct TargetDependencyRelationship: Serializable, Codable, Equatable, Sendable {
    /// The target which defines a dependency relation on all its dependencies
    public let target: TargetDescription
    /// All dependencies of target, sorted by their guid
    public let targetDependencies: [TargetDescription]

    /// Creates a new instance of a `TargetDependencyRelationship`.
    ///
    /// NOTE: dependencies will be sorted by their guid on init.
    public init(_ target: TargetDescription, dependencies: [TargetDescription]) {
        self.target = target
        self.targetDependencies = dependencies.sorted(by: \.guid)
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        target = try deserializer.deserialize()
        targetDependencies = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(target)
            serializer.serialize(targetDependencies)
        }
    }
}

public struct BuildOperationMetrics: Equatable, Codable, Sendable {
    public enum Counter: String, Equatable, Codable, Sendable {
        case clangCacheHits
        case clangCacheMisses
        case swiftCacheHits
        case swiftCacheMisses
    }

    public enum TaskCounter: String, Equatable, Codable, Sendable {
        case cacheHits
        case cacheMisses
    }

    public let counters: [Counter: Int]

    public init(counters: [Counter : Int]) {
        self.counters = counters
    }
}

public struct BuildOperationEnded: Message, Equatable, SerializableCodable {
    public static let name = "BUILD_OPERATION_ENDED"

    public enum Status: Int, Serializable, Codable, Sendable {
        case succeeded = 0
        case cancelled = 1
        case failed = 2
    }

    public let id: Int
    public let status: Status
    public let metrics: BuildOperationMetrics?

    public init(id: Int, status: Status, metrics: BuildOperationMetrics? = nil) {
        self.id = id
        self.status = status
        self.metrics = metrics
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.id = try deserializer.deserialize()
        self.status = try deserializer.deserialize()
        _ = try deserializer.deserialize() as Optional<[UInt8]>
        self.metrics = nil
    }
}

public struct BuildOperationTargetUpToDate: Message, Equatable {
    public static let name = "BUILD_TARGET_UPTODATE"

    public let guid: String

    public init(guid: String) {
        self.guid = guid
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.guid = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.guid)
        }
    }
}

public struct BuildOperationTargetStarted: Message, SerializableCodable, Equatable {
    public static let name = "BUILD_TARGET_STARTED"

    public let id: Int
    public let guid: String
    public let info: BuildOperationTargetInfo

    public init(id: Int, guid: String, info: BuildOperationTargetInfo) {
        self.id = id
        self.guid = guid
        self.info = info
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.id = try deserializer.deserialize()
        self.guid = try deserializer.deserialize()
        self.info = try deserializer.deserialize()
    }
}

public struct BuildOperationTargetEnded: Message, Equatable {
    public static let name = "BUILD_TARGET_ENDED"

    public let id: Int

    public init(id: Int) {
        self.id = id
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.id = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.id)
        }
    }
}

public struct BuildOperationTaskUpToDate: Message, Equatable {
    public static let name = "BUILD_TASK_UPTODATE"

    private let internalSignature: BuildOperationTaskSignature
    public var signature: ByteString { internalSignature.rawValue }
    // Consider replacing with a target signature in the future.
    public let targetID: Int?
    public let parentID: Int?

    public init(signature: BuildOperationTaskSignature, targetID: Int?, parentID: Int? = nil) {
        self.internalSignature = signature
        self.targetID = targetID
        self.parentID = parentID
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        guard let signature = BuildOperationTaskSignature(rawValue: try deserializer.deserialize()) else {
            throw StubError.error("Could not decode BuildOperationTaskSignature from raw value")
        }
        self.internalSignature = signature
        self.targetID = try deserializer.deserialize()
        self.parentID = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(self.internalSignature.rawValue)
            serializer.serialize(self.targetID)
            serializer.serialize(self.parentID)
        }
    }
}

public struct BuildOperationTaskStarted: Message, Equatable {
    public static let name = "BUILD_TASK_STARTED"

    public let id: Int
    // Consider replacing with a target signature in the future.
    public let targetID: Int?
    public let parentID: Int?
    public let info: BuildOperationTaskInfo

    public init(id: Int, targetID: Int?, parentID: Int?, info: BuildOperationTaskInfo) {
        self.id = id
        self.targetID = targetID
        self.parentID = parentID
        self.info = info
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.id = try deserializer.deserialize()
        self.targetID = try deserializer.deserialize()
        self.parentID = try deserializer.deserialize()
        self.info = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(self.id)
            serializer.serialize(self.targetID)
            serializer.serialize(self.parentID)
            serializer.serialize(self.info)
        }
    }
}

public struct BuildOperationTaskEnded: Message, Equatable, SerializableCodable {
    public static let name = "BUILD_TASK_ENDED"

    public enum Status: Int, Serializable, Sendable, Codable {
        case succeeded = 0
        case cancelled = 1
        case failed = 2
    }

    public struct Metrics: Serializable, Equatable, Sendable, Codable {
        /// Total amount of time (in µs) spent by the process executing in user mode.
        public let utime: UInt64

        /// Total amount of time (in µs) spent by the system executing on behalf of the process.
        public let stime: UInt64

        /// Maximum resident memory set size (in bytes).
        public let maxRSS: UInt64

        /// Wall clock time (in µs since the epoch) at which the process was started.
        public let wcStartTime: UInt64

        /// Wall clock time (in µs) from start to finish of process.
        public let wcDuration: UInt64

        public init(utime: UInt64, stime: UInt64, maxRSS: UInt64, wcStartTime: UInt64, wcDuration: UInt64) {
            self.utime = utime
            self.stime = stime
            self.maxRSS = maxRSS
            self.wcStartTime = wcStartTime
            self.wcDuration = wcDuration
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(5)
            self.utime = try deserializer.deserialize()
            self.stime = try deserializer.deserialize()
            self.maxRSS = try deserializer.deserialize()
            self.wcStartTime = try deserializer.deserialize()
            self.wcDuration = try deserializer.deserialize()
        }

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(5) {
                serializer.serialize(self.utime)
                serializer.serialize(self.stime)
                serializer.serialize(self.maxRSS)
                serializer.serialize(self.wcStartTime)
                serializer.serialize(self.wcDuration)
            }
        }
    }

    public let id: Int
    public let signature: BuildOperationTaskSignature
    public let status: Status
    public let signalled: Bool
    public let metrics: Metrics?

    public init(id: Int, signature: BuildOperationTaskSignature, status: Status, signalled: Bool, metrics: Metrics?) {
        self.id = id
        self.signature = signature
        self.status = status
        self.signalled = signalled
        self.metrics = metrics
    }
}

/// Reported info for a 'prepare-for-index' operation
public struct PreparedForIndexResultInfo: Serializable, Hashable, Equatable, Sendable {
    /// The timestamp of the 'prepare-for-index' marker node.
    public let timestamp: Date

    public init(timestamp: Date) {
        self.timestamp = timestamp
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.timestamp = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.timestamp)
        }
    }
}

public struct BuildOperationTargetPreparedForIndex: Message, Equatable {
    public static let name = "BUILD_TARGET_PREPARED_FOR_INDEX"

    public let targetGUID: String
    public let info: PreparedForIndexResultInfo

    public init(targetGUID: String, info: PreparedForIndexResultInfo) {
        self.targetGUID = targetGUID
        self.info = info
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.targetGUID = try deserializer.deserialize()
        self.info = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.targetGUID)
            serializer.serialize(self.info)
        }
    }
}

/// Provide a status update on a part of the build.
public struct BuildOperationProgressUpdated: Message, Equatable {
    public static let name = "BUILD_PROGRESS_UPDATED"

    /// The target that this task belongs to, if known.
    public let targetName: String?

    /// A message describing the current build task.
    public let statusMessage: String

    /// The percentage complete.
    public let percentComplete: Double

    /// Whether or not to create a corresponding entry in the build log.
    public let showInLog: Bool

    public init(targetName: String? = nil, statusMessage: String, percentComplete: Double, showInLog: Bool) {
        self.targetName = targetName
        self.statusMessage = statusMessage
        self.percentComplete = percentComplete
        self.showInLog = showInLog
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.targetName = try deserializer.deserialize()
        self.statusMessage = try deserializer.deserialize()
        self.percentComplete = try deserializer.deserialize()
        self.showInLog = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(self.targetName)
            serializer.serialize(self.statusMessage)
            serializer.serialize(self.percentComplete)
            serializer.serialize(self.showInLog)
        }
    }
}

/// Indicate that the "build preparation" phase has ended.
///
/// This is not currently explicitly encoded in the protocol, but generally speaking the service will not send "progress update" messages which are intended to be recorded in the log after this phase is done.
public struct BuildOperationPreparationCompleted: Message, Equatable {
    public static let name = "BUILD_PREPARATION_COMPLETED"

    public init() {}

    public init(from deserializer: any Deserializer) throws {
        _ = deserializer.deserializeNil()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeNil()
    }
}

/// A message inform the client of output from the build.
public struct BuildOperationConsoleOutputEmitted: Message, Equatable, SerializableCodable {
    public static let name = "BUILD_CONSOLE_OUTPUT_EMITTED"

    public let data: [UInt8]
    public let taskID: Int?
    public let taskSignature: BuildOperationTaskSignature?
    public let targetID: Int?

    public init(data: [UInt8]) {
        self.data = data
        self.taskID = nil
        self.taskSignature = nil
        self.targetID = nil
    }
    public init(data: [UInt8], targetID: Int) {
        self.data = data
        self.targetID = targetID
        self.taskID = nil
        self.taskSignature = nil
    }
    public init(data: [UInt8], taskID: Int, taskSignature: BuildOperationTaskSignature) {
        self.data = data
        self.targetID = nil
        self.taskID = taskID

        // FIXME: Re-enable usage of task signatures after addressing the performance issues.
        self.taskSignature = nil
    }

    public enum CodingKeys: CodingKey {
        case data // legacy key
        case data2
        case taskID
        case taskSignature // legacy key
        case taskSignature2
        case targetID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Array<UInt8>(), forKey: .data)
        try container.encode(Data(self.data), forKey: .data2)
        try container.encodeIfPresent(self.taskID, forKey: .taskID)
        try container.encodeIfPresent(self.taskSignature.map { Data($0.rawValue.bytes) }, forKey: .taskSignature2)
        try container.encodeIfPresent(self.targetID, forKey: .targetID)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.data = Array(try container.decode(Data.self, forKey: .data2))
        self.taskID = try container.decodeIfPresent(Int.self, forKey: .taskID)
        self.taskSignature = try container.decodeIfPresent(Data.self, forKey: .taskSignature2).flatMap { BuildOperationTaskSignature(rawValue: ByteString($0)) }
        self.targetID = try container.decodeIfPresent(Int.self, forKey: .targetID)
    }
}

/// A message inform the client of a diagnostic emitted from the build.
public struct BuildOperationDiagnosticEmitted: Message, Equatable, SerializableCodable {
    public static let name = "BUILD_DIAGNOSTIC_EMITTED"

    public enum Kind: Int, Serializable, Sendable, Codable {
        case note = 0
        case warning = 1
        case error = 2
        case remark = 3

        public var description: String {
            switch self {
            case .note: return "note"
            case .warning: return "warning"
            case .error: return "error"
            case .remark: return "remark"
            }
        }
    }

    public enum LocationContext: Equatable, Hashable, Sendable, Codable {
        case task(taskID: Int, taskSignature: BuildOperationTaskSignature, targetID: Int)
        case target(targetID: Int)
        case globalTask(taskID: Int, taskSignature: BuildOperationTaskSignature)
        case global

        enum CodingKeys: CodingKey {
            case task
            case target
            case globalTask
            case global
        }

        enum TaskCodingKeys: CodingKey {
            case taskID
            case taskSignature // legacy key
            case taskSignature2
            case targetID
        }

        enum TargetCodingKeys: CodingKey {
            case targetID
        }

        enum GlobalTaskCodingKeys: CodingKey {
            case taskID
            case taskSignature // legacy key
            case taskSignature2
        }

        enum GlobalCodingKeys: CodingKey {}

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.self)
            switch self {
            case .task(let taskID, let taskSignature, let targetID):
                var nestedContainer = container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.task)
                try nestedContainer.encode(taskID, forKey: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.taskID)
                try nestedContainer.encode([0] as [UInt8], forKey: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.taskSignature)
                try nestedContainer.encode(Data(taskSignature.rawValue.bytes), forKey: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.taskSignature2)
                try nestedContainer.encode(targetID, forKey: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.targetID)
            case .target(let targetID):
                var nestedContainer = container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.TargetCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.target)
                try nestedContainer.encode(targetID, forKey: BuildOperationDiagnosticEmitted.LocationContext.TargetCodingKeys.targetID)
            case .globalTask(let taskID, let taskSignature):
                var nestedContainer = container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.GlobalTaskCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.globalTask)
                try nestedContainer.encode(taskID, forKey: BuildOperationDiagnosticEmitted.LocationContext.GlobalTaskCodingKeys.taskID)
                try nestedContainer.encode([0] as [UInt8], forKey: BuildOperationDiagnosticEmitted.LocationContext.GlobalTaskCodingKeys.taskSignature)
                try nestedContainer.encode(Data(taskSignature.rawValue.bytes), forKey: BuildOperationDiagnosticEmitted.LocationContext.GlobalTaskCodingKeys.taskSignature2)
            case .global:
                _ = container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.GlobalCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.global)
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.self)
            var allKeys = ArraySlice(container.allKeys)
            guard let onlyKey = allKeys.popFirst(), allKeys.isEmpty else {
                throw DecodingError.typeMismatch(BuildOperationDiagnosticEmitted.LocationContext.self, DecodingError.Context.init(codingPath: container.codingPath, debugDescription: "Invalid number of keys found, expected one.", underlyingError: nil))
            }
            switch onlyKey {
            case .task:
                let nestedContainer = try container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.task)
                guard let taskSignature = BuildOperationTaskSignature(rawValue: ByteString(try nestedContainer.decode(Data.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.taskSignature2))) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Expected a valid task signature"))
                }
                self = BuildOperationDiagnosticEmitted.LocationContext.task(taskID: try nestedContainer.decode(Int.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.taskID), taskSignature: taskSignature, targetID: try nestedContainer.decode(Int.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.TaskCodingKeys.targetID))
            case .target:
                let nestedContainer = try container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.TargetCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.target)
                self = BuildOperationDiagnosticEmitted.LocationContext.target(targetID: try nestedContainer.decode(Int.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.TargetCodingKeys.targetID))
            case .globalTask:
                let nestedContainer = try container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.GlobalTaskCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.globalTask)
                guard let taskSignature = BuildOperationTaskSignature(rawValue: ByteString(try nestedContainer.decode(Data.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.GlobalTaskCodingKeys.taskSignature2))) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Expected a valid task signature"))
                }
                self = BuildOperationDiagnosticEmitted.LocationContext.globalTask(taskID: try nestedContainer.decode(Int.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.GlobalTaskCodingKeys.taskID), taskSignature: taskSignature)
            case .global:
                _ = try container.nestedContainer(keyedBy: BuildOperationDiagnosticEmitted.LocationContext.GlobalCodingKeys.self, forKey: BuildOperationDiagnosticEmitted.LocationContext.CodingKeys.global)
                self = BuildOperationDiagnosticEmitted.LocationContext.global
            }
        }
    }

    public typealias Location = Diagnostic.Location
    public typealias SourceRange = Diagnostic.SourceRange
    public typealias FixIt = Diagnostic.FixIt
    public let kind: Kind
    public let location: Location
    public let message: String
    public let locationContext: LocationContext
    public let component: Component
    public let optionName: String?
    public let appendToOutputStream: Bool
    public let sourceRanges: [SourceRange]
    public let fixIts: [FixIt]
    public let childDiagnostics: [BuildOperationDiagnosticEmitted]

    public init(kind: Kind, location: Location, message: String, locationContext: LocationContext = .global, component: Component = .default, optionName: String? = nil, appendToOutputStream: Bool = true, sourceRanges: [SourceRange], fixIts: [FixIt], childDiagnostics: [BuildOperationDiagnosticEmitted]) {
        self.kind = kind
        self.location = location
        self.message = message
        self.locationContext = locationContext
        self.component = component
        self.optionName = optionName
        self.appendToOutputStream = appendToOutputStream
        self.sourceRanges = sourceRanges
        self.fixIts = fixIts
        self.childDiagnostics = childDiagnostics
    }
}

public struct BuildOperationBacktraceFrameEmitted: Message, Equatable, SerializableCodable {
    public static let name = "BUILD_BACKTRACE_FRAME_EMITTED"

    public enum Identifier: Hashable, Equatable, Comparable, SerializableCodable, Sendable {
        case task(BuildOperationTaskSignature)
        case genericBuildKey(String)

        public static func < (lhs: BuildOperationBacktraceFrameEmitted.Identifier, rhs: BuildOperationBacktraceFrameEmitted.Identifier) -> Bool {
            switch (lhs, rhs) {
            case (.task(let lhsSig), .task(let rhsSig)):
                return lhsSig.rawValue.lexicographicallyPrecedes(rhsSig.rawValue)
            case (.task, .genericBuildKey):
                return true
            case (.genericBuildKey, .task):
                return false
            case (.genericBuildKey(let lhsBytes), .genericBuildKey(let rhsBytes)):
                return lhsBytes < rhsBytes
            }
        }
    }

    public enum Category: Sendable, Equatable, Comparable, SerializableCodable {
        case ruleNeverBuilt
        case ruleSignatureChanged
        case ruleHadInvalidValue
        case ruleInputRebuilt
        case ruleForced
        case dynamicTaskRegistration
        case dynamicTaskRequest
        case none
    }
    public enum Kind: Sendable, Equatable, Comparable, SerializableCodable {
        case genericTask
        case swiftDriverJob
        case file
        case directory
        case unknown
    }

    public let identifier: Identifier
    public let previousFrameIdentifier: Identifier?
    public let category: Category
    public let kind: Kind?
    public let description: String

    public init(identifier: Identifier, previousFrameIdentifier: Identifier?, category: Category, kind: Kind, description: String) {
        self.identifier = identifier
        self.previousFrameIdentifier = previousFrameIdentifier
        self.category = category
        self.kind = kind
        self.description = description
    }
}

let buildOperationMessageTypes: [any Message.Type] = [
    // Active build messages.
    CreateBuildRequest.self,
    BuildStartRequest.self,
    BuildCancelRequest.self,
    BuildCreated.self,

    // In-progress build messages.
    BuildOperationStarted.self,
    BuildOperationEnded.self,
    BuildOperationTargetUpToDate.self,
    BuildOperationTargetStarted.self,
    BuildOperationTargetEnded.self,
    BuildOperationTaskUpToDate.self,
    BuildOperationTaskStarted.self,
    BuildOperationTaskEnded.self,
    BuildOperationTargetPreparedForIndex.self,
    BuildOperationProgressUpdated.self,
    BuildOperationPreparationCompleted.self,
    BuildOperationConsoleOutputEmitted.self,
    BuildOperationDiagnosticEmitted.self,
    BuildOperationReportBuildDescription.self,
    BuildOperationReportPathMap.self,
    BuildOperationBacktraceFrameEmitted.self,
]

extension BuildOperationDiagnosticEmitted {
    public init(_ diagnostic: Diagnostic, _ locationContext: LocationContext) {
        // FIXME: Split apart the location and message.
        let kind: BuildOperationDiagnosticEmitted.Kind
        switch diagnostic.behavior {
        case .error:
            kind = .error
        case .warning:
            kind = .warning
        case .note, .ignored:
            kind = .note
        case .remark:
            kind = .remark
        }

        self.init(kind: kind, location: diagnostic.location, message: diagnostic.formatLocalizedDescription(.messageOnly), locationContext: locationContext, component: diagnostic.data.component, optionName: diagnostic.data.optionName, appendToOutputStream: diagnostic.appendToOutputStream, sourceRanges: diagnostic.sourceRanges, fixIts: diagnostic.fixIts, childDiagnostics: diagnostic.childDiagnostics.map { .init($0, locationContext) })
    }
}
