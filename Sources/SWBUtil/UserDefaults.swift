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

import class Foundation.ProcessInfo
import class Foundation.Thread
import class Foundation.UserDefaults
import class Foundation.NSNumber

/// A namespace for user defaults.  Swift Build's domain is 'org.swift.swift-build'.
///
/// By convention, all values here should directly query the default for each access -- clients should cache this value if necessary.
///
/// Note:
/// We don't want to access UserDefaults directly, since it's global state.
/// That means it can change during the build, and we also found that accessing UserDefaults can be slow in hot code paths
/// since it takes a lock on the user defaults state.
/// Instead, take a look at ``UserPreferences``, which is designed to capture UserDefaults into an immutable object at the beginning of the build,
/// and then pass that object down to subobjects that need it during the build.
public enum UserDefaults: Sendable {
    /// Binds the internal defaults to the specified `environment` for the duration of the synchronous `operation`.
    /// - parameter clean: `true` to start with a clean environment, `false` to merge the input environment over the existing process environment.
    /// - note: This is implemented via task-local values.
    @_spi(Testing) public static func withEnvironment<R>(_ environment: [String: String], clean: Bool = false, operation: () throws -> R) rethrows -> R {
        try $internalDefaults.withValue(.init(clean ? environment.p : internalDefaults.dictionary.addingContents(of: environment.p)), operation: operation)
    }

    /// Binds the internal defaults to the specified `environment` for the duration of the asynchronous `operation`.
    /// - parameter clean: `true` to start with a clean environment, `false` to merge the input environment over the existing process environment.
    /// - note: This is implemented via task-local values.
    @_spi(Testing) public static func withEnvironment<R>(_ environment: [String: String], clean: Bool = false, operation: () async throws -> R) async rethrows -> R {
        try await $internalDefaults.withValue(.init(clean ? environment.p : internalDefaults.dictionary.addingContents(of: environment.p)), operation: operation)
    }

    /// Internally overridden defaults.  This returns the process environment as user defaults.
    ///
    /// By convention the lookup methods for user defaults in this class look at the internal defaults returned here before the defaults in the swift-build domain, so environment variables take precedence over the normal defaults.
    ///
    /// The global function `exportUserDefaultToEnvironment()` can be used to add a user default key-value pair for the current process to its environment.  In Xcode, `SWBBuildServiceConnection.init()` does this in order to add selected Xcode-side user defaults to the environment it passes to Swift Build.
    @TaskLocal fileprivate static var internalDefaults = Registry<String, PropertyListItem>(ProcessInfo.processInfo.environment.p)

    /// We load user defaults from the `org.swift.swift-build` domain.  By convention the lookup methods will override these with the process environment.  See the `internalDefaults` property for more details.
    nonisolated(unsafe) private static let defaults: Foundation.UserDefaults = {
        let defaults =  Foundation.UserDefaults(suiteName: "org.swift.swift-build")!
        // Preserved for backwards compatibility
        defaults.addSuite(named: "com.apple.dt.XCBuild")
        return defaults
    }()

    /// Set a temporary string-value default.
    public static func set(key: String, value: String?) {
        internalDefaults[key] = value.map { .plString($0) }
    }

    /// Set a temporary bool-value default.
    public static func set(key: String, value: Bool) {
        internalDefaults[key] = .plBool(value)
    }

    /// Set a temporary string-array-value default.
    public static func set(key: String, value: [String]) {
        internalDefaults[key] = .plArray(value.map({ .plString($0) }))
    }

    /// Clear a temporary default.
    public static func reset(key: String) -> PropertyListItem? {
        return internalDefaults.removeValue(forKey: key)
    }

    /// Get a boolean default value.
    public static func bool(forKey key: String) -> Bool {
        return internalDefaults[key]?.looselyTypedBoolValue ?? UserDefaults.defaults.bool(forKey: key)
    }

    /// Get a string default value.
    public static func string(forKey key: String) -> String? {
        return internalDefaults[key]?.stringValue ?? UserDefaults.defaults.string(forKey: key)
    }

    /// Get an Int default value.
    public static func int(forKey key: String) -> Int {
        // Note: Can't use internalDefaults[key].intValue here because internalDefaults only registers .plString values
        if let stringValue = internalDefaults[key]?.stringValue {
            return Int(stringValue) ?? 0
        }
        return UserDefaults.defaults.integer(forKey: key)
    }

    /// Get a string array default value. If the value is a string, it will be automatically wrapped in an array.
    public static func stringArray(forKey key: String) -> [String]? {
        if let value = internalDefaults[key]?.stringValue {
            return [value]
        }
        return internalDefaults[key]?.stringArrayValue ?? UserDefaults.defaults.stringArray(forKey: key)
    }

    /// Returns `true` if the given user default is defined.
    public static func hasValue(forKey key: String) -> Bool {
        return internalDefaults[key] != nil || UserDefaults.defaults.object(forKey: key) != nil
    }

    // MARK: Actual Build Defaults

    public static var skipEarlyBuildOperationCancellation: Bool {
        return bool(forKey: "SkipEarlyBuildOperationCancellation")
    }

    /// Whether removal of stale files is enabled (on by default).
    public static var enableBuildSystemStaleFileRemoval: Bool {
        return !hasValue(forKey: "EnableBuildSystemStaleFileRemoval") || bool(forKey: "EnableBuildSystemStaleFileRemoval")
    }

    /// Whether to skip reporting of build debugging is enabled.
    public static var skipLogReporting: Bool {
        return bool(forKey: "SkipLogReporting")
    }

    /// Whether the device-agnostic file system mode should be used. The default is `true`.
    /// (See <rdar://problem/38916860> Building after a reboot does a full rebuild)
    public static var ignoreFileSystemDeviceInodeChanges: Bool {
        return hasValue(forKey: "IgnoreFileSystemDeviceInodeChanges") ? bool(forKey: "IgnoreFileSystemDeviceInodeChanges") : true
    }

    /// (See <rdar://problem/99632656> Make incremental builds resilient to content-preserving touch and git branch switch)
    public static var fileSystemMode: FileSystemMode {
        let defaultMode: FileSystemMode = .deviceAgnostic

        if hasValue(forKey: "FileSystemMode") {
            switch string(forKey: "FileSystemMode") {
            case "checksum-only":
                return .checksumOnly
            case "full-stat":
                return .fullStat
            case "device-agnostic":
                return .deviceAgnostic
            default:
                return defaultMode
            }
        }

        if hasValue(forKey: "IgnoreFileSystemDeviceInodeChanges") {
            if bool(forKey: "IgnoreFileSystemDeviceInodeChanges") {
                return .deviceAgnostic
            } else {
                return .fullStat
            }
        }

        return defaultMode
    }

    /// Additional directories to search for platforms.
    public static var additionalPlatformSearchPaths: [Path] {
        return stringArray(forKey: "DVTExtraPlatformFolders")?.compactMap({ $0.isEmpty ? nil : Path($0) }) ?? []
    }

    /// Whether serialization and writing-to-disk of a BuildDescription should be done synchronously.  Default is `false`.
    ///
    /// This default is intended for use only for comparative performance measurements.
    public static var useSynchronousBuildDescriptionSerialization: Bool {
        return bool(forKey: "UseSynchronousBuildDescriptionSerialization")
    }

    /// Whether the dependency cycle resolution should be attempted.
    public static var attemptDependencyCycleResolution: Bool {
        return bool(forKey: "AttemptDependencyCycleResolution")
    }

    /// Whether llbuild tracing points should be enabled.
    public static var enableTracing: Bool {
        return bool(forKey: "EnableTracing")
    }

    public static var enableDiagnosingDiamondProblemsWhenUsingPackages: Bool {
        return hasValue(forKey: "EnableDiagnosingDiamondProblemsWhenUsingPackages") ? bool(forKey: "EnableDiagnosingDiamondProblemsWhenUsingPackages") : true
    }

    public static var enableIndexingPayloadSerialization: Bool {
        return bool(forKey: "EnableIndexingPayloadSerialization")
    }

    public static var enablePluginManagerLogging: Bool {
        return bool(forKey: "EnablePluginManagerLogging")
    }

    public static var disableSigningProvisioningErrors: Bool {
        return bool(forKey: "DisableSigningProvisioningErrors")
    }

    public static var makeAggregateTargetsTransparentForSpecialization: Bool {
        return hasValue(forKey: "MakeAggregateTargetsTransparentForSpecialization") ? bool(forKey: "MakeAggregateTargetsTransparentForSpecialization") : true
    }

    public static var enableSDKStatCaching: Bool {
        return hasValue(forKey: "EnableSDKStatCaching") ? bool(forKey: "EnableSDKStatCaching") : true
    }

    public static var useTargetDependenciesForImpartedBuildSettings: Bool {
        return bool(forKey: "UseTargetDependenciesForImpartedBuildSettings")
    }

    public static var enableFixFor23297285: Bool {
        return !hasValue(forKey: "EnableFixFor23297285") || bool(forKey: "EnableFixFor23297285")
    }

    /// Provides a mechanism to control the concurrency behavior when calculating the dependency graph. This can be especially useful to disable when tracking down and testing ordering issues.
    public static var disableConcurrentDependencyResolution: Bool {
        return hasValue(forKey: "DisableConcurrentDependencyResolution") ? bool(forKey: "DisableConcurrentDependencyResolution") : false
    }

    public static var buildDescriptionInMemoryCacheSize: Int {
        return hasValue(forKey: "BuildDescriptionInMemoryCacheSize") ? int(forKey: "BuildDescriptionInMemoryCacheSize") : 4
    }

    public static var buildDescriptionInMemoryCostLimit: Int {
        return hasValue(forKey: "BuildDescriptionInMemoryCostLimit") ? int(forKey: "BuildDescriptionInMemoryCostLimit") : 50_000
    }

    public static var buildDescriptionOnDiskCacheSize: Int {
        return hasValue(forKey: "BuildDescriptionOnDiskCacheSize") ? int(forKey: "BuildDescriptionOnDiskCacheSize") : 4
    }

    /// What the llbuild scheduler lane width should be, where 0 (the default)
    /// means use the available hardware concurrency.
    public static var schedulerLaneWidth: UInt32? {
        if let laneWidthString = string(forKey: "SchedulerLaneWidth"), let laneWidth = UInt32(laneWidthString) {
            return laneWidth
        } else if let maxTasksString = string(forKey: "IDEBuildOperationMaxNumberOfConcurrentCompileTasks"), let maxTasks = UInt32(maxTasksString) {
            return maxTasks
        }

        return nil
    }

    /// What llbuild scheduler algorithm should be used.
    public static var schedulerAlgorithm: String? {
        return string(forKey: "SchedulerAlgorithm")
    }

    /// The on-disk path to use for the compilation cache.
    public static var compilationCachingCASPath: String? {
        return string(forKey: "CompilationCachingCASPath")
    }

    /// See `CASOptions.parseSizeLimit()` for the format of the string.
    public static var compilationCachingDiskSizeLimit: String? {
        return string(forKey: "CompilationCachingDiskSizeLimit")
    }

    /// Provides the default level of QoS support within Swift Build for global queues that are not tied to specific build requests.
    public static var undeterminedQoS: SWBQoS {
        // With 'unspecified' the QoS of the caller is influencing the QoS to be used for the enqueued work item.
        return qosFromKey("UndeterminedQoS", defaultValue: .unspecified)
    }

    /// Provides the default level of QoS support for requests that do not have parameterized QoS.
    public static var defaultRequestQoS: SWBQoS {
        return qosFromKey("DefaultRequestQoS", defaultValue: .default)
    }

    private static func qosFromKey(_ key: String, defaultValue: SWBQoS) -> SWBQoS {
        guard let qos = string(forKey: key) else { return defaultValue }

        switch qos {
        case "background": return .background
        case "utility": return .utility
        case "userInitiated": return .userInitiated
        case "userInteractive": return .userInteractive
        case "unspecified": return .unspecified
        default: return defaultValue
        }
    }

    /// Provide a mechanism to skip the run destination override
    public static var skipRunDestinationOverride: Bool {
        return bool(forKey: "XCBUILD_SKIP_RUN_DESTINATION_OVERRIDE")
    }

    /// Provide a mechanism to warn instead of error when specialization fails to choose a platform
    public static var platformSpecializationWarnOnly: Bool {
        return bool(forKey: "XCBUILD_PLATFORM_SPECIALIZATION_WARN_ONLY")
    }

    /// Provide a mechanism to avoid the `-rpath /usr/lib/swift` addition for Swift Concurrency. This is a fallback mechanism and is only intended to be used as a safeguard if any errors come up.
    public static var allowRuntimeSearchPathAdditionForSwiftConcurrency: Bool {
        return hasValue(forKey: "AllowRuntimeSearchPathAdditionForSwiftConcurrency") ? bool(forKey: "AllowRuntimeSearchPathAdditionForSwiftConcurrency") : true
    }

    public static var stopAfterOpeningLibClang: Bool {
        return hasValue(forKey: "StopAfterOpeningLibClang") ? bool(forKey: "StopAfterOpeningLibClang") : false
    }

    public static var previewsAllowInternalMacOSDebugDylib: Bool {
        return hasValue(forKey: "PreviewsEnableInternalMacOSDebugDylib") ? bool(forKey: "PreviewsEnableInternalMacOSDebugDylib") : false
    }
}

/// The level of activity text shortening
/// - warning: Note that since the enum cases represent increasing levels of shortening, their ordering is important.  In other words, `.legacy` represents no shortening, while `.full` represents the most shortening. This means, for example, that the build task counts text will be shortened if the level is >= `.buildCountsOnly`
public enum ActivityTextShorteningLevel: Int, Codable, Comparable, RawRepresentable, Sendable {
    /// Use Xcode 12 activity text
    case legacy

    /// Only shorten the progress message for build task counts
    case buildCountsOnly

    /// Shorten all messages with dynamic text (counts or target names)
    case allDynamicText

    /// Shorten all build system progress messages; move some behind `enableDebugActivityLogs`
    case full

    public static let `default`: ActivityTextShorteningLevel = .full
}


// MARK: -
// MARK: Exporting user defaults from Xcode to Swift Build.


/// List of user defaults we want Xcode to export from its domain down to Swift Build.
///
/// These defaults primarily fall into two sets:
///
/// - Swift Build-defined defaults which are useful to specify on the xcodebuild command line, or when launching Xcode e.g. for testing.
/// - Defaults which existed in the legacy build system but which are also supported by Swift Build.
///
/// These defaults will be exported via `exportUserDefaultToEnvironment()` - which see for its specific behaviors.
public let xcodeUserDefaultsToExportToSwiftBuild = [
    // Defaults controlling special diagnostic and debugging.
    "EnableDebugActivityLogs",
    "EnableBuildDebugging",
    "SkipLogReporting",
    "ActivityTextShorteningLevel",

    // Defaults useful for enabling or disabling specific features.
    "UsePerConfigurationBuildLocations",
    "AttemptDependencyCycleResolution",
    "IgnoreFileSystemDeviceInodeChanges",
    "FileSystemMode",
    "DVTExtraPlatformFolders",

    // Legacy build system defaults also supported by Swift Build.
    "IDEBuildOperationMaxNumberOfConcurrentCompileTasks",
    "EnableFixFor23297285",
]


/// Global function which exports the supplied user default key, if present in the standard UserDefaults, to the process environment if it has not already been set.
public func exportUserDefaultToEnvironment(_ key: String) {
    if let _ = getEnvironmentVariable(EnvironmentKey(key)) {
        // do not override existing environment variable
        return
    }

    if let udval = Foundation.UserDefaults.standard.string(forKey: key) {
        // export UserDefault value to the environment as key
        try? POSIX.setenv(key, udval, 1)
    }
}

fileprivate extension Registry {
    convenience init(_ dictionary: [Key: Value]) {
        self.init()
        for (key, value) in dictionary {
            self[key] = value
        }
    }

    var dictionary: [Key: Value] {
        var dict: [Key: Value] = [:]
        forEach { (key, value) in
            dict[key] = value
        }
        return dict
    }
}

fileprivate extension Dictionary where Key == String, Value == String {
    var p: [String: PropertyListItem] {
        // Presently, values are always treated as strings.  A client would need to convert it to any other type (such as an array) manually.
        mapValues { .plString($0) }
    }
}

extension Task where Failure == Never {
    /// Runs `block` in a new thread and suspends until it finishes execution.
    ///
    /// - note: This function should be used sparingly, such as for long-running operations that may block and therefore should not be run on the Swift Concurrency thread pool. Do not use this for operations for which there may be many concurrent invocations as it could lead to thread explosion. It is meant to be a bridge to pre-existing blocking code which can't easily be converted to use Swift concurrency features.
    public static func detachNewThread(name: String? = nil, _ block: @Sendable @escaping () -> Success) async -> Success {
        let env = UserDefaults.internalDefaults.dictionary
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                Thread.current.name = name
                return continuation.resume(returning: UserDefaults.$internalDefaults.withValue(.init(env), operation: block))
            }
        }
    }
}
