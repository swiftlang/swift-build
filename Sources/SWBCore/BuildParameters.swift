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
public import SWBProtocol
public import SWBMacro

/// Container for all of the parameters which can impact how a build is done.
public struct BuildParameters: Hashable, SerializableCodable, Sendable {
    /// The action to perf.
    public let action: BuildAction

    /// The configuration to build with.
    public let configuration: String?

    /// An optional overriding configuration to build Swift packages with.
    public let packageConfigurationOverride: String?

    public let activeRunDestination: RunDestinationInfo?

    /// The active architecture to use, if defined.
    public let activeArchitecture: String?

    /// The configured build arena.
    public let arena: ArenaInfo?

    // FIXME: This needs to be a fancier type, it should be a table capable of the full complexity of macro setting definition (macro types, multiple definitions, and conditions).
    //
    /// The overriding build parameters.
    public let overrides: [String: String]

    // FIXME: This needs to be a fancier type, it should be a table capable of the full complexity of macro setting definition (macro types, multiple definitions, and conditions).
    //
    /// The command line overrides.
    public let commandLineOverrides: [String: String]

    /// The command line xcconfig overrides.
    public let commandLineConfigOverridesPath: Path?

    // FIXME: This should be just the path of the command line xcconfig, but Xcode has trouble giving us that currently.
    //
    /// The command line xcconfig overrides.
    public let commandLineConfigOverrides: [String: String]

    /// The environment xcconfig overrides.
    public let environmentConfigOverridesPath: Path?

    // FIXME: This should be just the path of the environment xcconfig, but Xcode has trouble giving us that currently.
    //
    /// The environment xcconfig overrides.
    public let environmentConfigOverrides: [String: String]

    public let toolchainOverride: String?

    private var precomputedHash: Int = 0

    /// The source of the individual overrides, mainly for reporting issues so users (or Swift Build developers!) can trace back to where a problematic override came from.
    ///
    /// - remark: This doesn't happen automatically, clients working with these overrides must opt in to using this enum.
    public enum OverrideLevel: CustomStringConvertible {
        case environmentConfigOverridesPath(path: Path, table: MacroValueAssignmentTable?)
        case commandLineConfigOverridesPath(path: Path, table: MacroValueAssignmentTable?)
        case environmentConfigOverrides(dict: [String: String])
        case commandLineConfigOverrides(dict: [String: String])
        case commandLineOverrides(dict: [String: String])
        case buildParametersOverrides(dict: [String: String])

        public var description: String {
            switch self {
            case .environmentConfigOverridesPath(path: let path, table: let table):
                return "environment xcconfig overrides at path '\(path.str)' \(stringForm(for: table))"
            case .commandLineConfigOverridesPath(path: let path, table: let table):
                return "command line xcconfig overrides at path '\(path.str)' \(stringForm(for: table))"
            case .environmentConfigOverrides(dict: let dict):
                return "environment xcconfig overrides \(dict)"
            case .commandLineConfigOverrides(dict: let dict):
                return "command line xcconfig overrides \(dict)"
            case .commandLineOverrides(dict: let dict):
                return "command line overrides \(dict)"
            case .buildParametersOverrides(dict: let dict):
                return "build parameters overrides \(dict)"
            }
        }

        /// Private method to convert a _flat_ `MacroValueAssignmentTable` to its string form for emitting in the `OverrideLevel`'s description.
        private func stringForm(for table: MacroValueAssignmentTable?) -> String {
            guard let table else {
                return "(nil)"
            }
            var result = ""
            for key in table.valueAssignments.keys.sorted(by: \.name) {
                // Since this is a flat table, we only have to care about the first value.  We do add any conditions, though.
                if let value = table.valueAssignments[key] {
                    if !result.isEmpty {
                        result += ", "
                    }
                    result += "\"\(key.name)\(value.conditions?.description ?? "")\" = \"\(value.expression.stringRep)\""
                }
            }
            return "[\(result)]"
        }
    }

    public init(action: BuildAction = .build, configuration: String?, activeRunDestination: RunDestinationInfo? = nil, activeArchitecture: String? = nil, overrides: [String: String] = [:], commandLineOverrides: [String: String] = [:], commandLineConfigOverridesPath: Path? = nil, commandLineConfigOverrides: [String: String] = [:], environmentConfigOverridesPath: Path? = nil, environmentConfigOverrides: [String: String] = [:], toolchainOverride: String? = nil, arena: ArenaInfo? = nil) {
        self.action = action
        self.configuration = configuration
        self.activeRunDestination = activeRunDestination
        self.activeArchitecture = activeArchitecture
        self.arena = arena
        self.overrides = overrides
        self.commandLineOverrides = commandLineOverrides
        self.commandLineConfigOverridesPath = commandLineConfigOverridesPath
        self.commandLineConfigOverrides = commandLineConfigOverrides
        self.environmentConfigOverridesPath = environmentConfigOverridesPath
        self.environmentConfigOverrides = environmentConfigOverrides
        self.toolchainOverride = toolchainOverride

        if let configuration = configuration?.lowercased() {
            let isDebug = configuration.contains("debug") || configuration.contains("development")
            self.packageConfigurationOverride = isDebug ? "Debug" : "Release"
        } else {
            self.packageConfigurationOverride = nil
        }

        self.precomputedHash = computedHashValue()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(precomputedHash)
    }

    public static func ==(lhs: BuildParameters, rhs: BuildParameters) -> Bool {
        // Compare all properties except the signature which isn't stable.
        if lhs.action != rhs.action { return false }
        if lhs.configuration != rhs.configuration { return false }
        if lhs.packageConfigurationOverride != rhs.packageConfigurationOverride { return false }
        if lhs.activeRunDestination != rhs.activeRunDestination { return false }
        if lhs.activeArchitecture != rhs.activeArchitecture { return false }
        if lhs.arena != rhs.arena { return false }
        if lhs.overrides != rhs.overrides { return false }
        if lhs.commandLineOverrides != rhs.commandLineOverrides { return false }
        if lhs.commandLineConfigOverridesPath != rhs.commandLineConfigOverridesPath { return false }
        if lhs.commandLineConfigOverrides != rhs.commandLineConfigOverrides { return false }
        if lhs.environmentConfigOverridesPath != rhs.environmentConfigOverridesPath { return false }
        if lhs.environmentConfigOverrides != rhs.environmentConfigOverrides { return false }
        if lhs.toolchainOverride != rhs.toolchainOverride { return false }
        return true
    }

    // Serialization

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(11)
        let actionName: String = try deserializer.deserialize()
        guard let action = BuildAction(actionName: actionName) else { throw DeserializerError.deserializationFailed("BuildAction value '\(actionName)' not defined.") }
        self.action = action
        self.configuration = try deserializer.deserialize()
        self.packageConfigurationOverride = try deserializer.deserialize()
        self.activeRunDestination = try deserializer.deserialize()
        self.activeArchitecture = try deserializer.deserialize()
        self.arena = try deserializer.deserialize()
        self.overrides = try deserializer.deserialize()
        self.commandLineOverrides = try deserializer.deserialize()
        self.commandLineConfigOverridesPath = nil
        self.commandLineConfigOverrides = try deserializer.deserialize()
        self.environmentConfigOverridesPath = nil
        self.environmentConfigOverrides = try deserializer.deserialize()
        self.toolchainOverride = try deserializer.deserialize()

        // The hash is not guaranteed to be stable. Instead recompute it when deserializing.
        self.precomputedHash = computedHashValue()
    }

    enum CodingKeys: String, CodingKey {
        case action, configuration, packageConfigurationOverride, activeRunDestination, activeArchitecture, arena,  overrides, commandLineOverrides, commandLineConfigOverridesPath, commandLineConfigOverrides,  environmentConfigOverridesPath, environmentConfigOverrides, toolchainOverride
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encodeIfPresent(packageConfigurationOverride, forKey: .packageConfigurationOverride)
        try container.encodeIfPresent(activeRunDestination, forKey: .activeRunDestination)
        try container.encodeIfPresent(activeArchitecture, forKey: .activeArchitecture)
        try container.encodeIfPresent(arena, forKey: .arena)
        try container.encode(overrides, forKey: .overrides)
        try container.encode(commandLineOverrides, forKey: .commandLineOverrides)
        try container.encodeIfPresent(commandLineConfigOverridesPath, forKey: .commandLineConfigOverridesPath)
        try container.encode(commandLineConfigOverrides, forKey: .commandLineConfigOverrides)
        try container.encodeIfPresent(environmentConfigOverridesPath, forKey: .environmentConfigOverridesPath)
        try container.encode(environmentConfigOverrides, forKey: .environmentConfigOverrides)
        try container.encodeIfPresent(toolchainOverride, forKey: .toolchainOverride)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(BuildAction.self, forKey: .action)
        self.configuration = try container.decodeIfPresent(String.self, forKey: .configuration)
        self.packageConfigurationOverride = try container.decodeIfPresent(String.self, forKey: .packageConfigurationOverride)
        self.activeRunDestination = try container.decodeIfPresent(RunDestinationInfo.self, forKey: .activeRunDestination)
        self.activeArchitecture = try container.decodeIfPresent(String.self, forKey: .activeArchitecture)
        self.arena = try container.decodeIfPresent(ArenaInfo.self, forKey: .arena)
        self.overrides = try container.decode([String: String].self, forKey: .overrides)
        self.commandLineOverrides = try container.decode([String: String].self, forKey: .commandLineOverrides)
        self.commandLineConfigOverridesPath = try container.decodeIfPresent(Path.self, forKey: .commandLineConfigOverridesPath)
        self.commandLineConfigOverrides = try container.decode([String: String].self, forKey: .commandLineConfigOverrides)
        self.environmentConfigOverridesPath = try container.decodeIfPresent(Path.self, forKey: .environmentConfigOverridesPath)
        self.environmentConfigOverrides = try container.decode([String: String].self, forKey: .environmentConfigOverrides)
        self.toolchainOverride = try container.decodeIfPresent(String.self, forKey: .toolchainOverride)

        self.precomputedHash = computedHashValue()
    }

    private func computedHashValue() -> Int {
        // Compute the signature.
        var hasher = Hasher()
        hasher.combine(action)
        hasher.combine(configuration)
        hasher.combine(self.packageConfigurationOverride)
        hasher.combine(activeRunDestination)
        hasher.combine(activeArchitecture)
        hasher.combine(arena)
        hasher.combine(overrides)
        hasher.combine(commandLineOverrides)
        hasher.combine(commandLineConfigOverridesPath)
        hasher.combine(commandLineConfigOverrides)
        hasher.combine(environmentConfigOverridesPath)
        hasher.combine(environmentConfigOverrides)
        hasher.combine(toolchainOverride)
        return hasher.finalize()
    }
}

extension BuildParameters {
    public func mergingOverrides(_ overrides: [String: String]) -> BuildParameters {
        return BuildParameters(
            action: action,
            configuration: configuration,
            activeRunDestination: activeRunDestination,
            activeArchitecture: activeArchitecture,
            overrides: self.overrides.merging(overrides, uniquingKeysWith: { _, new in new }),
            commandLineOverrides: commandLineOverrides,
            commandLineConfigOverridesPath: commandLineConfigOverridesPath,
            commandLineConfigOverrides: commandLineConfigOverrides,
            environmentConfigOverridesPath: environmentConfigOverridesPath,
            environmentConfigOverrides: environmentConfigOverrides,
            toolchainOverride: toolchainOverride,
            arena: arena)
    }

    // Returns these `BuildParameters` after filtering out any overrides.
    public var withoutOverrides: BuildParameters {
        return BuildParameters(
            action: action,
            configuration: configuration,
            activeRunDestination: activeRunDestination,
            activeArchitecture: activeArchitecture,
            overrides: [:],
            commandLineOverrides: [:],
            commandLineConfigOverridesPath: nil,
            commandLineConfigOverrides: [:],
            environmentConfigOverridesPath: nil,
            environmentConfigOverrides: [:],
            toolchainOverride: toolchainOverride,
            arena: arena)
    }

    // Returns these `BuildParameters` after modifying `activeRunDestination` and `activeArchitecture`.
    public func replacing(activeRunDestination: RunDestinationInfo?, activeArchitecture: String?) -> BuildParameters {
        return BuildParameters(
            action: action,
            configuration: configuration,
            activeRunDestination: activeRunDestination,
            activeArchitecture: activeArchitecture,
            overrides: overrides,
            commandLineOverrides: commandLineOverrides,
            commandLineConfigOverridesPath: commandLineConfigOverridesPath,
            commandLineConfigOverrides: commandLineConfigOverrides,
            environmentConfigOverridesPath: environmentConfigOverridesPath,
            environmentConfigOverrides: environmentConfigOverrides,
            toolchainOverride: toolchainOverride,
            arena: arena)
    }

    /// Removes any of the potentially imposed settings **unless** those have been specified via explicit overrides which have come in via the initial build request.
    public func withoutImposedOverrides(_ buildRequest: BuildRequest, core: Core) -> BuildParameters {
        let settingsToRemove = SpecializationParameters.potentialImposedSettingNames(core: core).filter { setting in
            // FIXME: command line and environment overrides are not currently handled here. If/when we address rdar://80907686, this codepath should no longer be needed though.
            if buildRequest.parameters.overrides.contains(setting) { return false }
            return true
        }

        var prunedOverrides = overrides
        for setting in settingsToRemove {
            prunedOverrides.removeValue(forKey: setting)
        }

        return BuildParameters(
            action: action,
            configuration: configuration,
            activeRunDestination: activeRunDestination,
            activeArchitecture: activeArchitecture,
            overrides: prunedOverrides,
            commandLineOverrides: commandLineOverrides,
            commandLineConfigOverridesPath: commandLineConfigOverridesPath,
            commandLineConfigOverrides: commandLineConfigOverrides,
            environmentConfigOverridesPath: environmentConfigOverridesPath,
            environmentConfigOverrides: environmentConfigOverrides,
            toolchainOverride: toolchainOverride,
            arena: arena)
    }
}

extension BuildParameters {
    public init(from payload: BuildParametersMessagePayload) throws {
        guard let action = BuildAction(actionName: payload.action) else {
            throw MsgParserError.invalidBuildAction(name: payload.action)
        }

        self.init(action: action, configuration: payload.configuration, activeRunDestination: payload.activeRunDestination, activeArchitecture: payload.activeArchitecture, overrides: payload.overrides.synthesized, commandLineOverrides: payload.overrides.commandLine, commandLineConfigOverridesPath: payload.overrides.commandLineConfigPath, commandLineConfigOverrides: payload.overrides.commandLineConfig, environmentConfigOverridesPath: payload.overrides.environmentConfigPath, environmentConfigOverrides: payload.overrides.environmentConfig, toolchainOverride: payload.overrides.toolchainOverride, arena: payload.arenaInfo)
    }
}
