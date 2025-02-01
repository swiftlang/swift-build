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

import SWBUtil

/// Represents a device family or user interface idiom for which an application can be built.
public struct DeviceFamily: Decodable, Hashable, Sendable {
    /// The numeric identifier of the device family used to populate the `UIDeviceFamily` Info.plist key, if present.
    ///
    /// Mac (non-Catalyst) does not use a numeric identifier.
    public let identifier: Int?

    /// The string used to identify the device family's UI idiom.
    ///
    /// This is the value used to identify the UI idiom in actool/ibtool's `--target-device` argument.
    public let name: String?

    /// The human readable display name of the device family.
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case displayName = "DisplayName"
        case identifier = "Identifier"
        case name = "Name"
    }

    public init(identifier: Int, displayName: String) {
        self.identifier = identifier
        self.name = nil
        self.displayName = displayName
    }

    public init(identifier: Int? = nil, name: String, displayName: String) {
        self.identifier = identifier
        self.name = name
        self.displayName = displayName
    }

    /// Decodes a device family structure from the relevant subkeys of an SDKSettings.plist file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        let identifier = try container.decodeIntOrStringIfPresent(forKey: .identifier)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        switch (identifier, name) {
        case (let identifier, let name?):
            switch identifier {
            case 1:
                // FIXME: Allow rdar://85365710 (Accept phone and pad as aliases for iphone and ipad in actool/ibtool's --target-device argument) time to propagate
                self.identifier = identifier
                self.name = "iphone"
                break
            case 2:
                // FIXME: Allow rdar://85365710 (Accept phone and pad as aliases for iphone and ipad in actool/ibtool's --target-device argument) time to propagate
                self.identifier = identifier
                self.name = "ipad"
                break
            case 7:
                self.identifier = identifier
                self.name = "vision"
                break
            default:
                self.identifier = identifier
                self.name = name
                break
            }
        case (let identifier?, nil):
            self.identifier = identifier
            self.name = nil
        case (nil, nil):
            throw StubError.error("A DeviceFamily definition must contain at least \(CodingKeys.identifier.rawValue) or \(CodingKeys.name.rawValue).")
        }
    }
}

public struct DeviceFamilies: Hashable {
    @_spi(Testing) public let list: [DeviceFamily]

    /// Used for platforms where a numeric `UIDeviceFamily` value is not used, but a device family name must still be passed to asset processing tools via the `--target-device` flag. Mutually exclusive with `deviceFamiliesByIdentifier`.
    ///
    /// Currently this only applies on macOS (except Mac Catalyst), where the value `"mac"` is used.
    let explicitTargetDeviceName: String?

    /// Mapping of numeric `UIDeviceFamily` values to asset processing tool device family names. Mutually exclusive with `explicitTargetDeviceName`.
    private let deviceFamiliesByIdentifier: [Int: DeviceFamily]

    public init(families: [DeviceFamily]) throws {
        self.list = families

        self.explicitTargetDeviceName = list.count == 1
        ? list.filter { $0.identifier == nil }.only?.name
        : nil

        let familiesWithNumericIdentifiers = families.compactMap { family -> (Int, DeviceFamily)? in
            guard let identifier = family.identifier else {
                return nil
            }
            return (identifier, family)
        }
        self.deviceFamiliesByIdentifier = try Dictionary(grouping: familiesWithNumericIdentifiers, by: { $0.0 }).compactMapValues { identifier, deviceFamilies -> DeviceFamily? in
            if deviceFamilies.count > 1 {
                throw StubError.error("Multiple definitions for targeted device family identifier '\(identifier)': \(deviceFamilies.map { $0.1.displayName }.joined(separator: ", "))")
            }
            return deviceFamilies[0].1
        }
    }

    public func targetDeviceName(for targetedDeviceFamilyIdentifier: Int) -> String? {
        precondition(explicitTargetDeviceName == nil)
        return deviceFamiliesByIdentifier[targetedDeviceFamilyIdentifier]?.name
    }

    public func deviceDisplayName(for targetedDeviceFamilyIdentifier: Int) -> String? {
        precondition(explicitTargetDeviceName == nil)
        return deviceFamiliesByIdentifier[targetedDeviceFamilyIdentifier]?.displayName
    }

    /// Convenience property which returns the target device identifiers.
    public var targetDeviceIdentifiers: Set<Int> {
        return Set<Int>(list.compactMap(\.identifier))
    }

    /// Convenience property which returns the target device identifiers as strings
    public var targetDeviceIdentifierStrings: Set<String> {
        return Set<String>(list.compactMap({$0.identifier?.toString()}))
    }
}

fileprivate extension KeyedDecodingContainer {
    func decodeIntOrStringIfPresent(forKey key: Key) throws -> Int? {
        do {
            return try decodeIfPresent(Int.self, forKey: key)
        } catch {
            guard let string = try decodeIfPresent(String.self, forKey: key), !string.isEmpty else {
                return nil
            }
            guard let value = Int(string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not parse '\(string)' as Int for key \(key)")
            }
            return value
        }
    }
}
