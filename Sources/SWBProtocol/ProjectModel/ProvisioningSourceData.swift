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

public struct ProvisioningSourceData: Serializable, Sendable {
    public let configurationName: String
    /// Whether the App ID for this target+configuration has any features enabled.
    public let appIDHasFeaturesEnabled: Bool
    public let provisioningStyle: ProvisioningStyle
    public let bundleIdentifierFromInfoPlist: String

    public init(configurationName: String, appIDHasFeaturesEnabled: Bool, provisioningStyle: ProvisioningStyle, bundleIdentifierFromInfoPlist: String) {
        self.configurationName = configurationName
        self.appIDHasFeaturesEnabled = appIDHasFeaturesEnabled
        self.provisioningStyle = provisioningStyle
        self.bundleIdentifierFromInfoPlist = bundleIdentifierFromInfoPlist
    }
}

extension ProvisioningSourceData: Encodable, Decodable {
    enum CodingKeys: String, CodingKey {
        case configurationName
        case appIDHasFeaturesEnabled
        case provisioningStyle
        case bundleIdentifierFromInfoPlist
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let appIDHasFeaturesEnabled: Bool
        if let appIDString = try container.decodeIfPresent(String.self, forKey: .appIDHasFeaturesEnabled) {
            switch appIDString {
            case "true":
                appIDHasFeaturesEnabled = true
            case "false":
                appIDHasFeaturesEnabled = false
            default:
                throw DecodingError.dataCorruptedError(forKey: .appIDHasFeaturesEnabled, in: container, debugDescription: "\(appIDString) is not a boolean value")
            }
        } else {
            appIDHasFeaturesEnabled = false
        }

        guard let provisioningStyle = try ProvisioningStyle(rawValue: container.decode(ProvisioningStyle.RawValue.self, forKey: .provisioningStyle)) else {
            throw DecodingError.dataCorruptedError(forKey: .provisioningStyle, in: container, debugDescription: "invalid provisioning style")
        }

        self.init(configurationName: try container.decode(String.self, forKey: .configurationName), appIDHasFeaturesEnabled: appIDHasFeaturesEnabled, provisioningStyle: provisioningStyle, bundleIdentifierFromInfoPlist: try container.decode(String.self, forKey: .bundleIdentifierFromInfoPlist))
    }
}


// MARK: SerializableCodable

extension ProvisioningSourceData: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(configurationName)
            serializer.serialize(appIDHasFeaturesEnabled)
            serializer.serialize(provisioningStyle)
            serializer.serialize(bundleIdentifierFromInfoPlist)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(4...5)
        self.configurationName = try deserializer.deserialize()
        self.appIDHasFeaturesEnabled = try deserializer.deserialize()
        self.provisioningStyle = try deserializer.deserialize()
        if count > 4 {
            _ = try deserializer.deserialize() as String        // legacyTeamID
        }
        self.bundleIdentifierFromInfoPlist = try deserializer.deserialize()
    }
}
