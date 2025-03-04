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
    public let provisioningStyle: ProvisioningStyle
    public let bundleIdentifierFromInfoPlist: String

    public init(configurationName: String, provisioningStyle: ProvisioningStyle, bundleIdentifierFromInfoPlist: String) {
        self.configurationName = configurationName
        self.provisioningStyle = provisioningStyle
        self.bundleIdentifierFromInfoPlist = bundleIdentifierFromInfoPlist
    }
}

extension ProvisioningSourceData: Encodable, Decodable {
    enum CodingKeys: String, CodingKey {
        case configurationName
        case provisioningStyle
        case bundleIdentifierFromInfoPlist
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let provisioningStyle = try ProvisioningStyle(rawValue: container.decode(ProvisioningStyle.RawValue.self, forKey: .provisioningStyle)) else {
            throw DecodingError.dataCorruptedError(forKey: .provisioningStyle, in: container, debugDescription: "invalid provisioning style")
        }

        self.init(configurationName: try container.decode(String.self, forKey: .configurationName), provisioningStyle: provisioningStyle, bundleIdentifierFromInfoPlist: try container.decode(String.self, forKey: .bundleIdentifierFromInfoPlist))
    }
}


// MARK: SerializableCodable

extension ProvisioningSourceData: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(configurationName)
            serializer.serialize(provisioningStyle)
            serializer.serialize(bundleIdentifierFromInfoPlist)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(3...5)
        self.configurationName = try deserializer.deserialize()
        self.provisioningStyle = try deserializer.deserialize()
        if count > 3 {
            _ = try deserializer.deserialize() as Bool          // appIDHasFeaturesEnabled
        }
        if count > 4 {
            _ = try deserializer.deserialize() as String        // legacyTeamID
        }
        self.bundleIdentifierFromInfoPlist = try deserializer.deserialize()
    }
}
