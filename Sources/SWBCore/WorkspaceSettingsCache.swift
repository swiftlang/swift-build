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

import SWBUtil
import SWBMacro

final class WorkspaceSettingsCache: Sendable {
    unowned private let workspaceContext: WorkspaceContext
    private let macroConfigFileLoader: MacroConfigFileLoader

    init(workspaceContext: WorkspaceContext, macroConfigFileLoader: MacroConfigFileLoader) {
        self.workspaceContext = workspaceContext
        self.macroConfigFileLoader = macroConfigFileLoader
    }

    struct MacroConfigCacheKey: Equatable, Hashable {
        /// The path of the macro config file being loaded.
        let path: Path

        /// The ordered list of search paths in which to look for other macro config files being included by the macro config file being loaded.
        let searchPaths: [Path]
    }

    struct SettingsCacheKey: Equatable, Hashable {
        /// The parameter these settings are for.
        let parameters: BuildParameters

        /// The project GUID the settings are for.
        let projectGUID: String?

        /// The target GUID the settings are for, if any.
        let targetGUID: String?

        /// The purpose of the settings.
        let purpose: SettingsPurpose

        /// The provisioning task inputs contributing to the settings.
        let provisioningTaskInputs: ProvisioningTaskInputs?

        /// Additional properties imparted by dependencies.
        let impartedBuildProperties: [ImpartedBuildProperties]?

        // Using just this instead of all of `impartedBuildProperties` for equality should be fine, because we should only be seeing the same
        // `impartedBuildProperties` each time when looking up cached settings.
        private var impartedMacroDeclarations: [[MacroDeclaration]]? {
            return impartedBuildProperties?.map { return Array($0.buildSettings.valueAssignments.keys) }
        }

        static func == (lhs: SettingsCacheKey, rhs: SettingsCacheKey) -> Bool {
            return lhs.parameters == rhs.parameters && lhs.projectGUID == rhs.projectGUID && lhs.targetGUID == rhs.targetGUID && lhs.purpose == rhs.purpose && lhs.provisioningTaskInputs == rhs.provisioningTaskInputs && lhs.impartedMacroDeclarations == rhs.impartedMacroDeclarations
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(parameters)
            hasher.combine(projectGUID)
            hasher.combine(targetGUID)
            hasher.combine(provisioningTaskInputs)
            hasher.combine(purpose)
            hasher.combine(impartedMacroDeclarations)
        }
    }

    /// Get the cached settings for the given parameters, without considering the context of any project/target.
    public func getCachedSettings(_ parameters: BuildParameters, buildRequestContext: BuildRequestContext, purpose: SettingsPurpose = .build, filesSignature: ([Path]) -> FilesSignature) -> Settings {
        let key = SettingsCacheKey(parameters: parameters, projectGUID: nil, targetGUID: nil, purpose: purpose, provisioningTaskInputs: nil, impartedBuildProperties: nil)

        // Check if there were any changes in used xcconfigs
        return settingsCache.getOrInsert(key, isValid: { settings in filesSignature(settings.macroConfigPaths) == settings.macroConfigSignature }) {
            let settingsContext = SettingsContext(.build, project: nil, target: nil)
            return Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters, settingsContext: settingsContext, purpose: purpose, provisioningTaskInputs: nil, impartedBuildProperties: nil)
        }
    }

    /// Get the cached settings for the given parameters and project.
    public func getCachedSettings(_ parameters: BuildParameters, project: Project, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs? = nil, impartedBuildProperties: [ImpartedBuildProperties]? = nil, buildRequestContext: BuildRequestContext, filesSignature: ([Path]) -> FilesSignature) -> Settings {
        return getCachedSettings(parameters, project: project, target: nil, purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildProperties, buildRequestContext: buildRequestContext, filesSignature: filesSignature)
    }

    /// Get the cached settings for the given parameters and target.
    public func getCachedSettings(_ parameters: BuildParameters, target: Target, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs? = nil, impartedBuildProperties: [ImpartedBuildProperties]? = nil, buildRequestContext: BuildRequestContext, filesSignature: ([Path]) -> FilesSignature) -> Settings {
        return getCachedSettings(parameters, project: workspaceContext.workspace.project(for: target), target: target, purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildProperties, buildRequestContext: buildRequestContext, filesSignature: filesSignature)
    }

    /// Private method to get the cached settings for the given parameters, project, and target.
    ///
    /// - remark: This is internal so that clients don't somehow call this with a project which doesn't match the target, except for `BuildRequestContext` which has a cover method for it.  There are public methods covering this one.
    internal func getCachedSettings(_ parameters: BuildParameters, project: Project, target: Target? = nil, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs? = nil, impartedBuildProperties: [ImpartedBuildProperties]? = nil, buildRequestContext: BuildRequestContext, filesSignature: ([Path]) -> FilesSignature) -> Settings {
        let key = SettingsCacheKey(parameters: parameters, projectGUID: project.guid, targetGUID: target?.guid, purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildProperties)

        // Check if there were any changes in used xcconfigs
        return settingsCache.getOrInsert(key, isValid: { settings in filesSignature(settings.macroConfigPaths) == settings.macroConfigSignature }) {
            Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target, purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildProperties)
        }
    }

    /// We use a `Lazy` as the value type to allow concurrent settings construction while still ensuring we only ever construct the settings for a particular configuration once, e.g. concurrent access to already constructed settings as well as concurrent setting construction.
    private let settingsCache = ScopedKeepAliveCache(HeavyCache<SettingsCacheKey, Lazy<Settings>>(timeToLive: Tuning.workspaceSettingsCacheTTL))

    func keepAlive<R>(_ f: () throws -> R) rethrows -> R {
        try settingsCache.keepAlive(f)
    }

    func keepAlive<R>(_ f: () async throws -> R) async rethrows -> R {
        try await settingsCache.keepAlive(f)
    }

    /// Get the cached parse information for an `xcconfig` file.
    ///
    /// The loaded table will be defined in the `userNamespace` of the workspace.
    func getCachedMacroConfigFile(_ path: Path, project: Project? = nil, context: MacroConfigLoadContext, filesSignature: ([Path]) -> FilesSignature) -> MacroConfigInfo {
        let searchPaths: [Path]
        if let project {
            searchPaths = [project.sourceRoot]
        } else {
            searchPaths = [Path]()
        }

        var info = macroConfigCache.getOrInsert(MacroConfigCacheKey(path: path, searchPaths: searchPaths), isValid: { info in filesSignature(info.dependencyPaths) == info.signature }) {
            macroConfigFileLoader.loadSettingsFromConfig(path: path, namespace: workspaceContext.workspace.userNamespace, searchPaths: searchPaths, filesSignature: filesSignature)
        }

        // If we failed to read the file, add a diagnostic. We do this outside `loadSettingsFromConfig` because we intentionally avoid passing the Xcode project path there to avoid polluting the cache key (two Xcode projects in the same directory which attempt to load the same config file perform idempotent work, but we want distinct error messages for each access attempt).
        if info.isFileReadFailure {
            let message: String
            switch context {
            case .commandLineConfiguration:
                message = "Unable to open file '\(path.str)' referenced by xcodebuild -xcconfig flag or OverridingXCConfigPath user default."
            case .environmentConfiguration:
                message = "Unable to open file '\(path.str)' referenced by XCODE_XCCONFIG_FILE environment variable."
            case .baseConfiguration:
                message = "Unable to open base configuration reference file '\(path.str)'."
            }
            info.diagnostics.append(Diagnostic(behavior: .error, location: project.map { project in .path(project.xcodeprojPath) } ?? .unknown, data: DiagnosticData(message)))
        }

        return info
    }

    private let macroConfigCache = HeavyCache<MacroConfigCacheKey, Lazy<MacroConfigInfo>>(timeToLive: Tuning.workspaceSettingsCacheTTL)

    // MARK: Stacked search paths caching

    struct StackedSearchPathsCacheKey: Equatable, Hashable {
        let context: String
        let platformIdentifier: String?
        let toolchainIdentifiers: [String]
    }

    public func getCachedStackedSearchPath(context: String, platform: Platform?, toolchains: [Toolchain], _ create: (_ platform: Platform?, _ toolchains: [Toolchain]) -> StackedSearchPath) -> StackedSearchPath {
        stackedSearchPathsRegistry.getOrInsert(.init(context: context, platform: platform, toolchains: toolchains)) {
            create(platform, toolchains)
        }
    }

    private let stackedSearchPathsRegistry = Registry<StackedSearchPathsCacheKey, StackedSearchPath>()
}

extension WorkspaceSettingsCache.StackedSearchPathsCacheKey {
    init(context: String, platform: Platform?, toolchains: [Toolchain]) {
        self.context = context
        self.platformIdentifier = platform?.identifier
        self.toolchainIdentifiers = toolchains.map(\.identifier)
    }
}
