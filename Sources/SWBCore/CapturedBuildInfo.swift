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
import SWBMacro

/// The standard extension for build info files emitted in this format.
public let capturedBuildInfoFileExtension = "xcbuildinfo"

/// Errors thrown when deserializing captured build info from a property list.
public enum CapturedInfoDeserializationError: Error, CustomStringConvertible {
    case error([String])

    public var description: String {
        switch self {
        case .error(let strings):
            var result = ""
            for (idx, string) in strings.enumerated() {
                if idx > 0 {
                    result += "\n...."
                }
                result += string
            }
            return result
        }
    }

    public var singleLineDescription: String {
        switch self {
        case .error(let strings):
            var result = ""
            for (idx, string) in strings.enumerated() {
                switch idx {
                case 0:
                    break
                case 1:
                    result += " ("
                default:
                    result += ", "
                }
                result += string
            }
            if strings.count > 1 {
                result += ")"
            }
            return result
        }
    }

    func appending(_ string: String) -> CapturedInfoDeserializationError {
        switch self {
            case .error(let strings):
                return .error(strings + [string])
        }
    }
}

/// Captured information about the inputs to and structure of the build.
///
/// This structure is part of the build description and will be written by the build if it was instructed to do so. The written file can then be consumed by separate tools to provide information about the build's configuration.
///
/// This structure is not intended to capture every aspect of the targets' configuration, but instead those aspects which are currently known to be used, albeit balancing that against implementation simplicity. (For example, not every build setting is currently being used, but it's simpler to capture them all rather than to filter out those not being used.)
public struct CapturedBuildInfo: PropertyListItemConvertible, Sendable {
    /// The current build info format version.
    public static let currentFormatVersion = 1

    /// The version of this captured build info.
    private let version: Int

    /// The info for all of the targets built in this build.
    ///
    /// This list is in topological order: For each target all of the targets that it depends on will be listed before it.
    public let targets: [CapturedTargetInfo]

    /// Create a `BuildConfigurationInfo` struct from raw objects.
    public init(targets: [CapturedTargetInfo]) {
        self.version = type(of: self).currentFormatVersion
        self.targets = targets
    }

    /// Create a `BuildConfigurationInfo` struct from the inputs to a `BuildDescription`.
    public init(_ targetBuildGraph: TargetBuildGraph, _ settingsPerTarget: [ConfiguredTarget: Settings]) {
        var targetInfos = [CapturedTargetInfo]()
        for configuredTarget in targetBuildGraph.allTargets {
            let target = configuredTarget.target
            let project = targetBuildGraph.workspaceContext.workspace.project(for: target)

            let settings = settingsPerTarget[configuredTarget]
            let targetConstructionComponents = settings?.constructionComponents
            let projectXcconfigSettings: CapturedBuildSettingsTableInfo = {
                let settings = targetConstructionComponents?.projectXcconfigSettings?.capturedRepresentation ?? [:]
                return CapturedBuildSettingsTableInfo(name: CapturedBuildSettingsTableInfo.Name.projectXcconfig, path: targetConstructionComponents?.projectXcconfigPath, settings: settings)
            }()
            let projectSettings: CapturedBuildSettingsTableInfo = {
                let settings = targetConstructionComponents?.projectSettings?.capturedRepresentation ?? [:]
                return CapturedBuildSettingsTableInfo(name: CapturedBuildSettingsTableInfo.Name.project, path: nil, settings: settings)
            }()
            let targetXcconfigSettings: CapturedBuildSettingsTableInfo = {
                let settings = targetConstructionComponents?.targetXcconfigSettings?.capturedRepresentation ?? [:]
                return CapturedBuildSettingsTableInfo(name: CapturedBuildSettingsTableInfo.Name.targetXcconfig, path: targetConstructionComponents?.targetXcconfigPath, settings: settings)
            }()
            let targetSettings: CapturedBuildSettingsTableInfo = {
                let settings = targetConstructionComponents?.targetSettings?.capturedRepresentation ?? [:]
                return CapturedBuildSettingsTableInfo(name: CapturedBuildSettingsTableInfo.Name.target, path: nil, settings: settings)
            }()

            let targetInfo = CapturedTargetInfo(name: target.name, projectPath: project.xcodeprojPath, projectXcconfigSettings: projectXcconfigSettings, projectSettings: projectSettings, targetXcconfigSettings: targetXcconfigSettings, targetSettings: targetSettings, diagnostics: [])
            targetInfos.append(targetInfo)
        }

        self.init(targets: targetInfos)
    }

    private enum PropertyListStrings: String {
        case version
        case targets
    }

    public var propertyListItem: PropertyListItem {
        return [
            PropertyListStrings.version.rawValue: version.propertyListItem,
            PropertyListStrings.targets.rawValue: targets.map({ $0.propertyListItem }).propertyListItem,
        ].propertyListItem
    }

    public static func fromPropertyList(_ plist: PropertyListItem) throws -> CapturedBuildInfo {
        guard case .plDict(let dict) = plist else {
            throw CapturedInfoDeserializationError.error(["build info is not a dictionary: \(try plist.asJSONFragment().unsafeStringValue)"])
        }

        guard let version = dict[PropertyListStrings.version.rawValue]?.intValue else {
            throw CapturedInfoDeserializationError.error(["build info does not have a valid '\(PropertyListStrings.version.rawValue)' entry: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        // Throw an error if the version is not the same.
        // FIXME: We should instead be able to support older versions to the extent possible.
        if version != currentFormatVersion {
            throw CapturedInfoDeserializationError.error(["build info is version \(version) but only version \(currentFormatVersion) is supported"])
        }

        guard let plTargets = dict[PropertyListStrings.targets.rawValue]?.arrayValue else {
            throw CapturedInfoDeserializationError.error(["\(PropertyListStrings.targets.rawValue) entry in build info is not an array: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        let targets: [CapturedTargetInfo] = try plTargets.map { plTarget in
            return try CapturedTargetInfo.fromPropertyList(plTarget)
        }

        return CapturedBuildInfo(targets: targets)
    }
}

/// The configuration of this target as it was built in this build.
public struct CapturedTargetInfo: PropertyListItemConvertible, Sendable {
    /// The name of this target.
    public let name: String

    /// The path to the project containing this target.
    public let projectPath: Path

    /// The settings defined in the project-level `.xcconfig` file for this target.
    public let projectXcconfigSettings: CapturedBuildSettingsTableInfo

    /// The settings defined at the project level file for this target.
    public let projectSettings: CapturedBuildSettingsTableInfo

    /// The settings defined in the target-level `.xcconfig` file for this target.
    public let targetXcconfigSettings: CapturedBuildSettingsTableInfo

    /// The settings defined at the target level file for this target.
    public let targetSettings: CapturedBuildSettingsTableInfo

    /// All of the settings tables in the target, from lowest to highest precedence.
    public var allSettingsTables: [CapturedBuildSettingsTableInfo] {
        return [
            projectXcconfigSettings,
            projectSettings,
            targetXcconfigSettings,
            targetSettings,
        ]
    }

    /// Any diagnostics regarding getting the target info.
    public let diagnostics: [String]

    private enum PropertyListStrings: String {
        // Top-level keys

        case name
        case projectPath = "project-path"
        case settings
        case diagnostics

        // Settings keys

        case projectXcconfig = "project-xcconfig"
        case project
        case targetXcconfig = "target-xcconfig"
        case target
    }

    public var propertyListItem: PropertyListItem {
        var dict = [String: PropertyListItem]()

        dict[PropertyListStrings.name.rawValue] = name.propertyListItem
        dict[PropertyListStrings.projectPath.rawValue] = projectPath.str.propertyListItem

        // Serialize the settings tables in an array from lowest-precedence to highest, to make reading the serialized form easier.
        var settings = [PropertyListItem]()
        settings.append(projectXcconfigSettings.propertyListItem)
        settings.append(projectSettings.propertyListItem)
        settings.append(targetXcconfigSettings.propertyListItem)
        settings.append(targetSettings.propertyListItem)
        dict[PropertyListStrings.settings.rawValue] = settings.propertyListItem

        if !diagnostics.isEmpty {
            dict[PropertyListStrings.diagnostics.rawValue] = diagnostics.map({ $0.propertyListItem }).propertyListItem
        }
        return dict.propertyListItem
    }

    fileprivate static func fromPropertyList(_ plist: PropertyListItem) throws -> CapturedTargetInfo {
        guard case .plDict(let dict) = plist else {
            throw CapturedInfoDeserializationError.error(["target is not a dictionary: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        guard let targetName = dict[PropertyListStrings.name.rawValue]?.stringValue else {
            throw CapturedInfoDeserializationError.error(["target does not have a valid '\(PropertyListStrings.name.rawValue)' entry: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        let projectPath: Path
        if let plProjectPath = dict[PropertyListStrings.projectPath.rawValue] {
            guard let pathStr = plProjectPath.stringValue else {
                throw CapturedInfoDeserializationError.error(["project path for target '\(targetName)' is not a string: \(try plProjectPath.asJSONFragment().unsafeStringValue)"])
            }
            projectPath = Path(pathStr)
        }
        else {
            throw CapturedInfoDeserializationError.error(["no project path defined for target '\(targetName)': \(try plist.asJSONFragment().unsafeStringValue)"])
        }

        // Unpack the settings dictionaries.
        guard let settingsArray = dict[PropertyListStrings.settings.rawValue]?.arrayValue else {
            throw CapturedInfoDeserializationError.error(["\(PropertyListStrings.settings.rawValue) entry for target '\(targetName)' is not an array: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        guard settingsArray.count == 4 else {
            let plSettings = PropertyListItem.plArray(settingsArray)
            throw CapturedInfoDeserializationError.error(["target '\(targetName)' does not have the expected 4 build settings tables but has: \(try plSettings.asJSONFragment().unsafeStringValue)"])
        }
        let projectXcconfigSettings: CapturedBuildSettingsTableInfo
        let projectSettings: CapturedBuildSettingsTableInfo
        let targetXcconfigSettings: CapturedBuildSettingsTableInfo
        let targetSettings: CapturedBuildSettingsTableInfo
        do {
            projectXcconfigSettings = try CapturedBuildSettingsTableInfo.fromPropertyList(settingsArray[0], expectedTableName: PropertyListStrings.projectXcconfig.rawValue)
            projectSettings = try CapturedBuildSettingsTableInfo.fromPropertyList(settingsArray[1], expectedTableName: PropertyListStrings.project.rawValue)
            targetXcconfigSettings = try CapturedBuildSettingsTableInfo.fromPropertyList(settingsArray[2], expectedTableName: PropertyListStrings.targetXcconfig.rawValue)
            targetSettings = try CapturedBuildSettingsTableInfo.fromPropertyList(settingsArray[3], expectedTableName: PropertyListStrings.target.rawValue)
        }
        catch let error as CapturedInfoDeserializationError {
            throw error.appending("in target '\(targetName)'")
        }
        catch {
            throw CapturedInfoDeserializationError.error(["unable to unpack assignments table in target '\(targetName)': \(try plist.asJSONFragment().unsafeStringValue)"])
        }

        var diagnostics = [String]()
        if let plDiagnostics = dict[PropertyListStrings.diagnostics.rawValue] {
            guard let diags = plDiagnostics.arrayValue else {
                throw CapturedInfoDeserializationError.error(["diagnostics for target '\(targetName)' is not an array: \(try plDiagnostics.asJSONFragment().unsafeStringValue)"])
            }
            for plDiagnostic in diags {
                guard let diagnostic = plDiagnostic.stringValue else {
                    throw CapturedInfoDeserializationError.error(["diagnostic entry for target '\(targetName)' is not a string: \(try plDiagnostic.asJSONFragment().unsafeStringValue)"])
                }
                diagnostics.append(diagnostic)
            }
        }

        return Self.self(name: targetName, projectPath: projectPath, projectXcconfigSettings: projectXcconfigSettings, projectSettings: projectSettings, targetXcconfigSettings: targetXcconfigSettings, targetSettings: targetSettings, diagnostics: diagnostics)
    }
}

/// The representation of a build setting assignment table.
public struct CapturedBuildSettingsTableInfo: Sendable {
    public enum Name: String, Sendable {
        case projectXcconfig = "project-xcconfig"
        case project
        case targetXcconfig = "target-xcconfig"
        case target
    }

    /// The "name" of this table, which describes the level it sits at in its target.
    public let name: Name

    /// The path to the file from which these settings came, if appropriate.
    public let path: Path?

    /// The assignments in this table.
    ///
    /// For a given setting name (key), there will be one or more assignments from highest priority (top of the stack) to lowest.
    public let settings: [String: [CapturedBuildSettingAssignmentInfo]]

    private enum PropertyListStrings: String {
        case name
        case path
        case settings
    }

    public var propertyListItem: PropertyListItem {
        var dict = [
            PropertyListStrings.name.rawValue: name.rawValue.propertyListItem,
            PropertyListStrings.settings.rawValue: settings.propertyListItem,
        ]
        if let path {
            dict[PropertyListStrings.path.rawValue] = path.str.propertyListItem
        }
        return .plDict(dict)
    }

    fileprivate static func fromPropertyList(_ plist: PropertyListItem, expectedTableName: String) throws -> CapturedBuildSettingsTableInfo {
        guard case .plDict(let dict) = plist else {
            throw CapturedInfoDeserializationError.error(["build settings table \(expectedTableName) is not a dictionary: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        guard let nameString = dict[PropertyListStrings.name.rawValue]?.stringValue else {
            throw CapturedInfoDeserializationError.error(["build settings table \(expectedTableName) does not have a valid '\(PropertyListStrings.name.rawValue)' entry: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        guard let tableName = Name(rawValue: nameString) else {
            throw CapturedInfoDeserializationError.error(["invalid '\(PropertyListStrings.name.rawValue)' entry '\(nameString)' for build settings table \(expectedTableName): \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        // Check that the name is what we expect.
        guard tableName.rawValue == expectedTableName else {
            throw CapturedInfoDeserializationError.error(["\(expectedTableName) settings table's name property is not the expected value, but is '\(tableName.rawValue)'"])
        }

        var path: Path? = nil
        if let plPath = dict[PropertyListStrings.path.rawValue] {
            guard let pathStr = plPath.stringValue else {
                throw CapturedInfoDeserializationError.error(["path for build settings table '\(tableName.rawValue)' is not a string: \(try plPath.asJSONFragment().unsafeStringValue)"])
            }
            path = Path(pathStr)
        }

        // Deserialize the assignments table.
        guard let settingsDict = dict[PropertyListStrings.settings.rawValue]?.dictValue else {
            throw CapturedInfoDeserializationError.error(["\(expectedTableName) settings table is missing its settings dictionary: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        var settingsTable = [String: [CapturedBuildSettingAssignmentInfo]]()
        for (key, plAsgns) in settingsDict {
            guard let asgns = plAsgns.arrayValue else {
                throw CapturedInfoDeserializationError.error(["value for build setting '\(key)' in \(tableName.rawValue) settings table is not an array: \(try plAsgns.asJSONFragment().unsafeStringValue)"])
            }
            var settings = [CapturedBuildSettingAssignmentInfo]()
            for plAsgn in asgns {
                do {
                    let asgn = try CapturedBuildSettingAssignmentInfo.fromPropertyList(plAsgn, name: key)
                    settings.append(asgn)
                }
                catch let error as CapturedInfoDeserializationError {
                    throw error.appending("for build setting '\(key)'").appending("in \(tableName.rawValue) settings table")
                }
                catch {
                    throw CapturedInfoDeserializationError.error(["unable to decode assignment for build setting '\(key)' in \(tableName.rawValue) settings table: \(try plAsgn.asJSONFragment().unsafeStringValue)"])
                }
            }
            settingsTable[key] = settings
        }

        return Self.self(name: tableName, path: path, settings: settingsTable)
    }
}

/// The representation of a build setting assignment. This does not include the name of the setting.
public struct CapturedBuildSettingAssignmentInfo: PropertyListItemConvertible, CustomStringConvertible, Sendable {
    /// The name of this setting.
    public let name: String

    /// The conditions of this setting. Will often be empty.
    public let conditions: [CapturedBuildSettingConditionInfo]

    /// The value of the assignment.
    public let value: String

    public var description: String {
        return "\(name)" + conditions.map({ $0.description }).joined() + "=\(value)"
    }

    private enum PropertyListStrings: String {
        case conditions
        case value
    }

    public var propertyListItem: PropertyListItem {
        var dict = [String: PropertyListItem]()
        if !conditions.isEmpty {
            dict[PropertyListStrings.conditions.rawValue] = conditions.map({ $0.propertyListItem }).propertyListItem
        }
        dict[PropertyListStrings.value.rawValue] = value.propertyListItem
        return dict.propertyListItem
    }

    fileprivate static func fromPropertyList(_ plist: PropertyListItem, name: String) throws -> CapturedBuildSettingAssignmentInfo {
        guard case .plDict(let dict) = plist else {
            throw CapturedInfoDeserializationError.error(["build setting assignment is not a dictionary: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        var conditions = [CapturedBuildSettingConditionInfo]()
        if let conditionsEntry = dict[PropertyListStrings.conditions.rawValue] {
            guard let plConditions = conditionsEntry.arrayValue else {
                throw CapturedInfoDeserializationError.error(["build setting conditions entry for '\(PropertyListStrings.conditions.rawValue)' is not an array: \(try plist.asJSONFragment().unsafeStringValue)"])
            }
            for plCondition in plConditions {
                do {
                    let condition = try CapturedBuildSettingConditionInfo.fromPropertyList(plCondition)
                    conditions.append(condition)
                }
                catch let error as CapturedInfoDeserializationError {
                    throw error
                }
                catch {
                    throw CapturedInfoDeserializationError.error(["unable to decode condition '\(try plCondition.asJSONFragment().unsafeStringValue)' in build setting assignment: \(try plist.asJSONFragment().unsafeStringValue)"])
                }
            }
        }

        guard let value = dict[PropertyListStrings.value.rawValue]?.stringValue else {
            throw CapturedInfoDeserializationError.error(["build setting assignment does not have a valid '\(PropertyListStrings.value.rawValue)' entry: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        return Self.self(name: name, conditions: conditions, value: value)
    }
}

/// The representation of a build setting condition.
public struct CapturedBuildSettingConditionInfo: PropertyListItemConvertible, CustomStringConvertible, Sendable {
    /// The name of the condition.
    public let name: String

    /// The value of the condition.
    public let value: String

    public var description: String {
        return "[\(name)=\(value)]"
    }

    private enum PropertyListStrings: String {
        case name
        case value
    }

    public var propertyListItem: PropertyListItem {
        return .plDict([
            PropertyListStrings.name.rawValue: name.propertyListItem,
            PropertyListStrings.value.rawValue: value.propertyListItem
        ])
    }

    fileprivate static func fromPropertyList(_ plist: PropertyListItem) throws -> CapturedBuildSettingConditionInfo {
        guard case .plDict(let dict) = plist else {
            throw CapturedInfoDeserializationError.error(["build setting condition is not a dictionary: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        guard let name = dict[PropertyListStrings.name.rawValue]?.stringValue else {
            throw CapturedInfoDeserializationError.error(["build setting condition does not have a valid '\(PropertyListStrings.name.rawValue)' entry: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        guard let value = dict[PropertyListStrings.value.rawValue]?.stringValue else {
            throw CapturedInfoDeserializationError.error(["build setting condition does not have a valid '\(PropertyListStrings.value.rawValue)' entry: \(try plist.asJSONFragment().unsafeStringValue)"])
        }
        return Self.self(name: name, value: value)
    }
}

fileprivate extension MacroValueAssignmentTable {
    /// Create and return the captured form of an assignment table.
    var capturedRepresentation: [String: [CapturedBuildSettingAssignmentInfo]] {
        var assignments = [String: [CapturedBuildSettingAssignmentInfo]]()
        for (decl, val) in valueAssignments {
            let name = decl.name
            var asgn: MacroValueAssignment! = val
            // The assignments are ordered from highest-precedence to lowest.
            while asgn != nil {
                let conditions = asgn.conditions?.conditions.map {
                    CapturedBuildSettingConditionInfo(name: $0.parameter.name, value: $0.valuePattern)
                } ?? []
                let value = asgn.expression.stringRep
                let info = CapturedBuildSettingAssignmentInfo(name: name, conditions: conditions, value: value)
                assignments[name, default: [CapturedBuildSettingAssignmentInfo]()].append(info)

                asgn = asgn.next
            }
        }
        return assignments
    }
}
