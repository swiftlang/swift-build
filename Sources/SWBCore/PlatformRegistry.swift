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

import SWBLibc
public import SWBUtil

import struct Foundation.CharacterSet
import class Foundation.ProcessInfo
public import SWBMacro

/// Delegate protocol used to access external information (such as specifications) and to report diagnostics.
@_spi(Testing) public protocol PlatformRegistryDelegate: DiagnosticProducingDelegate, SpecRegistryProvider {
    var pluginManager: PluginManager { get }

    var developerPath: Core.DeveloperPath { get }
}

public final class Platform: Sendable {
    /// The name of the platform.
    public let name: String

    /// The display name of the platform.
    public let displayName: String

    /// The family name of the platform.
    public let familyName: String

    /// The family display name. For example, 'visionOS' when the family name is 'xrOS'
    public let familyDisplayName: String

    /// The identifier of the platform.
    public let identifier: String

    /// The path of the platform.
    public let path: Path

    /// The version of the platform, if specified.
    @_spi(Testing) public let version: String?

    /// The platform product build version.
    public let productBuildVersion: String?

    /// The default build settings.
    public let defaultSettings: [String: PropertyListItem]

    /// The parse default build settings table.
    public fileprivate(set) var defaultSettingsTable: MacroValueAssignmentTable! = nil

    /// Whether this is a platform for which real products are deployed. This will be `true` for most platforms, but `false` for a few such as simulators.
    public let isDeploymentPlatform: Bool

    // The entries which get added to the Info.plist of products build against this platform.
    public let additionalInfoPlistEntries: [String: PropertyListItem]

    /// Specification registry provider.
    public let specRegistryProvider: any SpecRegistryProvider

    /// The platform preferred architecture.
    public let preferredArch: String?

    /// The name of the deployment target build setting for this platform.
    public fileprivate(set) var deploymentTargetMacro: StringMacroDeclaration? = nil

    /// Minimum OS version for Swift-in-the-OS support. If this is `nil`, the platform does not support Swift-in-the-OS at all.
    fileprivate(set) var minimumOSForSwiftInTheOS: Version? = nil

    /// Minimum OS version for built-in Swift concurrency support. If this is `nil`, the platform does not support Swift concurrency at all.
    fileprivate(set) var minimumOSForSwiftConcurrency: Version? = nil

    /// The canonical name of the public SDK for this platform.
    /// - remark: This does not mean that this SDK exists, just that this is its canonical name if it does exist.
    @_spi(Testing) public let sdkCanonicalName: String?

    /// The corresponding device platform name, for simulator-like platforms.
    let correspondingDevicePlatformName: String?

    /// The corresponding simulator platform name, if available.
    let correspondingSimulatorPlatformName: String?

    /// The corresponding device platform, for simulator-like platforms. Bound via platform registry setup.
    fileprivate(set) weak var correspondingDevicePlatform: Platform? = nil

    /// The corresponding simulator platform, if available. Bound via platform registry setup.
    fileprivate(set) weak var correspondingSimulatorPlatform: Platform? = nil

    /// Whether this is a simulator platform or not.
    public var isSimulator: Bool {
        return correspondingDevicePlatformName != nil
    }

    /// The type of platform for the purposes of signing.
    @_spi(Testing) public var signingContext: any PlatformSigningContext {
        return signingContextCache.getValue(self)
    }
    private let signingContextCache = LazyCache { (platform: Platform) -> (any PlatformSigningContext) in
        if platform.isSimulator {
            return SimulatorSigningContext()
        }

        if platform.name == "macosx" {
            return MacSigningContext()
        }

        return DeviceSigningContext()
    }

    public var deploymentTargetRange: VersionRange {
        return deploymentTargetsCache.getValue(self).range
    }

    private var deploymentTargetsCache = LazyCache { (platform: Platform) -> (targets: [String], range: VersionRange) in
        func addValues(_ values: inout Set<String>, _ from: PropertyListItem?) {
            if case .plArray(let items)? = from {
                for item in items {
                    if case .plString(let value) = item {
                        values.insert(value)
                    }
                }
            }
        }

        func sdkDeploymentTargetMatchesPlatform(_ sdk: SDK, _ platform: Platform) -> Bool {
            let dtsn = "DEPLOYMENT_TARGET_SETTING_NAME"
            let platformDeploymentTargetSettingName = platform.defaultSettings[dtsn]
            let sdkDeploymentTargetSettingName = sdk.overrideSettings[dtsn] ?? sdk.defaultSettings[dtsn]
            return sdkDeploymentTargetSettingName == nil || platformDeploymentTargetSettingName == sdkDeploymentTargetSettingName
        }

        // Combine all of the values from the platform and each SDK.
        var values = Set<String>()
        addValues(&values, platform.defaultSettings["DEPLOYMENT_TARGET_SUGGESTED_VALUES"])
        for sdk in platform.sdks where sdkDeploymentTargetMatchesPlatform(sdk, platform) {
            addValues(&values, sdk.overrideSettings["DEPLOYMENT_TARGET_SUGGESTED_VALUES"])
            addValues(&values, sdk.defaultSettings["DEPLOYMENT_TARGET_SUGGESTED_VALUES"])
        }

        var result = [String](values)
        result.sort(by:) { (lhs,rhs) in
            // Compare as versions.
            let lhsNums = lhs.split(separator: ".").compactMap { Int($0) }
            let rhsNums = rhs.split(separator: ".").compactMap { Int($0) }
            return !lhsNums.lexicographicallyPrecedes(rhsNums)
        }

        var range = VersionRange()
        if let newest = result.first, let oldest = result.last {
            do {
                range = try VersionRange(start: try Version(oldest), end: try Version(newest))
            } catch {
                // ignore error for now
            }
        }

        // Add the maximum deployment target to the deployment targets *range* (if it's newer than what it contains) without adding it to the list of deployment targets.
        for sdk in platform.sdks where sdkDeploymentTargetMatchesPlatform(sdk, platform) {
            if let maximumDeploymentTarget = sdk.maximumDeploymentTarget, let end = range.end, maximumDeploymentTarget > end {
                if let start = range.start {
                    do {
                        range = try VersionRange(start: start, end: maximumDeploymentTarget)
                    } catch {
                        // ignore error for now
                    }
                } else {
                    range = VersionRange(end: maximumDeploymentTarget)
                }
            }
        }

        return (result, range)
    }

    /// The list of SDKs present in the platform.  These get added by the `SDKRegistry` as SDKs are loaded.
    @_spi(Testing) public var sdks: [SDK] = []

    /// The list of executable search paths in the platform.
    @_spi(Testing) public var executableSearchPaths: StackedSearchPath

    var sdkSearchPaths: [Path]

    init(_ name: String, _ displayName: String, _ familyName: String, _ familyDisplayName: String?, _ identifier: String, _ devicePlatformName: String?, _ simulatorPlatformName: String?, _ path: Path, _ version: String?, _ productBuildVersion: String?, _ defaultSettings: [String: PropertyListItem], _ additionalInfoPlistEntries: [String: PropertyListItem], _ isDeploymentPlatform: Bool, _ specRegistryProvider: any SpecRegistryProvider, preferredArchValue: String?, executableSearchPaths: [Path], sdkSearchPaths: [Path], fs: any FSProxy) {
        self.name = name
        self.displayName = displayName
        self.familyName = familyName
        self.familyDisplayName = familyDisplayName ?? familyName
        self.identifier = identifier
        self.correspondingDevicePlatformName = name != devicePlatformName ? devicePlatformName : nil
        self.correspondingSimulatorPlatformName = name != simulatorPlatformName ? simulatorPlatformName : nil
        self.path = path
        self.version = version
        self.productBuildVersion = productBuildVersion
        self.defaultSettings = defaultSettings
        self.additionalInfoPlistEntries = additionalInfoPlistEntries
        self.isDeploymentPlatform = isDeploymentPlatform
        self.specRegistryProvider = specRegistryProvider
        self.preferredArch = preferredArchValue
        self.executableSearchPaths = StackedSearchPath(paths: executableSearchPaths, fs: fs)
        self.sdkSearchPaths = sdkSearchPaths
        self.sdkCanonicalName = name
    }

    /// Perform late binding of the SDK data.
    fileprivate func loadExtendedInfo(_ namespace: MacroNamespace) throws {
        assert(defaultSettingsTable == nil)
        do {
            defaultSettingsTable = try namespace.parseTable(defaultSettings, allowUserDefined: true)
        } catch {
            throw StubError.error("unexpected macro parsing failure loading platform \(identifier): \(error)")
        }
    }
}

extension Platform: SpecLookupContext {
    public var specRegistry: SpecRegistry {
        return specRegistryProvider.specRegistry
    }

    public var platform: Platform? {
        return self
    }
}

extension Platform {
    fileprivate func swiftOSVersion(_ deploymentTarget: StringMacroDeclaration, forceNextMajorVersion: Bool) -> Version? {
        if BuiltinMacros.MACOSX_DEPLOYMENT_TARGET == deploymentTarget && forceNextMajorVersion {
            // NOTE: Due to how the rpaths are rewritten by the swift compiler, the update version of the OS (e.g. the .4 in 10.14.4) cannot be checked against. In these cases, the next major version needs to be returned. It's hard-coded to 10.15 in this case because we've already shipped both 10.14.4 and 10.15.
            return Version(10, 15)
        }

        // return platform-provided value or nil if Swift-in-the-OS is not supported for this platform; also, if we are given a simulator, the device fallback should be used.
        return self.minimumOSForSwiftInTheOS ?? self.correspondingDevicePlatform?.minimumOSForSwiftInTheOS ?? nil
    }

    /// Determines the deployment version to use for Swift's concurrency support.
    fileprivate func swiftOSCurrencyVersion(_ deploymentTarget: StringMacroDeclaration) -> Version? {
        return self.minimumOSForSwiftConcurrency ?? self.correspondingDevicePlatform?.minimumOSForSwiftConcurrency ?? nil
    }

    /// Determines if the platform supports Swift in the OS.
    public func supportsSwiftInTheOS(_ scope: MacroEvaluationScope, forceNextMajorVersion: Bool = false, considerTargetDeviceOSVersion: Bool = true) -> Bool {
        guard let deploymentTarget = self.deploymentTargetMacro else { return false }

        // If we have target device info and its platform matches the build platform, compare the device OS version
        let targetDeviceVersion: Version?
        if considerTargetDeviceOSVersion && scope.evaluate(BuiltinMacros.TARGET_DEVICE_PLATFORM_NAME) == self.name {
            targetDeviceVersion = try? Version(scope.evaluate(BuiltinMacros.TARGET_DEVICE_OS_VERSION))
        } else {
            targetDeviceVersion = nil
        }

        // Otherwise fall back to comparing the minimum deployment target
        let deploymentTargetVersion = try? Version(scope.evaluate(deploymentTarget))

        guard let version = targetDeviceVersion ?? deploymentTargetVersion else { return false }
        guard let minimumSwiftInTheOSVersion = swiftOSVersion(deploymentTarget, forceNextMajorVersion: forceNextMajorVersion) else { return false }

        return version >= minimumSwiftInTheOSVersion
    }

    /// Determines if the platform natively supports Swift concurrency. If `false`, then the Swift back-compat concurrency libs needs to be copied into the app/framework's bundle.
    public func supportsSwiftConcurrencyNatively(_ scope: MacroEvaluationScope, forceNextMajorVersion: Bool = false, considerTargetDeviceOSVersion: Bool = true) -> Bool? {
        guard let deploymentTarget = self.deploymentTargetMacro else { return false }

        // If we have target device info and its platform matches the build platform, compare the device OS version
        let targetDeviceVersion: Version?
        if considerTargetDeviceOSVersion && scope.evaluate(BuiltinMacros.TARGET_DEVICE_PLATFORM_NAME) == self.name {
            targetDeviceVersion = try? Version(scope.evaluate(BuiltinMacros.TARGET_DEVICE_OS_VERSION))
        } else {
            targetDeviceVersion = nil
        }

        // Otherwise fall back to comparing the minimum deployment target
        let deploymentTargetVersion = try? Version(scope.evaluate(deploymentTarget))

        guard let version = targetDeviceVersion ?? deploymentTargetVersion else { return false }

        // Return `nil` here as there is no metadata for the platform to allow downstream clients to be aware of this.
        guard let minimumSwiftConcurrencyVersion = swiftOSCurrencyVersion(deploymentTarget) else { return nil }

        return version >= minimumSwiftConcurrencyVersion
    }
}

extension Platform: CustomStringConvertible {
    public var description: String {
        return "\(type(of: self))(name: '\(name)', identifier: '\(identifier)', path: '\(path.str)', version: '\(String(describing: version))')"
    }
}

/// The PlatformRegistry manages the set of registered platforms.
public final class PlatformRegistry {
    /// The delegate.
    let delegate: any PlatformRegistryDelegate

    /// The list of all registered platforms, ordered by identifier.
    public private(set) var platforms = Array<Platform>()

    /// The map of platforms by identifier.
    @_spi(Testing) public private(set) var platformsByIdentifier = Dictionary<String, Platform>()

    /// The map of platforms by name.
    var platformsByName = Dictionary<String, Platform>()

    /// The set of all known deployment target macro names, even if the platforms that use those settings are not installed.
    private(set) var allDeploymentTargetMacroNames = Set<String>()

    /// The default deployment targets for all installed platforms.
    var defaultDeploymentTargets: [String: Version] {
        Dictionary(uniqueKeysWithValues: Dictionary(grouping: platforms, by: { $0.defaultSDKVariant?.deploymentTargetSettingName })
            .sorted(by: \.key)
            .compactMap { (key, value) in
                guard let key, let value = Set(value.compactMap { $0.defaultSDKVariant?.defaultDeploymentTarget }).only else {
                    return nil
                }
                return (key, value)
            })
    }

    @_spi(Testing) public init(delegate: any PlatformRegistryDelegate, searchPaths: [Path], hostOperatingSystem: OperatingSystem, fs: any FSProxy) async {
        self.delegate = delegate

        for path in searchPaths {
            await registerPlatformsInDirectory(path, fs)
        }

        @preconcurrency @PluginExtensionSystemActor func platformInfoExtensions() async -> [any PlatformInfoExtensionPoint.ExtensionProtocol] {
            return delegate.pluginManager.extensions(of: PlatformInfoExtensionPoint.self)
        }

        struct Context: PlatformInfoExtensionAdditionalPlatformsContext {
            var hostOperatingSystem: OperatingSystem
            var developerPath: Core.DeveloperPath
            var fs: any FSProxy
        }

        for platformExtension in await platformInfoExtensions() {
            do {
                for (path, data) in try platformExtension.additionalPlatforms(context: Context(hostOperatingSystem: hostOperatingSystem, developerPath: delegate.developerPath, fs: fs)) {
                    await registerPlatform(path, .plDict(data), fs)
                }
            } catch {
                delegate.error(error)

            }
        }
    }

    private func loadDeploymentTargetMacroNames() {
        // We must have loaded the extended platform info before doing this,
        // since deploymentTargetMacro is set on the Platform objects through there.
        precondition(hasLoadedExtendedInfo)

        // Set up allDeploymentTargetMacroNames in stages to detect issues.
        // First we add all deployment targets from installed platforms, and emit a warning if multiple platforms declare that they use the same deployment target.
        var platformsByDeploymentTarget = [String: Set<String>]()
        for platform in platforms {
            if let macroName = platform.deploymentTargetMacro?.name, !macroName.isEmpty {
                allDeploymentTargetMacroNames.insert(macroName)

                // Don't count simulator platforms separately, as a simulator platform always shares a deployment target with its corresponding device platform.
                platformsByDeploymentTarget[macroName, default: Set<String>()].insert(platform.correspondingDevicePlatform?.name ?? platform.name)
            }
        }

        // Now add in all deployment targets we know about.  This is because clang also knows about these deployment targets intrinsically when they are passed as environment variables, so we sometimes need to work with them even if the platform which defines them is not installed.
        @preconcurrency @PluginExtensionSystemActor func platformInfoExtensions() -> [any PlatformInfoExtensionPoint.ExtensionProtocol] {
            delegate.pluginManager.extensions(of: PlatformInfoExtensionPoint.self)
        }

        for platformExtension in platformInfoExtensions() {
            for knownDeploymentTargetMacroName in platformExtension.knownDeploymentTargetMacroNames() {
                allDeploymentTargetMacroNames.insert(knownDeploymentTargetMacroName)
                platformsByDeploymentTarget[knownDeploymentTargetMacroName] = nil
            }
        }

        // For any macros left in the dictionary, emit a warning that it's a deployment target macro we didn't know about so we can add them to the list above in the future.
        for macroName in platformsByDeploymentTarget.keys.sorted() {
            guard let platformNames = platformsByDeploymentTarget[macroName], !platformNames.isEmpty else {
                // This is a weird scenario - should we emit a warning here?
                continue
            }
            let platformList: String = (platformNames.count > 1 ? "s: " : ": ") + platformNames.sorted().joined(separator: ", ")
            delegate.warning("found previously-unknown deployment target macro '\(macroName)' declared by platform\(platformList)")
        }
    }

    /// Register all platforms in the given directory.
    private func registerPlatformsInDirectory(_ path: Path, _ fs: any FSProxy) async {
        for item in (try? localFS.listdir(path))?.sorted(by: <) ?? [] {
            let itemPath = path.join(item)

            // Check if this is a platform we should load
            guard itemPath.fileSuffix == ".platform" else { continue }

            let infoPath = itemPath.join("Info.plist")

            // Load the platform info.
            do {
                let infoPlist: PropertyListItem
                do {
                    infoPlist = try PropertyList.fromBytes(localFS.read(infoPath).bytes)
                } catch let e as POSIXError where e.code == ENOENT {
                    // Silently skip loading the platform if it does not have an Info.plist at all.  (We will still error below if it has an Info.plist which is malformed.)
                    continue
                }
                await registerPlatform(itemPath, infoPlist, fs)
            } catch let err {
                delegate.error(itemPath, "unable to load platform: 'Info.plist' was malformed: \(err)")
            }
        }
    }

    private func registerPlatform(_ path: Path, _ data: PropertyListItem, _ fs: any FSProxy) async {
        // The data should always be a dictionary.
        guard case .plDict(let items) = data else {
            delegate.error(path, "unexpected platform data")
            return
        }

        // Check that type is correct.
        guard case .plString(let typeName)? = items["Type"], typeName == "Platform" else {
            delegate.error(path, "invalid 'Type' field")
            return
        }

        // Get the name.
        guard let nameItem = items["Name"] else {
            delegate.error(path, "missing 'Name' field")
            return
        }
        guard case .plString(let name) = nameItem else {
            delegate.error(path, "invalid 'Name' field")
            return
        }

        // Get the identifier.
        guard let identifierItem = items["Identifier"] else {
            delegate.error(path, "missing 'Identifier' field")
            return
        }
        guard case .plString(let identifier) = identifierItem else {
            delegate.error(path, "invalid 'Identifier' field")
            return
        }

        // Get the version.
        var version: String? = nil
        if let versionItem = items["Version"] {
            guard case .plString(let value) = versionItem else {
                delegate.error(path, "invalid 'Version' field")
                return
            }
            version = value
        }

        // Get the display name.
        guard let displayNameItem = items["Description"] else {
            delegate.error(path, "missing 'Description' field")
            return
        }
        guard case .plString(let displayName) = displayNameItem else {
            delegate.error(path, "invalid 'Description' field")
            return
        }

        // Get the family name.
        guard let familyNameItem = items["FamilyName"] else {
            delegate.error(path, "missing 'FamilyName' field")
            return
        }
        guard case .plString(let familyName) = familyNameItem else {
            delegate.error(path, "invalid 'FamilyName' field")
            return
        }
        let familyDisplayName: String?
        if case .plString(let familyDisplayNameString) = items["FamilyDisplayName"] {
            familyDisplayName = familyDisplayNameString
        } else {
            familyDisplayName = nil
        }
        guard let familyIdentifierItem = items["FamilyIdentifier"] else {
            delegate.error(path, "missing 'FamilyIdentifier' field")
            return
        }
        guard case .plString(let familyIdentifier) = familyIdentifierItem else {
            delegate.error(path, "invalid 'FamilyIdentifier' field")
            return
        }
        if let onlyLoadPlatformFamilyNames = getEnvironmentVariable("XCODE_ONLY_PLATFORM_FAMILY_NAMES")?.split(separator: " ").map(String.init), !onlyLoadPlatformFamilyNames.contains(familyIdentifier) {
            return
        }

        let devicePlatformName: String?
        let simulatorPlatformName: String?
        if let familyPlatforms = items["FamilyPlatforms"]?.dictValue {
            devicePlatformName = familyPlatforms["Device"]?.stringValue
            simulatorPlatformName = familyPlatforms["Simulator"]?.stringValue
            switch (devicePlatformName, simulatorPlatformName) {
            case (nil, nil):
                break
            case let (devicePlatformName?, simulatorPlatformName?):
                if devicePlatformName == simulatorPlatformName {
                    delegate.error(path, "'Device' and 'Simulator' fields in 'FamilyPlatforms' must not be equal")
                    return
                } else if devicePlatformName != name && simulatorPlatformName != name {
                    delegate.error(path, "one of 'Device' or 'Simulator' fields in 'FamilyPlatforms' must be equal to 'Name'")
                    return
                }
            case (nil, .some(_)):
                delegate.error(path, "missing 'Device' field in 'FamilyPlatforms'")
                return
            case (.some(_), nil):
                delegate.error(path, "missing 'Simulator' field in 'FamilyPlatforms'")
                return
            }
        } else {
            devicePlatformName = nil
            simulatorPlatformName = nil
        }

        // Parse the default build settings.
        var defaultSettings: [String: PropertyListItem] = [:]
        if case .plDict(let defaultSettingsItems)? = items["DefaultProperties"] {
            defaultSettings = defaultSettingsItems

            // Rev-lock: rdar://85769354 (Remove DEPLOYMENT_TARGET_CLANG_* properties from SDK)
            for macroName in [
                "DEPLOYMENT_TARGET_CLANG_ENV_NAME",
                "DEPLOYMENT_TARGET_CLANG_FLAG_NAME",
                "DEPLOYMENT_TARGET_CLANG_FLAG_PREFIX",
            ] { defaultSettings.removeValue(forKey: macroName) }
        }

        // Parse whether this is a deployment platform.
        let isDeploymentPlatform = items["IsDeploymentPlatform"]?.looselyTypedBoolValue ?? true

        // Parse the entries which get added to the Info.plist of products build against this platform.  This should be a flat dictionary of keys to parseable strings.
        // Note that we DO NOT need to parse the items here as MacroExpressions.  They will get merged in to the product's Info.plist, which will then be parsed for evaluation.  So not expanding them here makes for simpler logic at both points, and there are not enough of these values that parsing them for each build will take significant time.
        var additionalInfoPlistEntries: [String: PropertyListItem] = [:]
        if case .plDict(let additionalInfoPlistEntriesItems)? = items["AdditionalInfo"] {
            additionalInfoPlistEntries = additionalInfoPlistEntriesItems
        }

        // Load the version information, if present.
        let versionInfoPath = path.join("version.plist")
        var productBuildVersion: String? = nil
        if localFS.exists(versionInfoPath) {
            do {
                let versionInfo = try PropertyList.fromPath(versionInfoPath, fs: localFS)
                if case .plDict(let items) = versionInfo {
                    if case .plString(let version)? = items["ProductBuildVersion"] {
                        productBuildVersion = version
                    }
                }
            } catch {
                delegate.warning(path, "unable to load platform version info: '\(versionInfoPath.str)' was malformed: \(error)")
            }
        }

        let preferredArchValue: String? = await {
            let values = await Set(platformInfoExtensions().asyncMap { $0.preferredArchValue(for: name) }).compactMap { $0 }
            if values.count > 1 {
                delegate.error(path, "platform '\(identifier)' has conflicting preferred arch values: \(values.sorted().joined(separator: ", "))")
            }
            return values.only
        }()

        @preconcurrency @PluginExtensionSystemActor func platformInfoExtensions() -> [any PlatformInfoExtensionPoint.ExtensionProtocol] {
            delegate.pluginManager.extensions(of: PlatformInfoExtensionPoint.self)
        }

        var executableSearchPaths: [Path] = [
            path.join("usr").join("bin"),
        ]

        var sdkSearchPaths: [Path] = [
            path.join("Developer").join("SDKs")
        ]

        for platformExtension in await platformInfoExtensions() {
            await executableSearchPaths.append(contentsOf: platformExtension.additionalPlatformExecutableSearchPaths(platformName: name, platformPath: path, fs: localFS))

            platformExtension.adjustPlatformSDKSearchPaths(platformName: name, platformPath: path, sdkSearchPaths: &sdkSearchPaths)

        }

        executableSearchPaths.append(contentsOf: [
            path.join("usr").join("local").join("bin"),
            path.join("Developer").join("usr").join("bin"),
            path.join("Developer").join("usr").join("local").join("bin")
        ])

        // FIXME: Need to parse other fields. It would also be nice to diagnose unused keys like we do for Spec data (and we might want to just use the spec parser here).
        let platform = Platform(name, displayName, familyName, familyDisplayName, identifier, devicePlatformName, simulatorPlatformName, path, version, productBuildVersion, defaultSettings, additionalInfoPlistEntries, isDeploymentPlatform, delegate, preferredArchValue: preferredArchValue, executableSearchPaths: executableSearchPaths, sdkSearchPaths: sdkSearchPaths, fs: fs)
        if let duplicatePlatform = platformsByIdentifier[identifier] {
            delegate.error(path, "platform '\(identifier)' already registered from \(duplicatePlatform.path.str)")
            return
        }
        if let duplicatePlatform = platformsByName[name] {
            delegate.error(path, "platform '\(identifier)' with name '\(name)' already registered from \(duplicatePlatform.path.str)")
            return
        }

        // Add the platform.
        platforms.append(platform)
        platforms.sort(by: { $0.identifier < $1.identifier })

        // Update the maps.
        platformsByIdentifier[platform.identifier] = platform
        platformsByName[platform.name] = platform
    }

    private func unregisterPlatform(_ platform: Platform) {
        platforms.removeAll(where: { $0 === platform })

        platformsByIdentifier.removeValue(forKey: platform.identifier)
        platformsByName.removeValue(forKey: platform.name)
    }

    /// Look up the platform with the given identifier.
    public func lookup(identifier: String) -> Platform? {
        return platformsByIdentifier[identifier]
    }

    /// Look up the platform with the given name.
    public func lookup(name: String) -> Platform? {
        return platformsByName[name]
    }

    /// Determines if a given platform is one of the set of required platforms.
    private func isPlatformRequired(identifier: String) -> Bool {
        // NOTE: An important use-case to consider are internal installs of Xcode that only contains a partial set of platform toolchains. Currently there are no required platforms, but this logic would need to be placed in multiple locations and could easily be missed. Do not remove this function unless you are sure this check would no longer be required.
        // IMPORTANT: Platforms are registered by both name and identifier. If this method is updated, please update `isPlatformRequired(name:)` as appropriate.
        return false
    }

    /// See `isPlatformRequired(identifier:)`.
    private func isPlatformRequired(name: String) -> Bool {
        return false
    }


    /// Load the extended platform info.
    @_spi(Testing) public func loadExtendedInfo(_ namespace: MacroNamespace) {
        precondition(!hasLoadedExtendedInfo)
        hasLoadedExtendedInfo = true

        // FIXME: Consider removing deployment target macro from Platform entirely and forcing clients to go through SDKVariant instead, but that's a bigger change especially with the Mac Catalyst inconsistency between using MACOSX_DEPLOYMENT_TARGET in some places and IPHONEOS_DEPLOYMENT_TARGET in others.
        for platform in platforms {
            let baseSDKs = platform.sdks.filter(\.isBaseSDK)
            let deploymentTargets = Set(baseSDKs.map(\.defaultVariant?.deploymentTargetSettingName).compactMap({ $0 }))
            if let value = deploymentTargets.only {
                do {
                    platform.deploymentTargetMacro = try namespace.declareStringMacro(value)
                } catch {
                    delegate.error("error registering deployment target setting name macro '\(value)': \(error)")
                }
            } else if !deploymentTargets.isEmpty {
                delegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Multiple deployment targets for platform '\(platform.name)'"), childDiagnostics: baseSDKs.sorted(by: \.canonicalName).compactMap { baseSDK in
                    guard let deploymentTargetSettingName = baseSDK.defaultVariant?.deploymentTargetSettingName else {
                        return nil
                    }
                    return Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("\(deploymentTargetSettingName), defined by SDK '\(baseSDK.canonicalName)'"))
                }))
            }

            if let variant = platform.defaultSDKVariant {
                platform.minimumOSForSwiftInTheOS = variant.minimumOSForSwiftInTheOS
                platform.minimumOSForSwiftConcurrency = variant.minimumOSForSwiftConcurrency
            }
        }

        // Perform late binding.
        for platform in platformsByName.values {
            do {
                platform.correspondingDevicePlatform = lookupCorrespondingPlatform(platform, \.correspondingDevicePlatformName)
                platform.correspondingSimulatorPlatform = lookupCorrespondingPlatform(platform, \.correspondingSimulatorPlatformName)
                try platform.loadExtendedInfo(namespace)
            } catch {
                delegate.warning("\(error)")
                unregisterPlatform(platform)
            }
        }

        loadDeploymentTargetMacroNames()
    }
    var hasLoadedExtendedInfo = false

    private func lookupCorrespondingPlatform(_ platform: Platform, _ predicate: (Platform) -> String?) -> Platform? {
        if let name = predicate(platform), let otherPlatform = lookup(name: name) {
            return otherPlatform
        }
        return nil
    }
}

extension Platform {
    fileprivate static let defaultArchsForIndexArena: [String] = ["arm64e", "arm64", "x86_64"]

    /// Determines the default architecture to use for the index arena build, preferring `preferredArch` if valid on this platform or the first "Standard" architecture otherwise.
    @_spi(Testing) public func determineDefaultArchForIndexArena(preferredArch: String?, using core: Core) -> String? {
        if let preferredArch,
           core.specRegistry.getSpec(preferredArch, domain: name) is ArchitectureSpec {
            return preferredArch
        }

        if let standardArch = core.specRegistry.getSpec("Standard", domain: name) as? ArchitectureSpec,
           let realArchs = standardArch.realArchs?.stringRep {
            return realArchs.split(" ").0
        }

        let defaultSDKArchs = Set(self.defaultSDKVariant?.archs ?? [])
        return Self.defaultArchsForIndexArena.first { defaultArch in
            defaultSDKArchs.contains(defaultArch)
        }
    }
}
