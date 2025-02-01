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

/// A request to generate information about the localization content of the build, such as input xcstrings and output stringsdata.
public struct LocalizationInfoRequest: SessionChannelBuildMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "LOCALIZATION_INFO_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// A payload describing the build request for the build we're interested in.
    public let request: BuildRequestMessagePayload

    /// A set of Target GUIDs (not ConfiguredTarget GUIDs) that localization info is specifically being requested for.
    ///
    /// If `nil`, data for all targets is returned.
    public let targetIdentifiers: Set<String>?

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload, targetIdentifiers: Set<String>?) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
        self.targetIdentifiers = targetIdentifiers
    }
}

/// A successful response to `LocalizationInfoRequest` with information about the localizable content of the build.
public struct LocalizationInfoResponse: Message, Equatable, SerializableCodable {
    public static let name = "LOCALIZATION_INFO_RECEIVED"

    /// A payload of localization info per Target.
    public let targetInfos: [LocalizationInfoMessagePayload]

    public init(targetInfos: [LocalizationInfoMessagePayload]) {
        self.targetInfos = targetInfos
    }
}

let localizationMessageTypes: [any Message.Type] = [
    LocalizationInfoRequest.self,
    LocalizationInfoResponse.self
]
