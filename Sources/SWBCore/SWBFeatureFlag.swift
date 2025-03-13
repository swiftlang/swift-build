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
public struct SWBFeatureFlagProperty {
    private let key: String
    private let defaultValue: Bool

    /// Whether the feature flag is actually set at all.
    public var hasValue: Bool {
        return SWBUtil.UserDefaults.hasValue(forKey: key) || getEnvironmentVariable(EnvironmentKey(key)) != nil
    }

    /// Indicates whether the feature flag is currently active in the calling environment.
    public var value: Bool {
        if !hasValue {
            return defaultValue
        }
        return SWBUtil.UserDefaults.bool(forKey: key) || getEnvironmentVariable(EnvironmentKey(key))?.boolValue == true
    }

    fileprivate init(_ key: String, defaultValue: Bool = false) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

public struct SWBOptionalFeatureFlagProperty {
    private let key: String

    /// Indicates whether the feature flag is currently active in the calling environment.
    /// Returns nil if neither environment variable nor User Default are set.  An implementation can then pick a default behavior.
    /// If both the environment variable and User Default are set, the two values are logically AND'd together; this allows the set false value of either to force the feature flag off.
    public var value: Bool? {
        let envValue = getEnvironmentVariable(EnvironmentKey(key))
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
    public static let enableDefaultInfoPlistTemplateKeys = SWBFeatureFlagProperty("EnableDefaultInfoPlistTemplateKeys")

    /// <rdar://46913378> Disables indiscriminately setting the "allows missing inputs" flag for all shell scripts.
    /// Longer term we may consider allowing individual inputs to be marked as required or optional in the UI, providing control over this to developers.
    public static let disableShellScriptAllowsMissingInputs = SWBFeatureFlagProperty("DisableShellScriptAllowsMissingInputs")

    /// Force `DEPLOYMENT_LOCATION` to always be enabled.
    public static let useHierarchicalBuiltProductsDir = SWBFeatureFlagProperty("UseHierarchicalBuiltProductsDir")

    /// Use the new layout in the `SYMROOT` for copying aside products when `RETAIN_RAW_BINARIES` is enabled.  See <rdar://problem/44850736> for details on how this works.
    /// This can be used for testing before we make this layout the default.
    public static let useHierarchicalLayoutForCopiedAsideProducts = SWBFeatureFlagProperty("UseHierarchicalLayoutForCopiedAsideProducts")

    /// Emergency opt-out of the execution policy exception registration changes. Should be removed before GM.
    public static let disableExecutionPolicyExceptionRegistration = SWBFeatureFlagProperty("DisableExecutionPolicyExceptionRegistration")

    /// Provide a mechanism to create all script inputs as directory nodes.
    /// This is an experimental flag while testing out options for rdar://problem/41126633.
    public static let treatScriptInputsAsDirectoryNodes = SWBFeatureFlagProperty("TreatScriptInputsAsDirectories")

    /// Enables filtering sources task generation to those build actions that support install headers.
    /// <rdar://problem/59862065> Remove EnableInstallHeadersFiltering after validation
    public static let enableInstallHeadersFiltering = SWBFeatureFlagProperty("EnableInstallHeadersFiltering")

    /// Temporary hack to phase in support for running InstallAPI even for targets skipped for installing.
    /// <rdar://problem/70499898> Remove INSTALLAPI_IGNORE_SKIP_INSTALL and enable by default
    public static let enableInstallAPIIgnoreSkipInstall = SWBOptionalFeatureFlagProperty("EnableInstallAPIIgnoreSkipInstall")

    /// Enables tracking files from from library specifiers as linker dependency inputs.
    public static let enableLinkerInputsFromLibrarySpecifiers = SWBFeatureFlagProperty("EnableLinkerInputsFromLibrarySpecifiers")

    /// Enables the use of different arguments to the tapi installapi tool.
    public static let enableModuleVerifierTool = SWBOptionalFeatureFlagProperty("EnableModuleVerifierTool")

    /// Allows for enabling target specialization for all targets on a global level. See rdar://45951215.
    public static let allowTargetPlatformSpecialization = SWBFeatureFlagProperty("AllowTargetPlatformSpecialization")

    /// Enable parsing optimization remarks in Swift Build.
    public static let enableOptimizationRemarksParsing = SWBFeatureFlagProperty("DTEnableOptRemarks")

    public static let enableClangExtractAPI = SWBFeatureFlagProperty("IDEDocumentationEnableClangExtractAPI", defaultValue: true)

    public static let enableValidateDependenciesOutputs = SWBFeatureFlagProperty("EnableValidateDependenciesOutputs")

    /// Allow build phase fusion in targets with custom shell script build rules.
    public static let allowBuildPhaseFusionWithCustomShellScriptBuildRules = SWBFeatureFlagProperty("AllowBuildPhaseFusionWithCustomShellScriptBuildRules")

    /// Allow build phase fusion of copy files phases.
    public static let allowCopyFilesBuildPhaseFusion = SWBFeatureFlagProperty("AllowCopyFilesBuildPhaseFusion")

    public static let enableEagerLinkingByDefault = SWBFeatureFlagProperty("EnableEagerLinkingByDefault")

    public static let enableBuildBacktraceRecording = SWBFeatureFlagProperty("EnableBuildBacktraceRecording", defaultValue: false)

    public static let generatePrecompiledModulesReport = SWBFeatureFlagProperty("GeneratePrecompiledModulesReport", defaultValue: false)

    /// Turn on llbuild's ownership analysis.
    /// Remove this feature flag after landing rdar://104894978 (Write "perform-ownership-analysis" = "yes" to build manifest by default)
    public static let performOwnershipAnalysis = SWBFeatureFlagProperty("PerformOwnershipAnalysis", defaultValue: false)

    /// Enable clang explicit modules by default.
    public static let enableClangExplicitModulesByDefault = SWBFeatureFlagProperty("EnableClangExplicitModulesByDefault", defaultValue: false)

    /// Enable Swift explicit modules by default.
    public static let enableSwiftExplicitModulesByDefault = SWBFeatureFlagProperty("EnableSwiftExplicitModulesByDefault", defaultValue: false)

    /// Enable Clang caching by default.
    public static let enableClangCachingByDefault = SWBFeatureFlagProperty("EnableClangCachingByDefault", defaultValue: false)

    /// Enable Swift caching by default.
    public static let enableSwiftCachingByDefault = SWBFeatureFlagProperty("EnableSwiftCachingByDefault", defaultValue: false)

    public static let useStrictLdEnvironmentBuildSetting = SWBFeatureFlagProperty("UseStrictLdEnvironmentBuildSetting", defaultValue: false)

    public static let enableCacheMetricsLogs = SWBFeatureFlagProperty("EnableCacheMetricsLogs", defaultValue: false)

    public static let enableAppSandboxConflictingValuesEmitsWarning = SWBFeatureFlagProperty("AppSandboxConflictingValuesEmitsWarning", defaultValue: false)
}
