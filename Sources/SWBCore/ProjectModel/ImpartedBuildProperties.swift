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

public import SWBProtocol
import SWBUtil
public import SWBMacro

/// Build properties, such as build settings, which are imparted recursively onto any clients.
///
/// Build settings defined by this object will override settings defined in the client target itself, so merging requires
/// `$(inherited)` to be present in the build setting value.
public final class ImpartedBuildProperties: ProjectModelItem {
    /// The (cached) parsed build settings table.
    public var buildSettings: MacroValueAssignmentTable { return buildSettingsCache.getValue(self) }
    private let buildSettingsCache = LazyCache { (buildProperties: ImpartedBuildProperties) -> MacroValueAssignmentTable in
        return BuildConfiguration.createTableFromUserSettings(buildProperties.buildSettingsData, namespace: buildProperties.namespace)
    }
    private let buildSettingsData: [String: PropertyListItem]

    /// The namespace to use for lazily parsing build settings.
    private let namespace: MacroNamespace

    @_spi(Testing) public init(_ model: SWBProtocol.ImpartedBuildProperties, _ pifLoader: PIFLoader) {
        self.namespace = pifLoader.userNamespace
        self.buildSettingsData = BuildConfiguration.convertMacroBindingSourceToPlistDictionary(model.buildSettings)
    }

    init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // buildSettings is required.
        guard case let .plDict(settingsDict)? = pifDict[PIFKey_BuildConfiguration_buildSettings] else {
            throw PIFParsingError.missingRequiredKey(keyName: PIFKey_BuildConfiguration_buildSettings, objectType: Self.self)
        }

        // Create the macro assignment table.
        namespace = pifLoader.userNamespace
        buildSettingsData = settingsDict
    }

    /// Returns `true` if there are no declared properties.
    public var isEmpty: Bool {
        return buildSettingsData.isEmpty
    }
}
