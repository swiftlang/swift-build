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

public protocol IndexingInfoRequest: SessionChannelBuildMessage {
    var targetID: String { get }
}

public protocol IndexingInfoResponse {
    var targetID: String { get }
}

public struct IndexingFileSettingsRequest: IndexingInfoRequest, RequestMessage, SessionChannelBuildMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "INDEXING_INFO_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// The request itself.
    public let request: BuildRequestMessagePayload

    /// Which target needs indexing info?
    public let targetID: String

    /// Which source file needs indexing info? If it is `nil` info is returned for all files.
    public let filePath: String?

    /// If `true` only information for the output path is returned.
    public let outputPathOnly: Bool

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload, targetID: String, filePath: String?, outputPathOnly: Bool) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
        self.targetID = targetID
        self.filePath = filePath
        self.outputPathOnly = outputPathOnly
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.request = try deserializer.deserialize()
        self.targetID = try deserializer.deserialize()
        self.filePath = try deserializer.deserialize()
        self.outputPathOnly = try deserializer.deserialize()
    }
}

public struct IndexingFileSettingsResponse: IndexingInfoResponse, Message, Equatable {
    public static let name = "INDEXING_INFO_RECEIVED"

    /// Which target requested this info?
    public let targetID: String

    // FIXME: A future commit will use a stronger type here (e.g. SourceFileIndexingInfo)
    /// A serialized representation of the old indexing info plist
    public let data: ByteString

    public init(targetID: String, data: ByteString) {
        self.targetID = targetID
        self.data = data
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.targetID = try deserializer.deserialize()
        self.data = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.targetID)
            serializer.serialize(self.data)
        }
    }
}

public struct IndexingHeaderInfoRequest: IndexingInfoRequest, RequestMessage, SessionChannelBuildMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = VoidResponse
    
    public static let name = "INDEXING_HEADER_INFO_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// The request itself.
    public let request: BuildRequestMessagePayload

    /// Which target needs indexing info?
    public let targetID: String

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload, targetID: String) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
        self.targetID = targetID
    }
}

public struct IndexingHeaderInfoResponse: IndexingInfoResponse, Message, Equatable, SerializableCodable {
    public static let name = "INDEXING_HEADER_INFO_RECEIVED"

    /// Which target requested this info?
    public let targetID: String

    public let productName: String
    public let copiedPathMap: [String: String]

    public init(targetID: String, productName: String, copiedPathMap: [String: String]) {
        self.targetID = targetID
        self.productName = productName
        self.copiedPathMap = copiedPathMap
    }
}

let indexingMessageTypes: [any Message.Type] = [
    IndexingFileSettingsRequest.self,
    IndexingFileSettingsResponse.self,
    IndexingHeaderInfoRequest.self,
    IndexingHeaderInfoResponse.self,
    BuildDescriptionTargetInfoRequest.self,
]

public struct BuildDescriptionTargetInfoRequest: SessionChannelBuildMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = VoidResponse
    
    public static let name = "BUILD_DESCRIPTION_TARGET_INFO"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// The request itself.
    public let request: BuildRequestMessagePayload

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.request = try deserializer.deserialize()
    }
}
