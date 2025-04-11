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

/// A generic IPC message.
public protocol Message: Serializable, Sendable {
    static var name: String { get }
}

/// A session-specific message.
public protocol SessionMessage: Message {
    // FIXME: Use a better type than String here.
    var sessionHandle: String { get }
}

/// A session-specific message whose response is sent on a dedicated channel
public protocol SessionChannelMessage: SessionMessage {
    var responseChannel: UInt64 { get }
}

/// A session-specific message whose response is sent on a dedicated channel and which carries a build request.
public protocol SessionChannelBuildMessage: SessionChannelMessage {
    var request: BuildRequestMessagePayload { get }
}

/// A client exchange message.
public protocol ClientExchangeMessage: SessionMessage {
    var exchangeHandle: String { get }
}

public protocol RequestMessage: Message {
    associatedtype ResponseMessage: Message
}

public protocol IncrementalPIFMessage: RequestMessage where ResponseMessage == TransferSessionPIFResponse {
}

// MARK: Requests from the client

public struct PingRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = PingResponse

    public static let name = "PING"

    public init() {}

    public init(from deserializer: any Deserializer) throws {
        _ = deserializer.deserializeNil()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeNil()
    }
}

public struct SetConfigItemRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse
    
    public static let name = "SET_CONFIG_ITEM"

    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.key = try deserializer.deserialize()
        self.value = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.key)
        serializer.serialize(self.value)
    }
}

public struct ClearAllCachesRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "CLEAR_ALL_CACHES"

    public init() {}

    public init(from deserializer: any Deserializer) throws {
        _ = deserializer.deserializeNil()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeNil()
    }
}

public struct GetPlatformsRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = StringResponse

    public static let name = "GET_PLATFORMS"

    public let sessionHandle: String
    public let commandLine: [String]

    public init(sessionHandle: String, commandLine: [String]) {
        self.sessionHandle = sessionHandle
        self.commandLine = commandLine
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.commandLine)
    }
}

public struct GetSDKsRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = StringResponse

    public static let name = "GET_SDKS"

    public let sessionHandle: String
    public let commandLine: [String]

    public init(sessionHandle: String, commandLine: [String]) {
        self.sessionHandle = sessionHandle
        self.commandLine = commandLine
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.commandLine)
    }
}

public struct GetSpecsRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = StringResponse

    public static let name = "GET_SPECS"

    public let sessionHandle: String
    public let commandLine: [String]

    public init(sessionHandle: String, commandLine: [String]) {
        self.sessionHandle = sessionHandle
        self.commandLine = commandLine
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.commandLine)
    }
}

public struct GetStatisticsRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = StringResponse

    public static let name = "GET_STATISTICS"

    public init() {}

    public init(from deserializer: any Deserializer) throws {
        _ = deserializer.deserializeNil()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeNil()
    }
}

public struct GetToolchainsRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = StringResponse

    public static let name = "GET_TOOLCHAINS"

    public let sessionHandle: String
    public let commandLine: [String]

    public init(sessionHandle: String, commandLine: [String]) {
        self.sessionHandle = sessionHandle
        self.commandLine = commandLine
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.commandLine)
    }
}

/// Execute an internal `swbuild` command line tool.
public struct ExecuteCommandLineToolRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "EXECUTE_COMMAND_LINE_TOOL"

    public let commandLine: [String]
    public let workingDirectory: Path
    public let developerPath: Path?
    public let replyChannel: UInt64

    public init(commandLine: [String], workingDirectory: Path, developerPath: Path?, replyChannel: UInt64) {
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.developerPath = developerPath
        self.replyChannel = replyChannel
    }

    public init(from deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(3...4)
        self.commandLine = try deserializer.deserialize()
        self.workingDirectory = try deserializer.deserialize()
        self.developerPath = try count > 3 ? deserializer.deserialize() : nil
        self.replyChannel = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(4)
        serializer.serialize(self.commandLine)
        serializer.serialize(self.workingDirectory)
        serializer.serialize(self.developerPath)
        serializer.serialize(self.replyChannel)
    }
}

public struct GetBuildSettingsDescriptionRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = StringResponse

    public static let name = "GET_BUILD_SETTINGS_DESCRIPTION"

    public let sessionHandle: String
    public let commandLine: [String]

    public init(sessionHandle: String, commandLine: [String]) {
        self.sessionHandle = sessionHandle
        self.commandLine = commandLine
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.commandLine)
    }
}

public struct CreateXCFrameworkRequest: RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = StringResponse
    
    public static let name = "CREATE_XCFRAMEWORK_REQUEST"

    public let developerPath: Path?
    public let xcodeAppPath: Path?
    public let commandLine: [String]
    public let currentWorkingDirectory: Path

    public init(developerPath: Path?, commandLine: [String], currentWorkingDirectory: Path) {
        self.developerPath = developerPath
        self.xcodeAppPath = developerPath?.dirname.dirname
        self.commandLine = commandLine
        self.currentWorkingDirectory = currentWorkingDirectory
    }
}

// TODO: Delete once all clients are no longer calling the public APIs which invoke this message
public struct AvailableAppExtensionPointIdentifiersRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = StringListResponse

    public static let name = "AVAILABLE_APP_EXTENSION_POINT_IDENTIFIERS_REQUEST"

    public let platform: BuildVersion.Platform

    public init(platform: BuildVersion.Platform) {
        self.platform = platform
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(platform)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        platform = try deserializer.deserialize()
    }
}

// TODO: Delete once all clients are no longer calling the public APIs which invoke this message
public struct MacCatalystUnavailableFrameworkNamesRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = StringListResponse

    public static let name = "MACCATALYST_UNAVAILABLE_FRAMEWORK_NAMES_REQUEST"

    public let developerPath: Path?
    public let xcodeAppPath: Path?

    public init(developerPath: Path?) {
        self.developerPath = developerPath
        self.xcodeAppPath = developerPath?.dirname.dirname
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.xcodeAppPath)
            serializer.serialize(self.developerPath)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(1...2)
        self.xcodeAppPath = try deserializer.deserialize()
        self.developerPath = count >= 2 ? try deserializer.deserialize() : xcodeAppPath?.join("Contents").join("Developer")
    }
}

public struct AppleSystemFrameworkNamesRequest: RequestMessage, Equatable, PendingSerializableCodable {
    public typealias ResponseMessage = StringListResponse

    public static let name = "APPLE_SYSTEM_FRAMEWORK_NAMES_REQUEST"

    public let developerPath: Path?
    public let xcodeAppPath: Path?

    public init(developerPath: Path?) {
        self.developerPath = developerPath
        self.xcodeAppPath = developerPath?.dirname.dirname
    }

    public func legacySerialize<T>(to serializer: T) where T : SWBUtil.Serializer {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.xcodeAppPath)
            serializer.serialize(self.developerPath)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(1...2)
        self.xcodeAppPath = try deserializer.deserialize()
        self.developerPath = count >= 2 ? try deserializer.deserialize() : xcodeAppPath?.join("Contents").join("Developer")
    }
}

public struct ProductTypeSupportsMacCatalystRequest: RequestMessage, Equatable, PendingSerializableCodable {
    public typealias ResponseMessage = BoolResponse

    public static let name = "MACCATALYST_SUPPORTS_PRODUCT_TYPE"

    public let developerPath: Path?
    public let xcodeAppPath: Path?
    public let productTypeIdentifier: String

    public init(developerPath: Path?, productTypeIdentifier: String) {
        self.developerPath = developerPath
        self.xcodeAppPath = developerPath?.dirname.dirname
        self.productTypeIdentifier = productTypeIdentifier
    }

    public func legacySerialize<T>(to serializer: T) where T : SWBUtil.Serializer {
        serializer.serializeAggregate(3) {
            serializer.serialize(self.xcodeAppPath)
            serializer.serialize(self.developerPath)
            serializer.serialize(self.productTypeIdentifier)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(2...3)
        self.xcodeAppPath = try deserializer.deserialize()
        self.developerPath = count >= 3 ? try deserializer.deserialize() : xcodeAppPath?.join("Contents").join("Developer")
        self.productTypeIdentifier = try deserializer.deserialize()
    }
}

// MARK: Session Management

public enum DeveloperPath: Sendable, Hashable, Codable {
    case xcode(Path)
    case swiftToolchain(Path)
}

public struct CreateSessionRequest: RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = CreateSessionResponse

    public static let name = "CREATE_SESSION"

    public let name: String
    public let developerPath: Path?
    public let developerPath2: DeveloperPath?
    public let resourceSearchPaths: [Path]?
    public let appPath: Path?
    public let cachePath: Path?
    public let inferiorProductsPath: Path?
    public let environment: [String:String]?

    public init(name: String, developerPath: Path?, cachePath: Path?, inferiorProductsPath: Path?) {  // ABI compatibility
        self.init(name: name, developerPath: developerPath, cachePath: cachePath, inferiorProductsPath: inferiorProductsPath, environment: nil)
    }

    public init(name: String, developerPath: Path?, cachePath: Path?, inferiorProductsPath: Path?, environment: [String:String]?) { // ABI Compatibility
        self.init(name: name, developerPath: developerPath, resourceSearchPaths: [], cachePath: cachePath, inferiorProductsPath: inferiorProductsPath, environment: environment)
    }

    public init(name: String, developerPath: Path?, resourceSearchPaths: [Path], cachePath: Path?, inferiorProductsPath: Path?, environment: [String:String]?) { // API/ABI compatibility
        self.name = name
        self.developerPath = developerPath
        self.developerPath2 = nil
        self.resourceSearchPaths = resourceSearchPaths
        self.appPath = developerPath?.dirname.dirname
        self.cachePath = cachePath
        self.inferiorProductsPath = inferiorProductsPath
        self.environment = environment
    }

    public init(name: String, developerPath: DeveloperPath?, resourceSearchPaths: [Path], cachePath: Path?, inferiorProductsPath: Path?, environment: [String:String]?) {
        self.name = name
        self.developerPath2 = developerPath
        switch developerPath {
        case .xcode(let path), .swiftToolchain(let path):
            self.developerPath = path
        case nil:
            self.developerPath = nil
        }
        self.resourceSearchPaths = resourceSearchPaths
        self.appPath = self.developerPath?.dirname.dirname
        self.cachePath = cachePath
        self.inferiorProductsPath = inferiorProductsPath
        self.environment = environment
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(4...5)
        self.name = try deserializer.deserialize()
        self.appPath = try deserializer.deserialize()
        self.developerPath = count >= 5 ? try deserializer.deserialize() : appPath?.join("Contents").join("Developer")
        self.developerPath2 = nil
        self.resourceSearchPaths = []
        self.cachePath = try deserializer.deserialize()
        self.inferiorProductsPath = try deserializer.deserialize()
        self.environment = nil
    }
}

public struct CreateSessionResponse: Message {
    public static let name = "SESSION_CREATED"

    public let sessionID: String?
    public let diagnostics: [Diagnostic]

    public init(sessionID: String?, diagnostics: [Diagnostic]) {
        self.sessionID = sessionID
        self.diagnostics = diagnostics
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionID = try deserializer.deserialize()
        self.diagnostics = try deserializer.deserialize()
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionID)
        serializer.serialize(self.diagnostics)
    }
}

public struct DeveloperPathRequest: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = StringResponse

    public static let name = "DEVELOPER_PATH_REQUEST"

    public let sessionHandle: String

    public init(sessionHandle: String) {
        self.sessionHandle = sessionHandle
    }
}

public struct SetSessionSystemInfoRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "SET_SESSION_SYSTEM_INFO"

    public let sessionHandle: String

    public let operatingSystemVersion: Version
    public let productBuildVersion: String
    public let nativeArchitecture: String

    public init(sessionHandle: String, operatingSystemVersion: Version, productBuildVersion: String, nativeArchitecture: String) {
        self.sessionHandle = sessionHandle
        self.operatingSystemVersion = operatingSystemVersion
        self.productBuildVersion = productBuildVersion
        self.nativeArchitecture = nativeArchitecture
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.sessionHandle = try deserializer.deserialize()
        self.operatingSystemVersion = Version(try deserializer.deserialize() /* major */, try deserializer.deserialize() /* minor */, try deserializer.deserialize() /* update */)
        self.productBuildVersion = try deserializer.deserialize()
        self.nativeArchitecture = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(3)
        serializer.serialize(sessionHandle)
        let osVersion = self.operatingSystemVersion.zeroPadded(toMinimumNumberOfComponents: 3)
        serializer.serialize(osVersion.rawValue[0])     // major
        serializer.serialize(osVersion.rawValue[1])     // minor
        serializer.serialize(osVersion.rawValue[2])     // update
        serializer.serialize(self.productBuildVersion)
        serializer.serialize(self.nativeArchitecture)
    }
}

public struct SetSessionUserInfoRequest: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "SET_SESSION_USER_INFO"

    public let sessionHandle: String

    public let user: String
    public let group: String
    public let uid: Int
    public let gid: Int
    public let home: String
    public let processEnvironment: [String: String]
    public let buildSystemEnvironment: [String: String]

    public init(sessionHandle: String, user: String, group: String, uid: Int, gid: Int, home: String, processEnvironment: [String: String], buildSystemEnvironment: [String: String]) {
        self.sessionHandle = sessionHandle
        self.user = user
        self.group = group
        self.uid = uid
        self.gid = gid
        self.home = home
        self.processEnvironment = processEnvironment
        self.buildSystemEnvironment = buildSystemEnvironment
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(9)
        self.sessionHandle = try deserializer.deserialize()
        self.user = try deserializer.deserialize()
        self.group = try deserializer.deserialize()
        self.uid = try deserializer.deserialize()
        self.gid = try deserializer.deserialize()
        self.home = try deserializer.deserialize()
        self.processEnvironment = try deserializer.deserialize()
        self.buildSystemEnvironment = try deserializer.deserialize()
        _ = try deserializer.deserialize() as Optional<Bool>
    }
}

public struct SetSessionUserPreferencesRequest: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "SET_SESSION_USER_PREFERENCES"

    public let sessionHandle: String

    public let enableDebugActivityLogs: Bool
    public let enableBuildDebugging: Bool
    public let enableBuildSystemCaching: Bool
    public let activityTextShorteningLevel: ActivityTextShorteningLevel
    public let usePerConfigurationBuildLocations: Bool?
    public let allowsExternalToolExecution: Bool?

    public init(sessionHandle: String, enableDebugActivityLogs: Bool, enableBuildDebugging: Bool, enableBuildSystemCaching: Bool, activityTextShorteningLevel: ActivityTextShorteningLevel, usePerConfigurationBuildLocations: Bool?) {
        self.sessionHandle = sessionHandle
        self.enableDebugActivityLogs = enableDebugActivityLogs
        self.enableBuildDebugging = enableBuildDebugging
        self.enableBuildSystemCaching = enableBuildSystemCaching
        self.activityTextShorteningLevel = activityTextShorteningLevel
        self.usePerConfigurationBuildLocations = usePerConfigurationBuildLocations
        self.allowsExternalToolExecution = nil
    }

    public init(sessionHandle: String, enableDebugActivityLogs: Bool, enableBuildDebugging: Bool, enableBuildSystemCaching: Bool, activityTextShorteningLevel: ActivityTextShorteningLevel, usePerConfigurationBuildLocations: Bool?, allowsExternalToolExecution: Bool) {
        self.sessionHandle = sessionHandle
        self.enableDebugActivityLogs = enableDebugActivityLogs
        self.enableBuildDebugging = enableBuildDebugging
        self.enableBuildSystemCaching = enableBuildSystemCaching
        self.activityTextShorteningLevel = activityTextShorteningLevel
        self.usePerConfigurationBuildLocations = usePerConfigurationBuildLocations
        self.allowsExternalToolExecution = allowsExternalToolExecution
    }
}

public struct ListSessionsRequest: RequestMessage, Equatable {
    public typealias ResponseMessage = ListSessionsResponse

    public static let name = "LIST_SESSIONS"

    public init() { }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(0)
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(0)
    }
}

public struct ListSessionsResponse: Message, Equatable, SerializableCodable {
    public static let name = "SESSIONS_LIST"

    public struct SessionInfo: Sendable, Equatable, Codable {
        public let name: String
        public let activeBuildCount: Int
        public let activeNormalBuildCount: Int
        public let activeIndexBuildCount: Int

        public init(name: String, activeBuildCount: Int, activeNormalBuildCount: Int, activeIndexBuildCount: Int) {
            self.name = name
            self.activeBuildCount = activeBuildCount
            self.activeNormalBuildCount = activeNormalBuildCount
            self.activeIndexBuildCount = activeIndexBuildCount
        }
    }

    /// The list of session mapping UID to info.
    public let sessions: [String: SessionInfo]

    public init(sessions: [String: SessionInfo]) {
        self.sessions = sessions
    }
}

public struct WaitForQuiescenceRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "WAIT_FOR_QUIESCENCE"

    public let sessionHandle: String

    public init(sessionHandle: String) {
        self.sessionHandle = sessionHandle
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.sessionHandle = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.sessionHandle)
    }
}

public struct DeleteSessionRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "DELETE_SESSION"

    public let sessionHandle: String

    public init(sessionHandle: String) {
        self.sessionHandle = sessionHandle
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.sessionHandle = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.sessionHandle)
    }
}

// MARK: PIF Transfer

public struct SetSessionWorkspaceContainerPathRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "SET_SESSION_WORKSPACE_CONTAINER_PATH_REQUEST"

    public let sessionHandle: String
    public let containerPath: String

    public init(sessionHandle: String, containerPath: String) {
        self.sessionHandle = sessionHandle
        self.containerPath = containerPath
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.containerPath = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.containerPath)
    }
}

public struct SetSessionPIFRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "SET_SESSION_PIF_REQUEST"

    public let sessionHandle: String
    public let pifContents: [UInt8]

    public init(sessionHandle: String, pifContents: [UInt8]) {
        self.sessionHandle = sessionHandle
        self.pifContents = pifContents
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.pifContents = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.pifContents)
    }
}

public struct TransferSessionPIFRequest: SessionMessage, RequestMessage, IncrementalPIFMessage, Equatable {
    public typealias ResponseMessage = TransferSessionPIFResponse

    public static let name = "TRANSFER_SESSION_PIF_REQUEST"

    public let sessionHandle: String
    public let workspaceSignature: String

    public init(sessionHandle: String, workspaceSignature: String) {
        self.sessionHandle = sessionHandle
        self.workspaceSignature = workspaceSignature
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.workspaceSignature = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.workspaceSignature)
    }
}

public struct TransferSessionPIFResponse: Message, Equatable {
    public struct MissingObject: Serializable, Equatable, Sendable {
        public let type: PIFObjectType
        public let signature: String

        public init(type: PIFObjectType, signature: String) {
            self.type = type
            self.signature = signature
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            self.type = try deserializer.deserialize()
            self.signature = try deserializer.deserialize()
        }

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.beginAggregate(2)
            serializer.serialize(self.type)
            serializer.serialize(self.signature)
        }
    }

    public static let name = "TRANSFER_SESSION_PIF_RESPONSE"

    /// Whether the PIF transfer is done (and the service has received all the necessary objects).
    public var isComplete: Bool {
        return missingObjects.isEmpty
    }

    /// The list of objects which are missing and still needed to complete the transfer.
    public let missingObjects: [MissingObject]

    public init(missingObjects: [MissingObject]) {
        self.missingObjects = missingObjects
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.missingObjects = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.missingObjects)
    }
}

public struct TransferSessionPIFObjectsLegacyRequest: SessionMessage, RequestMessage, IncrementalPIFMessage, Equatable {
    public typealias ResponseMessage = TransferSessionPIFResponse

    public static let name = "TRANSFER_SESSION_PIF_OBJECTS_LEGACY_REQUEST"

    private struct ObjectData: Serializable, Equatable {
        let data: [UInt8]

        init(_ data: [UInt8]) {
            self.data = data
        }

        init(from deserializer: any Deserializer) throws {
            self.data = try deserializer.deserialize()
        }

        func serialize<T: Serializer>(to serializer: T) {
            serializer.serialize(self.data)
        }
    }

    public let sessionHandle: String
    public let objects: [[UInt8]]

    public init(sessionHandle: String, objects: [[UInt8]]) {
        self.sessionHandle = sessionHandle
        self.objects = objects
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.objects = (try deserializer.deserialize() as [ObjectData]).map{ $0.data }
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.objects.map{ ObjectData($0) })
    }
}

public struct TransferSessionPIFObjectsRequest: SessionMessage, RequestMessage, IncrementalPIFMessage, Equatable {
    public typealias ResponseMessage = TransferSessionPIFResponse

    public static let name = "TRANSFER_SESSION_PIF_OBJECTS_REQUEST"

    public struct ObjectData: Serializable, Equatable, Sendable {
        public let pifType: PIFObjectType
        public let signature: String
        public let data: ByteString

        public init(pifType: PIFObjectType, signature: String, data: ByteString) {
            self.pifType = pifType
            self.signature = signature
            self.data = data
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(3)
            self.pifType = try deserializer.deserialize()
            self.signature = try deserializer.deserialize()
            // FIXME: Avoid copying here, we should be able to decode slices.
            self.data = try deserializer.deserialize()
        }

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.beginAggregate(3)
            serializer.serialize(self.pifType)
            serializer.serialize(self.signature)
            serializer.serialize(self.data)
        }
    }

    public let sessionHandle: String
    public let objects: [ObjectData]

    public init(sessionHandle: String, objects: [ObjectData]) {
        self.sessionHandle = sessionHandle
        self.objects = objects
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.objects = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.objects)
    }
}

public struct AuditSessionPIFRequest: SessionMessage, RequestMessage, IncrementalPIFMessage, Equatable {
    public typealias ResponseMessage = TransferSessionPIFResponse

    public static let name = "AUDIT_SESSION_PIF_REQUEST"

    public let sessionHandle: String
    public let pifContents: [UInt8]

    public init(sessionHandle: String, pifContents: [UInt8]) {
        self.sessionHandle = sessionHandle
        self.pifContents = pifContents
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.pifContents = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.pifContents)
    }
}

public struct IncrementalPIFLookupFailureRequest: SessionMessage, RequestMessage, IncrementalPIFMessage, Equatable {
    public typealias ResponseMessage = TransferSessionPIFResponse

    public static let name = "INCREMENTAL_PIF_LOOKUP_FAILURE"

    public let sessionHandle: String
    public let diagnostic: String

    public init(sessionHandle: String, diagnostic: String) {
        self.sessionHandle = sessionHandle
        self.diagnostic = diagnostic
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.diagnostic = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.diagnostic)
    }
}

// MARK: Workspace Model

public struct WorkspaceInfoRequest: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = WorkspaceInfoResponse

    public static let name = "WORKSPACE_INFO_REQUEST"

    public let sessionHandle: String

    public init(sessionHandle: String) {
        self.sessionHandle = sessionHandle
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.sessionHandle = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.sessionHandle)
    }
}

public struct WorkspaceInfoResponse: Message, Equatable {
    public static let name = "WORKSPACE_INFO_RESPONSE"

    public struct WorkspaceInfo: SerializableCodable, Equatable, Sendable {
        public struct TargetInfo: SerializableCodable, Equatable, Sendable {
            public let guid: String
            public let targetName: String
            public let projectName: String

            public init(guid: String, targetName: String, projectName: String) {
                self.guid = guid
                self.targetName = targetName
                self.projectName = projectName
            }
        }

        public let targetInfos: [TargetInfo]

        public init(targetInfos: [WorkspaceInfoResponse.WorkspaceInfo.TargetInfo]) {
            self.targetInfos = targetInfos
        }
    }

    public let sessionHandle: String
    public let workspaceInfo: WorkspaceInfo

    public init(sessionHandle: String, workspaceInfo: WorkspaceInfo) {
        self.sessionHandle = sessionHandle
        self.workspaceInfo = workspaceInfo
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.workspaceInfo = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.workspaceInfo)
    }
}

// MARK: Generic Responses to the client

public struct ErrorResponse: Message, Equatable {
    public static let name = "ERROR"

    public let description: String

    public init(_ description: String) {
        self.description = description
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.description = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.description)
    }
}

public struct BoolResponse: Message, Equatable {
    public static let name = "BOOL"

    public let value: Bool

    public init(_ value: Bool) {
        self.value = value
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.value = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.value)
    }
}

public struct StringResponse: Message, Equatable {
    public static let name = "STRING"

    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.value = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.value)
    }
}

public struct StringListResponse: Message, Equatable {
    public static let name = "STRING_LIST"

    public let value: [String]

    public init(_ value: [String]) {
        self.value = value
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.value = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.value)
    }
}

// MARK: Responses to the client

public typealias PingResponse = PingRequest

public typealias VoidResponse = PingRequest

// MARK: Polymorphic IPC Message

/// A generic IPC message.
///
/// We use a custom encoding for IPC messages to make them somewhat recognizable on the wire.
public struct IPCMessage: Serializable, Sendable {

    static let extraMessageTypes: [any Message.Type] = []

    /// All known message types.
    static let messageTypes: [any Message.Type] = [
        PingRequest.self,
        SetConfigItemRequest.self,
        ClearAllCachesRequest.self,

        GetPlatformsRequest.self,
        GetSDKsRequest.self,
        GetSpecsRequest.self,
        GetStatisticsRequest.self,
        GetToolchainsRequest.self,
        GetBuildSettingsDescriptionRequest.self,
        ExecuteCommandLineToolRequest.self,

        CreateSessionRequest.self,
        CreateSessionResponse.self,
        SetSessionSystemInfoRequest.self,
        SetSessionUserInfoRequest.self,
        SetSessionUserPreferencesRequest.self,
        ListSessionsRequest.self,
        ListSessionsResponse.self,
        WaitForQuiescenceRequest.self,
        DeleteSessionRequest.self,

        SetSessionWorkspaceContainerPathRequest.self,
        SetSessionPIFRequest.self,
        TransferSessionPIFRequest.self,
        TransferSessionPIFResponse.self,
        TransferSessionPIFObjectsRequest.self,
        TransferSessionPIFObjectsLegacyRequest.self,
        AuditSessionPIFRequest.self,
        IncrementalPIFLookupFailureRequest.self,

        WorkspaceInfoRequest.self,
        WorkspaceInfoResponse.self,

        CreateXCFrameworkRequest.self,

        AppleSystemFrameworkNamesRequest.self,
        ProductTypeSupportsMacCatalystRequest.self,
        DeveloperPathRequest.self,

        // TODO: Delete once all clients are no longer calling the public APIs which invoke this message
        AvailableAppExtensionPointIdentifiersRequest.self,
        MacCatalystUnavailableFrameworkNamesRequest.self,

        ErrorResponse.self,
        BoolResponse.self,
        StringResponse.self,
        StringListResponse.self
    ] + buildOperationMessageTypes
      + macroEvaluationMessageTypes
      + planningOperationMessageTypes
      + taskConstructionMessageTypes
      + indexingMessageTypes
      + previewInfoMessageTypes
      + projectDescriptorMessageTypes
      + documentationMessageTypes
      + localizationMessageTypes
      + dependencyClosureMessageTypes
      + dependencyGraphMessageTypes

    /// Reverse name mapping.
    static let messageNameToID: [String: any Message.Type] = {
        var result = [String: any Message.Type]()
        for type in IPCMessage.messageTypes {
            result[type.name] = type
        }
        return result
    }()

    /// The wrapped message.
    public let message: any Message

    /// Create a wrapper IPC message.
    public init(_ message: any Message) {
        self.message = message
    }

    public init(from deserializer: any Deserializer) throws {
        // Custom encoding: (true, <name>, message)
        let name = try deserializer.deserialize() as String
        guard let type = IPCMessage.messageNameToID[name] else {
            throw DeserializerError.incorrectType("unexpected IPC message: `\(name)`")
        }
        do {
            self.message = try type.init(from: deserializer)
        } catch let error as DeserializerError {
            throw error.withSuffix(" (while deserializing IPC message: `\(name)`)")
        } catch {
            throw error
        }
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serialize(type(of: message).name)
        message.serialize(to: serializer)
    }
}

private extension DeserializerError {
    func withSuffix(_ suffix: String) -> DeserializerError {
        switch self {
        case let .invalidDelegate(message):
            return .invalidDelegate(message + suffix)
        case let .incorrectType(message):
            return .incorrectType(message + suffix)
        case let .unexpectedValue(message):
            return .unexpectedValue(message + suffix)
        case let .deserializationFailed(message):
            return .deserializationFailed(message + suffix)
        }
    }
}

// protocol to aid in changing messages which carry an xcodeAppPath, to developerPath
// delete this after a while, and change effectiveDeveloperPath to just developerPath
public protocol DeveloperPathTransitional {
    var developerPath: Path? { get }
    var xcodeAppPath: Path? { get }
}

extension DeveloperPathTransitional {
    public var effectiveDeveloperPath: Path? {
        if let developerPath {
            return developerPath
        } else if let xcodeAppPath = xcodeAppPath {
            return xcodeAppPath.join("Contents").join("Developer")
        }
        return nil
    }
}

extension CreateXCFrameworkRequest: DeveloperPathTransitional {}
extension AppleSystemFrameworkNamesRequest: DeveloperPathTransitional {}
extension ProductTypeSupportsMacCatalystRequest: DeveloperPathTransitional {}
extension CreateSessionRequest: DeveloperPathTransitional {
    public var xcodeAppPath: Path? {
        appPath
    }
}
