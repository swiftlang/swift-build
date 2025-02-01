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

public struct PreviewInfoRequest: SessionChannelBuildMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "PREVIEW_INFO_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// The request itself.
    public let request: BuildRequestMessagePayload

    /// Which targets needs preview info?
    public let targetIDs: [String]

    /// The source file that is being edited during the preview.
    public let sourceFile: Path

    /// Suffix for disambiguating different thunk variants.
    public let thunkVariantSuffix: String

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload, targetID: String, sourceFile: Path, thunkVariantSuffix: String) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
        self.targetIDs = [targetID]
        self.sourceFile = sourceFile
        self.thunkVariantSuffix = thunkVariantSuffix
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.request = try deserializer.deserialize()
        self.targetIDs = try deserializer.deserialize()
        self.sourceFile = try deserializer.deserialize()
        self.thunkVariantSuffix = try deserializer.deserialize()
    }
}

public struct PreviewInfoResponse: Message, Equatable {
    public static let name = "PREVIEW_INFO_RECEIVED"

    /// Which target requested this info?
    public let targetIDs: [String]

    /// A serialized representation of the payload.
    public let output: [PreviewInfoMessagePayload]

    public init(targetIDs: [String], output: [PreviewInfoMessagePayload]) {
        self.targetIDs = targetIDs
        self.output = output
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.targetIDs = try deserializer.deserialize()
        self.output = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.targetIDs)
            serializer.serialize(self.output)
        }
    }
}

public struct PreviewTargetDependencyInfoRequest: SessionChannelBuildMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "PREVIEW_TARGET_DEPENDENCY_INFO_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// The request itself.
    public let request: BuildRequestMessagePayload

    /// Which targets needs preview info?
    public let targetIDs: [String]

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload, targetIDs: [String]) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
        self.targetIDs = targetIDs
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.request = try deserializer.deserialize()
        self.targetIDs = try [deserializer.deserialize()]
    }
}

let previewInfoMessageTypes: [any Message.Type] = [
    PreviewInfoRequest.self,
    PreviewInfoResponse.self,
    PreviewTargetDependencyInfoRequest.self,
]
