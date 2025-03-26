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
import class Foundation.ProcessInfo
public import SWBMacro

/// Delegate protocol used to report diagnostics.
@_spi(Testing) public protocol SDKRegistryDelegate: DiagnosticProducingDelegate, Sendable {
    /// The namespace to parse macros into.
    var namespace: MacroNamespace { get }

    var pluginManager: PluginManager { get }

    var platformRegistry: PlatformRegistry? { get }
}

public final class SDK: Sendable {
    @_spi(Testing) public struct CanonicalNameComponents: Sendable {
        public let basename: String
        public let version: Version?
        public let suffix: String?
    }

    private static func supportedSDKCanonicalNameSuffixes(pluginManager: PluginManager) -> Set<String> {
        @preconcurrency @PluginExtensionSystemActor func extensions() -> [any SDKRegistryExtensionPoint.ExtensionProtocol] {
            pluginManager.extensions(of: SDKRegistryExtensionPoint.self)
        }
        var suffixes: Set<String> = []
        for `extension` in extensions() {
            suffixes.formUnion(`extension`.supportedSDKCanonicalNameSuffixes)
        }
        return suffixes
    }

    /// Returns the component pieces of a given `canonicalName` for an SDK. Returns `nil` if the string is does not match the canonical name format.
    @_spi(Testing) public static func parseSDKName(_ sdkCanonicalName: String, pluginManager: PluginManager) throws -> CanonicalNameComponents {
        // Remove the suffix, if there is one.
        var baseAndVersion = sdkCanonicalName
        var suffix: String? = nil
        for supportedSuffix in Self.supportedSDKCanonicalNameSuffixes(pluginManager: pluginManager).sorted() {
            // Some SDKs use the dot for suffixes and some do not, so both are supported.
            if sdkCanonicalName.hasSuffix(".\(supportedSuffix)") {
                baseAndVersion = sdkCanonicalName.withoutSuffix(".\(supportedSuffix)")
                suffix = supportedSuffix
                break
            }
            else if sdkCanonicalName.hasSuffix(supportedSuffix) {
                baseAndVersion = sdkCanonicalName.withoutSuffix(supportedSuffix)
                suffix = supportedSuffix
                break
            }
        }

        // Split the baseAndVersion into the basename and the version.  Note that there might not be a version.
        guard let match = try #/(?<name>[^0-9]+)(?<version>[0-9]+(?:\.[0-9]+)*)?(?<suffix>.*)/#.wholeMatch(in: baseAndVersion), match.output.suffix.isEmpty else {
            throw StubError.error("SDK canonical name '\(sdkCanonicalName)' not in supported format '<name>[<version>][suffix]'.")
        }

        let basename = String(match.output.name)
        let version: Version?
        if let versionString = match.output.version?.nilIfEmpty {
            do {
                version = try Version(String(versionString))
            } catch {
                throw StubError.error("Version '\(versionString)' of SDK canonical name '\(sdkCanonicalName)' is not in a recognized version format.")
            }
        } else {
            version = nil
        }

        return CanonicalNameComponents(basename: basename, version: version, suffix: suffix)
    }

    /// The canonical name of the SDK.
    public let canonicalName: String

    @_spi(Testing) public let canonicalNameComponents: CanonicalNameComponents?

    /// Aliases for `canonicalName`
    public let aliases: Set<String>

    /// Additional platform names to use as a disambiguating factor when multiple SDKs share an alias.
    public let cohortPlatforms: [String]

    /// The display name of the SDK.
    public let displayName: String

    /// The path of the SDK.
    public let path: Path

    /// The SDK version, if available.
    public let version: Version?

    /// The SDK product build version, if available.
    public let productBuildVersion: String?

    /// The default build settings.
    public let defaultSettings: [String: PropertyListItem]

    /// The parsed default build settings table.
    public private(set) var defaultSettingsTable: MacroValueAssignmentTable? = nil

    /// The overriding build settings.
    public let overrideSettings: [String: PropertyListItem]

    /// The parsed default build settings table.
    public private(set) var overrideSettingsTable: MacroValueAssignmentTable? = nil

    /// SDK variants, mapped by their name.  Each variant can define a set of additional settings that a target can opt into by setting `SDK_VARIANT`.
    @_spi(Testing) public let variants: [String: SDKVariant]

    /// Get the SDK variant for the given name.
    public func variant(for name: String) -> SDKVariant? {
        // Unfortunately on macOS the default variant name 'macos' doesn't match the corresponding supported target name 'macosx'.  Since there are already projects expecting SDK_VARIANT to be 'macos', we prefer that name.
        let variantName = (name == "macosx" ? "macos" : name)
        return variants[variantName]
    }

    /// Default SDK variant (one of the variants in `variants`).  The default variant is the one that is used if `$(SDK_VARIANT)` evaluates to the empty string.
    public let defaultVariant: SDKVariant?

    /// Default deployment target for the SDK. Note that SDK variants might contain a more specific value for the deployment target.
    public let defaultDeploymentTarget: Version?

    /// Additional header search paths to use when building against this SDK.
    public let headerSearchPaths: [Path]

    /// Additional framework search paths to use when building against this SDK.
    public let frameworkSearchPaths: [Path]

    /// Additional library search paths to use when building against this SDK.
    public let librarySearchPaths: [Path]

    /// Provides the platform version mapping when working with macCatalyst and macOS variants.
    public let versionMap: [String:[Version:Version]]

    /// The SDK-specific directory macros.
    let directoryMacros: [StringMacroDeclaration]

    /// Is this a Base SDK or a Sparse SDK?
    @_spi(Testing) public let isBaseSDK: Bool

    /// Values to use as 'sdk' macro conditions in `Settings` objects which use this SDK.  This consists of the SDK's canonical name, plus any fallback condition values it defines (but only if it is a base SDK).
    let settingConditionValues: [String]

    /// The toolchains that this SDK wants to use.
    public let toolchains: [String]

    /// The maximum deployment target value for this SDK.
    /// Currently (2019) this always has "99" as the third version component, intended to allow developers to target patch versions of the current SDK.
    /// Note that this is technically "broken" for macOS, as the third version component in practice is more like a minor version, and macOS does not have true patch versions, but we'll respect the value in the SDK as-is for now.
    @_spi(Testing) public let maximumDeploymentTarget: Version?

    init(_ canonicalName: String, canonicalNameComponents: CanonicalNameComponents?, _ aliases: Set<String>, _ cohortPlatforms: [String], _ displayName: String, _ path: Path, _ version: Version?, _ productBuildVersion: String?, _ defaultSettings: [String: PropertyListItem], _ overrideSettings: [String: PropertyListItem], _ variants: [String: SDKVariant], _ defaultDeploymentTarget: Version?, _ defaultVariant: SDKVariant?, _ searchPaths: (header: [Path], framework: [Path], library: [Path]), _ directoryMacros: [StringMacroDeclaration], _ isBaseSDK: Bool, _ fallbackSettingConditionValues: [String], _ toolchains: [String], _ versionMap: [String:[Version:Version]], _ maximumDeploymentTarget: Version?) {
        self.canonicalName = canonicalName
        self.canonicalNameComponents = canonicalNameComponents
        self.aliases = aliases
        self.cohortPlatforms = cohortPlatforms
        self.displayName = displayName
        self.path = path
        self.version = version
        self.productBuildVersion = productBuildVersion
        self.defaultSettings = defaultSettings
        self.overrideSettings = overrideSettings
        self.variants = variants
        self.defaultDeploymentTarget = defaultDeploymentTarget
        self.headerSearchPaths = searchPaths.header
        self.frameworkSearchPaths = searchPaths.framework
        self.librarySearchPaths = searchPaths.library
        self.directoryMacros = directoryMacros
        self.isBaseSDK = isBaseSDK
        // We only use the fallback condition values if this is a base SDK.
        self.settingConditionValues = isBaseSDK ? ([canonicalName] + fallbackSettingConditionValues) : [canonicalName]
        self.toolchains = toolchains
        self.versionMap = versionMap
        self.maximumDeploymentTarget = maximumDeploymentTarget

        if defaultVariant == nil {
            // We sort the variant names so that we always pick the same one.
            if let firstVariantName = variants.keys.sorted().first {
                self.defaultVariant = variants[firstVariantName]
            } else {
                self.defaultVariant = nil
            }
        } else {
            self.defaultVariant = defaultVariant
        }
    }

    public var canonicalNameSuffix: String? {
        canonicalNameComponents?.suffix
    }

    fileprivate let associatedTypesForKeysMatching: [String: MacroType] = [
        "_DEPLOYMENT_TARGET": .string
    ]

    /// Perform late binding of the SDK data.
    fileprivate func loadExtendedInfo(_ namespace: MacroNamespace) throws {
        assert(defaultSettingsTable == nil && overrideSettingsTable == nil)

        do {
            defaultSettingsTable = try namespace.parseTable(defaultSettings, allowUserDefined: true, associatedTypesForKeysMatching: associatedTypesForKeysMatching)
            overrideSettingsTable = try namespace.parseTable(overrideSettings, allowUserDefined: true, associatedTypesForKeysMatching: associatedTypesForKeysMatching)
            for variant in self.variants.values {
                try variant.parseSettingsTable(namespace, associatedTypesForKeysMatching: associatedTypesForKeysMatching)
            }
        } catch {
            defaultSettingsTable = nil
            overrideSettingsTable = nil
            throw StubError.error("unexpected macro parsing failure loading SDK \(canonicalName): \(error)")
        }
    }
}

extension SDK: CustomStringConvertible {
    public var description: String {
        return "\(type(of: self))(canonicalName: '\(canonicalName)', path: '\(path.str)')"
    }
}

extension SDK {
    public func targetBuildVersionPlatform(sdkVariant: SDKVariant? = nil) -> BuildVersion.Platform? {
        let buildVersionPlatformID: Int?
        if let id = sdkVariant?.buildVersionPlatformID {
            buildVersionPlatformID = id
        } else if let platformName = defaultSettings[BuiltinMacros.PLATFORM_NAME.name]?.stringValue, let id = variant(for: platformName)?.buildVersionPlatformID {
            buildVersionPlatformID = id
        } else {
            buildVersionPlatformID = nil
        }

        guard let platformID = buildVersionPlatformID.map({ UInt32($0) }) else {
            return nil
        }

        return BuildVersion.Platform(rawValue: platformID)
    }
}

/// Definition of a single SDK variant.  A variant has a non-empty name, which must be unique within the SDK, and a set of additional build settings that a target can opt into by setting `SDK_VARIANT` to the name of the variant.
public final class SDKVariant: PlatformInfoProvider, Sendable {
    /// Variant name (must be non-empty and unique within the SDK).
    public let name: String

    /// Settings that are added on top of the settings in the SDK itself when the variant is chosen using `SDK_VARIANT`.
    public let settings: [String: PropertyListItem]

    /// Parsed form of the `settings`.
    public private(set) var settingsTable: MacroValueAssignmentTable?

    // FIXME: Presently all of the keys from the 'SupportedTargets' dict are treated as optional.  We should improve this in the future.

    /// The architectures supported by this variant.
    public let archs: [String]?

    /// The default value to use for the primary deployment target for this variant if none is defined.
    public let defaultDeploymentTarget: Version?

    /// A list of valid values for the primary deployment target for this variant.
    public let validDeploymentTargets: [Version]?

    /// The minimum value allowed for the primary deployment target for this variant.
    public let minimumDeploymentTarget: Version?

    /// The recommended value for the primary deployment target for this variant.
    public let recommendedDeploymentTarget: Version?

    /// The maximum value allowed for the primary deployment target for this variant.
    public let maximumDeploymentTarget: Version?

    /// The range of values allows for the primary deployment target for this variant.  This is derived from `minimumDeploymentTarget` and `maximumDeploymentTarget`.
    public let deploymentTargetRange: VersionRange

    /// The target vendor to be passed in the target triple to LLVM-based tools for this variant.
    public let llvmTargetTripleVendor: String?

    /// The target system to be passed in the target triple to LLVM-based tools for this variant.  This is typically a platform name.
    public let llvmTargetTripleSys: String?

    /// The target environment to be passed in the target triple to LLVM-based tools for this variant.  This is the 'suffix' which comes after the three main components.
    public let llvmTargetTripleEnvironment: String?

    /// The build version platform ID for this variant.  Different platforms have different integers associated with them.
    public let buildVersionPlatformID: Int?

    /// The platform family name this SDK variant targets used for diagnostics
    public let platformFamilyName: String?

    /// The TARGET_OS or other macro name used for diagnostics
    public let targetOSMacroName: String?

    /// The _DEPLOYMENT_TARGET setting name
    public let deploymentTargetSettingName: String?

    /// The device families supported by this SDK variant.
    public let deviceFamilies: DeviceFamilies

    /// Infix for clang runtime library filenames associated with this SDK variant, such as sanitizer runtime libraries.
    public let clangRuntimeLibraryPlatformName: String?

    /// Minimum OS version for Swift-in-the-OS support. If this is `nil`, the platform does not support Swift-in-the-OS at all.
    public let minimumOSForSwiftInTheOS: Version?

    /// Minimum OS version for built-in Swift concurrency support. If this is `nil`, the platform does not support Swift concurrency at all.
    public let minimumOSForSwiftConcurrency: Version?

    /// The path prefix under which all built content produced by this SDK variant should be installed, relative to the system root.
    ///
    /// Empty string if content should be installed directly into the system root (default).
    public let systemPrefix: String

    /// Initializes the SDK variant with a non-empty name and a dictionary of settings.  The settings will not be parsed until the private `parseSettingsTable()` method is invoked, which must happen before they can be used.
    init(name: String, settings: [String: PropertyListItem], supportedTargetDict: [String: PropertyListItem]) throws {
        var modifiedSettings = settings

        // Additional settings for the SDK variants.  In general these should be moved into the variant settings in SDKSettings.plist when possible.
        if name == MacCatalystInfo.sdkVariantName {
            modifiedSettings["IS_MACCATALYST"] = .plString("YES")
        }
        else if name == "macos" {
            // Also set IS_MACCATALYST explicitly for the 'macos' variant, to make build setting interpolation easier.
            modifiedSettings["IS_MACCATALYST"] = .plString("NO")
        }

        // Capture the contents of the SDK variant source data.
        self.name = name
        self.settings = modifiedSettings

        // Capture the contents of the support target source data.
        var archs = [String]()
        for arch in supportedTargetDict["Archs"]?.arrayValue ?? [] {
            if let value = arch.stringValue {
                archs.append(value)
            }
        }
        self.archs = archs

        self.defaultDeploymentTarget = try? Version(supportedTargetDict["DefaultDeploymentTarget"]?.stringValue ?? "")
        self.minimumDeploymentTarget = try? Version(supportedTargetDict["MinimumDeploymentTarget"]?.stringValue ?? "")
        self.maximumDeploymentTarget = try? Version(supportedTargetDict["MaximumDeploymentTarget"]?.stringValue ?? "")
        if let min = minimumDeploymentTarget, let max = maximumDeploymentTarget {
            do {
                deploymentTargetRange = try VersionRange(start: min, end: max)
            }
            catch {
                // ignore error for now (same as in Platform.deploymentTargetsCache)
                deploymentTargetRange = VersionRange()
            }
        }
        else {
            deploymentTargetRange = VersionRange()
        }


        var validDeploymentTargets = [Version]()
        for deploymentTarget in supportedTargetDict["ValidDeploymentTargets"]?.arrayValue ?? [] {
            if let value = try? Version(deploymentTarget.stringValue ?? "") {
                validDeploymentTargets.append(value)
            }
        }
        self.validDeploymentTargets = validDeploymentTargets

        // The recommended deployment target is the default deployment target for the platform, unless we've overridden to a more specific value.
        self.recommendedDeploymentTarget = (try? Version(supportedTargetDict["RecommendedDeploymentTarget"]?.stringValue ?? Self.fallbackRecommendedDeploymentTarget(variantName: name) ?? "")) ?? defaultDeploymentTarget

        self.llvmTargetTripleEnvironment = supportedTargetDict["LLVMTargetTripleEnvironment"]?.stringValue
        self.llvmTargetTripleSys = supportedTargetDict["LLVMTargetTripleSys"]?.stringValue
        self.llvmTargetTripleVendor = supportedTargetDict["LLVMTargetTripleVendor"]?.stringValue

        self.buildVersionPlatformID = Int(supportedTargetDict["BuildVersionPlatformID"]?.stringValue ?? "")
        self.platformFamilyName = supportedTargetDict["PlatformFamilyName"]?.stringValue
        self.deploymentTargetSettingName = supportedTargetDict["DeploymentTargetSettingName"]?.stringValue
        if let targetOSMacroName = supportedTargetDict["TargetOSMacroName"]?.stringValue, !targetOSMacroName.isEmpty {
            self.targetOSMacroName = targetOSMacroName
        } else {
            self.targetOSMacroName = nil
        }

        self.deviceFamilies = try DeviceFamilies(families: PropertyList.decode([DeviceFamily].self, from: supportedTargetDict["DeviceFamilies"] ?? Self.fallbackDeviceFamiliesData(variantName: name)))

        self.clangRuntimeLibraryPlatformName = supportedTargetDict["ClangRuntimeLibraryPlatformName"]?.stringValue ?? Self.fallbackClangRuntimeLibraryPlatformName(variantName: name)

        let (os, concurrency) = Self.fallbackSwiftVersions(variantName: name)
        self.minimumOSForSwiftInTheOS = try (supportedTargetDict["SwiftOSRuntimeMinimumDeploymentTarget"]?.stringValue ?? os).map { try Version($0) }
        self.minimumOSForSwiftConcurrency = try (supportedTargetDict["SwiftConcurrencyMinimumDeploymentTarget"]?.stringValue ?? concurrency).map { try Version($0) }

        self.systemPrefix = supportedTargetDict["SystemPrefix"]?.stringValue ?? {
            switch name {
            case MacCatalystInfo.sdkVariantName:
                return "/System/iOSSupport"
            case "driverkit":
                return "/System/DriverKit"
            default:
                return ""
            }
        }()
    }

    private static func fallbackDeviceFamiliesData(variantName name: String) throws -> PropertyListItem {
        switch name {
        case "macos", "macosx":
            return .plArray([
                .plDict([
                    "Name": .plString("mac"),
                    "DisplayName": .plString("Mac"),
                ])
            ])
        case MacCatalystInfo.sdkVariantName:
            return .plArray([
                .plDict([
                    "Identifier": .plInt(2),
                    "Name": .plString("pad"),
                    "DisplayName": .plString("iPad"),
                ]),
                .plDict([
                    "Identifier": .plInt(6),
                    "Name": .plString("mac"),
                    "DisplayName": .plString("Mac"),
                ])
            ])
        default:
            // Other platforms don't have device families
            return .plArray([])
        }
    }

    private static func fallbackClangRuntimeLibraryPlatformName(variantName name: String) -> String? {
        switch name {
        case "macos", "macosx", MacCatalystInfo.sdkVariantName:
            return "osx"
        default:
            return nil
        }
    }

    private static func fallbackSwiftVersions(variantName name: String) -> (String?, String?) {
        switch name {
        case "macos", "macosx":
            return ("10.14.4", "12.0")
        default:
            return (nil, nil)
        }
    }

    private static func fallbackRecommendedDeploymentTarget(variantName name: String) -> String? {
        switch name {
            // Late Summer 2019 aligned, except iOS which got one final 12.x update in Winter 2020, making this version set the last minor update series of the Fall 2018 aligned releases.
        case "macos", "macosx":
            return "10.14.6"
        case "iphoneos", "iphonesimulator":
            return "12.5"
        case "appletvos", "appletvsimulator":
            return "12.4"
        case "watchos", "watchsimulator":
            return "5.3"

            // No Summer 2019 aligned versions since these were first introduced on or after Fall 2019, so simply use the minimum versions.
        case "driverkit":
            return "19.0"
        case MacCatalystInfo.sdkVariantName:
            return "13.1"
        case "xros", "xrsimulator":
            return "1.0"

            // Fall back to the default deployment target, which is equal to the SDK version.
        default:
            return nil
        }
    }

    /// Perform late binding of the build settings.  This is a private function that may only be invoked once for any given SDK variant.
    /// - Parameters:
    ///   - associatedTypesForKeysMatching: Passed to `MacroNamespace.parseTable` - refer there for more info.
    fileprivate func parseSettingsTable(_ namespace: MacroNamespace, associatedTypesForKeysMatching: [String: MacroType]? = nil) throws {
        assert(settingsTable == nil)
        settingsTable = try namespace.parseTable(settings, allowUserDefined: true, associatedTypesForKeysMatching: associatedTypesForKeysMatching)
    }
}

extension SDKVariant {
    public var isMacCatalyst: Bool {
        return name == MacCatalystInfo.sdkVariantName
    }
}

extension SDKVariant: CustomStringConvertible {
    public var description: String {
        return "\(type(of: self))(name: '\(name)')"
    }
}

public protocol SDKRegistryLookup: Sendable {
    /// Look up the SDK with the given name.
    /// - parameter name: Canonical name, alias, or short name of the SDK to look up.
    /// - parameter activeRunDestination: Active run destination for the build. Used to disambiguate between multiple matches for the same alias by comparing the run destination's platform with the matched SDK's cohort platforms.
    /// - throws: `AmbiguousSDKLookupError` if there are multiple suitable matches and the run destination (if provided) was not able to disambiguate them.
    /// - returns: The found `SDK`, or `nil` if no SDK with the given name could be found or `name` was in an invalid format.
    func lookup(_ name: String, activeRunDestination: RunDestinationInfo?) throws -> SDK?

    /// Look up the SDK with the given path.  If the registry is immutable, then this will only return the SDK if it was loaded when the registry was created; only mutable registries can discover and load new SDKs after that point.
    /// - parameter path: Absolute path of the SDK to look up.
    /// - returns: The found `SDK`, or `nil` if no SDK was found at the given path.
    func lookup(_ path: Path) -> SDK?

    /// Look up the SDK with the given name or path string. If no SDK is found
    /// when treating the value as a name, then it will be treated as a path
    /// relative to the given `basePath`.
    ///
    /// If the SDK is not present by name, but it is present by path, it will be
    /// loaded and added to the registry.
    ///
    /// - parameter nameOrPath: Name or path string indicating the SDK to look up.
    /// - parameter basePath: The directory to perform path-style searches against. Must be absolute.
    /// - parameter activeRunDestination: Active run destination for the build. Used to disambiguate between multiple matches for the same alias by comparing the run destination's platform with the matched SDK's cohort platforms.
    /// - throws: `AmbiguousSDKLookupError` if there are multiple suitable matches and the run destination (if provided) was not able to disambiguate them.
    /// - returns: The found `SDK`, or `nil` if no SDK with the given name could be found or `nameOrPath` was in an invalid format.
    func lookup(nameOrPath: String, basePath: Path, activeRunDestination: RunDestinationInfo?) throws -> SDK?
}

/// Ways in which a framework may be replaced.
public enum FrameworkReplacementKind: Sendable {
    /// The framework is deprecated and is replaced by the functionally equivalent named framework, if any.
    ///
    /// A `nil` replacement indicates that there is no replacement for the deprecated framework.
    case deprecated(replacement: String?)

    /// The framework is renamed (via ld64 renaming symbols) to the named framework.
    case renamed(replacement: String)

    /// The framework is a successor to an existing framework, but the successor is not yet supported
    /// in all usage scenarios (despite being available in the SDK) and the existing framework is not
    /// yet formally deprecated.
    ///
    /// - Parameters:
    ///   - original: The name of the original framework which this framework is succeeding.
    case conditionallyAvailableSuccessor(original: String)
}

/// This object manages the set of SDKs.
public final class SDKRegistry: SDKRegistryLookup, CustomStringConvertible, Sendable {
    /// The type of an SDK registry.
    @_spi(Testing) public enum SDKRegistryType: String, Sendable {
        /// A registry for built-in SDKs.
        case builtin
        /// A registry for overriding SDKs.
        case overriding
        /// A registry for external SDKs.
        case external

        /// Returns `true` if a registry of this type cannot discover additional SDKs after it is created.
        var isImmutable: Bool {
            return self != .external
        }
    }

    internal let hostOperatingSystem: OperatingSystem

    /// The type of the SDK registry.
    private let type: SDKRegistryType

    /// The delegate.
    private let delegate: any SDKRegistryDelegate

    /// The map of SDKs by identifier.
    private let sdksByCanonicalName = Registry<String, SDK>()

    /// The map of SDKs by alias.
    private let sdksByAlias = Registry<String, [SDK]>()

    /// The map of SDKs by path.
    private let sdksByPath = Registry<Path, SDK>()

    /// The map of canonical name strings parsed to semantic understandings of an SDK name.
    private let parsedSDKNames = Registry<String, Result<SDK.CanonicalNameComponents, any Error>>()

    private func parseSDKName(_ canonicalName: String) throws -> SDK.CanonicalNameComponents {
        try parsedSDKNames.getOrInsert(canonicalName) {
            Result { try SDK.parseSDKName(canonicalName, pluginManager: delegate.pluginManager) }
        }.get()
    }

    /// The boot system SDK.
    //
    // FIXME: This doesn't belong here.
    @_spi(Testing) public var bootSystemSDK: SDK? {
        return try? self.lookup("macosx", activeRunDestination: nil)
    }

    @_spi(Testing) public init(delegate: any SDKRegistryDelegate, searchPaths: [(Path, Platform?)], type: SDKRegistryType, hostOperatingSystem: OperatingSystem) {
        self.delegate = delegate
        self.type = type
        self.hostOperatingSystem = hostOperatingSystem

        for (path, platform) in searchPaths {
            registerSDKsInDirectory(path, platform)
        }
    }

    /// Register all the SDKs in the given directory.
    private func registerSDKsInDirectory(_ path: Path, _ platform: Platform?) {
        guard let pathResolved = try? localFS.realpath(path) else { return }
        guard let contents = try? localFS.listdir(path) else { return }
        guard let sdkPaths: [(sdkPath: Path, sdkPathResolved: Path)] = try? (contents.filter { $0.hasSuffix(".sdk") }.sorted(by: <).map { path.join($0) }.map{ ($0, try localFS.realpath($0)) }) else { return }

        // If you have SDKs A and L in the same directory, where L is a symlink to A, we'll ignore A and register L.
        let sdkNamesTargetedByLinks = Set(sdkPaths.compactMap { (sdkPath, sdkPathResolved) -> String? in
            guard localFS.isSymlink(sdkPath) else { return nil }
            guard sdkPathResolved.dirname == pathResolved else { return nil }
            return sdkPathResolved.basename
        })

        for (sdkPath, sdkPathResolved) in sdkPaths {
            guard !sdkNamesTargetedByLinks.contains(sdkPath.basename) else { continue }
            guard sdksByPath[sdkPathResolved] == nil else { continue }
            registerSDK(sdkPath, sdkPathResolved, platform)
        }
    }

    internal func registerSDKs(extension: any SDKRegistryExtension, context: any SDKRegistryExtensionAdditionalSDKsContext) async throws {
        for (path, platform, data) in try await `extension`.additionalSDKs(context: context) {
            registerSDK(path, path, platform, .plDict(data))
        }
    }

    /// Register and return an SDK for a platform.
    /// - parameter path: The nominal (given) path to the SDK directory.
    /// - parameter pathResolved: The resolved (normalized) path to the SDK directory.
    /// - parameter platform: The platform in which to register the SDK, if any.
    @discardableResult private func registerSDK(_ path: Path, _ pathResolved: Path, _ platform: Platform?) -> SDK? {
        // Clients are responsible for checking this
        assert(sdksByPath[pathResolved] == nil)

        let sdkSettingsPath = path.join("SDKSettings.plist")

        // We silently ignore missing SDKSettings.plist
        guard localFS.exists(sdkSettingsPath) else { return nil }

        var data: PropertyListItem
        do {
            data = try PropertyList.fromPath(sdkSettingsPath, fs: localFS)
        } catch {
            delegate.error(path, "unable to load SDK: '\(sdkSettingsPath.basename)' was malformed: \(error)")
            return nil
        }

        return registerSDK(path, pathResolved, platform, data)
    }

    @discardableResult private func registerSDK(_ path: Path, _ pathResolved: Path, _ platform: Platform?, _ data: PropertyListItem) -> SDK? {
        // The data should always be a dictionary.
        guard case .plDict(let items) = data else {
            delegate.error(path, "unexpected SDK data")
            return nil
        }

        // Extract the name properties.
        guard case .plString(let canonicalName)? = items["CanonicalName"] ?? items["Name"] else {
            delegate.error(path, "invalid or missing 'CanonicalName' field")
            return nil
        }

        var aliases = Set<String>()
        if let plAliases = items["Aliases"] {
            guard case .plArray(let plArrayAliases) = plAliases else {
                delegate.error(path, "expected array of strings in 'Aliases' field, but found: \(plAliases)")
                return nil
            }

            for plAlias in plArrayAliases {
                guard case .plString(let alias) = plAlias else {
                    delegate.error(path, "expected array of strings in 'Aliases' field, but found: \(plAlias)")
                    return nil
                }

                aliases.insert(alias)
            }
        }

        var cohortPlatforms: [String] = []
        if let plCohortPlatforms = items["CohortPlatforms"] {
            guard let plArrayCohortPlatforms = plCohortPlatforms.stringArrayValue else {
                delegate.error(path, "expected array of strings in 'CohortPlatforms' field, but found: \(plCohortPlatforms)")
                return nil
            }

            cohortPlatforms = plArrayCohortPlatforms
        }

        var displayName = canonicalName
        if case .plString(let value)? = items["DisplayName"] {
            displayName = value
        }

        let isBaseSDK = items["IsBaseSDK"]?.looselyTypedBoolValue
            ?? items["isBaseSDK"]?.looselyTypedBoolValue
            ?? false

        let maximumDeploymentTarget = try? Version(items["MaximumDeploymentTarget"]?.stringValue ?? "")

        func filteredSettings(_ settings: [String: PropertyListItem]) -> [String: PropertyListItem] {
            if isBaseSDK {
                return settings
            } else {
                let filteredSettings: [(String, PropertyListItem)] = settings.filter { key, _ in
                    var keyIsAllowed = true
                    if SDKRegistry.ignoredSparseSdkSettingKeys.contains(key) {
                        keyIsAllowed = false
                    }
                    else {
                        for suffix in SDKRegistry.ignoredSparseSdkSettingKeySuffixes {
                            if key.hasSuffix(suffix) {
                                keyIsAllowed = false
                                break
                            }
                        }
                    }

                    // If the key is not allowed in the sparse SDK, then emit a warning.
                    if !keyIsAllowed {
                        delegate.warning(path, "setting '\(key)' is not allowed in sparse SDK")
                    }

                    return keyIsAllowed
                }
                return Dictionary(uniqueKeysWithValues: filteredSettings)
            }
        }

        // Parse the toolchain identifiers.
        var toolchains: [String] = []
        if case .plArray(let toolchainsItem)? = items["Toolchains"] {
            for item in toolchainsItem {
                guard case .plString(let str) = item else { continue }
                toolchains.append(str)
            }
        }

        // Parse the default build settings.
        var defaultSettings: [String: PropertyListItem] = [:]
        if case .plDict(let settingsItems)? = items["DefaultProperties"] {
            defaultSettings = filteredSettings(settingsItems)
                .filter { $0.key != "TEST_FRAMEWORK_DEVELOPER_VARIANT_SUBPATH" } // rdar://107954685 (Remove watchOS special case for testing framework paths)
        }

        // Parse the custom properties settings.
        var overrideSettings: [String: PropertyListItem] = [:]
        if case .plDict(let settingsItems)? = items["CustomProperties"] {
            overrideSettings = filteredSettings(settingsItems)
                .filter { !$0.key.hasPrefix("SWIFT_MODULE_ONLY_") } // Rev-lock: don't set SWIFT_MODULE_ONLY_ in SDKs
        }

        // Parse the Variants array and the SupportedTargets dictionary, then create the SDKVariant objects from them.  Note that it is not guaranteed that any variant will have both sets of data, so we don't the presence of either one.
        var variantNames = OrderedSet<String>()
        var variantSettingsData = [String: [String: PropertyListItem]]()
        if case .plArray(let variantDictItems)? = items["Variants"] {
            for item in variantDictItems {
                // Make sure the array entry is a dictionary.
                guard case .plDict(let variantDict) = item else {
                    delegate.error(path, "expected array of dictionaries in 'Variants' field, but found \(item)")
                    return nil
                }

                // Validate the variant name.
                guard case .plString(let variantName)? = variantDict["Name"] else {
                    delegate.error(path, "missing 'Name' field in variant dictionary")
                    return nil
                }
                if variantName.isEmpty {
                    delegate.error(path, "empty value for 'Name' field in variant dictionary")
                    return nil
                }

                // Fail if we already have a variant with this name.
                if variantSettingsData[variantName] != nil {
                    // This error could be misleading due to the swizzling above.
                    delegate.error(path, "found multiple entries in 'Variants' field with the name '\(variantName)'")
                    return nil
                }

                // Fail if the variant data doesn't contain a BuildSettings dictionary.
                guard case .plDict(let settingsDict)? = variantDict["BuildSettings"] else {
                    delegate.error(path, "missing 'BuildSettings' field in variant dictionary")
                    return nil
                }

                // Construct a macro definition table from the build settings dictionary.
                var variantSettings: [String: PropertyListItem] = [:]
                variantSettings = filteredSettings(settingsDict)

                // Also make sure that the variant name is also set in a build setting.
                variantSettings["SDK_VARIANT"] = .plString(variantName)

                // Record the name and the settings for later use.
                variantNames.append(variantName)
                variantSettingsData[variantName] = variantSettings
            }
        }
        var supportedTargetsData = [String: [String: PropertyListItem]]()
        if case .plDict(let supportedTargets)? = items["SupportedTargets"] {
            for (name, plist) in supportedTargets {
                // Unfortunately on macOS the default variant name 'macos' doesn't match the corresponding supported target name 'macosx'.  Since there are already projects expecting SDK_VARIANT to be 'macos', we prefer that name.
                let variantName = (name == "macosx" ? "macos" : name)
                // Extract the dict for this target to be processed when we create the SDKVariant object.
                let supportedTargetDict: [String: PropertyListItem]
                if case .plDict(let dict) = plist {
                    supportedTargetDict = dict
                }
                else {
                    supportedTargetDict = [:]
                }

                // Record the name and the property list for later use.
                variantNames.append(variantName)
                supportedTargetsData[variantName] = supportedTargetDict
            }
        }

        // Create the SDK variants from the data we loaded.
        var variants: [String: SDKVariant] = [:]
        for name in variantNames {
            // FIXME: We should convert this to a failable initializer and pass it the delegate so it can emit errors when processing the data.
            do {
                variants[name] = try SDKVariant(name: name, settings: variantSettingsData[name] ?? [:], supportedTargetDict: supportedTargetsData[name] ?? [:])
            } catch {
                delegate.error(error)
                return nil
            }
        }

        let defaultDeploymentTarget = try? Version(items["DefaultDeploymentTarget"]?.stringValue ?? "")

        // Deal with the default variant, if there is one.
        var defaultVariant: SDKVariant? = nil
        if case .plString(let defaultVariantName)? = items["DefaultVariant"] {
            if defaultVariantName.isEmpty {
                delegate.error(path, "empty value for 'DefaultVariant' field")
                return nil
            }
            guard let variant = variants[defaultVariantName] else {
                delegate.error(path, "value of 'DefaultVariant' field, '\(defaultVariantName)', isn't the name of an SDK variant")
                return nil
            }
            defaultVariant = variant
        }

        // If the SDK did not specify a default variant, and has only one variant, that shall be its default.
        if defaultVariant == nil {
            defaultVariant = variants.only?.value
        }

        // An SDK shouldn't specify variants without a default; this should probably be an error but will start with a warning just in case.
        if !variants.isEmpty && defaultVariant == nil {
            delegate.warning(path, "SDK has variants but there is no default variant")
        }

        // Parse the header, framework and library search paths.  Emit a warning for any paths which are listed but which don't exist on disk.  (Warnings currently disabled, c.f. <<rdar://problem/34170562>>)
        var headerSearchPaths = [Path]()
        if case .plArray(let headerSearchPathsItems)? = items["HeaderSearchPaths"] {
            for item in headerSearchPathsItems {
                guard case .plString(let str) = item else { continue }
                let searchPath = path.join(str)
                guard localFS.exists(searchPath), localFS.isDirectory(searchPath) else {
                    // FIXME: <rdar://problem/34170562> Re-enable this when we want to warn about search paths an SDK declares which do not exist.
//                    delegate.warning(path, "header search path does not exist: \(searchPath.str)")
                    continue
                }
                headerSearchPaths.append(searchPath)
            }
        }
        var frameworkSearchPaths = [Path]()
        if case .plArray(let frameworkSearchPathsItems)? = items["FrameworkSearchPaths"] {
            for item in frameworkSearchPathsItems {
                guard case .plString(let str) = item else { continue }
                let searchPath = path.join(str)
                guard localFS.exists(searchPath), localFS.isDirectory(searchPath) else {
                    // FIXME: <rdar://problem/34170562> Re-enable this when we want to warn about search paths an SDK declares which do not exist.
//                    delegate.warning(path, "framework search path does not exist: \(searchPath.str)")
                    continue
                }
                frameworkSearchPaths.append(searchPath)
            }
        }
        var librarySearchPaths = [Path]()
        if case .plArray(let librarySearchPathsItems)? = items["LibrarySearchPaths"] {
            for item in librarySearchPathsItems {
                guard case .plString(let str) = item else { continue }
                let searchPath = path.join(str)
                guard localFS.exists(searchPath), localFS.isDirectory(searchPath) else {
                    // FIXME: <rdar://problem/34170562> Re-enable this when we want to warn about search paths an SDK declares which do not exist.
//                    delegate.warning(path, "library search path does not exist: \(searchPath.str)")
                    continue
                }
                librarySearchPaths.append(searchPath)
            }
        }

        var fallbackSettingConditionValues = [String]()
        if case .plArray(let conditionValues)? = items["PropertyConditionFallbackNames"] {
            for item in conditionValues {
                guard case .plString(let conditionValue) = item else { continue }
                fallbackSettingConditionValues.append(conditionValue)
            }
        }

        // Load the version information, if present.
        var version: Version? = nil
        if case .plString(let versionString)? = items["Version"] {
            do {
                version = try Version(versionString)
            }
            catch {
                delegate.error(path, "invalid 'Version' field: \(error)")
                return nil
            }
        }

        let versionInfoPath = path.join("System/Library/CoreServices/SystemVersion.plist")
        var productBuildVersion: String? = nil
        if localFS.exists(versionInfoPath) {
            do {
                let versionInfo = try PropertyList.fromPath(versionInfoPath, fs: localFS)
                if case .plDict(let items) = versionInfo {
                    if version == nil {
                        if case .plString(let versionString)? = items["Version"] ?? items["ProductVersion"] {
                            version = try Version(versionString)
                        }
                    }

                    if case .plString(let version)? = items["ProductBuildVersion"] {
                        productBuildVersion = version
                    }
                }
            } catch {
                delegate.warning(path, "unable to load SDK version info: '\(versionInfoPath.str)' was malformed: \(error)")
            }
        }

        var versionMap: [String:[Version:Version]] = [:]
        if case .plDict(let container)? = items["VersionMap"] {
            for (key, dict) in container {
                var mappings: [Version:Version] = [:]
                for (from, to) in dict.dictValue ?? [:] {
                    do {
                        mappings[try Version(from)] = try Version(to.stringValue ?? "")
                    }
                    catch {
                        delegate.warning("Unable to create version map for '\(key)' mapping '\(from)' to '\(to)' for SDK '\(displayName)'.")
                    }
                }

                versionMap[key] = mappings
            }
        }

        // Bind the SDK-specific directory macros.
        var directoryMacros = OrderedSet<StringMacroDeclaration>()
        // This macro contains the SDK's full canonical name, which could include a version number or other very specific information.
        do {
            directoryMacros.append(try delegate.namespace.declareStringMacro("SDK_DIR_" + canonicalName.asLegalCIdentifier))
        } catch {
            delegate.error("\(error)")
            return nil
        }
        // This macro contains just the SDK's base name, as parsed from the canonical name.  Note that if the canonical name is not in the format <basename><version><\.?suffix> then this won't be added.
        // This macro uses the "family identifier" of the SDK, which is useful for looking up an effective SDK if you don't know (or don't want to encode) the version number or information which might change from release to release.  For base SDKs, this will be the platform's family identifier.  Note that it's possible there won't be one of these for some SDKs.
        do {
            if let sdkNameComponents = try? parseSDKName(canonicalName) {
                directoryMacros.append(try delegate.namespace.declareStringMacro("SDK_DIR_" + sdkNameComponents.basename.asLegalCIdentifier))
            }
        }
        catch {
            delegate.error("\(error)")
            return nil
        }

        @preconcurrency @PluginExtensionSystemActor func extensions() -> [any SDKRegistryExtensionPoint.ExtensionProtocol] {
            delegate.pluginManager.extensions(of: SDKRegistryExtensionPoint.self)
        }

        // Construct the SDK and add it to the registry.
        let sdk = SDK(canonicalName, canonicalNameComponents: try? parseSDKName(canonicalName), aliases, cohortPlatforms, displayName, path, version, productBuildVersion, defaultSettings, overrideSettings, variants, defaultDeploymentTarget, defaultVariant, (headerSearchPaths, frameworkSearchPaths, librarySearchPaths), directoryMacros.elements, isBaseSDK, fallbackSettingConditionValues, toolchains, versionMap, maximumDeploymentTarget)
        if let duplicate = sdksByCanonicalName[canonicalName] {
            delegate.error(path, "SDK '\(canonicalName)' already registered from \(duplicate.path.str)")
            return nil
        }

        sdksByCanonicalName[canonicalName] = sdk

        for alias in sdk.aliases {
            self.sdksByAlias[alias] = (self.sdksByAlias[alias] ?? []) + [sdk]
        }

        sdksByPath[path] = sdk
        sdksByPath[pathResolved] = sdk

        platform?.sdks.append(sdk)

        return sdk
    }

    private static let ignoredSparseSdkSettingKeys = Set<String>([
        "ARCHS",
        "BUILD_VARIANTS",
        "CURRENT_ARCH",
        "PLATFORM_NAME",
        "SDKROOT"
    ])

    private static let ignoredSparseSdkSettingKeySuffixes = Set<String>([
        "_DEPLOYMENT_TARGET"
    ])

    /// Load the extended platform info.
    @_spi(Testing) public func loadExtendedInfo(_ namespace: MacroNamespace) {
        for sdk in sdksByCanonicalName.values {
            do {
                try sdk.loadExtendedInfo(namespace)
            } catch {
                delegate.error(error)
            }
        }
    }

    /// The list of all SDKs.
    public var allSDKs: AnyCollection<SDK> {
        return AnyCollection(sdksByCanonicalName.values)
    }

    public func lookup(_ canonicalName: String, activeRunDestination: RunDestinationInfo?) throws -> SDK? {
        // First, look for an exact match.
        if let sdk = sdksByCanonicalName[canonicalName] {
            return sdk
        }

        // Next, check aliases...
        let aliasedSDKs = sdksByAlias[canonicalName] ?? []
        if !aliasedSDKs.isEmpty {
            // If there's only a single match, we're done!
            if let sdk = aliasedSDKs.only {
                return sdk
            }

            // Next, group by cohort platform.
            // We could get here if we have DriverKit suffixed SDKs for multiple platforms, or multiple versions of any SDK.
            let (sdksByActivePlatform, ambiguous) = sdksForActiveRunDestination(aliasedSDKs, activeRunDestination)
            if ambiguous {
                throw AmbiguousSDKLookupError(canonicalName: canonicalName, candidateSDKs: aliasedSDKs, forRunDestination: false)
            }

            // If there are still multiple SDKs, we next try further grouping by version.
            // We could get here if we have multiple versions of DriverKit suffixed SDKs.
            return try sdksByActivePlatform.newestSDK(canonicalName: canonicalName)
        }

        // Check if this is a request for the boot system.
        if canonicalName == "" {
            return bootSystemSDK
        }

        // Otherwise, we're looking for an SDK using a placeholder which basically means "look for the newest-version SDK which has the same exact base name, matching suffixes".
        // Split the requested SDK into pieces.  If we can't, then we return nil.
        guard let components = try? parseSDKName(canonicalName) else {
            return nil
        }
        // If the version number in the components is present, then we return nil. A request for a version number needs to match by exact lookup.
        guard components.version == nil else {
            return nil
        }

        // Iterate through all of the SDKs looking for the best match.
        // We sort the values by canonical name in reverse-lexicographic order solely to ensure determinism in any potential weird edge cases someone might accidentally stumble into that we haven't considered.
        var matchedSDK: (sdk: SDK, components: SDK.CanonicalNameComponents)? = nil
        for candidateSDK in sdksByCanonicalName.values.sorted(by: { $0.canonicalName > $1.canonicalName }) {
            // Get the components for the candidate SDK.
            guard let candidateComponents = try? parseSDKName(candidateSDK.canonicalName) else {
                continue
            }

            // This SDK is a match if its basename matches the request basename, and their suffixes match.
            guard components.basename == candidateComponents.basename, components.suffix == candidateComponents.suffix else {
                continue
            }

            // If we've previously found a match, then we use this one instead if it looks like a better match.
            if let prevSDK = matchedSDK {
                // The best match is just the one with the newest version number.
                if candidateComponents.version ?? Version(0) > prevSDK.components.version ?? Version(0) {
                    matchedSDK = (candidateSDK, candidateComponents)
                }
            }
            else {
                matchedSDK = (candidateSDK, candidateComponents)
            }
        }

        // Xcode has special logic so that if there's no match here, and we'e *not* looking for a suffixed SDK, but we have an suffixed SDK which would otherwise match, then we use that. c.f. <rdar://problem/11414721> But we haven't needed that logic yet in Swift Build, so maybe we never will.

        return matchedSDK?.sdk
    }

    public func lookup(_ path: Path) -> SDK? {
        #if !os(Windows)
        // TODO: Turn this validation back on once our path handling is cleaned up a bit more
        precondition(path.isAbsolute, "\(path.str) is not absolute")
        #endif

        // First see if we already have it in the cache.
        if let sdk = sdksByPath[path] {
            return sdk
        }

        guard let pathResolved = try? localFS.realpath(path) else {
            return nil
        }

        if let sdk = sdksByPath[pathResolved] {
            return sdk
        }

        // If we don't have it cached, then we load it, if the registry is not immutable.  (If it is immutable, then we can't load more SDKs after the registry has been initialized, so we return nil.)
        guard !type.isImmutable else { return nil }

        // We're strict and require it have a .sdk suffix.
        guard path.fileSuffix == ".sdk" else { return nil }

        // Load the SDK.  We don't associate it with a platform.
        guard let sdk = registerSDK(path, pathResolved, nil) else { return nil }

        do {
            try sdk.loadExtendedInfo(delegate.namespace)
        } catch {
            delegate.error(error)
        }

        return sdk
    }

    public func lookup(nameOrPath key: String, basePath: Path, activeRunDestination: RunDestinationInfo?) throws -> SDK? {
        #if !os(Windows)
        // TODO: Turn this validation back on once our path handling is cleaned up a bit more
        precondition(basePath.isAbsolute, "\(basePath.str) is not absolute")
        #endif

        // Check if this is a request for the boot system SDK.
        if key == "" || key == "/" {
            return bootSystemSDK
        }

        // If the key looks like a path, always resolve it as such.
        let keyPath = Path(key)
        if !keyPath.dirname.isEmpty {
            return self.lookup(keyPath.isAbsolute ? keyPath : basePath.join(key))
        }

        // Otherwise, attempt to resolve the SDK as a canonical name.
        if let sdk = try lookup(key, activeRunDestination: activeRunDestination) {
            return sdk
        }

        // Finally, if that failed, try as a relative path to the base directory.
        return self.lookup(basePath.join(key))
    }

    private func sdksForActiveRunDestination(_ allSDKs: [SDK], _ activeRunDestination: RunDestinationInfo?) -> (sdksByActivePlatform: [SDK], ambiguous: Bool) {
        // This function is only ever called with a non-empty list
        assert(!allSDKs.isEmpty)

        let sdksByCohortPlatform: [String?: [SDK]] = {
            var dict = [String?: [SDK]]()
            for sdk in allSDKs {
                if !sdk.cohortPlatforms.isEmpty {
                    for cohortPlatform in sdk.cohortPlatforms {
                        dict[cohortPlatform, default: []].append(sdk)
                    }
                } else {
                    dict[nil, default: []].append(sdk)
                }
            }
            return dict
        }()

        let sdksByActivePlatform: [SDK]
        if sdksByCohortPlatform.count > 1 {
            // If we got here, we have DriverKit SDKs (the only ones which use cohort platforms) for multiple cohort platforms. Narrow down the list by disambiguating using the run destination.

            func selectSDKList() -> [SDK]? {
                if let list = sdksByCohortPlatform[activeRunDestination?.platform] {
                    return list
                }

                // In addition to disambiguating by the run destination's own platform, we also need to disambiguate
                // by the cohort platforms of the run destination's SDK's platform. This is necessary to resolve
                // driverkit when we have a DriverKit run destination but with a platform-specific SDK.
                if let runDestination = activeRunDestination,
                   let cohortPlatforms = try? lookup(runDestination.sdk, activeRunDestination: nil)?.cohortPlatforms {
                    for cohortPlatform in cohortPlatforms {
                        if let list = sdksByCohortPlatform[cohortPlatform] {
                            return list
                        }
                    }
                }

                return nil
            }

            guard let sdks = selectSDKList() else {
                // We either don't have a run destination, or we have a run destination that isn't disambiguating.
                return (allSDKs, true)
            }

            // The candidate list is now the SDKs whose cohort platform matches the run destination.
            sdksByActivePlatform = sdks
        } else {
            // The candidate list is now the SDKs of the sole cohort platform (we must have multiple versions of some SDK).
            // The list is guaranteed to not be empty (and therefore must have a single entry), since sdksForActiveRunDestination is only ever called with a non-empty list (as asserted at the beginning of the method).
            assert(sdksByCohortPlatform.count == 1)
            sdksByActivePlatform = sdksByCohortPlatform.values.flatMap { $0 }
        }

        return (sdksByActivePlatform, false)
    }

    func supportedSDKCanonicalNameSuffixes() -> Set<String> {
        @preconcurrency @PluginExtensionSystemActor func extensions() -> [any SDKRegistryExtensionPoint.ExtensionProtocol] {
            delegate.pluginManager.extensions(of: SDKRegistryExtensionPoint.self)
        }
        var suffixes: Set<String> = []
        for `extension` in extensions() {
            suffixes.formUnion(`extension`.supportedSDKCanonicalNameSuffixes)
        }
        return suffixes
    }

    // MARK: CustomStringConvertible conformance


    public var description: String {
        return "<\(Swift.type(of: self)):\(self.type)>"

    }
}

public struct AmbiguousSDKLookupError: Hashable, Error {
    let canonicalName: String
    let candidateSDKs: [SDK]
    let forRunDestination: Bool

    var diagnostic: Diagnostic {
        let prefix = forRunDestination ? "unable to resolve run destination SDK:" : "unable to resolve SDK:"
        return Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("\(prefix) multiple SDKs match alias '\(canonicalName)'"), childDiagnostics: candidateSDKs.sorted(by: \.canonicalName).map { sdk in
            Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Candidate '\(sdk.canonicalName)' at path '\(sdk.path.str)'"))
        })
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalName)
        hasher.combine(Set(candidateSDKs.map(\.canonicalName)))
        hasher.combine(forRunDestination)
    }

    public static func == (lhs: AmbiguousSDKLookupError, rhs: AmbiguousSDKLookupError) -> Bool {
        return lhs.canonicalName == rhs.canonicalName && Set(lhs.candidateSDKs.map(\.canonicalName)) == Set(rhs.candidateSDKs.map(\.canonicalName)) && lhs.forRunDestination == rhs.forRunDestination
    }
}

private extension Array where Element == SDK {
    /// Looks up the newest SDK in the array of SDKs (which should already represent different versions of the same logical SDK). Throws an error if there is more than one SDK with the same version number.
    func newestSDK(canonicalName: String) throws -> SDK? {
        let group = Dictionary(grouping: self, by: { sdk in sdk.version })
        let multiples = group.values.filter({ sdks in sdks.count > 1 })
        if !multiples.isEmpty {
            throw AmbiguousSDKLookupError(canonicalName: canonicalName, candidateSDKs: multiples.flatMap { $0 }, forRunDestination: false)
        }
        return group.compactMap({ (version, sdks) -> SDK? in sdks.only }).sorted(by: { ($0.version ?? Version()) > ($1.version ?? Version()) }).first
    }
}
