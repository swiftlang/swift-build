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

public struct BuildSettingsInfoRequest: SessionChannelMessage, SerializableCodable, Equatable {
    public static let name = "BUILD_SETTINGS_INFO_REQUEST"

    public let sessionHandle: String
    public let responseChannel: UInt64
    public let targetGUIDs: [TargetGUID]

    public init(sessionHandle: String, responseChannel: UInt64, targetGUIDs: [TargetGUID]) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.targetGUIDs = targetGUIDs
    }
}

public struct BuildSettingsInfoResponse: Message, SerializableCodable, Equatable {
    public static let name = "BUILD_SETTINGS_INFO_RESPONSE"

    public let propertyDomainSpecificationIdentifiers: Set<String>

    public init(propertyDomainSpecificationIdentifiers: Set<String>) {
        self.propertyDomainSpecificationIdentifiers = propertyDomainSpecificationIdentifiers
    }
}

// MARK: Registering messages

let buildSettingsInfoMessageTypes: [any Message.Type] = [
    BuildSettingsInfoRequest.self,
    BuildSettingsInfoResponse.self,
]
