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

/// A request to generate information about the documentation that will be built for a given build request.
///
/// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
public struct DocumentationInfoRequest: SessionChannelBuildMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse
    
    public static let name = "DOCUMENTATION_INFO_REQUESTED"

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

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.request = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(self.sessionHandle)
            serializer.serialize(self.responseChannel)
            serializer.serialize(self.request)
        }
    }
}

/// A response to `DocumentationInfoRequest` with information about the documentation that will be built for the request.
///
/// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
public struct DocumentationInfoResponse: Message, Equatable {
    public static let name = "DOCUMENTATION_INFO_RECEIVED"

    /// A serialized representation of the payload.
    public let output: [DocumentationInfoMessagePayload]

    public init(output: [DocumentationInfoMessagePayload]) {
        self.output = output
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.output = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            serializer.serialize(self.output)
        }
    }
}

let documentationMessageTypes: [any Message.Type] = [
    DocumentationInfoRequest.self,
    DocumentationInfoResponse.self,
]
