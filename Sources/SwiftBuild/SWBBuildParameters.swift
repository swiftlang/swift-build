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

/// Build parameters are a container for many of the customizable properties that can override a build or target behavior.
public struct SWBBuildParameters: Codable, Sendable {
    /// The action name.
    public var action: String? = nil

    /// The configuration name to build with.
    public var configurationName: String? = nil

    public var activeRunDestination: SWBRunDestinationInfo? = nil

    /// The active architecture name, if any.
    public var activeArchitecture: String? = nil

    /// The build arena.
    public var arenaInfo: SWBArenaInfo? = nil

    /// The overriding build settings.
    public var overrides = SWBSettingsOverrides()

    public init() {
        self.action = "build"
    }
}

/// Refer to `SWBProtocol.RunDestinationInfo`
public struct SWBRunDestinationInfo: Codable, Sendable {
    public var platform: String
    public var sdk: String
    public var sdkVariant: String?
    public var targetArchitecture: String
    public var supportedArchitectures: [String]
    public var disableOnlyActiveArch: Bool
    public var hostTargetedPlatform: String?

    public init(platform: String, sdk: String, sdkVariant: String?, targetArchitecture: String, supportedArchitectures: [String], disableOnlyActiveArch: Bool) {
        self.platform = platform
        self.sdk = sdk
        self.sdkVariant = sdkVariant
        self.targetArchitecture = targetArchitecture
        self.supportedArchitectures = supportedArchitectures
        self.disableOnlyActiveArch = disableOnlyActiveArch
    }

    public init(platform: String, sdk: String, sdkVariant: String?, targetArchitecture: String, supportedArchitectures: [String], disableOnlyActiveArch: Bool, hostTargetedPlatform: String?) {
        self.init(platform: platform, sdk: sdk, sdkVariant: sdkVariant, targetArchitecture: targetArchitecture, supportedArchitectures: supportedArchitectures, disableOnlyActiveArch: disableOnlyActiveArch)
        self.hostTargetedPlatform = hostTargetedPlatform
    }
}

/// Refer to `SWBProtocol.ArenaInfo`
public struct SWBArenaInfo: Codable, Sendable {
    public var derivedDataPath: String
    public var buildProductsPath: String
    public var buildIntermediatesPath: String
    public var pchPath: String

    public var indexRegularBuildProductsPath: String?
    public var indexRegularBuildIntermediatesPath: String?
    public var indexPCHPath: String
    public var indexDataStoreFolderPath: String?
    public var indexEnableDataStore: Bool

    public init(derivedDataPath: String, buildProductsPath: String, buildIntermediatesPath: String, pchPath: String, indexRegularBuildProductsPath: String?, indexRegularBuildIntermediatesPath: String?, indexPCHPath: String, indexDataStoreFolderPath: String?, indexEnableDataStore: Bool) {
        self.derivedDataPath = derivedDataPath
        self.buildProductsPath = buildProductsPath
        self.buildIntermediatesPath = buildIntermediatesPath
        self.pchPath = pchPath

        self.indexRegularBuildProductsPath = indexRegularBuildProductsPath
        self.indexRegularBuildIntermediatesPath = indexRegularBuildIntermediatesPath
        self.indexPCHPath = indexPCHPath
        self.indexDataStoreFolderPath = indexDataStoreFolderPath
        self.indexEnableDataStore = indexEnableDataStore
    }
}

/// A table of overriding build settings.
public struct SWBSettingsTable: Codable, Equatable, Sendable {
    internal private(set) var table: [String: String] = [:]

    public init() {}

    /// Set the macro expression string to use for the given macro.
    ///
    /// This definition will replace any other override in the table, there is currently no support for supplying multiple definition.
    ///
    /// \param name The name of the macro being defined.
    /// \param value The string form of the macro expression to use, which will be parsed as a macro expression.
    //
    // FIXME: We should have a set literal value form too.
    //
    // FIXME: We need support for setting conditions.
    public mutating func set(value: String, for macro: String) {
        table[macro] = value
    }
}

/// The set of settings overrides which can be applied to a build.
public struct SWBSettingsOverrides: Codable, Sendable {
    /// The set of command line overrides, if present.
    public var synthesized: SWBSettingsTable? = nil

    /// Client synthesized overrides which are applied at the highest level.
    public var commandLine: SWBSettingsTable? = nil

    /// The xcconfig overrides file from a command line option, if used.
    ///
    /// This is passed via the `-xcconfig` option in `xcodebuild`, falling back to the `OverridingXCConfigPath`
    /// user-default in the `com.apple.dt.Xcode` domain if the command line option is not present.
    public var commandLineConfigPath: String? = nil

    /// The xcconfig overrides file from an environment variable, if used.
    ///
    /// This is passed via the `XCODE_XCCONFIG_FILE` environment variable to `xcodebuild`.
    public var environmentConfigPath: String? = nil

    public var toolchainOverride: String? = nil

    public init() {}

    public var commandLineConfig: SWBSettingsTable? = nil
    public var environmentConfig: SWBSettingsTable? = nil
}
