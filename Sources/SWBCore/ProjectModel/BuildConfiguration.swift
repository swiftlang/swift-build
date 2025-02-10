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

import SWBProtocol
import SWBUtil
public import SWBMacro

public final class BuildConfiguration: ProjectModelItem, Encodable, Sendable
{
    public let name: String

    /// The (cached) parsed build settings table.
    public var buildSettings: MacroValueAssignmentTable { return buildSettingsCache.getValue(self) }
    private let buildSettingsCache = LazyCache { (buildConfiguration: BuildConfiguration) -> MacroValueAssignmentTable in
        return BuildConfiguration.createTableFromUserSettings(buildConfiguration.buildSettingsData, namespace: buildConfiguration.namespace)
    }
    private let buildSettingsData: [String: PropertyListItem]

    /// The namespace to use for lazily parsing build settings.
    private let namespace: MacroNamespace

    public let baseConfigurationFileReferenceGUID: String?

    public func baseConfigurationFileReference(_ workspace: Workspace) -> FileReference? {
        if let baseConfigurationFileReferenceGUID {
            return workspace.lookupReference(for: baseConfigurationFileReferenceGUID) as? FileReference
        } else {
            return nil
        }
    }

    public let impartedBuildProperties: ImpartedBuildProperties

    private enum CodingKeys : String, CodingKey {
        case name
        case namespace
        case baseConfigurationFileReferenceGUID
    }

    /// Helper method to convert MacroBindingSource array to plist dictionary.
    static func convertMacroBindingSourceToPlistDictionary(
        _ buildSettings: [SWBProtocol.BuildConfiguration.MacroBindingSource]
    ) -> [String: PropertyListItem] {
        // FIXME: Change the base representation once the legacy implementation dies.
        var settings = [String: PropertyListItem]()
        for setting in buildSettings {
            switch setting.value {
            case .string(let value):
                settings[setting.key] = .plString(value)
            case .stringList(let value):
                settings[setting.key] = .plArray(value.map{ .plString($0) })
            }
        }
        return settings
    }

    init(_ model: SWBProtocol.BuildConfiguration, _ pifLoader: PIFLoader) {
        self.name = model.name
        self.namespace = pifLoader.userNamespace
        self.buildSettingsData = BuildConfiguration.convertMacroBindingSourceToPlistDictionary(model.buildSettings)
        self.baseConfigurationFileReferenceGUID = model.baseConfigurationFileReferenceGUID
        self.impartedBuildProperties = ImpartedBuildProperties(model.impartedBuildProperties, pifLoader)
    }

    @_spi(Testing) public init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // name is required.
        name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)

        // buildSettings is required.
        guard case let .plDict(settingsDict)? = pifDict[PIFKey_BuildConfiguration_buildSettings] else {
            throw PIFParsingError.missingRequiredKey(keyName: PIFKey_BuildConfiguration_buildSettings, objectType: Self.self)
        }

        // Create the macro assignment table.
        namespace = pifLoader.userNamespace
        buildSettingsData = settingsDict

        // baseConfigurationFileReference is optional.
        // The raw value here is the GUID of the file reference, but since that reference must be in the same project, and the project's group tree is loaded before any of the project's build configurations or targets, we can safely resolve the GUIDs to actual objects here.
        baseConfigurationFileReferenceGUID = try Self.parseOptionalValueForKeyAsString(PIFKey_BuildConfiguration_baseConfigurationFileReference, pifDict: pifDict)

        // The imparted build properties are optional.
        impartedBuildProperties = try Self.parseOptionalValueForKeyAsProjectModelItem(PIFKey_impartedBuildProperties, pifDict: pifDict, pifLoader: pifLoader, construct: { try ImpartedBuildProperties(fromDictionary: $0, withPIFLoader: pifLoader) }) ?? ImpartedBuildProperties(fromDictionary: [PIFKey_BuildConfiguration_buildSettings: .plDict([:])], withPIFLoader: pifLoader)
    }

    /// Create a macro value assignment table from a user provided dictionary of settings.
    //
    // FIXME: Figure out where this should really live, and how it should be factored. See also , e.g., MacroNamespace.parseTable.
    //
    // FIXME: We need to ensure that diagnostics from here are surfaced.
    static func createTableFromUserSettings(_ settings: [String: PropertyListItem], namespace: MacroNamespace) -> MacroValueAssignmentTable {
        // Iterate over the keys and values in the dictionary.
        var table = MacroValueAssignmentTable(namespace: namespace)
        for (key, value) in settings.sorted(byKey: <) {
            // Ask the MacroConfigFileParser to separate the macro name and any conditions.
            let (name, conditions) = MacroConfigFileParser.parseMacroNameAndConditionSet(key)

            // We might not get a macro name if the macro was malformed (for example in the case of environment variables).  We ignore such entries.
            guard let macroName = name else { continue }

            // If we did find a macro name, we look up the macro.
            let macro = namespace.lookupOrDeclareMacro(UserDefinedMacroDeclaration.self, macroName)

            // We also construct a condition set if we have conditions.
            var conditionSet: MacroConditionSet?
            if let conditions {
                conditionSet = MacroConditionSet(conditions: conditions.map{ MacroCondition(parameter: namespace.declareConditionParameter($0.0), valuePattern: $0.1) })
            }

            // Parse the value in a manner consistent with the macro definition.
            let expr: MacroExpression
            switch value {
            case .plString(let stringValue):
                expr = namespace.parseForMacro(macro, value: stringValue)
            case .plArray(let contents):
                let asStringList = contents.map{ item -> String in
                    guard case let .plString(string) = item else { fatalError("unexpected build configuration data") }
                    return string
                }
                expr = namespace.parseForMacro(macro, value: asStringList)
            default:
                fatalError("unexpected build configuration data")
            }

            table.push(macro, expr, conditions: conditionSet)
        }
        return table
    }
}
