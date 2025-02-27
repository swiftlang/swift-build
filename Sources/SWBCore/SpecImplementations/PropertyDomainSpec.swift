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
public import SWBMacro

// Build option types.
private protocol BuildOptionType: Sendable {
    /// The user-visible name of the type.
    var typeName: String { get }

    /// Whether the type is a list.
    var isListType: Bool { get }

    /// Whether the type supports declared values.
    var supportsValuesDefinitions: Bool { get }

    /// Declare a macro suitable for the given option type.
    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration
}
private final class BoolBuildOptionType : BuildOptionType {
    let typeName = "Boolean"
    let isListType = false
    let supportsValuesDefinitions = true

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareBooleanMacro(name)
    }
}
private final class CodeSignIdentityBuildOptionType : BuildOptionType {
    let typeName = "CodeSignIdentity"
    let isListType = false
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringMacro(name)
    }
}
private final class CodeSignStyleBuildOptionType : BuildOptionType {
    let typeName = "CodeSignStyle"
    let isListType = false
    let supportsValuesDefinitions = true

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringMacro(name)
    }
}
private final class CompilerVersionBuildOptionType : BuildOptionType {
    let typeName = "CompilerVersion"
    let isListType = false
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringMacro(name)
    }
}
private final class DevelopmentTeamBuildOptionType : BuildOptionType {
    let typeName = "DevelopmentTeam"
    let isListType = false
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringMacro(name)
    }
}
private final class EnumBuildOptionType : BuildOptionType {
    let typeName = "Enumeration"
    let isListType = false
    let supportsValuesDefinitions = true

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        switch name {
        case "ENABLE_USER_SELECTED_FILES",
            "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER",
            "ENABLE_FILE_ACCESS_PICTURE_FOLDER",
            "ENABLE_FILE_ACCESS_MUSIC_FOLDER",
            "ENABLE_FILE_ACCESS_MOVIES_FOLDER":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<FileAccessMode>
        case "INFOPLIST_KEY_LSApplicationCategoryType":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<ApplicationCategory>
        case "INFOPLIST_KEY_NSStickerSharingLevel":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<StickerSharingLevel>
        case "INFOPLIST_KEY_UIStatusBarStyle":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<StatusBarStyle>
        case "INFOPLIST_KEY_UIUserInterfaceStyle":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<UserInterfaceStyle>
        case "ENTITLEMENTS_DESTINATION":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<EntitlementsDestination>
        case "MERGED_BINARY_TYPE":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<MergedBinaryType>
        case "PACKAGE_RESOURCE_TARGET_KIND":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<PackageResourceTargetKind>
        case "VALIDATE_DEPENDENCIES",
            "VALIDATE_DEVELOPMENT_ASSET_PATHS":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<BooleanWarningLevel>
        case "STRIP_STYLE":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<StripStyle>
        case "SWIFT_LTO":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<LTOSetting>
        case "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<SwiftEnableExplicitModulesSetting>
        case "SWIFT_ENABLE_EXPLICIT_MODULES":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<SwiftEnableExplicitModulesSetting>
        case "LINKER_DRIVER":
            return try namespace.declareEnumMacro(name) as EnumMacroDeclaration<LinkerDriverChoice>
        default:
            return try namespace.declareStringMacro(name)
        }
    }
}
private final class StringBuildOptionType : BuildOptionType {
    let typeName = "String"
    let isListType = false
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringMacro(name)
    }
}
private final class StringListBuildOptionType : BuildOptionType {
    let typeName = "StringList"
    let isListType = true
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringListMacro(name)
    }
}
private final class OpenCLArchitecturesBuildOptionType : BuildOptionType {
    let typeName = "OpenCLArchitectures"
    let isListType = true
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringListMacro(name)
    }
}
private final class PathBuildOptionType : BuildOptionType {
    let typeName = "Path"
    let isListType = false
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declarePathMacro(name)
    }
}
private final class PathListBuildOptionType : BuildOptionType {
    let typeName = "PathList"
    let isListType = true
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declarePathListMacro(name)
    }
}
private final class ProvisioningProfileBuildOptionType : BuildOptionType {
    let typeName = "ProvisioningProfile"
    let isListType = false
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringMacro(name)
    }
}
private final class ProvisioningProfileSpecifierBuildOptionType : BuildOptionType {
    let typeName = "ProvisioningProfileSpecifier"
    let isListType = false
    let supportsValuesDefinitions = false

    func declareMacro(_ namespace: MacroNamespace, _ name: String) throws -> MacroDeclaration {
        return try namespace.declareStringMacro(name)
    }
}

private let boolBuildOptionBoolType = BoolBuildOptionType()
private let enumBuildOptionEnumType = EnumBuildOptionType()
private let pathBuildOptionType = PathBuildOptionType()
private let pathListBuildOptionType = PathListBuildOptionType()
private let stringBuildOptionType = StringBuildOptionType()
private let stringListBuildOptionType = StringListBuildOptionType()

// FIXME: Normalize the type spelling (<rdar://problem/22426239>).
private let buildOptionTypes: [String: any BuildOptionType] = [
    "bool": boolBuildOptionBoolType,
    "Bool": boolBuildOptionBoolType,
    "boolean": boolBuildOptionBoolType,
    "Boolean": boolBuildOptionBoolType,
    "CodeSignIdentity": CodeSignIdentityBuildOptionType(),
    "CodeSignStyle": CodeSignStyleBuildOptionType(),
    "CompilerVersion": CompilerVersionBuildOptionType(),
    "DevelopmentTeam": DevelopmentTeamBuildOptionType(),
    "enum": enumBuildOptionEnumType,
    "Enumeration": enumBuildOptionEnumType,
    "string": stringBuildOptionType,
    "String": stringBuildOptionType,
    "stringlist": stringListBuildOptionType,
    "StringList": stringListBuildOptionType,
    "OpenCLArchitectures": OpenCLArchitecturesBuildOptionType(),
    "path": pathBuildOptionType,
    "Path": pathBuildOptionType,
    "pathlist": pathListBuildOptionType,
    "PathList": pathListBuildOptionType,
    "ProvisioningProfile": ProvisioningProfileBuildOptionType(),
    "ProvisioningProfileSpecifier": ProvisioningProfileSpecifierBuildOptionType(),
]

/// Descriptor for a possible value for a build option.
//
// FIXME: This should possibly be private, and we really want the compiler to be able to optimize it as much as possible. However, we currently depend on it only being internal for our unit tests.
@_spi(Testing) public struct BuildOptionValue: Sendable {
    /// Type describing the possible ways a value can be expanded into command line arguments.
    ///
    /// For list types, this template defines what to do *for each* option in the list.
    @_spi(Testing) public enum CommandLineTemplateSpecifier: Sendable {
        /// Don’t add anything — this can be used to “block” default fallback templates.
        case empty

        /// Expand to the literal dynamic value, unmodified.
        case literal

        /// Expand into the given arguments, after macro expression evaluation (as appropriate for the macro type). The special macro '$(value)' can be used to refer to the dynamic value of the option.
        case args(MacroStringListExpression)

        /// Expand to the given flag.
        ///
        /// For the boolean type this expands to just the flag, for all other types it expands to the flag followed by the dynamic value.
        ///
        /// FIXME: The linker spec is the only one that currently uses a full macro expression here. We should consider moving it to the arg form, just to avoid the parsing overhead for all of the other options.
        case flag(MacroStringExpression)

        /// Expand to the given flag followed by the dynamic value.
        ///
        /// FIXME: The linker spec is the only one that currently uses a full macro expression here. We should consider moving it to the arg form, just to avoid the parsing overhead for all of the other options.
        case prefixFlag(MacroStringExpression)
    }

    /// The specifier for how this option should appear on the command line (if at all).
    @_spi(Testing) public let commandLineTemplate: CommandLineTemplateSpecifier?

    /// If present, an expression defining additional linker arguments to use when this value is active.
    @_spi(Testing) public let additionalLinkerArgs: MacroStringListExpression?

    fileprivate init(commandLineTemplate: CommandLineTemplateSpecifier?, additionalLinkerArgs: MacroStringListExpression? = nil) {
        self.commandLineTemplate = commandLineTemplate
        self.additionalLinkerArgs = additionalLinkerArgs
    }

    /// Return a copy of the value with a replacement template.
    fileprivate func with(commandLineTemplate: CommandLineTemplateSpecifier) -> BuildOptionValue {
        return BuildOptionValue(commandLineTemplate: commandLineTemplate, additionalLinkerArgs: additionalLinkerArgs)
    }

    /// Return a copy of the value with additional linker args.
    fileprivate func with(additionalLinkerArgs: MacroStringListExpression?) -> BuildOptionValue {
        return BuildOptionValue(commandLineTemplate: commandLineTemplate, additionalLinkerArgs: additionalLinkerArgs)
    }
}

/// Represents an individual option that is part of a property domain spec.
@_spi(Testing) public final class BuildOption: CustomStringConvertible, Sendable {
    /// Helper type for representing the type of command line argument specifier that was used for a build option.
    private enum CommandLineSpecifier {
    case arrayArgs(value: [String])
    case dictArgs(value: [String: PropertyListItem])
    case stringArgs(value: String)
    case flag(value: String)
    case prefixFlag(value: String)
    }

    /// The name (build setting) of the option.
    @_spi(Testing) public let name: String

    /// The localized descriptive name for the option.
    @_spi(Testing) public let localizedName: String

    /// The localized description for the option, if present.
    @_spi(Testing) public let localizedDescription: String?

    /// The localized name of the category in which the build setting is grouped, if present.
    ///
    /// This is only concretely used by the UI, but is also a proxy for whether the setting is expected to be included in `getBuildSettingsDescriptionDump()` for documentation purposes.
    @_spi(Testing) public let localizedCategoryName: String?

    /// The type of the option.
    private let type: any BuildOptionType

    /// The macro declaration used for this option.
    @_spi(Testing) public let macro: MacroDeclaration

    /// The name of the option this one should appear after, for impacting the command line and UI order.
    let appearsAfter: String?

    /// The parsed default value for this option, if present. The type of this expression will agree with \see type.isListType.
    @_spi(Testing) public let defaultValue: MacroExpression?

    /// The value descriptor to use for empty values (the empty string, or the empty list, depending on the type).
    @_spi(Testing) public let emptyValueDefn: BuildOptionValue?

    /// The value descriptor to use for "other" values which do not have a specific definition.
    @_spi(Testing) public let otherValueDefn: BuildOptionValue?

    /// The condition expression which must be satisfied in order for the option to contribute arguments to a command line.
    let condition: MacroConditionExpression?

    /// The list of architectures this option is valid for.  If missing, it is assumed valid for all architectures.
    let architectures: Set<String>?

    /// The list of file type identifiers this option is valid for. If missing, it is assumed valid for all types.
    let fileTypeIdentifiers: [String]?

    /// Whether to expand recursive search paths in the value.
    ///
    /// This is almost exclusively used as a mechanism for Ld and friends to handle recursive library/framework search paths. This could probably be extract out of the generic property handling code.
    let flattenRecursiveSearchPathsInValue: Bool

    /// The map of possible values to value definitions which specify how the value should be handled.
    ///
    /// This is only valid for string-based types.
    @_spi(Testing) public let valueDefns: [String: BuildOptionValue]?

    /// The name of the environment variable use to set the value of this option in the environment.
    let environmentVariableNameOpt: MacroStringExpression?

    /// The version ranges for which command-line options can be generated for this build option.
    let supportedVersionRangesOpt: [VersionRange]?

    let dependencyFormat: DependencyDataFormat?

    /// The feature flags that must be enabled for command-line options to be generated.
    let featureFlags: [String]?

    /// Additional input dependencies to consider when this build option is active.
    let inputInclusions: [MacroStringExpression]?

    /// Additional output dependencies to consider when this build option is active.
    let outputDependencies: [MacroStringExpression]?

    /// Helper function for extract an individual value definition from a dictionary.
    private static func parseBuildOptionValue(_ parser: SpecParser, _ name: String, _ type: any BuildOptionType, _ data: [String: PropertyListItem]) -> (String, BuildOptionValue)? {
        func getValueName() -> String {
            if case .plString(let value)? = data["Value"] {
                return value
            }
            return "<UNKNOWN>"
        }
        func error(_ message: String) {
            parser.error("\(message) for value '\(getValueName())' in option '\(name)'")
        }

        var valueNameOpt: String? = nil
        var commandLineTemplateOpt: BuildOptionValue.CommandLineTemplateSpecifier? = nil
        var commandLineKey: String? = nil
        for (key,valueData) in data {
            switch key {
            case "Value":
                guard case .plString(let value) = valueData else {
                    error("invalid build option value key '\(key)'")
                    continue
                }
                valueNameOpt = value

            case "CommandLine", "CommandLineArgs", "CommandLineFlag":
                // Validate another 'CommandLine...' key form hasn't been used.
                guard commandLineKey == nil else {
                    error("invalid build option value key '\(key)', cannot combine with '\(commandLineKey!)'")
                    continue
                }

                // Create the appropriate specifier.
                //
                // NOTE: The handling of these forms is subtly different from the handing inside the main BuildOption parsing. We should reconcile the two so that they are consistent. Tracked by <rdar://problem/22456852>.
                switch key {
                case "CommandLine":
                    guard case .plString(let value) = valueData else {
                        error("expected string value for build option value key '\(key)'")
                        continue
                    }
                    let expr = parser.delegate.internalMacroNamespace.parseStringList(value) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error on '\(key)' for value '\(getValueName())' in option '\(name)'")
                    }
                    commandLineTemplateOpt = .args(expr)

                case "CommandLineArgs":
                    guard case .plArray(let values) = valueData else {
                        error("expected array value for build option value key '\(key)'")
                        continue
                    }
                    // Each item should be a string.
                    let strings = values.compactMap { data -> String? in
                        guard case .plString(let value) = data else {
                            error("expected string in 'CommandLineArgs'")
                            return nil
                        }
                        return value
                    }
                    let expr = parser.delegate.internalMacroNamespace.parseStringList(strings) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error on '\(key)' for value '\(getValueName())' in option '\(name)'")
                    }
                    commandLineTemplateOpt = .args(expr)

                default:
                    assert(key == "CommandLineFlag")
                    guard case .plString(let value) = valueData else {
                        error("expected string value for build option value key '\(key)'")
                        continue
                    }
                    if value.isEmpty {
                        // Empty command line flags add no arguments.
                        //
                        // FIXME: This is inconsistent with empty 'CommandLineFlag' arguments at the top-level, but depended on by the linker spec. Resolve.
                        commandLineTemplateOpt = .empty
                    } else {
                        let expr = parser.delegate.internalMacroNamespace.parseString(value) { diag in
                            parser.handleMacroDiagnostic(diag, "macro parsing error on '\(key)' for value '\(getValueName())' in option '\(name)'")
                        }
                        commandLineTemplateOpt = .flag(expr)
                    }
                }

                // Remember what key form was used, for diagnostics.
                commandLineKey = key

            case "DisplayName":
                // Not used, currently.
                continue

            case "Outputs":
                // FIXME: We don't support the 'Outputs' key.
                continue

            default:
                error("unknown build option value key '\(key)'")
            }
        }

        guard let valueName = valueNameOpt else {
            parser.error("missing build option value key 'Value' in option '\(name)'")
            return nil
        }

        return (valueName, BuildOptionValue(commandLineTemplate: commandLineTemplateOpt))
    }

    /// Helper function for extract the value definition objects.
    ///
    /// - returns: A tuple of the (empty-value-defn, other-value-dfn, value-defns) items.
    private static func parseValueDefinitions(_ parser: SpecParser, _ name: String, _ type: any BuildOptionType, _ commandLineSpecifierOpt: CommandLineSpecifier?, _ commandLineKey: String?, _ valuesOpt: [PropertyListItem]?, _ additionalLinkerArgs: [String: PropertyListItem]?) -> (BuildOptionValue?, BuildOptionValue?, [String: BuildOptionValue]?) {
        var valuesOpt = valuesOpt

        func error(_ message: String) {
            parser.error("\(message) for option '\(name)'")
        }

        // Check if the types support the 'Values' key, although we should consider relaxing this restriction <rdar://problem/22444795>.
        //
        // FIXME: Note that the code below is already prepared to handle this for scalar types, we just don't enable it because we don't want to diverge from Xcode 7 yet.
        if !type.supportsValuesDefinitions {
            if valuesOpt != nil {
                error("invalid build option key 'Values' used with type '\(type.typeName)'")
                valuesOpt = nil
            }
        }

        // The 'Values' key is required for enum types.
        if type is EnumBuildOptionType {
            if valuesOpt == nil {
                // FIXME: Make this an error once <rdar://problem/22422978> is fully landed.
                parser.warning("missing required build option key 'Values' used with type '\(type.typeName)' for option '\(name)'")
            }
        }

        // Parse the values key.
        //
        // Historically, Xcode only supported this for Boolean and Enumeration types, but we support it for all scalar types for consistency.
        var valueDefnsOpt: [String: BuildOptionValue]? = nil
        if let valuesData = valuesOpt {
            var valueDefns = Dictionary<String, BuildOptionValue>()
            for item in valuesData {
                switch item {
                case .plString(let valueName):
                    // Individual strings in the list just define the option, with no command line template.
                    if valueDefns[valueName] != nil {
                        error("duplicate value definition '\(valueName)'")
                        continue
                    }
                    valueDefns[valueName] = BuildOptionValue(commandLineTemplate: nil)
                case .plDict(let items):
                    // Parse the option from the definition dict.
                    guard let (valueName,option) = parseBuildOptionValue(parser, name, type, items) else { continue }
                    if valueDefns[valueName] != nil {
                        error("duplicate value definition '\(valueName)'")
                        continue
                    }
                    valueDefns[valueName] = option
                default:
                    error("invalid value definition data '\(item)'")
                }
            }

            valueDefnsOpt = valueDefns
        }

        // Parse and combine the command line args specifier.
        var emptyValueDefn: BuildOptionValue? = nil
        var otherValueDefn: BuildOptionValue? = nil
        if let commandLineSpecifier = commandLineSpecifierOpt {
            switch commandLineSpecifier {
            case .dictArgs(let items):
                func getTemplateForData(_ key: String, _ data: PropertyListItem) -> BuildOptionValue.CommandLineTemplateSpecifier? {
                    switch data {
                    case .plString(let value):
                        // Empty strings provide no arguments.
                        guard !value.isEmpty else { return .empty }

                        // Parse as a string list expression, even though this is a string.
                        let expr = parser.delegate.internalMacroNamespace.parseStringList(value) { diag in
                            parser.handleMacroDiagnostic(diag, "macro parsing error for '\(key)' in 'CommandLineArgs'")
                        }
                        return .args(expr)

                    case .plArray(let values):
                        // Empty arrays provide no arguments.
                        guard !values.isEmpty else { return .empty }

                        // Each item should be a string.
                        let strings = values.compactMap { data -> String? in
                            guard case .plString(let value) = data else {
                                error("expected string for '\(key)' in 'CommandLineArgs'")
                                return nil
                            }
                            return value
                        }
                        // Parse as a string list expression.
                        let expr = parser.delegate.internalMacroNamespace.parseStringList(strings) { diag in
                            parser.handleMacroDiagnostic(diag, "macro parsing error for '\(key)' in 'CommandLineArgs'")
                        }
                        return .args(expr)

                    default:
                        error("invalid build option value for '\(key)' in 'CommandLineArgs'")
                        return nil
                    }
                }
                for (key,valueData) in items.sorted(byKey: <) {
                    // Convert the valueData to the appropriate option.
                    guard let template = getTemplateForData(key, valueData) else { continue }

                    // Merge the option, based on the key.
                    switch key {
                    case "":
                        emptyValueDefn = BuildOptionValue(commandLineTemplate: template)

                    case "<<otherwise>>":
                        otherValueDefn = BuildOptionValue(commandLineTemplate: template)

                    default:
                        // If we have a command line template for a specific value, we have to merge it with any existing values.
                        if valueDefnsOpt == nil {
                            valueDefnsOpt = Dictionary<String, BuildOptionValue>()
                        }

                        // If the key was already defined in 'Values', merge the definition.
                        if let defn = valueDefnsOpt![key] {
                            guard defn.commandLineTemplate == nil else {
                                error("invalid key '\(key)' in 'CommandLineArgs', a command line template was already defined in 'Values'")
                                continue
                            }
                            valueDefnsOpt![key] = defn.with(commandLineTemplate: template)
                        } else {
                            // Add the value.
                            valueDefnsOpt![key] = BuildOptionValue(commandLineTemplate: template)
                        }
                    }
                }
                if let template = otherValueDefn?.commandLineTemplate {
                    for (value, defn) in valueDefnsOpt ?? [:] {
                        guard defn.commandLineTemplate == nil else { continue }
                        valueDefnsOpt?[value] = defn.with(commandLineTemplate: template)
                    }
                }

            case .arrayArgs(let values):
                if values.isEmpty {
                    // The string is expected to include a macro reference, if desired, so an empty string is empty.
                    otherValueDefn = BuildOptionValue(commandLineTemplate: .empty)
                } else {
                    // Parse as a string list expression.
                    let expr = parser.delegate.internalMacroNamespace.parseStringList(values) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error on 'CommandLineArgs'")
                    }
                    otherValueDefn = BuildOptionValue(commandLineTemplate: .args(expr))
                    // For the string value, the arguments are always added independent of the value of the parameter; the expectation is that the value goes into the arguments, via substitution.
                    emptyValueDefn = otherValueDefn
                    // Also propagate this command line template down to any of the values that doesn't already have a tmplate.
                    for (value, defn) in valueDefnsOpt ?? [:] {
                        guard defn.commandLineTemplate == nil else { continue }
                        valueDefnsOpt?[value] = defn.with(commandLineTemplate: .args(expr))
                    }
                }

            case .stringArgs(let value):
                if value.isEmpty {
                    // The string is expected to include a macro reference, if desired, so an empty string is empty.
                    otherValueDefn = BuildOptionValue(commandLineTemplate: .empty)
                } else {
                    // Parse as a string list expression, even though this is a string.
                    let expr = parser.delegate.internalMacroNamespace.parseStringList(value) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'CommandLineArgs'")
                    }
                    otherValueDefn = BuildOptionValue(commandLineTemplate: .args(expr))
                    // For the string value, the arguments are always added independent of the value of the parameter; the expectation is that the value goes into the arguments, via substitution.
                    emptyValueDefn = otherValueDefn
                    // Also propagate this command line template down to any of the values that doesn't already have a tmplate.
                    for (value, defn) in valueDefnsOpt ?? [:] {
                        guard defn.commandLineTemplate == nil else { continue }
                        valueDefnsOpt?[value] = defn.with(commandLineTemplate: .args(expr))
                    }
                }

            case .flag(let value):
                if value.isEmpty {
                    // For boolean options, no arguments are added.
                    if type is BoolBuildOptionType {
                        otherValueDefn = BuildOptionValue(commandLineTemplate: .empty)
                    } else {
                        otherValueDefn = BuildOptionValue(commandLineTemplate: .literal)
                    }
                } else {
                    let expr = parser.delegate.internalMacroNamespace.parseString(value) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'CommandLineArgs'")
                    }
                    otherValueDefn = BuildOptionValue(commandLineTemplate: .flag(expr))
                }

            case .prefixFlag(let value):
                if value.isEmpty {
                    otherValueDefn = BuildOptionValue(commandLineTemplate: .literal)
                } else {
                    let expr = parser.delegate.internalMacroNamespace.parseString(value) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'CommandLineArgs'")
                    }
                    otherValueDefn = BuildOptionValue(commandLineTemplate: .prefixFlag(expr))
                }
            }
        }

        // For boolean types, validate and normalize the keys.
        if type is BoolBuildOptionType {
            if let valueDefns = valueDefnsOpt {
                for (key,item) in valueDefns {
                    if key == "NO" {
                        emptyValueDefn = item
                    } else if key == "YES" {
                        otherValueDefn = item
                    } else {
                        error("unexpected '\(key)' value definition for boolean type (expected only 'YES' or 'NO')")
                    }
                }
            }
        }

        // If we have a definition for additional linker args, apply it.
        if let additionalLinkerArgs {
            let definedKeys = Set(additionalLinkerArgs.keys)
            for (key, valueData) in additionalLinkerArgs {
                // Parse the value.
                let expr: MacroStringListExpression
                switch valueData {
                case .plString(let value):
                    // Ignore empty values.
                    if value.isEmpty {
                        continue
                    }

                    expr = parser.delegate.internalMacroNamespace.parseStringList(value) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error for '\(key)' in 'CommandLineArgs'")
                    }

                case .plArray(let values):
                    // Ignore empty values.
                    if values.isEmpty {
                        continue
                    }

                    // Each item should be a string.
                    let strings = values.compactMap { data -> String? in
                        guard case .plString(let value) = data else {
                            error("expected string for '\(key)' in 'AdditionalLinkerArgs'")
                            return nil
                        }
                        return value
                    }

                    // Parse as a string list expression.
                    expr = parser.delegate.internalMacroNamespace.parseStringList(strings) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error for '\(key)' in 'CommandLineArgs'")
                    }

                default:
                    error("unexpected value for '\(key)' in 'AdditionalLinkerArgs'")
                    continue
                }

                // Apply the expression to the appropriate option.
                func addLinkerArgsExpr(_ option: BuildOptionValue?) -> BuildOptionValue {
                    if let option = option {
                        return option.with(additionalLinkerArgs: expr)
                    } else {
                        return BuildOptionValue(commandLineTemplate: nil, additionalLinkerArgs: expr)
                    }
                }
                if type is BoolBuildOptionType {
                    if key == "NO" {
                        emptyValueDefn = addLinkerArgsExpr(emptyValueDefn)
                    } else if key == "YES" {
                        otherValueDefn = addLinkerArgsExpr(otherValueDefn)
                    } else {
                        error("unexpected '\(key)' linker args definition for boolean type (expected only 'YES' or 'NO')")
                        continue
                    }
                } else {
                    if key.isEmpty {
                        emptyValueDefn = addLinkerArgsExpr(emptyValueDefn)
                    } else if key == "<<otherwise>>" {
                        // This code handles values for the option for which there are no specific linker args defined when the option does define an <<otherwise>> value for AdditionalLinkerArgs.
                        // For such values, we set the expr for <<otherwise>> as their linker args.  By skipping 'definedKeys' we let those values which have keys defined in AdditionalLinkerArgs get those args rather than the <<otherwise>> args.
                        // One case that this handles is where the explicit args for the value are empty - we want to preserve that emptiness rather than supplant it with the <<otherwise>> args.
                        if valueDefnsOpt != nil {
                            for defnKey in valueDefnsOpt!.keys {
                                guard !definedKeys.contains(defnKey) else { continue }
                                if valueDefnsOpt![defnKey]?.additionalLinkerArgs == nil {
                                    valueDefnsOpt![defnKey] = addLinkerArgsExpr(valueDefnsOpt![defnKey])
                                }
                            }
                        }
                        // Also set the expr in the otherValueDefn to catch cases where the value doesn't have any definition at all.
                        otherValueDefn = addLinkerArgsExpr(otherValueDefn)
                    } else {
                        if valueDefnsOpt == nil {
                            valueDefnsOpt = Dictionary<String, BuildOptionValue>()
                        }

                        valueDefnsOpt![key] = addLinkerArgsExpr(valueDefnsOpt![key])
                    }
                }
            }
        }

        return (emptyValueDefn, otherValueDefn, valueDefnsOpt)
    }

    /// Initialize a build option from the xcspec serialized definition.
    fileprivate init(_ parser: SpecParser, _ data: PropertyListItem) {
        // Get the items dictionary.
        let items = { () -> [String: PropertyListItem] in
            if case .plDict(let items) = data {
                return items
            }
            parser.error("expected build option definition dictionary instead of item: \(data)")
            return [:]
        }()

        func getName() -> String {
            if case .plString(let value)? = items["Name"] {
                return value
            }

            return "<UNKNOWN>"
        }
        func error(_ message: String) {
            parser.error("\(message) for option '\(getName())'")
        }
        func warning(_ message: String) {
            parser.warning("\(message) for option '\(getName())'")
        }

        var additionalLinkerArgs: [String: PropertyListItem]? = nil
        var appearsAfter: String? = nil
        var commandLineKey: String? = nil
        var commandLineSpecifierOpt: CommandLineSpecifier? = nil
        var condition: MacroConditionExpression? = nil
        var defaultValueItemOpt: PropertyListItem? = nil
        var description: String? = nil
        var displayName: String? = nil
        var categoryName: String? = nil
        var architectures: Set<String>? = nil
        var fileTypeIdentifiers: [String]? = nil
        var flattenRecursiveSearchPathsInValue = false
        var nameOpt: String? = nil
        var type: (any BuildOptionType)? = nil
        var valuesOpt: [PropertyListItem]? = nil
        var environmentVariableNameOpt: MacroStringExpression? = nil
        var supportedVersionRangesOpt: [VersionRange]? = nil
        var dependencyFormat: DependencyDataFormat? = nil
        var featureFlags: [String]? = nil
        var inputInclusions: [MacroStringExpression]? = nil
        var outputDependencies: [MacroStringExpression]? = nil
        for (key, valueData) in items {
            switch key {
            case "Name":
                guard case .plString(let value) = valueData else {
                    parser.error("expected string value for build option key '\(key)' in data: \(data)")
                    continue
                }
                guard !value.isEmpty && value == value.asLegalCIdentifier else {
                    parser.error("'\(value)' is not a valid build setting name")
                    continue
                }
                nameOpt = value

            case "Type":
                guard case .plString(let value) = valueData else {
                    error("invalid build option key '\(key)' value")
                    continue
                }
                guard let resolvedType = buildOptionTypes[value] else {
                    error("unknown build option type '\(value)'")
                    continue
                }
                type = resolvedType

            case "DefaultValue":
                defaultValueItemOpt = valueData
                continue

            // Extract 'Values' key for processing once all keys are scanned.
            //
            // FIXME: Deprecate AllowedValues once <rdar://problem/22425505> lands.
            case "AllowedValues", "Values":
                if valuesOpt != nil {
                    error("cannot specify both 'AllowedValues' and 'Values'")
                    continue
                }
                guard case .plArray(let valueItems) = valueData else {
                    error("invalid build option key '\(key)' value")
                    continue
                }
                valuesOpt = valueItems

            // Extract the various 'CommandLine...' keys for processing once all keys are scanned.
            case "CommandLineArgs", "CommandLineFlag", "CommandLinePrefixFlag":
                // Validate another 'CommandLine...' key form hasn't been used.
                guard commandLineSpecifierOpt == nil else {
                    error("invalid build option key '\(key)', cannot combine with '\(commandLineKey!)'")
                    continue
                }

                // Create the appropriate specifier.
                switch key {
                case "CommandLineArgs":
                    switch valueData {
                        // FIXME: The string form is very rarely used, although conceptually it makes sense. We should verify it is worth the complexity though.
                    case .plString(let value):
                        commandLineSpecifierOpt = .stringArgs(value: value)
                    case .plArray(let value):
                        // Each item should be a string.
                        let strings = value.compactMap { data -> String? in
                            guard case .plString(let value) = data else {
                                error("expected string in 'CommandLineArgs'")
                                return nil
                            }
                            return value
                        }
                        commandLineSpecifierOpt = .arrayArgs(value: strings)
                    case .plDict(let value):
                        commandLineSpecifierOpt = .dictArgs(value: value)
                    default:
                        error("expected string, array, or dict value for build option key '\(key)'")
                    }
                case "CommandLineFlag":
                    guard case .plString(let value) = valueData else {
                        error("expected string value for build option key '\(key)'")
                        continue
                    }
                    commandLineSpecifierOpt = .flag(value: value)
                default:
                    assert(key == "CommandLinePrefixFlag")
                    guard case .plString(let value) = valueData else {
                        error("expected string value for build option key '\(key)'")
                        continue
                    }
                    commandLineSpecifierOpt = .prefixFlag(value: value)
                }

                // Remember what key form was used, for diagnostics.
                commandLineKey = key

            // Extract the command-line 'Condition' key as a parsed MacroConditionExpression.
            case "Condition":
                guard case .plString(let value) = valueData else {
                    parser.error("expected string value for build option key '\(key)'")
                    continue
                }
                condition = MacroConditionExpression.fromString(value, macroNamespace: parser.delegate.internalMacroNamespace) {
                    (diagnostic: String) in parser.error("unable to parse value for build option key '\(key)': \(diagnostic)")
                }

            case "AdditionalLinkerArgs":
                guard case .plDict(let items) = valueData else {
                    error("expected dictionary value for build option key '\(key)'")
                    continue
                }
                additionalLinkerArgs = items

            case "Architectures":
                // Each item should be a string.
                guard case .plArray(let valueItems) = valueData else {
                    error("invalid build option key '\(key)' value")
                    continue
                }
                let values = valueItems.compactMap { data -> String? in
                    guard case .plString(let value) = data else {
                        error("expected string in '\(key)'")
                        return nil
                    }
                    return value
                }
                architectures = Set(values)
                continue

            case "FileTypes":
                // Each item should be a string.
                guard case .plArray(let valueItems) = valueData else {
                    error("invalid build option key '\(key)' value")
                    continue
                }
                fileTypeIdentifiers = valueItems.compactMap { data -> String? in
                    guard case .plString(let value) = data else {
                        error("expected string in '\(key)'")
                        return nil
                    }
                    return value
                }
                continue

            case "AppearsAfter":
                guard case .plString(let name) = valueData else {
                    error("expected string value for build option key '\(key)'")
                    continue
                }
                appearsAfter = name

            case "SetValueInEnvironmentVariable":
                guard case .plString(let name) = valueData else {
                    error("expected string value for build option key '\(key)'")
                    continue
                }
                // Rev-lock: rdar://85769354 (Remove DEPLOYMENT_TARGET_CLANG_* properties from SDK)
                // Note that this is likely wrong for Mac Catalyst, but retains existing behavior.
                if name == "$(DEPLOYMENT_TARGET_CLANG_ENV_NAME)" {
                    environmentVariableNameOpt = parser.delegate.internalMacroNamespace.parseString("$(DEPLOYMENT_TARGET_SETTING_NAME)")
                    continue
                }
                environmentVariableNameOpt = parser.delegate.internalMacroNamespace.parseString(name)

            // Ignore keys we have no use for yet.
            //
            // FIXME: Eliminate any of these fields which are unused.
            case "AvoidEmptyValue":
                continue
            case "AvoidMacroDefinition":
                continue
            case "Basic":
                continue
            case "Category":
                guard case .plString(let name) = valueData else {
                    error("expected string value for build option key '\(key)'")
                    continue
                }
                categoryName = name
            case "ConditionFlavors":
                continue
            case "Description":
                guard case .plString(let value) = valueData else {
                    error("expected string value for build option key '\(key)'")
                    continue
                }
                description = value

            case "DisplayName":
                guard case .plString(let value) = valueData else {
                    error("expected string value for build option key '\(key)'")
                    continue
                }
                displayName = value

            case "DisplayValues":
                // FIXME: This is only used in any spec by TARGETED_DEVICE_FAMILY, and I'm not sure from the UI if it is ever actually used anymore.
                continue

            case "FlattenRecursiveSearchPathsInValue":
                guard let value = valueData.looselyTypedBoolValue else {
                    error("expected bool value for build option key '\(key)'")
                    continue
                }
                flattenRecursiveSearchPathsInValue = value

            case "InputInclusions":
                switch valueData {
                case .plString(let value):
                    inputInclusions = [parser.delegate.internalMacroNamespace.parseString(value)]
                case .plArray(let values):
                    inputInclusions = values.compactMap({ data in
                        guard case .plString(let value) = data else {
                            error("expected all string values in array for '\(key)'")
                            return nil
                        }
                        return parser.delegate.internalMacroNamespace.parseString(value)
                    })
                default:
                    error("expected string or array value for build option key '\(key)'")
                }

            case "IsInputDependency":
                // Currently instances of IsInputDependency in spec files are being handled in code.  If we decide to support the IsInputDependency property here, then places where those are handled will either need to be removed or uniqued.
                continue
            case "IsOutputDependency":
                continue
            case "OutputsAreSourceFiles":
                continue
            case "OutputDependencies":
                switch valueData {
                case .plString(let value):
                    outputDependencies = [parser.delegate.internalMacroNamespace.parseString(value)]
                case .plArray(let values):
                    outputDependencies = values.compactMap({ data in
                        guard case .plString(let value) = data else {
                            error("expected all string values in array for '\(key)'")
                            return nil
                        }
                        return parser.delegate.internalMacroNamespace.parseString(value)
                    })
                default:
                    error("expected string or array value for build option key '\(key)'")
                }

            case "SupportedVersionRanges":
                guard case .plArray(let valueItems) = valueData else {
                    error("expected array value for build option key '\(key)'")
                    continue
                }
                // 'SupportedVersionRanges' is an array whose elements may be one of three types of values:
                //  - A string, which is a version indicating the earliest version for which this option was supported.
                //  - An array with a single element, which is a version indicating the earliest version for which this option was supported.
                //  - An array with two elements, which are versions indicating the earliest version for which this option was supported, and the latest version for which this was supported.
                // All versions are inclusive.  As currently implemented, all ranges must have a starting version.
                // The top-level array this describes one or more ranges of versions for which the option is supported.  If the version of the tool falls in *any* of these ranges, then the option is supported by that tool version.
                supportedVersionRangesOpt = valueItems.compactMap { data -> VersionRange? in
                    switch data {
                    case .plString(let value):
                        if let startVersion = try? Version(value) {
                            return VersionRange(start: startVersion)
                        }

                        // Clang and tapi have usually several branches for the different OS trains and Xcode trains. Currently we use 0 for macOS and Xcode. 2 is used for the embedded trains. This is not always the case and we have used several different branches/numbers to provide content to the various trains in the past. When it comes to version comparison we allow specs to define a minimum version where one or more components are "*", and these will be ignored for comparison purposes. For example, 1100.0.2.1 >= 1100.*.2.1 and 1100.2.2.1 >= 1100.*.2.1 are both true, but 1100.3 is less than 1100.*.2.1.
                        if let fuzzyVersion = try? FuzzyVersion(value) {
                            return VersionRange(start: fuzzyVersion)
                        }

                        error("could not parse value '\(value)' in array for '\(key)'")
                        return nil
                    case .plArray(let valueItems):
                        if valueItems.count == 1 {
                            guard case .plString(let value) = valueItems[0], let startVersion = try? Version(value) else {
                                error("could not parse value '\(valueItems)' in array for '\(key)'")
                                return nil
                            }
                            return VersionRange(start: startVersion)
                        }
                        else if valueItems.count == 2 {
                            guard case .plString(let startValue) = valueItems[0], let startVersion = try? Version(startValue) else {
                                error("could not parse first element of value '\(valueItems)' in array for '\(key)'")
                                return nil
                            }
                            guard case .plString(let endValue) = valueItems[1], let endVersion = try? Version(endValue) else {
                                error("could not parse second element of value '\(valueItems)' in array for '\(key)'")
                                return nil
                            }
                            do {
                                return try VersionRange(start: startVersion, end: endVersion)
                            } catch let e {
                                error("unexpected value '\(valueItems)' in array for '\(key)' - \(e)") // e == "version range start must be less than or equal to end, but \(start) greater than \(end)"
                                return nil
                            }
                        }
                        else {
                            error("unexpected value '\(valueItems)' in array for '\(key)' - array contains more than 2 elements")
                            return nil
                        }
                    default:
                        error("unexpected value '\(data)' in array for '\(key)'")
                        return nil
                    }
                }
            case "UIType":
                continue
            case "FeatureFlags":
                // An single string or array of strings representing the feature flags required to include this option
                switch valueData {
                case .plString(let value):
                    featureFlags = [value]
                case .plArray(let values):
                    featureFlags = values.compactMap({ data in
                        guard case .plString(let value) = data else {
                            error("expected all string values in array for '\(key)'")
                            return nil
                        }
                        return value
                    })
                default:
                    error("expected string or array value for build option key '\(key)'")
                }
            case "DependencyDataFormat":
                guard case .plString(let value) = valueData else {
                    error("expected string value for build option key '\(key)'")
                    continue
                }
                dependencyFormat = DependencyDataFormat(rawValue: value)
                if dependencyFormat == nil {
                    error("unrecognized value '\(value)' for build option key '\(key)'")
                    continue
                }

            default:
                error("unknown build option key '\(key)'")
            }
        }

        // If we have a name and no type was assigned, infer from the known macro type.
        if let name = nameOpt, type == nil  {
            if let macro = parser.delegate.internalMacroNamespace.lookupMacroDeclaration(name) {
                if macro is StringMacroDeclaration {
                    // This is the default, no warning about type incompatibility.
                    type = stringBuildOptionType
                } else {
                    // Otherwise, we should warn the user to improve the specs.
                    if macro is StringListMacroDeclaration {
                        type = stringListBuildOptionType
                    } else {
                        precondition(macro is BooleanMacroDeclaration)
                        type = boolBuildOptionBoolType
                    }
                    parser.warning("build option '\(name)' missing type declaration (as '\(type!.typeName)')")
                }
            }
        }

        // Initialize the name and type.
        if nameOpt == nil {
            parser.error("missing build option key 'Name' in data: \(data)")
        }
        let name = nameOpt ?? "<UNKNOWN>"
        self.name = name
        self.type = type ?? stringBuildOptionType

        // Lookup or create the macro associated with this option.
        do {
            self.macro = try self.type.declareMacro(parser.delegate.internalMacroNamespace, self.name)
        } catch let err {
            parser.error("unable to declare macro for option '\(name)': \(err)")

            // Create a stub macro.

            self.macro = MacroDeclaration(name: self.name)
        }

        // Parse the default value, if present.
        if let defaultValueItem = defaultValueItemOpt {
            // FIXME: We should support users supplying explicit lists here (for list typed options).
            if case .plString(let string) = defaultValueItem {
                // Parse the expression in a manner consistent with its type.
                if self.type.isListType {
                    self.defaultValue = parser.delegate.internalMacroNamespace.parseStringList(string) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'DefaultValue'")
                    }
                } else {
                    self.defaultValue = parser.delegate.internalMacroNamespace.parseString(string) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'DefaultValue'")
                    }
                }
            } else {
                error("expected string value for build option key 'DefaultValue'")
                self.defaultValue = nil
            }
        } else {
            self.defaultValue = nil
        }

        // Initialize the value definitions.
        (self.emptyValueDefn, self.otherValueDefn, self.valueDefns) = BuildOption.parseValueDefinitions(parser, name, self.type, commandLineSpecifierOpt, commandLineKey, valuesOpt, additionalLinkerArgs)

        // Initialize other member variables.
        self.appearsAfter = appearsAfter
        self.condition = condition
        self.architectures = architectures
        self.fileTypeIdentifiers = fileTypeIdentifiers
        self.flattenRecursiveSearchPathsInValue = flattenRecursiveSearchPathsInValue
        self.environmentVariableNameOpt = environmentVariableNameOpt
        self.supportedVersionRangesOpt = supportedVersionRangesOpt
        self.dependencyFormat = dependencyFormat
        self.featureFlags = featureFlags

        let localizedName = parser.proxy.lookupLocalizedString("[\(name)]-name")
        if let displayName {
            // Validate we don't have both a localized name and a display name.
            if localizedName != nil {
                // FIXME: Disabled pending: <rdar://problem/27069050> Eliminate duplicate plist keys and localized strings for build option display name and display description
                // warning("duplicate 'DisplayName' and localized name")
            }
            self.localizedName = displayName
        } else {
            self.localizedName = localizedName ?? name
        }

        let localizedDescription = parser.proxy.lookupLocalizedString("[\(name)]-description")
        if let description {
            // Validate we don't have both a localized name and a display name.
            if localizedDescription != nil {
                // FIXME: Disabled pending: <rdar://problem/27069050> Eliminate duplicate plist keys and localized strings for build option display name and display description
                // warning("duplicate 'Description' and localized description")
            }
            self.localizedDescription = description
        } else {
            self.localizedDescription = localizedDescription
        }

        let localizedCategoryName = parser.proxy.lookupLocalizedString("[\(name)]-category")
        if let categoryName {
            // Validate we don't have both a localized name and a display name.
            if localizedCategoryName != nil {
                // FIXME: Disabled pending: <rdar://problem/27069050> Eliminate duplicate plist keys and localized strings for build option display name and display description
                // warning("duplicate 'Category' and localized category")
            }
            self.localizedCategoryName = categoryName
        } else {
            self.localizedCategoryName = localizedCategoryName
        }

        self.inputInclusions = inputInclusions
        self.outputDependencies = outputDependencies
    }

    /// Add the option's default value to the given table, if necessary.
    func addDefaultIfNecessary(_ table: inout MacroValueAssignmentTable) {
        if let defaultValue = self.defaultValue {
            table.push(self.macro, defaultValue)
        }
    }

    private func supportsArchitecture(_ arch: String) -> Bool {
        // If we don't have any supported architectures, we support all architectures.
        guard let architectures else {
            return true
        }

        // Otherwise, see if we have a matching architecture.
        return architectures.contains(arch)
    }

    private func supportsFileType(_ producer: any CommandProducer, inputFileType: FileTypeSpec) -> Bool {
        // If we don't have any identifiers, we support all types.
        guard let identifiers = fileTypeIdentifiers else {
            return true
        }

        // Otherwise, see if we have a matching file type.
        for identifier in identifiers {
            if let type = producer.lookupFileType(identifier: identifier) {
                if inputFileType.conformsTo(type) {
                    return true
                }
            }
        }

        return false
    }

    /// Get the command line arguments to use for this option in the given context.
    func getArgumentsForCommand(_ producer: any CommandProducer, scope: MacroEvaluationScope, inputFileType: FileTypeSpec?, optionContext: (any BuildOptionGenerationContext)?, lookup: ((MacroDeclaration) -> MacroExpression?)?) -> [CommandLineArgument] {
        // Filter by supported architecture.
        guard supportsArchitecture(scope.evaluate(BuiltinMacros.CURRENT_ARCH)) else {
            return []
        }

        // Filter by supported file type.
        //
        // FIXME: We shouldn't need the producer here, all this should be bound at core load time.
        if let inputFileType {
            guard supportsFileType(producer, inputFileType: inputFileType) else {
                return []
            }
        }

        // Filter by the tool version the build option belongs to, if this option defines supported version ranges.
        // If no BuildOptionGenerationContext was passed in or if it doesn't contain a tool version, then no options will be filtered - if we have no way to get a tool's version, then we never restrict options.
        if let supportedVersionRanges = supportedVersionRangesOpt, let toolVersion = optionContext?.toolVersion {
            var versionIsSupported = false
            for range in supportedVersionRanges {
                if range.contains(toolVersion) {
                    versionIsSupported = true
                    break
                }
            }
            if !versionIsSupported {
                return []
            }
        }

        if let featureFlags, let optionContext {
            for flag in featureFlags {
                if !optionContext.hasFeature(flag) {
                    return []
                }
            }
        }

        // Filter by macro condition expression.  If we don't have one, or we do have one and it evaluates to true, then we can proceed with argument generation.
        guard condition == nil || condition!.evaluateAsBoolean(scope, lookup: lookup) else {
            return []
        }

        // Handle boolean options.
        guard !(type is BoolBuildOptionType) else {
            // FIXME: Find a way to get more type safety here. We should perhaps use subclasses of BuildOption to make the three major kinds (boolean, string, string list) more apparent.

            // For boolean options, we always map directly onto the "empty" or "other" definitions.
            let value = scope.evaluate(self.macro as! BooleanMacroDeclaration, lookup: lookup)
            guard let valueDefnOpt = value ? otherValueDefn : emptyValueDefn else {
                return []
            }

            // If we have no template, we are done.
            guard let template = valueDefnOpt.commandLineTemplate else {
                return []
            }

            // Add the arguments from the template.
            switch template {
            case .empty:
                return []

            case .args(let expr):
                return scope.evaluate(expr) { macro in
                    if macro === BuiltinMacros.value {
                        return scope.table.namespace.parseLiteralString(value ? "YES" : "NO")
                    }
                    return lookup?(macro)
                }.map { .literal(ByteString(encodingAsUTF8: $0)) }

            case .flag(let flag):
                return [.literal(ByteString(encodingAsUTF8: scope.evaluate(flag)))]

            default:
                fatalError("invalid template type for Bool option")
            }
        }

        let valuesArePaths = type is PathBuildOptionType || type is PathListBuildOptionType

        // Handle list typed options.
        guard !type.isListType else {
            var values = switch self.macro {
            case let macro as StringListMacroDeclaration:
                scope.evaluate(macro, lookup: lookup)
            case let macro as PathListMacroDeclaration:
                scope.evaluate(macro, lookup: lookup)
            default:
                fatalError("invalid macro type for List option")
            }

            // Get the value definition to use.
            let valueDefnOpt = values.isEmpty ? emptyValueDefn : otherValueDefn

            // If we have no template, we are done.
            guard let template = valueDefnOpt?.commandLineTemplate else {
                return []
            }

            if self.name == "TAPI_HEADER_SEARCH_PATHS" && (scope.evaluate(BuiltinMacros.TAPI_ENABLE_PROJECT_HEADERS) ||
                scope.evaluate(BuiltinMacros.TAPI_USE_SRCROOT)) {
                return values.map { valuesArePaths ? .path(Path($0)) : .literal(ByteString(encodingAsUTF8: $0)) }
            }

            // Perform recursive search path expansion, if requested.
            if flattenRecursiveSearchPathsInValue {
                values = producer.expandedSearchPaths(for: values, scope: scope)
            }

            // Add the arguments from the template.
            switch template {
            case .empty:
                return []

            case .literal:
                return values.map { valuesArePaths ? .path(Path($0)) : .literal(ByteString(encodingAsUTF8: $0)) }

            case .args(let expr):
                // The arguments are evaluated, once for each item.
                return values.flatMap { value in
                    return scope.evaluate(expr) { macro in
                        if macro === BuiltinMacros.value {
                            return scope.table.namespace.parseLiteralString(value)
                        }
                        return lookup?(macro)
                    }
                }.map { valuesArePaths ? .path(Path($0)) : .literal(ByteString(encodingAsUTF8: $0)) }

            case .flag(let flag):
                // The flag is added once per item.
                return values.flatMap { [.literal(ByteString(encodingAsUTF8: scope.evaluate(flag))), valuesArePaths ? .path(Path($0)) : .literal(ByteString(encodingAsUTF8: $0))] }

            case .prefixFlag(let flag):
                // The flag is added once per item.
                // TODO: Add a new CommandLineArgument case to represent joined arguments
                return values.map { .literal(ByteString(encodingAsUTF8: scope.evaluate(flag) + $0)) }
            }
        }

        // Otherwise, we have a scalar option.
        let value: String
        switch macro {
        case let macro as AnyEnumMacroDeclaration where type is EnumBuildOptionType:
            value = scope.evaluateAsString(macro, lookup: lookup)
        case let macro as StringMacroDeclaration:
            value = scope.evaluate(macro, lookup: lookup)
        case let macro as PathMacroDeclaration:
            value = scope.evaluate(macro, lookup: lookup).str
        default:
            preconditionFailure("Unexpected macro type: \(Swift.type(of: self.macro))")
        }

        // Get the value definition to use.
        let valueDefnOpt = valueDefns.flatMap { $0[value] } ?? (value.isEmpty ? emptyValueDefn : otherValueDefn)

        // If we have no template, we are done.
        guard let template = valueDefnOpt?.commandLineTemplate else {
            return []
        }

        // Add the arguments from the template.
        switch template {
        case .empty:
            return []

        case .literal:
            return valuesArePaths ? [.path(Path(value))] : [.literal(ByteString(encodingAsUTF8: value))]

        case .args(let expr):
            return scope.evaluate(expr) { macro in
                if macro === BuiltinMacros.value {
                    return scope.table.namespace.parseLiteralString(value)
                }
                return lookup?(macro)
            }.map { valuesArePaths ? .path(Path($0)) : .literal(ByteString(encodingAsUTF8: $0)) }

        case .flag(let flag):
            if type is EnumBuildOptionType {
                return [.literal(ByteString(encodingAsUTF8: scope.evaluate(flag)))]
            } else {
                return [.literal(ByteString(encodingAsUTF8: scope.evaluate(flag))), valuesArePaths ? .path(Path(value)) : .literal(ByteString(encodingAsUTF8: value))]
            }

        case .prefixFlag(let flag):
            // TODO: Add a new CommandLineArgument case to represent joined arguments
            return [.literal(ByteString(encodingAsUTF8: scope.evaluate(flag) + value))]
        }
    }

    // Get the environment assignment for this option in the given context.
    func getEnvironmentAssignmentForCommand(_ cbc: CommandBuildContext, lookup: @escaping (MacroDeclaration) -> MacroExpression?) -> (String, String)? {
        if let keyExpr = environmentVariableNameOpt {

            // FIXME: Filter by supported architecture.

            // Filter by supported file type.
            guard let primaryInputType = cbc.inputs.first?.fileType, supportsFileType(cbc.producer, inputFileType: primaryInputType) else {
                return nil
            }

            // Filter by macro condition expression.  If we don't have one, or we do have one and it evaluates to true, then we can proceed with argument generation.
            guard condition == nil || condition!.evaluateAsBoolean(cbc.scope, lookup: lookup) else {
                return nil
            }

            // Evaluate the key.
            let key = cbc.scope.evaluate(keyExpr)
            guard !key.isEmpty else { return nil }

            // Handle boolean options.
            guard !(type is BoolBuildOptionType) else {
                // FIXME: Find a way to get more type safety here. We should perhaps use subclasses of BuildOption to make the three major kinds (boolean, string, string list) more apparent.

                // For boolean options, we evaluate it to either "YES" or "NO".
                return (key, cbc.scope.evaluate(self.macro as! BooleanMacroDeclaration, lookup: lookup) ? "YES" : "NO")
            }
            // Handle list typed options.
            guard !type.isListType else {
                let values = switch self.macro {
                case let macro as StringListMacroDeclaration:
                    cbc.scope.evaluate(macro, lookup: lookup)
                case let macro as PathListMacroDeclaration:
                    cbc.scope.evaluate(macro, lookup: lookup)
                default:
                    fatalError("invalid macro type for List option")
                }
                // FIXME: This is probably not right - we likely need to quote or escape the values here.
                return values.isEmpty ? nil : (key, values.joined(separator: " "))
            }

            guard !(type is PathBuildOptionType) else {
                let value = cbc.scope.evaluate(self.macro as! PathMacroDeclaration, lookup: lookup).str
                return value.isEmpty ? nil : (key, value)
            }

            guard !(type is PathListBuildOptionType) else {
                let values = cbc.scope.evaluate(self.macro as! PathListMacroDeclaration, lookup: lookup)
                // FIXME: This is probably not right - we likely need to quote or escape the values here.
                return values.isEmpty ? nil : (key, values.joined(separator: " "))
            }

            // Otherwise, we have a scalar option.
            let value = cbc.scope.evaluate(self.macro as! StringMacroDeclaration, lookup: lookup)
            return value.isEmpty ? nil : (key, value)
        }
        return nil
    }

    /// Get the command line arguments to use for this option in the given scope.
    func getAdditionalLinkerArgs(_ producer: any CommandProducer, scope: MacroEvaluationScope, inputFileTypes: [FileTypeSpec]) -> [String] {
        // Filter by (any) supported file type.
        func supportsAnyFileType() -> Bool {
            for fileType in inputFileTypes {
                if supportsFileType(producer, inputFileType: fileType) {
                    return true
                }
            }
            return false
        }
        guard supportsAnyFileType() else {
            return []
        }

        // Filter by macro condition expression.  If we don't have one, or we do have one and it evaluates to true, then we can proceed with argument generation.
        guard condition == nil || condition!.evaluateAsBoolean(scope) else {
            return []
        }

        // Handle boolean options.
        guard !(type is BoolBuildOptionType) else {
            // FIXME: Find a way to get more type safety here. We should perhaps use subclasses of BuildOption to make the three major kinds (boolean, string, string list) more apparent.

            // For boolean options, we always map directly onto the "empty" or "other" definitions.
            guard let valueDefnOpt = scope.evaluate(self.macro as! BooleanMacroDeclaration) ? otherValueDefn : emptyValueDefn else { return [] }

            guard let expr = valueDefnOpt.additionalLinkerArgs else { return [] }
            return scope.evaluate(expr)
        }

        // Handle list typed options.
        guard !type.isListType else {
            let values = switch self.macro {
            case let macro as StringListMacroDeclaration:
                scope.evaluate(macro)
            case let macro as PathListMacroDeclaration:
                scope.evaluate(macro)
            default:
                fatalError("invalid macro type for List option")
            }

            // Get the value definition to use.
            let valueDefnOpt = values.isEmpty ? emptyValueDefn : otherValueDefn

            guard let expr = valueDefnOpt?.additionalLinkerArgs else { return [] }
            return scope.evaluate(expr)
        }

        // Otherwise, we have a scalar option.
        let value = scope.evaluateAsString(self.macro)

        // Get the value expression to use.
        let valueDefnOpt = valueDefns.flatMap { $0[value] } ?? (value.isEmpty ? emptyValueDefn : otherValueDefn)
        guard let expr = valueDefnOpt?.additionalLinkerArgs else { return [] }

        // Return the evaluated value expression.
        return scope.evaluate(expr) { macro in
            if macro === BuiltinMacros.value {
                return scope.table.namespace.parseLiteralString(value)
            }
            return nil
        }
    }

    public var description: String {
        return "<\(Swift.type(of: self)):\(self.name):\(self.type.typeName)>"
    }
}


/// A `BuildOptionGenerationContext` provides information that a `BuildOption` need to generate command-line options for a tool.
public protocol BuildOptionGenerationContext {
    /// The path to the tool in question.
    var toolPath: Path { get }
    /// The version of the tool.  If the tool has multiple versions, then this is the "primary" version, which is used for determining whether a build option is supported.  This will be nil if a version couldn't be determined.
    var toolVersion: Version? { get }

    /// Features that can be checked from `BuildOption` to decide whether to generate command-line options for a tool or not.
    func hasFeature(_ feature: String) -> Bool
}

extension BuildOptionGenerationContext {
    public func hasFeature(_ feature: String) -> Bool {
        return false
    }
}

/// This is a shared base class, but cannot itself be a declared spec type.
open class PropertyDomainSpec : Spec, @unchecked Sendable {
    /// The ordered list of build options associated with this spec, not including any buildOptions from its BasedOn spec (see `flattenedBuildOptions` and `flattenedOrderedBuildOptions` instead).
    @_spi(Testing) public let buildOptions: [BuildOption]

    /// The list of options from the super spec to ignore when building the flattened option list for this spec.
    let deletedOptionNames: [String]

    private static func parseBuildOptions(_ parser: SpecParser, _ key: String, _ data: PropertyListItem) -> [BuildOption] {
        guard case .plArray(let items) = data else {
            parser.error("expected build option array for '\(key)' key")
            return []
        }

        return items.map { BuildOption(parser, $0) }
    }

    /// The flattened list of build options for this spec, including ones inherited from the base spec.
    @_spi(Testing) public var flattenedBuildOptions: [String: BuildOption] {
        return flattenedBuildOptionsCache.getValue(self)
    }
    private var flattenedBuildOptionsCache = LazyCache { (spec: PropertyDomainSpec) -> [String: BuildOption] in
        var options: [String: BuildOption] = (spec.basedOnSpec != nil) ? (spec.basedOnSpec! as! PropertyDomainSpec).flattenedBuildOptions : [:]
        for option in spec.buildOptions {
            options[option.name] = option
        }
        return options
    }

    /// The flattened list of build options for this spec, including ones inherited from the base spec, preserving the setting order for command-line generation.
    @_spi(Testing) public var flattenedOrderedBuildOptions: [BuildOption] {
        return flattenedOrderedBuildOptionsCache.getValue(self)
    }
    private var flattenedOrderedBuildOptionsCache = LazyCache { (spec: PropertyDomainSpec) -> [BuildOption] in
    // We start with a list of ordered option names defined by our basedOnSpec.
        var orderedOptionNames = OrderedSet<String>((spec.basedOnSpec != nil) ? (spec.basedOnSpec! as! PropertyDomainSpec).flattenedOrderedBuildOptions.map({ $0.name }) : [])
        // Now we go through our own options, and decide where to add each one.  An invariant is that no option should appear in the list more than once.
        for option in spec.buildOptions {
            // If the option specifies the name of one to appear after, put it there.
            if let appearsAfter = option.appearsAfter {
                // If we can find the index of the option to appear after, then we add it after that and continue.
                if let index = orderedOptionNames.firstIndex(of: appearsAfter) {
                    orderedOptionNames.insert(option.name, at: index + 1)
                    continue
                }
            }
            // Otherwise, we add it to the list.  If it is already in the list then we add it in the same location (replacing the definition from an ancestor spec), otherwise we just append it.
            if let index = orderedOptionNames.firstIndex(of: option.name) {
                orderedOptionNames.remove(at: index)
                orderedOptionNames.insert(option.name, at: index)
            }
            else {
                orderedOptionNames.append(option.name)
            }
        }
        // Use the ordered list of option names to return the ordered list of options.
        return orderedOptionNames.elements.compactMap({ spec.flattenedBuildOptions[$0] })
    }

    override init(_ registry: SpecRegistry, _ proxy: SpecProxy) {
        self.buildOptions = []
        self.deletedOptionNames = []
        super.init(registry, proxy)
    }

    required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        // Parse the build options.
        //
        // FIXME: Rename 'Options' to 'Properties' in existing specs and eliminate support for the legacy name.
        if let properties = parser.parseObject("Properties", inherited: false) {
            if parser.parseObject("Options", inherited: false) != nil {
                parser.error("cannot define both 'Properties' and 'Options'")
            }
            buildOptions = PropertyDomainSpec.parseBuildOptions(parser, "Properties", properties)
        } else if let options = parser.parseObject("Options", inherited: false) {
            buildOptions = PropertyDomainSpec.parseBuildOptions(parser, "Options", options)
        } else {
            buildOptions = []
        }

        // Parse the list of deleted options.
        deletedOptionNames = parser.parseStringList("DeletedProperties") ?? []

        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        parser.parseBool("IsGlobalDomainInUI")
        parser.parseStringList("OptionConditionFlavors")

        // FIXME: Validate that specs never try and define "OutputPath" or "OutputFormat", both of which previously had reserved meanings (and were removed from unioned defaults).

        super.init(parser, basedOnSpec)
    }
}


/// Extensions to PropertyDomainSpec for performance testing.
public extension PropertyDomainSpec {

    /// Creates and returns a ``MacroValueAssignmentTable`` populated with the default values of the receiver's build options.
    /// The table's namespace is also returned so that the caller can add further settings to it if desired.
    func macroTableForBuildOptionDefaults(_ core: Core) -> (MacroValueAssignmentTable, MacroNamespace) {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        for option in self.flattenedOrderedBuildOptions {
            guard let value = option.defaultValue else { continue }
            table.push(option.macro, value)
        }
        return (table, table.namespace)
    }

}
