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

import Foundation

public import SWBUtil
public import struct SWBProtocol.RunDestinationInfo
public import SWBMacro
import Synchronization

/// Wrapper for user context information.
public struct UserInfo: Codable, Hashable, Sendable {
    /// The Unix user name the session is operating on behalf of.
    public let user: String

    /// The Unix group the session is operating on behalf of.
    public let group: String

    /// The UID of the user.
    public let uid: Int

    /// The GID of the group.
    public let gid: Int

    /// The home directory path.
    public let home: Path

    /// The process environment of the user context.
    public var processEnvironment: [String: String]

    /// The environment of the user context to expose to the *build system*. This need not match the process environment, and can be used to restrict the set of environment variables which will cause tasks to rebuild.
    ///
    /// This is passed to Swift Build from clients
    public var buildSystemEnvironment: [String: String]

    public init(user: String, group: String, uid: Int, gid: Int, home: Path, processEnvironment: [String: String], buildSystemEnvironment: [String: String]) {
        self.user = user
        self.group = group
        self.uid = uid
        self.gid = gid
        self.home = home
        self.processEnvironment = processEnvironment
        self.buildSystemEnvironment = buildSystemEnvironment
    }

    public init(user: String, group: String, uid: Int, gid: Int, home: Path, environment: [String: String]) {
        self.init(user: user, group: group, uid: uid, gid: gid, home: home, processEnvironment: environment, buildSystemEnvironment: environment)
    }

    public func withAdditionalEnvironment(environment: [String: String]) -> Self {
        return UserInfo(
            user: self.user,
            group: self.group,
            uid: self.uid,
            gid: self.gid,
            home: self.home,
            processEnvironment: self.processEnvironment.merging(environment, uniquingKeysWith: { a, b in b }),
            buildSystemEnvironment: self.buildSystemEnvironment.merging(environment, uniquingKeysWith: { a, b in b })
        )
    }
}

/// Wrapper for operation system information.
public struct SystemInfo: Sendable, Hashable, Codable {
    /// The operating system version.
    public let operatingSystemVersion: Version

    /// The product build version (a build number like 18A999 on macOS).
    public let productBuildVersion: String

    /// The native architecture name of the local computer.
    public let nativeArchitecture: String

    public init(operatingSystemVersion: Version, productBuildVersion: String, nativeArchitecture: String) {
        self.operatingSystemVersion = operatingSystemVersion
        self.productBuildVersion = productBuildVersion
        self.nativeArchitecture = nativeArchitecture
    }
}

/// Wrapper for user preferences.
public struct UserPreferences: Sendable {
    /// Whether to emit additional information to the build log for use in build system debugging.
    ///
    /// The intention is that the logs should remain usable for daily use, but that the information would generally only be of interest to engineers working on Swift Build.
    public let enableDebugActivityLogs: Bool

    /// Whether build debugging is enabled.
    public let enableBuildDebugging: Bool

    /// Whether caching of build system instances is enabled.
    public let enableBuildSystemCaching: Bool

    /// How terse the progress update messages should be
    public let activityTextShorteningLevel: ActivityTextShorteningLevel

    /// Whether to use per-configuration build directories, if configured.
    public let usePerConfigurationBuildLocations: Bool?

    /// Whether dynamic tasks are allowed to request processes be spawned as external tools.
    public let allowsExternalToolExecution: Bool

    public static var allowsExternalToolExecutionDefaultValue: Bool {
        #if RC_PLAYGROUNDS
        return true
        #else
        return false
        #endif
    }

    static let `default` = UserPreferences(
        enableDebugActivityLogs: UserDefaults.enableDebugActivityLogs,
        enableBuildDebugging: UserDefaults.enableBuildDebugging,
        enableBuildSystemCaching: UserDefaults.enableBuildSystemCaching,
        activityTextShorteningLevel: UserDefaults.activityTextShorteningLevel,
        usePerConfigurationBuildLocations: UserDefaults.usePerConfigurationBuildLocations,
        allowsExternalToolExecution: UserDefaults.allowsExternalToolExecution
    )

    public init(
        enableDebugActivityLogs: Bool,
        enableBuildDebugging: Bool,
        enableBuildSystemCaching: Bool,
        activityTextShorteningLevel: ActivityTextShorteningLevel,
        usePerConfigurationBuildLocations: Bool?,
        allowsExternalToolExecution: Bool
    ) {
        self.enableDebugActivityLogs = enableDebugActivityLogs
        self.enableBuildDebugging = enableBuildDebugging
        self.enableBuildSystemCaching = enableBuildSystemCaching
        self.activityTextShorteningLevel = activityTextShorteningLevel
        self.usePerConfigurationBuildLocations = usePerConfigurationBuildLocations
        self.allowsExternalToolExecution = allowsExternalToolExecution
    }
}

fileprivate extension SWBUtil.UserDefaults {
    static var enableDebugActivityLogs: Bool {
        return bool(forKey: "EnableDebugActivityLogs")
    }

    static var enableBuildDebugging: Bool {
        return bool(forKey: "EnableBuildDebugging")
    }

    static var enableBuildSystemCaching: Bool {
        return !hasValue(forKey: "EnableBuildSystemCaching") || bool(forKey: "EnableBuildSystemCaching")
    }

    static var activityTextShorteningLevel: ActivityTextShorteningLevel {
        return hasValue(forKey: "ActivityTextShorteningLevel") ? (ActivityTextShorteningLevel(rawValue: int(forKey: "ActivityTextShorteningLevel")) ?? .default) : .default
    }

    static var usePerConfigurationBuildLocations: Bool? {
        return hasValue(forKey: "UsePerConfigurationBuildLocations") ? bool(forKey: "UsePerConfigurationBuildLocations") : nil
    }

    static var allowsExternalToolExecution: Bool {
        return hasValue(forKey: "AllowsExternalToolExecution") ? bool(forKey: "AllowsExternalToolExecution") : UserPreferences.allowsExternalToolExecutionDefaultValue
    }
}

// SDK lookup priorities:
//
// 1. Overriding SDKs
// - Found via XCODE_OVERRIDING_SDKS_DIRECTORY
// - Supports name and path lookup
// - Populated in init() and immutable
//
// 2. Builtin SDKs
// - Shipped with Xcode
// - Supports name and path lookup
// - Populated in init() and immutable
//
// 3. Discovered external SDKs
// - Found via SDKROOT=path where path is previously unseen in 1 and 2
// - Supports only path lookup
// - Discovers (and caches) new SDKs on demand
public struct WorkspaceContextSDKRegistry: SDKRegistryLookup, Sendable {
    private var underlyingLookup: CascadingSDKRegistryLookup

    /// Allows lookup(...) to search multiple SDK registries in order.
    private struct CascadingSDKRegistryLookup: SDKRegistryLookup, Sendable {
        let registries: [any SDKRegistryLookup]

        private func lookupInEach(f: (any SDKRegistryLookup) throws -> SDK?) rethrows -> SDK? {
            for registry in registries {
                if let result = try f(registry) {
                    return result
                }
            }

            return nil
        }

        public func lookup(_ name: String, activeRunDestination: RunDestinationInfo?) throws -> SDK? {
            return try lookupInEach { try $0.lookup(name, activeRunDestination: activeRunDestination) }
        }

        public func lookup(_ path: Path) -> SDK? {
            return lookupInEach { $0.lookup(path) }
        }

        public func lookup(nameOrPath: String, basePath: Path, activeRunDestination: RunDestinationInfo?) throws -> SDK? {
            return try lookupInEach { try $0.lookup(nameOrPath: nameOrPath, basePath: basePath, activeRunDestination: activeRunDestination) }
        }
    }

    @_spi(Testing) public init(coreSDKRegistry: SDKRegistry, delegate: any SDKRegistryDelegate, userNamespace: MacroNamespace, overridingSDKsDir: Path?) {
        var result: [any SDKRegistryLookup] = []

        // 1. Overriding SDKs
        if let overridingSDKsDir {
            let registry = SDKRegistry(delegate: delegate, searchPaths: [(overridingSDKsDir, nil)], type: .overriding, hostOperatingSystem: coreSDKRegistry.hostOperatingSystem)
            registry.loadExtendedInfo(delegate.namespace)
            result.append(registry)
        }

        // 2. Builtin SDKs
        result.append(coreSDKRegistry)

        // 3. Discovered external SDKs.  This is the only registry which is allowed to add new SDKs (by path) after it's created.
        let registry = SDKRegistry(delegate: delegate, searchPaths: [], type: .external, hostOperatingSystem: coreSDKRegistry.hostOperatingSystem)
        result.append(registry)

        underlyingLookup = CascadingSDKRegistryLookup(registries: result)
    }

    public func lookup(_ name: String, activeRunDestination: RunDestinationInfo?) throws -> SDK? {
        return try underlyingLookup.lookup(name, activeRunDestination: activeRunDestination)
    }

    public func lookup(_ path: Path) -> SDK? {
        return underlyingLookup.lookup(path)
    }

    public func lookup(nameOrPath: String, basePath: Path, activeRunDestination: RunDestinationInfo?) throws -> SDK? {
        return try underlyingLookup.lookup(nameOrPath: nameOrPath, basePath: basePath, activeRunDestination: activeRunDestination)
    }
}

/// Wrapper for information needed to use a workspace.
///
/// The context's lifetime is tied to the session (one per Xcode workspace), but will be recreated when the workspace itself changes due to a PIF transfer.
public final class WorkspaceContext: Sendable {
    /// The core to use.
    public let core: Core

    /// The workspace object.
    public let workspace: Workspace

    /// The proxy to use for all filesystem operations performed on behalf of this workspace.
    public let fs: any FSProxy

    /// The registered user information.
    ///
    /// This includes the user account's info, the process environment, and some other details.
    private let _userInfo: SWBMutex<UserInfo?>
    public var userInfo: UserInfo? {
        _userInfo.withLock { $0 }
    }
    public func updateUserInfo(_ value: UserInfo) {
        _userInfo.withLock { $0 = value }
    }

    /// The registered system information.
    ///
    /// This includes the OS version info, and the nafive architecture of the host machine.
    private let _systemInfo: SWBMutex<SystemInfo?>
    public var systemInfo: SystemInfo? {
        _systemInfo.withLock { $0 }
    }
    public func updateSystemInfo(_ value: SystemInfo) {
        _systemInfo.withLock { $0 = value }
    }

    /// The registered user preferences.
    ///
    /// This includes standard configuration sourced from environment variables and user defaults.
    private let _userPreferences: SWBMutex<UserPreferences>
    public var userPreferences: UserPreferences {
        _userPreferences.withLock { $0 }
    }
    public func updateUserPreferences(_ value: UserPreferences) {
        _userPreferences.withLock { $0 = value }
    }

    /// Helper object for cached workspace specific settings.
    private let _workspaceSettings: UnsafeDelayedInitializationSendableWrapper<WorkspaceSettings>
    private let _workspaceSettingsCache: UnsafeDelayedInitializationSendableWrapper<WorkspaceSettingsCache>
    internal var workspaceSettings: WorkspaceSettings {
        _workspaceSettings.value
    }
    internal var workspaceSettingsCache: WorkspaceSettingsCache {
        _workspaceSettingsCache.value
    }

    internal let macroConfigFileLoader: MacroConfigFileLoader

    let machOInfoCache: FileSystemSignatureBasedCache<MachOInfo>

    /// The cache of the xcframeworks used throughout the task planning process.
    let xcframeworkCache: FileSystemSignatureBasedCache<XCFramework>

    public let discoveredCommandLineToolSpecInfoCache: DiscoveredCommandLineToolSpecInfoCache

    public var sdkRegistry: WorkspaceContextSDKRegistry {
        return sdkRegistryCache.getValue(self)
    }
    private let sdkRegistryCache = LazyCache { (workspaceContext: WorkspaceContext) -> WorkspaceContextSDKRegistry in
        let overridingSDKsDir: Path? = workspaceContext.userInfo?.processEnvironment["XCODE_OVERRIDING_SDKS_DIRECTORY"].flatMap{Path($0)}

        return WorkspaceContextSDKRegistry(coreSDKRegistry: workspaceContext.core.sdkRegistry, delegate: workspaceContext.core.registryDelegate, userNamespace: workspaceContext.workspace.userNamespace, overridingSDKsDir: overridingSDKsDir)
    }

    public init(core: Core, workspace: Workspace, fs: any FSProxy = localFS, processExecutionCache: ProcessExecutionCache) {
        self.core = core
        self.workspace = workspace
        self.fs = fs
        self.machOInfoCache = FileSystemSignatureBasedCache(fs: fs)
        self.xcframeworkCache = FileSystemSignatureBasedCache(fs: fs)
        self.macroConfigFileLoader = MacroConfigFileLoader(core: core, fs: fs)
        self.discoveredCommandLineToolSpecInfoCache = DiscoveredCommandLineToolSpecInfoCache(processExecutionCache: processExecutionCache)
        self._userInfo = .init(nil)
        self._systemInfo = .init(nil)
        self._userPreferences = .init(.default)
        self._workspaceSettings = .init()
        self._workspaceSettingsCache = .init()

        self._workspaceSettings.initialize(to: WorkspaceSettings(self))
        self._workspaceSettingsCache.initialize(to: WorkspaceSettingsCache(workspaceContext: self, macroConfigFileLoader: macroConfigFileLoader))
    }

    /// Get the cached header index info.
    public var headerIndex: WorkspaceHeaderIndex {
        get async {
            await headerIndexCache.value {
                await WorkspaceHeaderIndex(core: core, workspace: workspace)
            }
        }
    }

    private let headerIndexCache = AsyncSingleValueCache<WorkspaceHeaderIndex, Never>()

    public var buildDirectoryMacros: [PathMacroDeclaration] {
        return [BuiltinMacros.DSTROOT, BuiltinMacros.OBJROOT, BuiltinMacros.SYMROOT, BuiltinMacros.BUILT_PRODUCTS_DIR, BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_DIR]
    }

    /// The path to the module session file for the workspace given a set of build parameters.
    public func getModuleSessionFilePath(_ parameters: BuildParameters) -> Path {
        var cacheFolderPath: Path!
        if let p = parameters.arena?.derivedDataPath {
            // If the arena defines a derived data path, then use it.
            cacheFolderPath = p
        }
        else {
            // Otherwise use the path to the default clang user cache directory.  This will mainly used when running xcodebuild without -scheme.
            // First see if CCHROOT is defined in the environment.  If it is, and if it does *not* start with "/Library/Caches/com.apple.Xcode", then we use it.
            if let CCHROOT = self.userInfo?.processEnvironment["CCHROOT"], !CCHROOT.isEmpty {
                let cchrootPath = Path(CCHROOT).normalize()
                if !cchrootPath.str.hasPrefix("/Library/Caches/com.apple.Xcode") {
                    cacheFolderPath = cchrootPath
                }
            }

            // If we couldn't use CCHROOT, then we use a path in the equivalent of what 'getconf DARWIN_USER_CACHE_DIR' returns.
            if cacheFolderPath == nil {
                let secureCacheBasePath = userCacheDir()
                cacheFolderPath = secureCacheBasePath.join("org.llvm.clang")
            }
        }
        let moduleCacheFolderPath = cacheFolderPath.join("ModuleCache.noindex")
        return moduleCacheFolderPath.join("Session.modulevalidation")
    }
}

extension FSProxy {
    private static var CreatedByBuildSystemAttribute: String {
        #if os(Linux) || os(Android)
        // On Linux, "the name [of an extended attribute] must be a null-terminated string prefixed by a namespace identifier and a dot character" and only the "user" namespace is available for unrestricted access.
        "user.org.swift.swift-build.CreatedByBuildSystem"
        #else
        "com.apple.xcode.CreatedByBuildSystem"
        #endif
    }

    private static var CreatedByBuildSystemAttributeOnValue: String {
        "true"
    }

    public func hasCreatedByBuildSystemAttribute(_ path: Path) throws -> Bool {
        return try getExtendedAttribute(path, key: Self.CreatedByBuildSystemAttribute) == Self.CreatedByBuildSystemAttributeOnValue
    }

    public func setCreatedByBuildSystemAttribute(_ path: Path) throws {
        // Many filesystems on other platforms (e.g. various non-ext4 temporary filesystems on Linux) don't support xattrs and will return ENOTSUP.
        // In particular, tmpfs doesn't support xattrs on Linux unless `CONFIG_TMPFS_XATTR` is enabled in the kernel config.
        // FIXME: Detect whether the FS supports xattrs at runtime
        #if canImport(Darwin)
        try setExtendedAttribute(path, key: Self.CreatedByBuildSystemAttribute, value: Self.CreatedByBuildSystemAttributeOnValue)
        #endif
    }

    public func commandLineArgumentsToApplyCreatedByBuildSystemAttribute(to path: Path) -> [String] {
        ["xattr", "-w", Self.CreatedByBuildSystemAttribute, Self.CreatedByBuildSystemAttributeOnValue, path.str]
    }
}

public struct MachOInfo: Sendable {
    public let architectures: Set<String>
    public let platforms: Set<BuildVersion.Platform>
    public let linkage: MachO.WrappedFileType
}

extension MachOInfo: FileSystemInitializable {
    init(path: Path, fs: any FSProxy) throws {
        let executablePath: Path
        if let bundle = Bundle(path: path.str) {
            if let path = bundle.executablePath {
                executablePath = Path(path)
            } else {
                throw StubError.error("could not determine executable path for bundle '\(path.str)'")
            }
        } else {
            executablePath = path
        }
        self = try fs.read(executablePath) { fileHandle in
            let (slices, linkage) = try MachO(data: fileHandle).slicesIncludingLinkage()
            let machoArchs = Set(slices.map { $0.arch })
            let machoPlatforms = Set(try slices.flatMap { slice in try slice.buildVersions().map { $0.platform } })
            return MachOInfo(architectures: machoArchs, platforms: machoPlatforms, linkage: linkage)
        }
    }
}

extension XCFramework: FileSystemInitializable { }
