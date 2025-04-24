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

import struct Foundation.CharacterSet
import Foundation
import SWBMacro

/// Delegate protocol used to report diagnostics.
@_spi(Testing) public protocol ToolchainRegistryDelegate: DiagnosticProducingDelegate {
    var pluginManager: PluginManager { get }
    var platformRegistry: PlatformRegistry? { get }
}

/// Some problems are reported as either errors or warnings depending on if we're loading a built-in toolchain or an external toolchain
private extension ToolchainRegistryDelegate {
    func issue(strict: Bool, _ path: Path, _ message: String) {
        if strict {
            error(path, message)
        }
        else {
            warning(path, message)
        }
    }
}

public final class Toolchain: Hashable, Sendable {
    /// The identifier of the toolchain.
    public let identifier: String

    public let version: Version

    /// Always lower-cased
    public let aliases: Set<String>

    /// The path of the toolchain.
    public let path: Path

    /// The display name of the toolchain.
    public let displayName: String

    /// The default build settings.
    @_spi(Testing) public let defaultSettings: [String: PropertyListItem]

    /// The override build settings that should be in effect whenever the toolchain is used.
    @_spi(Testing) public let overrideSettings: [String: PropertyListItem]

    /// The default build settings, if the primary toolchain.
    ///
    /// Note that this dictionary contains unbound and unparsed settings; binding & parsing will occur when constructing a `Settings` object using this toolchain in `SettingsBuilder.addToolchainSettings()`.
    let defaultSettingsWhenPrimary: [String: PropertyListItem]

    /// The search paths for libraries.
    public let librarySearchPaths: StackedSearchPath

    /// The search paths for executables.
    public let executableSearchPaths: StackedSearchPath

    /// The fallback search paths for frameworks.
    public let fallbackFrameworkSearchPaths: StackedSearchPath

    /// The fallback search paths for libraries.
    public let fallbackLibrarySearchPaths: StackedSearchPath

    /// The names of the platforms for which this toolchain contains testing libraries.
    public let testingLibraryPlatformNames: Set<String>

    package init(identifier: String, displayName: String, version: Version, aliases: Set<String>, path: Path, frameworkPaths: [String], libraryPaths: [String], defaultSettings: [String: PropertyListItem], overrideSettings: [String: PropertyListItem], defaultSettingsWhenPrimary: [String: PropertyListItem], executableSearchPaths: [Path], testingLibraryPlatformNames: Set<String>, fs: any FSProxy) {
        self.identifier = identifier
        self.version = version

        assert(!aliases.contains{ $0.lowercased() != $0 })
        self.aliases = aliases

        self.path = path
        self.displayName = displayName
        self.defaultSettings = defaultSettings
        self.overrideSettings = overrideSettings
        self.defaultSettingsWhenPrimary = defaultSettingsWhenPrimary
        self.executableSearchPaths = StackedSearchPath(paths: executableSearchPaths, fs: fs)
        self.librarySearchPaths = StackedSearchPath(
            paths: [path.join("usr/lib"), path.join("usr/local/lib")],
            fs: fs
        )
        let frameworkSearchPaths = frameworkPaths.map { path.join($0) }
        self.fallbackFrameworkSearchPaths = StackedSearchPath(
            paths: frameworkSearchPaths,
            fs: fs
        )
        let librarySearchPaths = libraryPaths.map { path.join($0) }
        self.fallbackLibrarySearchPaths = StackedSearchPath(
            paths: librarySearchPaths,
            fs: fs
        )
        self.testingLibraryPlatformNames = testingLibraryPlatformNames
    }

    convenience init(path: Path, operatingSystem: OperatingSystem, fs: any FSProxy, pluginManager: PluginManager, platformRegistry: PlatformRegistry?) async throws {
        let data: PropertyListItem

        do {
            // Load the toolchain info.
            let infoPlistNames = ["Info.plist", "ToolchainInfo.plist"]
            let toolchainInfoPathOpt = infoPlistNames.map { path.join($0) }.first { fs.exists($0) }
            guard let toolchainInfoPath = toolchainInfoPathOpt else {
                throw StubError.error("could not find \(infoPlistNames[0]) in \(path.str)")
            }

            data = try PropertyList.fromPath(toolchainInfoPath, fs: fs)
        } catch {
            if path.fileExtension != "xctoolchain" && operatingSystem == .windows {
                // Windows toolchains do not have any metadata files that define a version (ToolchainInfo.plist is only present in Swift 6.2+ toolchains), so the version needs to be derived from the path.
                // Use the directory name to scrape the semantic version from.
                // This branch can be removed once we no longer need to work with toolchains older than Swift 6.2.
                let pattern = #/^(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(-(0|[1-9A-Za-z-][0-9A-Za-z-]*)(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$/#
                guard let match = try pattern.wholeMatch(in: path.basename) else {
                    throw StubError.error("Unable to extract version from toolchain directory name in \(path.str)")
                }
                // Set the version to only major/minor/patch numerics, as this is used as the directory in other parts of the windows SDK.
                // i.e. do not include the pre-release '-<version>' match group
                let version = "\(match.major).\(match.minor).\(match.patch)"

                data = .plDict([
                    "Identifier": .plString(ToolchainRegistry.defaultToolchainIdentifier),
                    "FallbackLibrarySearchPaths": .plArray([.plString("usr/bin")]),
                    "Version": .plString(version),
                    "DefaultBuildSettings": .plDict([
                        "TOOLCHAIN_VERSION": .plString(version)
                    ]),
                ])
            } else {
                throw error
            }
        }

        // The data should always be a dictionary.
        guard case .plDict(let items) = data else {
            throw StubError.error("expected dictionary in toolchain data")
        }

        // Extract the identifier.
        let identifier: String
        if case .plString(let toolchainIdentifier)? = items["Identifier"] {
            identifier = toolchainIdentifier
        } else if case .plString(let toolchainIdentifier)? = items["CFBundleIdentifier"] {
            identifier = toolchainIdentifier
        } else {
            throw StubError.error("invalid or missing 'Identifier' field")
        }

        // Display name
        let displayName: String
        if let infoDisplayName = items["Name"] {
            guard case .plString(let infoDisplayNameString) = infoDisplayName else {
                throw StubError.error("if the 'Name' key is present, it must be a string")
            }
            displayName = infoDisplayNameString
        }
        else if let infoDisplayName = items["DisplayName"] {
            guard case .plString(let infoDisplayNameString) = infoDisplayName else {
                throw StubError.error("if the 'DisplayName' key is present, it must be a string")
            }
            displayName = infoDisplayNameString
        }
        else {
            displayName = Toolchain.deriveDisplayName(identifier: identifier)
        }

        // Version
        let version: Version
        if let infoVersion = items["Version"] {
            guard case .plString(let infoVersionString) = infoVersion else {
                throw StubError.error("if the 'Version' key is present, it must be a string")
            }

            do {
                version = try Version(infoVersionString)
            }
            catch {
                throw StubError.error("'Version' parse error: \(error)")
            }
        }
        else {
            // No version specified in the plist, so we derive the version from the identifier.
            version = Toolchain.deriveVersion(identifier: identifier)
        }

        // Aliases
        var aliases = Set<String>()
        if let infoAliases = items["Aliases"] {
            guard case .plArray(let infoAliasesArray) = infoAliases else {
                throw StubError.error("if the 'Aliases' key is present, it must be an array of strings")
            }

            for alias in infoAliasesArray {
                guard case .plString(let aliasStr) = alias else {
                    throw StubError.error("if the 'Aliases' key is present, it must be an array of strings")
                }

                guard !aliasStr.isEmpty else { continue }
                aliases.insert(aliasStr.lowercased())
            }
        }
        else {
            // No aliases specified in the plist, so we derive them from the identifier.
            aliases = Toolchain.deriveAliases(path: path, identifier: identifier)
        }

        // Framework Search Paths
        var frameworkSearchPaths = Array<String>()
        if let infoFrameworkSearchPaths = items["FallbackFrameworkSearchPaths"] {
            guard case .plArray(let infoFrameworkSearchPathsArray) = infoFrameworkSearchPaths else {
                throw StubError.error("if the 'FallbackFrameworkSearchPaths' key is present, it must be an array of strings")
            }

            for path in infoFrameworkSearchPathsArray {
                guard case .plString(let pathStr) = path else {
                    throw StubError.error("if the 'FallbackFrameworkSearchPaths' key is present, it must be an array of strings")
                }

                guard !pathStr.isEmpty else { continue }
                frameworkSearchPaths.append(pathStr)
            }
        }

        // Library Search Paths
        var librarySearchPaths = Array<String>()
        if let infoLibrarySearchPaths = items["FallbackLibrarySearchPaths"] {
            guard case .plArray(let infoLibrarySearchPathsArray) = infoLibrarySearchPaths else {
                throw StubError.error("if the 'FallbackLibrarySearchPaths' key is present, it must be an array of strings")
            }

            for path in infoLibrarySearchPathsArray {
                guard case .plString(let pathStr) = path else {
                    throw StubError.error("if the 'FallbackLibrarySearchPaths' key is present, it must be an array of strings")
                }

                guard !pathStr.isEmpty else { continue }
                librarySearchPaths.append(pathStr)
            }
        }

        // Parse the default build settings.
        // FIXME: <rdar://problem/36364112> We should perform late binding and parsing of these settings in Core.getInitializedCore() rather than binding them when creating a Settings object.
        var defaultSettings: [String: PropertyListItem] = [:]
        if case .plDict(let settingsItems)? = items["DefaultBuildSettings"] {
            defaultSettings = settingsItems
        }

        var overrideSettings: [String: PropertyListItem] = [:]
        if case .plDict(let settingsItems)? = items["OverrideBuildSettings"] {
            overrideSettings = settingsItems
        }

        // Until <rdar://problem/46784630> is implemented and widely available, we need to force the toolchain values.
        // NOTE: The value is only added if there is no existing value. This makes this code safe to keep in, but, we should still remove it when the above radar is fixed. =)
        if identifier.starts(with: "org.swift") {
            if !overrideSettings.contains(BuiltinMacros.SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME.name) {
                overrideSettings[BuiltinMacros.SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME.name] = PropertyListItem.plString("YES")
            }

            if !overrideSettings.contains(BuiltinMacros.SWIFT_DEVELOPMENT_TOOLCHAIN.name) {
                overrideSettings[BuiltinMacros.SWIFT_DEVELOPMENT_TOOLCHAIN.name] = PropertyListItem.plString("YES")
            }
        }

        // Compute build setting defaults which will be applied when this is the primary toolchain.
        var defaultSettingsWhenPrimary: [String: PropertyListItem] = [:]
        if case .plDict(let settingsItems)? = items["DefaultBuildSettingsIfTopToolchain"] {
            defaultSettingsWhenPrimary = settingsItems
        }
        defaultSettingsWhenPrimary["TOOLCHAIN_DIR"] = .plString(path.str)
        defaultSettingsWhenPrimary["TOOLCHAIN_VERSION"] = .plString(version.description)

        var executableSearchPaths = [
            path.join("usr").join("bin"),
        ]

        for platformExtension in await pluginManager.extensions(of: PlatformInfoExtensionPoint.self) {
            executableSearchPaths.append(contentsOf: platformExtension.additionalToolchainExecutableSearchPaths(toolchainIdentifier: identifier, toolchainPath: path))
        }

        executableSearchPaths.append(contentsOf: [
            path.join("usr").join("local").join("bin"),
            path.join("usr").join("libexec")
        ])

        // Testing library platform names
        let testingLibrarySearchDir = path.join("usr").join("lib").join("swift")
        let testingLibraryPlatformNames: Set<String> = if let platformRegistry, fs.exists(testingLibrarySearchDir) {
            Set(try fs.listdir(testingLibrarySearchDir).filter {
                platformRegistry.lookup(name: $0) != nil && fs.exists(testingLibrarySearchDir.join($0).join("testing"))
            })
        } else {
            []
        }

        // Construct the toolchain
        self.init(identifier: identifier, displayName: displayName, version: version, aliases: aliases, path: path, frameworkPaths: frameworkSearchPaths, libraryPaths: librarySearchPaths, defaultSettings: defaultSettings, overrideSettings: overrideSettings, defaultSettingsWhenPrimary: defaultSettingsWhenPrimary, executableSearchPaths: executableSearchPaths, testingLibraryPlatformNames: testingLibraryPlatformNames, fs: fs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func ==(lhs: Toolchain, rhs: Toolchain) -> Bool {
        return lhs === rhs
    }

    @_spi(Testing) public static func deriveDisplayName(identifier: String) -> String {
        if identifier == ToolchainRegistry.defaultToolchainIdentifier {
            return "Xcode Default"
        }
        else if identifier.hasPrefix(ToolchainRegistry.appleToolchainIdentifierPrefix) {
            return identifier.withoutPrefix(ToolchainRegistry.appleToolchainIdentifierPrefix)
        }
        else {
            return identifier
        }
    }

    @_spi(Testing) public static func deriveAliases(path: Path, identifier: String) -> Set<String> {
        var aliases = Set<String>()

        // We start with the lowercased version of the last dot-separated component of the identifier.
        var alias = identifier.lowercased()

        let lastComponent = Path(alias).fileExtension
        if !lastComponent.isEmpty {
            aliases.insert(lastComponent)
        }

        // Also add the toolchain path's basename.
        aliases.insert(path.basenameWithoutSuffix.lowercased())

        // Also trim off successive numerical ranges from the end, adding an alias for each.  So for example, "iOS6.1.3" would have aliases "iOS6.1", "iOS6", and "iOS".  In each case, the registration code makes sure that the toolchain that gets to "own" each alias is the one with the highest version number that has that alias.
        while true {
            // Also add the result of replacing any underscores with dots.
            let lastComponent = Path(alias).fileExtension
            if !lastComponent.isEmpty {
                aliases.insert(lastComponent.replacingOccurrences(of: "_", with: "."))
            }

            // Trim off any trailing decimal digits and any trailing punctuation.
            let trimmedAlias = alias.trimmingCharacters(in: CharacterSet.decimalDigits).trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if trimmedAlias == alias {
                // Couldn't trim any more, so we break out.
                break
            }

            // Add the lowercased version of the alias (the full one as well as the last component).
            if !trimmedAlias.isEmpty {
                aliases.insert(trimmedAlias)
            }

            let trimmedLastComponent = Path(trimmedAlias).fileExtension
            if !trimmedLastComponent.isEmpty {
                aliases.insert(trimmedLastComponent)
            }

            // Move the chains.
            alias = trimmedAlias
        }

        return aliases
    }

    @_spi(Testing) public static func deriveVersion(identifier: String) -> Version {
        struct Static { static let deriveVersionPattern = RegEx(patternLiteral: "([0-9]+)") }
        let groups: [[String]] = Static.deriveVersionPattern.matchGroups(in: identifier)

        // <rdar://problem/31359366> error: ambiguous use of 'prefix'
        let numbers: [UInt] = Array(groups.prefix(3)).map{ $0.first! }.map{ UInt($0) ?? 0 }

        return Version(numbers)
    }

    func testingLibrarySearchPath(forPlatformNamed platformName: String) -> Path? {
        if testingLibraryPlatformNames.contains(platformName) {
            path.join("usr").join("lib").join("swift").join(platformName).join("testing")
        } else {
            nil
        }
    }
}

extension Toolchain: CustomStringConvertible {
    public var description: String {
        return "\(type(of: self))(identifier: '\(identifier)', path: '\(path.str)')"
    }
}

extension Array where Element == Toolchain {
    /// Returns `true` if any of the `Toolchain` items is a swift.org toolchain.
    public var usesSwiftOpenSourceToolchain: Bool {
        return self.reduce(false) { $0 || $1.overrideSettings[BuiltinMacros.SWIFT_DEVELOPMENT_TOOLCHAIN.name]?.looselyTypedBoolValue == true }
    }

    /// Returns `true` if the primary toolchain is the `defaultToolchain`.
    public var defaultToolchainIsPrimaryToolchain: Bool {
        return self.first?.identifier == ToolchainRegistry.defaultToolchainIdentifier
    }
}

/// The ToolchainRegistry manages the set of registered toolchains.
public final class ToolchainRegistry: @unchecked Sendable {
    let fs: any FSProxy
    let hostOperatingSystem: OperatingSystem

    /// The map of toolchains by identifier.
    @_spi(Testing) public private(set) var toolchainsByIdentifier = Dictionary<String, Toolchain>()

    /// Lower-cased alias -> toolchain (alias lookup is case-insensitive)
    @_spi(Testing) public private(set) var toolchainsByAlias = Dictionary<String, Toolchain>()

    public static let defaultToolchainIdentifier: String = "com.apple.dt.toolchain.XcodeDefault"

    public static let appleToolchainIdentifierPrefix: String = "com.apple.dt.toolchain."

    @_spi(Testing) public init(delegate: any ToolchainRegistryDelegate, searchPaths: [(Path, strict: Bool)], fs: any FSProxy, hostOperatingSystem: OperatingSystem) async {
        self.fs = fs
        self.hostOperatingSystem = hostOperatingSystem

        for (path, strict) in searchPaths {
            if !strict && !fs.exists(path) {
                continue
            }

            do {
                try await registerToolchainsInDirectory(path, strict: strict, operatingSystem: hostOperatingSystem, delegate: delegate)
            }
            catch let err {
                delegate.issue(strict: strict, path, "failed to load toolchains in \(path.str): \(err)")
            }
        }

        struct Context: ToolchainRegistryExtensionAdditionalToolchainsContext {
            var hostOperatingSystem: OperatingSystem
            var toolchainRegistry: ToolchainRegistry
            var fs: any FSProxy
        }

        for toolchainExtension in await delegate.pluginManager.extensions(of: ToolchainRegistryExtensionPoint.self) {
            do {
                for toolchain in try await toolchainExtension.additionalToolchains(context: Context(hostOperatingSystem: hostOperatingSystem, toolchainRegistry: self, fs: fs)) {
                    try register(toolchain)
                }
            } catch {
                delegate.error(error)
            }
        }
    }

    /// Register all the toolchains in the given directory.
    private func registerToolchainsInDirectory(_ path: Path, strict: Bool, operatingSystem: OperatingSystem, delegate: any ToolchainRegistryDelegate) async throws {
        let toolchainPaths: [Path] = try fs.listdir(path)
            .sorted()
            .map { path.join($0) }
            .filter { path in
                return path.fileExtension == "xctoolchain" || operatingSystem == .windows
            }

        for toolchainPath in toolchainPaths {
            // Check if this is a toolchain we should load.
            guard toolchainPath.basenameWithoutSuffix != "swift-latest" else { continue }

            do {
                let toolchain = try await Toolchain(path: toolchainPath, operatingSystem: operatingSystem, fs: fs, pluginManager: delegate.pluginManager, platformRegistry: delegate.platformRegistry)
                try register(toolchain)
            } catch let err {
                delegate.issue(strict: strict, toolchainPath, "failed to load toolchain: \(err)")
            }
        }
    }

    private func register(_ toolchain: Toolchain) throws {
        if let duplicateToolchain = toolchainsByIdentifier[toolchain.identifier] {
            throw StubError.error("toolchain '\(toolchain.identifier)' already registered from \(duplicateToolchain.path.str)")
        }
        toolchainsByIdentifier[toolchain.identifier] = toolchain

        for alias in toolchain.aliases {
            guard !alias.isEmpty else { continue }
            assert(alias.lowercased() == alias)

            // When two toolchains have conflicting aliases, the highest-versioned toolchain wins (regardless of identifier)
            if let existingToolchain = toolchainsByAlias[alias], existingToolchain.version >= toolchain.version {
                continue
            }

            toolchainsByAlias[alias] = toolchain
        }
    }

    /// Look up the toolchain with the given identifier.
    public func lookup(_ identifier: String) -> Toolchain? {
        let lowercasedIdentifier = identifier.lowercased()
        if hostOperatingSystem == .macOS {
            if ["default", "xcode"].contains(lowercasedIdentifier) {
                return toolchainsByIdentifier[ToolchainRegistry.defaultToolchainIdentifier] ?? toolchainsByAlias[lowercasedIdentifier]
            } else {
                return toolchainsByIdentifier[identifier] ?? toolchainsByAlias[lowercasedIdentifier]
            }
        } else {
            // On non-Darwin, assume if there is only one registered toolchain, it is the default.
            if ["default", "xcode"].contains(lowercasedIdentifier) || identifier == ToolchainRegistry.defaultToolchainIdentifier {
                return toolchainsByIdentifier[ToolchainRegistry.defaultToolchainIdentifier] ?? toolchainsByAlias[lowercasedIdentifier] ?? toolchainsByIdentifier.values.only
            } else {
                return toolchainsByIdentifier[identifier] ?? toolchainsByAlias[lowercasedIdentifier]
            }
        }
    }

    public var defaultToolchain: Toolchain? {
        return self.lookup(ToolchainRegistry.defaultToolchainIdentifier)
    }

    public var toolchains: Set<Toolchain> {
        return Set(self.toolchainsByIdentifier.values)
    }
}
