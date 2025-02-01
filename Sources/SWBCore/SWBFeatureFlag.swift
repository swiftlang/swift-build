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
import SWBUtil

/// Represents a standard Swift Build feature flag.
///
/// Feature flags are opt-in behaviors that can be triggered by a user default
/// in the `org.swift.swift-build` domain, or environment variable of the same
/// name.
///
/// Feature flags should be added for potentially risky behavior changes that
/// we plan to eventually turn on unconditionally by default, but need more time
/// to evaluate risk and prepare any affected internal projects for changes.
///
/// - note: The lifetime of a feature flag is intended to be *temporary*, and
/// the flag must removed from the code once the associated behavior is
/// considered to be "ready" and a decision is made whether to turn the behavior
/// "on" or "off" by default. For features whose configurability should be
/// toggleable indefinitely, do not use a feature flag, and consider an
/// alternative such as a build setting.
@propertyWrapper
public struct SWBFeatureFlagProperty {
    private let key: String
    private let defaultValue: Bool

    /// Whether the feature flag is actually set at all.
    public var hasValue: Bool {
        return SWBUtil.UserDefaults.hasValue(forKey: key) || getEnvironmentVariable(key) != nil
    }

    /// Indicates whether the feature flag is currently active in the calling environment.
    public var wrappedValue: Bool {
        if !hasValue {
            return defaultValue
        }
        return SWBUtil.UserDefaults.bool(forKey: key) || getEnvironmentVariable(key)?.boolValue == true
    }

    fileprivate init(_ key: String, defaultValue: Bool = false) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

@propertyWrapper
public struct SWBOptionalFeatureFlagProperty {
    private let key: String

    /// Indicates whether the feature flag is currently active in the calling environment.
    /// Returns nil if neither environment variable nor User Default are set.  An implementation can then pick a default behavior.
    /// If both the environment variable and User Default are set, the two values are logically AND'd together; this allows the set false value of either to force the feature flag off.
    public var wrappedValue: Bool? {
        let envValue = getEnvironmentVariable(key)
        let envHasValue = envValue != nil
        let defHasValue = SWBUtil.UserDefaults.hasValue(forKey: key)
        if !envHasValue && !defHasValue {
            return nil
        }
        if envHasValue && defHasValue {
            return (envValue?.boolValue == true) && SWBUtil.UserDefaults.bool(forKey: key)
        }
        if envHasValue {
            return envValue?.boolValue == true
        }
        return SWBUtil.UserDefaults.bool(forKey: key)
    }

    fileprivate init(_ key: String) {
        self.key = key
    }
}

public enum SWBFeatureFlag {
    /// Enables the addition of default Info.plist keys as we prepare to shift these from the templates to the build system.
    @SWBFeatureFlagProperty("EnableDefaultInfoPlistTemplateKeys")
    public static var enableDefaultInfoPlistTemplateKeys: Bool

    /// <rdar://46913378> Disables indiscriminately setting the "allows missing inputs" flag for all shell scripts.
    /// Longer term we may consider allowing individual inputs to be marked as required or optional in the UI, providing control over this to developers.
    @SWBFeatureFlagProperty("DisableShellScriptAllowsMissingInputs")
    public static var disableShellScriptAllowsMissingInputs: Bool

    /// Force `DEPLOYMENT_LOCATION` to always be enabled.
    @SWBFeatureFlagProperty("UseHierarchicalBuiltProductsDir")
    public static var useHierarchicalBuiltProductsDir: Bool

    /// Use the new layout in the `SYMROOT` for copying aside products when `RETAIN_RAW_BINARIES` is enabled.  See <rdar://problem/44850736> for details on how this works.
    /// This can be used for testing before we make this layout the default.
    @SWBFeatureFlagProperty("UseHierarchicalLayoutForCopiedAsideProducts")
    public static var useHierarchicalLayoutForCopiedAsideProducts: Bool

    /// Emergency opt-out of the execution policy exception registration changes. Should be removed before GM.
    @SWBFeatureFlagProperty("DisableExecutionPolicyExceptionRegistration")
    public static var disableExecutionPolicyExceptionRegistration: Bool

    /// Provide a mechanism to create all script inputs as directory nodes.
    /// This is an experimental flag while testing out options for rdar://problem/41126633.
    @SWBFeatureFlagProperty("TreatScriptInputsAsDirectories")
    public static var treatScriptInputsAsDirectoryNodes: Bool

    /// Enables filtering sources task generation to those build actions that support install headers.
    /// <rdar://problem/59862065> Remove EnableInstallHeadersFiltering after validation
    @SWBFeatureFlagProperty("EnableInstallHeadersFiltering")
    public static var enableInstallHeadersFiltering: Bool

    /// Temporary hack to phase in support for running InstallAPI even for targets skipped for installing.
    /// <rdar://problem/70499898> Remove INSTALLAPI_IGNORE_SKIP_INSTALL and enable by default
    @SWBOptionalFeatureFlagProperty("EnableInstallAPIIgnoreSkipInstall")
    public static var enableInstallAPIIgnoreSkipInstall: Bool?

    /// Enables tracking files from from library specifiers as linker dependency inputs.
    @SWBFeatureFlagProperty("EnableLinkerInputsFromLibrarySpecifiers")
    public static var enableLinkerInputsFromLibrarySpecifiers: Bool

    /// Enables the use of different arguments to the tapi installapi tool.
    @SWBOptionalFeatureFlagProperty("EnableModuleVerifierTool")
    public static var enableModuleVerifierTool: Bool?

    /// Allows for enabling target specialization for all targets on a global level. See rdar://45951215.
    @SWBFeatureFlagProperty("AllowTargetPlatformSpecialization")
    public static var allowTargetPlatformSpecialization: Bool

    /// Enable parsing optimization remarks in Swift Build.
    @SWBFeatureFlagProperty("DTEnableOptRemarks")
    public static var enableOptimizationRemarksParsing: Bool

    @SWBFeatureFlagProperty("IDEDocumentationEnableClangExtractAPI", defaultValue: true)
    public static var enableClangExtractAPI: Bool

    @SWBFeatureFlagProperty("EnableValidateDependenciesOutputs")
    public static var enableValidateDependenciesOutputs: Bool

    /// Allow build phase fusion in targets with custom shell script build rules.
    @SWBFeatureFlagProperty("AllowBuildPhaseFusionWithCustomShellScriptBuildRules")
    public static var allowBuildPhaseFusionWithCustomShellScriptBuildRules: Bool

    /// Allow build phase fusion of copy files phases.
    @SWBFeatureFlagProperty("AllowCopyFilesBuildPhaseFusion")
    public static var allowCopyFilesBuildPhaseFusion: Bool

    @SWBFeatureFlagProperty("EnableEagerLinkingByDefault")
    public static var enableEagerLinkingByDefault: Bool

    @SWBFeatureFlagProperty("EnableBuildBacktraceRecording", defaultValue: false)
    public static var enableBuildBacktraceRecording: Bool

    @SWBFeatureFlagProperty("GeneratePrecompiledModulesReport", defaultValue: false)
    public static var generatePrecompiledModulesReport: Bool

    /// Turn on llbuild's ownership analyis.
    /// Remove this feature flag after landing rdar://104894978 (Write "perform-ownership-analysis" = "yes" to build manifest by default)
    @SWBFeatureFlagProperty("PerformOwnershipAnalysis", defaultValue: false)
    public static var performOwnershipAnalysis: Bool

    /// Enable clang explicit modules by default.
    @SWBFeatureFlagProperty("EnableClangExplicitModulesByDefault", defaultValue: false)
    public static var enableClangExplicitModulesByDefault: Bool

    /// Enable Swift explicit modules by default.
    @SWBFeatureFlagProperty("EnableSwiftExplicitModulesByDefault", defaultValue: false)
    public static var enableSwiftExplicitModulesByDefault: Bool

    /// Enable Clang caching by default.
    @SWBFeatureFlagProperty("EnableClangCachingByDefault", defaultValue: false)
    public static var enableClangCachingByDefault: Bool

    /// Enable Swift caching by default.
    @SWBFeatureFlagProperty("EnableSwiftCachingByDefault", defaultValue: false)
    public static var enableSwiftCachingByDefault: Bool

    @SWBFeatureFlagProperty("UseStrictLdEnvironmentBuildSetting", defaultValue: false)
    public static var useStrictLdEnvironmentBuildSetting: Bool

    @SWBFeatureFlagProperty("EnableCacheMetricsLogs", defaultValue: false)
    public static var enableCacheMetricsLogs: Bool

    @SWBFeatureFlagProperty("AppSandboxConflictingValuesEmitsWarning", defaultValue: false)
    public static var enableAppSandboxConflictingValuesEmitsWarning: Bool
}
