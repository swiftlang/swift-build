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
public import SWBProtocol
public import SWBMacro

fileprivate struct PreOverridesSettings {
    var sdk: SDK?
}

/// This class stores settings tables which are cached or shared across all clients of the Core.
@_spi(Testing) public final class CoreSettings {
    /// The core this object is associated with.
    unowned let core: Core

    /// The default toolchain.
    @_spi(Testing) public let defaultToolchain: Toolchain?

    /// The core build system.
    @_spi(Testing) public let coreBuildSystemSpec: BuildSystemSpec!
    /// The external build system.
    let externalBuildSystemSpec: BuildSystemSpec!
    /// The native build system.
    let nativeBuildSystemSpec: BuildSystemSpec!

    init(_ core: Core) {
        self.core = core

        // Ensure platform extended info is initialized.
        //
        // FIXME: This needs to be handled better.
        if !core.platformRegistry.hasLoadedExtendedInfo {
            core.platformRegistry.loadExtendedInfo(core.specRegistry.internalMacroNamespace)
        }

        // Bind the default toolchain.
        if let toolchain = core.toolchainRegistry.lookup("default") {
            self.defaultToolchain = toolchain
        } else {
            core.delegate.error("missing required default toolchain")
            self.defaultToolchain = nil
        }

        // We pre-bind various specifications we do not support running without.
        func getRequiredBuildSystemSpec(_ identifier: String) -> BuildSystemSpec? {
            guard let spec = core.specRegistry.getSpec(identifier) else {
                core.delegate.error("missing required spec '\(identifier)'")
                return nil
            }
            guard let buildSystemSpec = spec as? BuildSystemSpec else {
                core.delegate.error("invalid type for required 'BuildSystem' spec '\(identifier)'")
                return nil
            }
            return buildSystemSpec
        }
        self.coreBuildSystemSpec = getRequiredBuildSystemSpec("com.apple.build-system.core")
        self.externalBuildSystemSpec = getRequiredBuildSystemSpec("com.apple.build-system.external")
        self.nativeBuildSystemSpec = getRequiredBuildSystemSpec("com.apple.build-system.native")
    }

    private var unionedToolDefaultsCache = Registry<String, (MacroValueAssignmentTable, errors: [String])>()
    @_spi(Testing) public func unionedToolDefaults(domain: String) -> (table: MacroValueAssignmentTable, errors: [String]) {
        return unionedToolDefaultsCache.getOrInsert(domain) {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            var errors = [String]()

            // - We have a bag of tools, each of which has build options with optional default values.
            // - There's no meaningful ordering or layering between the tools (all tools in a domain are peers - even if they ended up in that domain through domain composition), so we don't want to add the same macros on top of each other (whether linked or overwritten). We'll only allow one assignment of any given macro.
            // - If there's a conflict (the same macro is assigned twice with different values), we'll emit an error. Since this is an error, the order in which we traverse specs to add defaults doesn't matter.

            let specs = core.specRegistry.findSpecs(CommandLineToolSpec.self, domain: domain)
            let ignoredMacros: [MacroDeclaration] = [BuiltinMacros.OutputFormat, BuiltinMacros.OutputPath]

            for spec in specs {
                for option in spec.flattenedBuildOptions.values {
                    guard !ignoredMacros.contains(option.macro) else { continue }

                    if let value = option.defaultValue {
                        if let existing = table.lookupMacro(option.macro) {
                            if existing.expression != value {
                                errors.append("Conflicting default values for \(option.macro.name):\n\(value.stringRep)\n\(existing.expression.stringRep)")
                            }
                            continue
                        }

                        table.push(option.macro, value)
                    }

                    // FIXME: Xcode has support here for adding additional build settings for the option, but nothing seems to use it. Eliminate this if nothing shows up.
                }
            }

            return (table, errors)
        }
    }

    fileprivate var universalDefaults: MacroValueAssignmentTable { return universalDefaultsCache.getValue(self) }
    private var universalDefaultsCache = LazyCache{ (settings: CoreSettings) -> MacroValueAssignmentTable in settings.computeUniversalDefaults() }
    private func computeUniversalDefaults() -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)

        // Add the constants.

        // FIXME: Deprecate this setting, once we have the capability of doing so.
        table.push(BuiltinMacros.OS, literal: "MACOS")

        table.push(BuiltinMacros.arch, literal: "undefined_arch")
        table.push(BuiltinMacros.variant, literal: "normal")

        table.push(BuiltinMacros.SYSTEM_APPS_DIR, literal: "/Applications")
        table.push(BuiltinMacros.SYSTEM_ADMIN_APPS_DIR, literal: "/Applications/Utilities")
        table.push(BuiltinMacros.SYSTEM_DEMOS_DIR, literal: "/Applications/Extras")
        table.push(BuiltinMacros.SYSTEM_LIBRARY_DIR, literal: "/System/Library")
        table.push(BuiltinMacros.SYSTEM_CORE_SERVICES_DIR, literal: "/System/Library/CoreServices")
        table.push(BuiltinMacros.SYSTEM_DOCUMENTATION_DIR, literal: "/Library/Documentation")
        table.push(BuiltinMacros.SYSTEM_LIBRARY_EXECUTABLES_DIR, literal: "")
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_EXECUTABLES_DIR, literal: "")
        table.push(BuiltinMacros.LOCAL_ADMIN_APPS_DIR, literal: "/Applications/Utilities")
        table.push(BuiltinMacros.LOCAL_APPS_DIR, literal: "/Applications")
        table.push(BuiltinMacros.LOCAL_DEVELOPER_DIR, literal: "/Library/Developer")
        table.push(BuiltinMacros.LOCAL_DEVELOPER_EXECUTABLES_DIR, literal: "")
        table.push(BuiltinMacros.LOCAL_LIBRARY_DIR, literal: "/Library")

        table.push(BuiltinMacros.USER_APPS_DIR, BuiltinMacros.namespace.parseString("$(HOME)/Applications"))
        table.push(BuiltinMacros.USER_LIBRARY_DIR, BuiltinMacros.namespace.parseString("$(HOME)/Library"))

        // TODO: rdar://80796520 (Re-enable dependency validator)
        //table.push(BuiltinMacros.VALIDATE_DEPENDENCIES, literal: .yes)
        table.push(BuiltinMacros.VALIDATE_DEVELOPMENT_ASSET_PATHS, literal: .yesError)

        table.push(BuiltinMacros.DIAGNOSE_MISSING_TARGET_DEPENDENCIES, literal: .yes)

        // This is a hack to allow more tests to run in Swift CI when using older Xcode versions.
        if core.xcodeProductBuildVersion < (try! ProductBuildVersion("16A242d")) {
            table.push(BuiltinMacros.LM_SKIP_METADATA_EXTRACTION, BuiltinMacros.namespace.parseString("YES"))
        }

        // Add the "calculated" settings.
        addCalculatedUniversalDefaults(&table)

        return table
    }

    private func addCalculatedUniversalDefaults(_ table: inout MacroValueAssignmentTable) {
        // NOTE: All of these settings must depend only on the core, and be immutable, as these values are cached in the universal defaults table.

        // FIXME: These need to translate to "fake-VFS" paths, for the pseudo-SWB testing.
        let developerPath = core.developerPath.path

        switch core.developerPath {
        case .xcode(let path):
            let legacyDeveloperPath = path.dirname.join("PlugIns/Xcode3Core.ideplugin/Contents/SharedSupport/Developer")
            table.push(BuiltinMacros.LEGACY_DEVELOPER_DIR, literal: legacyDeveloperPath.str)
        default:
            break
        }

        let developerToolsPath = developerPath.join("Tools")
        let developerAppsPath = developerPath.join("Applications")
        let developerLibPath = developerPath.join("Library")
        let developerAppSupportPath = developerLibPath.join("Xcode")
        let developerFrameworksPath = developerLibPath.join("Frameworks")
        let javaToolsPath = developerAppsPath.join("Java Tools")
        let perfToolsPath = developerAppsPath.join("Performance Tools")
        let graphicsToolsPath = developerAppsPath.join("Graphics Tools")
        let developerUtilitiesPath = developerAppsPath.join("Utilities")
        let developerDemosPath = developerUtilitiesPath.join("Built Examples")
        let developerDocPath = developerPath.join("ADC Reference Library")
        let developerToolsDocPath = developerDocPath.join("documentation/DeveloperTools")
        let developerReleaseNotesPath = developerDocPath.join("releasenotes")
        let developerToolsReleaseNotesPath = developerReleaseNotesPath.join("DeveloperTools")
        let developerUsrPath = developerPath.join("usr")
        let developerBinPath = developerPath.join("usr/bin")
        // For historical reasons, DEVELOPER_SDK_DIR is the SDKs directory inside the default (macOS) platform.  If there is no macOS platform then it will not be assigned.
        var developerSDKsPath: Path? = nil
        if let macosPlatform = core.platformRegistry.lookup(identifier: "com.apple.platform.macosx") {
            developerSDKsPath = macosPlatform.path.join("Developer/SDKs")
        }

        // FIXME: We should see if any of these can be deprecated, once we support that.
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_DIR, literal: developerPath.str)
        table.push(BuiltinMacros.DEVELOPER_DIR, literal: developerPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_APPS_DIR, literal: developerAppsPath.str)
        table.push(BuiltinMacros.DEVELOPER_APPLICATIONS_DIR, literal: developerAppsPath.str)
        table.push(BuiltinMacros.DEVELOPER_LIBRARY_DIR, literal: developerLibPath.str)
        table.push(BuiltinMacros.DEVELOPER_FRAMEWORKS_DIR, literal: developerFrameworksPath.str)
        table.push(BuiltinMacros.DEVELOPER_FRAMEWORKS_DIR_QUOTED, literal: developerFrameworksPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_JAVA_TOOLS_DIR, literal: javaToolsPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_PERFORMANCE_TOOLS_DIR, literal: perfToolsPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_GRAPHICS_TOOLS_DIR, literal: graphicsToolsPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_UTILITIES_DIR, literal: developerUtilitiesPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_DEMOS_DIR, literal: developerDemosPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_DOC_DIR, literal: developerDocPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_TOOLS_DOC_DIR, literal: developerToolsDocPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_RELEASENOTES_DIR, literal: developerReleaseNotesPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_TOOLS_RELEASENOTES_DIR, literal: developerToolsReleaseNotesPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_TOOLS, literal: developerToolsPath.str)
        table.push(BuiltinMacros.DEVELOPER_TOOLS_DIR, literal: developerToolsPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_USR_DIR, literal: developerUsrPath.str)
        table.push(BuiltinMacros.DEVELOPER_USR_DIR, literal: developerUsrPath.str)
        table.push(BuiltinMacros.SYSTEM_DEVELOPER_BIN_DIR, literal: developerBinPath.str)
        table.push(BuiltinMacros.DEVELOPER_BIN_DIR, literal: developerBinPath.str)
        if let developerSDKsPath {
            table.push(BuiltinMacros.DEVELOPER_SDK_DIR, literal: developerSDKsPath.str)
        }
        table.push(BuiltinMacros.XCODE_APP_SUPPORT_DIR, literal: developerAppSupportPath.str)

        let availablePlatformNames = core.platformRegistry.platformsByIdentifier.values.map({ $0.name }).sorted()
        table.push(BuiltinMacros.AVAILABLE_PLATFORMS, literal: availablePlatformNames)
    }

    // FIXME: This never actually pushed anything to the table, so I've disabled it for now.
    #if false
    private var unionedCustomizedCompilerDefaultsCache = Registry<String, MacroValueAssignmentTable>()
    fileprivate func unionedCustomizedCompilerDefaults(domain: String) -> MacroValueAssignmentTable {
        // FIXME: This table is barely used (for Xcode proper it is almost empty). We should figure out if there might be a simpler solution to this problem.
        //
        // That said, it would likely be used a lot more often if we started to pull compiler specific defaults out of the unioned table, although if we had alternate support for them (for example, recognizing the macro type as compiler specific and error out on access from invalid contents), then we might still be able to push them as a single unioned table.
        return unionedCustomizedCompilerDefaultsCache.getOrInsert(domain) {
            // Add the defaults from all the registered tools in the given domain.
            //
            // FIXME: This is somewhat wasteful, as we end up duplicating values for super specifications. However, that lets us keep the condition set required to enable a particular compiler very simple.
            let unionedDefaults = unionedToolDefaults(domain: domain)
            let customizedDefaults = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            for spec in core.specRegistry.findSpecs(CompilerSpec.self, domain: domain) {
                // Add all the necessary defaults.
                for option in spec.flattenedBuildOptions.values {
                    if let defaultValue = option.defaultValue {
                        // Only push the default value if it diverges from the existing default.
                        //
                        // FIXME: This optimization could be subsumed by the macro assignment table itself, but for now we do it here as an important special case.
                        if let existingDefault = unionedDefaults.lookupMacro(option.macro)?.expression, existingDefault == defaultValue {
                            continue
                        }

                        // FIXME: Need ability to push conditional assignments.
                    }
                }
            }
            return customizedDefaults
        }
    }
    #endif

    /// The cache for system build rules.
    private let systemBuildRuleCache = Registry<SystemBuildRuleCacheKey, SystemBuildRules>()

    struct SystemBuildRuleCacheKey: Hashable {
        private let combineHiDPIImages: Bool
        private let platform: Ref<Platform>?

        init(combineHiDPIImages: Bool, platform: Ref<Platform>?) {
            self.combineHiDPIImages = combineHiDPIImages
            self.platform = platform
        }
    }
    struct SystemBuildRules {
        let rules: [(any BuildRuleCondition, any BuildRuleAction)]
        let diagnostics: OrderedSet<Diagnostic>
    }

    fileprivate func systemBuildRules(combineHiDPIImages: Bool, platform: Platform?, scope: MacroEvaluationScope) -> SystemBuildRules {
        let key = SystemBuildRuleCacheKey(combineHiDPIImages: combineHiDPIImages, platform: platform.map({ Ref($0) }))
        let value = systemBuildRuleCache.getOrInsert(key) {
            let specLookupContext = SpecLookupCtxt(specRegistry: core.specRegistry, platform: platform)
            var diagnostics = OrderedSet<Diagnostic>()

            // The namespace to use to parse settings.
            let namespace = specLookupContext.specRegistry.internalMacroNamespace

            // We’ll be building up and returning an array of condition-action pairs.
            var rules = [(any BuildRuleCondition, any BuildRuleAction)]()

            guard let tiffutilToolSpec = specLookupContext.getSpec("com.apple.compilers.tiffutil") as? CommandLineToolSpec else {
                diagnostics.append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Couldn't load tool spec com.apple.compilers.tiffutil")))
                return .init(rules: [], diagnostics: diagnostics)
            }

            guard let copyTiffFileToolSpec = specLookupContext.getSpec("com.apple.build-tasks.copy-tiff-file") as? CommandLineToolSpec else {
                diagnostics.append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Couldn't load tool spec com.apple.build-tasks.copy-tiff-file")))
                return .init(rules: [], diagnostics: diagnostics)
            }

            // Temporary hack: Add a couple of rules for combining HiDPI images. These rules are handled through custom logic in the legacy build system. We emulate this by making them precede the other rules.
            let tiffRuleAction = combineHiDPIImages ? tiffutilToolSpec : copyTiffFileToolSpec
            // FIXME: This should probably use file types instead of patterns once we have a good API for that.
            rules.append((BuildRuleFileNameCondition(namePatterns: [Static { namespace.parseString("*.tiff") }]), BuildRuleTaskAction(toolSpec: tiffRuleAction)))
            rules.append((BuildRuleFileNameCondition(namePatterns: [Static { namespace.parseString("*.tif") }]), BuildRuleTaskAction(toolSpec: tiffRuleAction)))
            if combineHiDPIImages {
                rules.append((BuildRuleFileNameCondition(namePatterns: [Static { namespace.parseString("*.png") }]), BuildRuleTaskAction(toolSpec: tiffutilToolSpec)))
                rules.append((BuildRuleFileNameCondition(namePatterns: [Static { namespace.parseString("*.jpg") }]), BuildRuleTaskAction(toolSpec: tiffutilToolSpec)))
            }

            // First we synthesize build rules from tool specifications which declare that they do so.
            // Sort the tool specifications by identifier, since there is no inherent order between them; this at least stable, and matches Xcode.
            for toolSpec in specLookupContext.findSpecs(CommandLineToolSpec.self).sorted(by: \.identifier) {

                // If the tool specification doesn’t want to synthesize build rules, we just proceed to the next one.
                guard toolSpec.shouldSynthesizeBuildRules else { continue }

                // If the tool specification doesn’t have any file type descriptors, we just proceed to the next one.
                guard let inputFileTypeDescriptors = toolSpec.inputFileTypeDescriptors else { continue }

                // Otherwise, go through its input file type descriptors
                for inputFileType in inputFileTypeDescriptors {
                    guard let fileType = specLookupContext.getSpec(inputFileType.identifier) as? FileTypeSpec else {
                        diagnostics.append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Couldn't load file type spec '\(inputFileType.identifier)' in domain '\(specLookupContext.domain)'")))
                        return .init(rules: [], diagnostics: diagnostics)
                    }

                    // Create a condition and an action from the information in the tool specification.
                    let condition = BuildRuleFileTypeCondition(fileType: fileType)
                    let action = BuildRuleTaskAction(toolSpec: toolSpec)

                    // Append the condition-action pair as a build rule.
                    rules.append((condition, action))
                }
            }

            // Method to load all build rules from a plist file.
            func loadBuildRules(from path: Path) -> [(any BuildRuleCondition, any BuildRuleAction)] {
                do {
                    return try PropertyList.decode([BuildRuleFile].self, from: PropertyList.fromPath(path, fs: localFS)).map {
                        try core.createRule(buildRule: $0, platform: platform, scope: scope, namespace: namespace)
                    }
                } catch {
                    diagnostics.append(Diagnostic(behavior: .error, location: .path(path), data: DiagnosticData("Couldn't load build rules file: \(error)")))
                    return []
                }
            }

            func findAndLoadBuildRules(resourcesPath: Path) {
                for item in (try? localFS.listdir(resourcesPath)) ?? [] {
                    let itemPath = resourcesPath.join(item)

                    // If this is a .xcbuildrules file, then load it. Ignore dotfiles, as installing roots on filesystems which don't support extended attributes (such as NFS) may create AppleDouble files.
                    if !itemPath.basename.hasPrefix(".") && itemPath.fileSuffix == ".xcbuildrules" {
                        rules.append(contentsOf: loadBuildRules(from: itemPath))
                    }
                }
            }

            @preconcurrency @PluginExtensionSystemActor func searchPaths() -> [Path] {
                core.pluginManager.extensions(of: SpecificationsExtensionPoint.self).flatMap { ext in
                    ext.specificationSearchPaths(resourceSearchPaths: core.resourceSearchPaths).compactMap { try? $0.filePath }
                }.sorted()
            }

            // Add rules from the Resources directories of the loaded plugins. We sort the paths to ensure deterministic loading.
            for searchPath in searchPaths() {
                findAndLoadBuildRules(resourcesPath: searchPath)
            }

            return SystemBuildRules(rules: rules, diagnostics: diagnostics)
        }
        return value
    }
}

/// This class stores settings tables which are cached by the WorkspaceContext.
final class WorkspaceSettings: Sendable {
    unowned let workspaceContext: WorkspaceContext

    var core: Core {
        return workspaceContext.core
    }
    var coreSettings: CoreSettings {
        return core.coreSettings
    }

    init(_ workspaceContext: WorkspaceContext) {
        self.workspaceContext = workspaceContext
    }

    struct BuiltinSettingsInfoKey: Hashable, Sendable {
        let targetType: TargetType?
        let domain: String
    }
    struct BuiltinSettingsInfo: Sendable {
        /// The actual settings.
        let table: MacroValueAssignmentTable

        /// The set of macro name to export to shell scripts.
        let exportedMacros: Set<MacroDeclaration>

        /// Errors generated during construction, to be reported in the build log.
        let errors: [String]
    }

    private let builtinSettingsInfoCache = Registry<BuiltinSettingsInfoKey, BuiltinSettingsInfo>()

    func builtinSettingsInfo(forTargetType targetType: TargetType?, domain: String) -> BuiltinSettingsInfo {
        return builtinSettingsInfoCache.getOrInsert(BuiltinSettingsInfoKey(targetType: targetType, domain: domain)) {
            var errors = [String]()
            var builtinsTable = MacroValueAssignmentTable(namespace: workspaceContext.workspace.userNamespace)
            var exportedMacros = Set<MacroDeclaration>()
            func push(_ items: MacroValueAssignmentTable, exported: Bool = false) {
                builtinsTable.pushContentsOf(items)
                if exported {
                    exportedMacros.formUnion(items.valueAssignments.keys)
                }
            }

            // Add the environment settings from the user info.
            if let userInfo = workspaceContext.userInfo {
                // FIXME: See also `createTableFromUserSettings`
                var settingsCopy = [String: PropertyListItem]()
                for (key, value) in userInfo.buildSystemEnvironment {
                    settingsCopy[key] = .plString(value)
                }
                do {
                    push(try builtinsTable.namespace.parseTable(settingsCopy, allowUserDefined: true))
                } catch {
                    errors.append("unable to parse user environment: '\(error)'")
                }
            }

            // Add the tool defaults.
            do {
                let (table, toolErrors) = coreSettings.unionedToolDefaults(domain: domain)
                push(table)
                errors.append(contentsOf: toolErrors)
            }

            // Add the builtin universal settings.
            push(coreSettings.universalDefaults, exported: true)

            // Add the dynamic defaults which may depend on the environment.
            push(getDynamicUniversalDefaults(), exported: true)

            // Add internal, implementation specific defaults.
            push(getInternalDefaults())

            // Add the appropriate build system settings.
            // FIXME: <rdar://problem/56210749> Support BuildSystem specs per platform - Radar contains work-in-progress patches to support this.
            let buildSystemSpec: BuildSystemSpec
            switch targetType {
            case .external?:
                buildSystemSpec = coreSettings.externalBuildSystemSpec
            case .standard?, .aggregate?, .packageProduct?:
                buildSystemSpec = coreSettings.nativeBuildSystemSpec
            case nil:
                buildSystemSpec = coreSettings.coreBuildSystemSpec
            }
            do {
                var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
                for option in buildSystemSpec.flattenedBuildOptions.values {
                    option.addDefaultIfNecessary(&table)
                }

                // Add additional settings from build settings specs.
                //
                // FIXME: For legacy compatibility, we only do this when configuring settings for a target. This distinction most likely isn't important, and should just be eliminated.
                if targetType != nil {
                    for spec in core.specRegistry.findSpecs(BuildSettingsSpec.self, domain: domain) {
                        for option in spec.flattenedBuildOptions.values {
                            option.addDefaultIfNecessary(&table)
                        }
                    }
                }

                push(table, exported: true)
            }

            // Add the compiler specific settings.
            //
            // This is necessary to support tools that have distinct values for the same settings (otherwise the tool defaults above would covert it), and is used in conjunction with a compiler condition asserted by the build phase processing.
            #if false // This never did anything, see comments at `unionedCustomizedCompilerDefaults`
            push(coreSettings.unionedCustomizedCompilerDefaults(domain: domain))
            #endif

            return BuiltinSettingsInfo(table: builtinsTable, exportedMacros: exportedMacros, errors: errors)
        }
    }

    // MARK: Utilities

    func getCacheRoot() -> Path {
        // FIXME: Cache this.

        // Use the value of CCHROOT if it is provided, absolute, and not doesn't look like our own caches path.
        let cacheRootPath: Path
        if let cchroot = workspaceContext.userInfo?.buildSystemEnvironment["CCHROOT"], cchroot.hasPrefix("/") && cchroot != "" && !cchroot.hasPrefix("/Library/Caches/com.apple.Xcode") {
            cacheRootPath = Path(cchroot)
        } else {
            // Otherwise, derive the result from the secure system cache directory.
            cacheRootPath = userCacheDir().join("com.apple.DeveloperTools")
        }

        // Add the version, build, and app name (to match Xcode).
        return cacheRootPath.join("\(core.xcodeVersionString)-\(core.xcodeProductBuildVersionString)").join("Xcode")
    }

    /// Add the dynamic universal defaults.
    func getDynamicUniversalDefaults() -> MacroValueAssignmentTable {
        // These settings are always exported.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        // Add the CACHE_ROOT definition.
        table.push(BuiltinMacros.CACHE_ROOT, literal: getCacheRoot().str)

        // Add additional settings for which we explicitly allow the environment to override the default definition.

        // Inherit or add DT_TOOLCHAIN_DIR.
        if let dtToolchainDir = workspaceContext.userInfo?.buildSystemEnvironment["DT_TOOLCHAIN_DIR"] {
            table.push(BuiltinMacros.DT_TOOLCHAIN_DIR, literal: dtToolchainDir)
        } else if let defaultToolchain = coreSettings.defaultToolchain {
            table.push(BuiltinMacros.DT_TOOLCHAIN_DIR, literal: defaultToolchain.path.str)
        }

        return table
    }

    /// Add internal implementation specific defaults.
    func getInternalDefaults() -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        // Add convenience macros for access some computed files for Swift.
        table.push(BuiltinMacros.SWIFT_UNEXTENDED_MODULE_MAP_PATH, Static { BuiltinMacros.namespace.parseString("$(TARGET_TEMP_DIR)/unextended-module.modulemap") })
        table.push(BuiltinMacros.SWIFT_UNEXTENDED_VFS_OVERLAY_PATH, Static { BuiltinMacros.namespace.parseString("$(TARGET_TEMP_DIR)/unextended-module-overlay.yaml") })
        table.push(BuiltinMacros.SWIFT_UNEXTENDED_INTERFACE_HEADER_PATH, Static { BuiltinMacros.namespace.parseString("$(TARGET_TEMP_DIR)/unextended-interface-header.h") })

        // Add convenience macros for TAPI.
        table.push(BuiltinMacros.TAPI_OUTPUT_PATH, Static { BuiltinMacros.namespace.parseString("$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/$(EXECUTABLE_PREFIX)$(PRODUCT_NAME)$(EXECUTABLE_VARIANT_SUFFIX).tbd") })

        // Add shared output path for eager linking TBDs.
        table.push(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_DIR, Static { BuiltinMacros.namespace.parseString("$(OBJROOT)/EagerLinkingTBDs/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)") })
        table.push(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH, Static { BuiltinMacros.namespace.parseString("$(EAGER_LINKING_INTERMEDIATE_TBD_DIR)/$(CONTENTS_FOLDER_PATH)/$(EXECUTABLE_PREFIX)$(PRODUCT_NAME)$(EXECUTABLE_VARIANT_SUFFIX).tbd") })

        // Add shared output path for clang explicit modules
        table.push(BuiltinMacros.CLANG_EXPLICIT_MODULES_OUTPUT_PATH, Static { BuiltinMacros.namespace.parseString("$(OBJROOT)/ExplicitPrecompiledModules") })

        // Add shared output path for Swift explicit modules
        table.push(BuiltinMacros.SWIFT_EXPLICIT_MODULES_OUTPUT_PATH, Static { BuiltinMacros.namespace.parseString("$(OBJROOT)/SwiftExplicitPrecompiledModules") })

        // Add default values for the compilation caching plugin (off-by-default).
        table.push(BuiltinMacros.COMPILATION_CACHE_PLUGIN_PATH, Static { BuiltinMacros.namespace.parseString("$(DEVELOPER_USR_DIR)/lib/libToolchainCASPlugin.dylib") })

        // Add default value for using integrated compilation cache queries.
        table.push(BuiltinMacros.COMPILATION_CACHE_ENABLE_INTEGRATED_QUERIES, literal: true)

        // Enable the integrated driver
        table.push(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER, literal: true)

        if SWBFeatureFlag.enableEagerLinkingByDefault.value {
            table.push(BuiltinMacros.EAGER_LINKING, literal: true)
        }

        // Add default value for using Swift response files
        table.push(BuiltinMacros.USE_SWIFT_RESPONSE_FILE, literal: true)

        // Do not add arm64e to ARCHS_STANDARD by default
        table.push(BuiltinMacros.ENABLE_POINTER_AUTHENTICATION, literal: false)

        // Enable additional codesign tracking by default, but opt-out of scripts phases as their outputs are free-form, and thus have the potential to introduce cycles in the build some circumstances. If that does happen, these build settings provide a relief valve while projects authors figure out how to break the cycle they are introducing (or how we break the target dependencies more granularly).
        table.push(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING, literal: true)
        table.push(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS, literal: true)

        /// <rdar://problem/59862065> Remove EnableInstallHeadersFiltering after validation
        if SWBFeatureFlag.enableInstallHeadersFiltering.value {
            table.push(BuiltinMacros.EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING, literal: true)
        }

        if SWBFeatureFlag.enableClangExplicitModulesByDefault.value {
            table.push(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES, literal: true)
        }

        if SWBFeatureFlag.enableSwiftExplicitModulesByDefault.value {
            table.push(BuiltinMacros.SWIFT_ENABLE_EXPLICIT_MODULES, literal: .enabled)
        }

        if SWBFeatureFlag.enableClangCachingByDefault.value {
            table.push(BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE, literal: true)
        }

        if SWBFeatureFlag.enableSwiftCachingByDefault.value {
            table.push(BuiltinMacros.SWIFT_ENABLE_COMPILE_CACHE, literal: true)
        }

        return table
    }
}


/// This class represents the computed settings of a project and (optionally) target.
public final class Settings: PlatformBuildContext, Sendable {
    /// The build parameters which were used to construct these settings.
    public let parameters: BuildParameters

    private let settingsContext: SettingsContext

    /// The project the settings are for, if any.
    public var project: Project? {
        return settingsContext.project
    }

    /// The target the settings are for, if any.
    public var target: Target? {
        return settingsContext.target
    }

    /// The effective configuration for the target, if any.  If there is no target, this will be nil.  If there is a target, then this will be the configuration specified in the build parameters if there is one, or else the default configuration in the project, if there is one.  Or else it will be nil.
    public let targetConfiguration: BuildConfiguration?

    // FIXME: This probably shouldn't be duplicated among all targets, and could be shared by the project or higher-level context.
    //
    /// The namespace in which user macros will be registered.
    public let userNamespace: MacroNamespace

    /// The bound platform, if any.
    public let platform: Platform?

    /// The bound SDK, if any.
    public let sdk: SDK?

    /// The bound SDK variant, if any.
    public let sdkVariant: SDKVariant?

    /// The bound toolchains.
    public let toolchains: [Toolchain]

    /// The bound sparse SDKs.
    public let sparseSDKs: [SDK]

    /// The settings table.
    ///
    /// Nothing should have to access this directly once it's been created - in particular nothing should be able to push additional macros onto the table.
    fileprivate let table: MacroValueAssignmentTable

    /// The bound product type, if appropriate.
    public let productType: ProductTypeSpec?

    /// The bound package type, if appropriate.
    public let packageType: PackageTypeSpec?

    /// The computed preferred architecture.
    ///
    /// This is currently only used for indexing but should be used
    /// with single-file compile and analyzer as well.
    public let preferredArch: String?

    /// The set of macro name to export to shell scripts.
    public let exportedMacroNames: Set<MacroDeclaration>

    /// The set of additional macros to be exported to shell scripts running in native builds.
    public let exportedNativeMacroNames: Set<MacroDeclaration>

    /// The global evaluation scope.
    public let globalScope: MacroEvaluationScope

    /// The file path resolver.
    public let filePathResolver: FilePathResolver

    /// The executable search paths.
    public let executableSearchPaths: StackedSearchPath

    /// The framework search paths.
    public let fallbackFrameworkSearchPaths: StackedSearchPath

    /// The library search paths.
    public let fallbackLibrarySearchPaths: StackedSearchPath

    /// Errors generated during settings construction, to be reported in the build log.
    public let errors: OrderedSet<String>

    /// Warnings generated during settings construction, to be reported in the build log.
    public let warnings: OrderedSet<String>

    /// Notes generated during settings construction, to be reported in the build log.
    public let notes: OrderedSet<String>

    /// Diagnostics generated during settings construction, to be reported in the build log.
    /// This is used for diagnostics which need the full API and aren't represented as a single string as in `errors`, `warnings`, and `notes`.
    // FIXME: <rdar://70240308> Remove the latter three at some point and introduce convenience methods to emit simple-string diagnostics.
    public let diagnostics: OrderedSet<Diagnostic>

    /// Target-specific counterpart of `diagnostics`.
    public let targetDiagnostics: OrderedSet<Diagnostic>

    /// The list of XCConfigs used to construct the settings.
    let macroConfigPaths: [Path]

    /// The signature of the XCConfigs used to construct the settings.
    public let macroConfigSignature: FilesSignature

    /// The list of system build rules to use for these settings.
    public let systemBuildRules: [(any BuildRuleCondition, any BuildRuleAction)]

    public struct SigningSettings: Sendable {
        public let inputs: ProvisioningTaskInputs

        public struct Identity: Sendable {
            /// May be "-" for ad hoc signing.
            public let hash: String
            public let name: String
        }

        public let identity: Identity

        public struct Profile: Sendable {
            public let input: Path
            public let output: Path
        }

        public let profile: Profile?

        public struct Entitlements: Sendable {
            // Input may be a path (CODE_SIGN_ENTITLEMENTS in the scope) or a dict of merged entitlements in ProvisioningTaskInputs. It's currently handled at task construction, but it might make sense to move it here to share it.
            public let output: Path

            // DER-encoded equivalent of `output` plist.
            public let outputDer: Path
        }

        public let signedEntitlements: Entitlements?
        public let simulatedEntitlements: Entitlements?

        public struct LaunchConstraints: Sendable {
            public let process: Path?
            public let parentProcess: Path?
            public let responsibleProcess: Path?
        }

        public let launchConstraints: LaunchConstraints
        public let libraryConstraint: Path?
    }

    /// The bound signing settings.
    public let signingSettings: SigningSettings?

    /// The bound deployment target for the deployment target macro defined in the platform.
    public let deploymentTarget: Version?

    /// The supported platforms of a target, taking into account pre-overrides.
    /// For example, this will contain both `iOS` and `macCatalyst` when building for macCatalyst, if the target's SDKROOT was `iphoneos`.
    public let supportedBuildVersionPlatforms: Set<BuildVersion.Platform>

    public var targetBuildVersionPlatforms: Set<BuildVersion.Platform>? {
        targetBuildVersionPlatforms(in: globalScope)
    }

    public static func supportsMacCatalyst(scope: MacroEvaluationScope, core: Core) -> Bool {
        @preconcurrency @PluginExtensionSystemActor func sdkVariantInfoExtensions() -> [any SDKVariantInfoExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: SDKVariantInfoExtensionPoint.self)
        }
        var supportsMacCatalystMacros: Set<String> = []
        for sdkVariantInfoExtension in sdkVariantInfoExtensions() {
            supportsMacCatalystMacros.formUnion(sdkVariantInfoExtension.supportsMacCatalystMacroNames)
        }

        return supportsMacCatalystMacros.contains { scope.evaluate(scope.namespace.parseString("$(\($0)")).boolValue } ||
            // For index build ensure zippered frameworks can be configured separately for both macOS and macCatalyst.
            (scope.evaluate(BuiltinMacros.IS_ZIPPERED) && scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA))
    }

    public static func supportsCompilationCaching(_ core: Core) -> Bool {
        @preconcurrency @PluginExtensionSystemActor func featureAvailabilityExtensions() -> [any FeatureAvailabilityExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: FeatureAvailabilityExtensionPoint.self)
        }
        return featureAvailabilityExtensions().contains {
            $0.supportsCompilationCaching
        }
    }

    public var enableTargetPlatformSpecialization: Bool {
        return Settings.targetPlatformSpecializationEnabled(scope: globalScope)
    }

    public static func targetPlatformSpecializationEnabled(scope: MacroEvaluationScope) -> Bool {
        return scope.evaluate(BuiltinMacros.ALLOW_TARGET_PLATFORM_SPECIALIZATION) ||
            SWBFeatureFlag.allowTargetPlatformSpecialization.value
    }

    public var enableBuildRequestOverrides: Bool {
        return Settings.buildRequestOverridesEnabled(scope: globalScope)
    }

    public static func buildRequestOverridesEnabled(scope: MacroEvaluationScope) -> Bool {
        return scope.evaluate(BuiltinMacros.ALLOW_BUILD_REQUEST_OVERRIDES)
    }

    /// Structure to hold information about the project model components from which a settings object was constructed.
    ///
    /// - remark: The overhead of this object should be very small, because the majority of the actual data are the linked lists of macro definitions, which are shared with the main table in the `Settings` object.
    public struct ConstructionComponents: Sendable {
        // These properties are the individual tables (and info about them) of specific levels which contributed to the Settings.

        /// The path to the project-level xcconfig file.
        let projectXcconfigPath: Path?
        /// The project-level xcconfig settings table.
        let projectXcconfigSettings: MacroValueAssignmentTable?
        /// The project-level settings table.
        let projectSettings: MacroValueAssignmentTable?
        /// The path to the target-level xcconfig file.
        let targetXcconfigPath: Path?
        /// The target-level xcconfig settings table.
        let targetXcconfigSettings: MacroValueAssignmentTable?
        /// The target-level settings table.
        let targetSettings: MacroValueAssignmentTable?

        // These properties are the actual tables of settings up to a certain point, which are used to compute the resolved values of settings at that level in the build settings editor (e.g., in the Levels view).

        /// The defaults settings table (basically everything below the project xcconfig settings).
        let upToDefaultsSettings: MacroValueAssignmentTable?
        /// The settings up to the project-level xcconfig.
        let upToProjectXcconfigSettings: MacroValueAssignmentTable?
        /// The settings up to the project-level.
        let upToProjectSettings: MacroValueAssignmentTable?
        /// The settings up to the target-level xcconfig.
        let upToTargetXcconfigSettings: MacroValueAssignmentTable?
        /// The settings up to the target-level.
        let upToTargetSettings: MacroValueAssignmentTable?
    }

    /// The information about the project model components from which these settings were constructed.
    public let constructionComponents: ConstructionComponents

    public convenience init(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, parameters: BuildParameters, project: Project, target: Target? = nil, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs? = nil, impartedBuildProperties: [ImpartedBuildProperties]? = nil, includeExports: Bool = true, sdkRegistry: (any SDKRegistryLookup)? = nil) {
        self.init(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters, settingsContext: SettingsContext(purpose, project: project, target: target), purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildProperties, includeExports: includeExports, sdkRegistry: sdkRegistry)
    }

    /// Construct the settings for a project and optionally a target.
    public init(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, parameters: BuildParameters, settingsContext: SettingsContext, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs? = nil, impartedBuildProperties: [ImpartedBuildProperties]? = nil, includeExports: Bool = true, sdkRegistry: (any SDKRegistryLookup)? = nil) {
        if let target = settingsContext.target {
            precondition(workspaceContext.workspace.project(for: target) === settingsContext.project)
        }

        self.parameters = parameters
        self.settingsContext = settingsContext

        // Construct the settings table.
        let builder = SettingsBuilder(workspaceContext, buildRequestContext, parameters, settingsContext, provisioningTaskInputs, includeExports: includeExports, sdkRegistry)
        let (boundProperties, boundDeploymentTarget) = MacroNamespace.withExpressionInterningEnabled{ builder.construct(impartedBuildProperties) }

        // Extract the constructed data.
        self.targetConfiguration = builder.targetConfiguration
        self.userNamespace = builder.userNamespace
        self.platform = boundProperties.platform
        self.sdk = boundProperties.sdk
        self.sdkVariant = boundProperties.sdkVariant
        self.toolchains = boundProperties.toolchains
        self.sparseSDKs = boundProperties.sparseSDKs
        self.deploymentTarget = boundDeploymentTarget.platformDeploymentTarget
        self.table = builder._table
        self.productType = builder.productType
        self.packageType = builder.packageType
        self.preferredArch = builder.preferredArch
        self.exportedMacroNames = builder.exportedMacroNames
        self.exportedNativeMacroNames = builder.exportedNativeMacroNames
        self.macroConfigPaths = builder.macroConfigPaths.elements
        self.macroConfigSignature = builder.macroConfigSignature
        self.signingSettings = builder.signingSettings

        // Create the global evaluation scope.  This uses the bound SDK if the SettingsContext's purpose wants that condition.
        let globalScope = builder.createScope(sdkToUse: settingsContext.purpose.bindToSDK ? self.sdk : nil)
        self.globalScope = globalScope

        // Create the file path resolver.
        self.filePathResolver = FilePathResolver(scope: globalScope, projectDir: settingsContext.project == nil ? .root : nil)

        // Compute the executable search paths.
        self.executableSearchPaths = workspaceContext.createExecutableSearchPaths(platform: boundProperties.platform, toolchains: boundProperties.toolchains)

        // Compute the fallback framework search paths.
        self.fallbackFrameworkSearchPaths = workspaceContext.createFallbackFrameworkSearchPaths(platform: boundProperties.platform, toolchains: boundProperties.toolchains)

        // Compute the fallback library search paths.
        self.fallbackLibrarySearchPaths = workspaceContext.createFallbackLibrarySearchPaths(platform: boundProperties.platform, toolchains: boundProperties.toolchains)

        // Compute the system build rules.
        let combineHiDPIImages = globalScope.evaluate(BuiltinMacros.COMBINE_HIDPI_IMAGES)
        let systemBuildRules = workspaceContext.core.coreSettings.systemBuildRules(combineHiDPIImages: combineHiDPIImages, platform: platform, scope: globalScope)
        self.systemBuildRules = systemBuildRules.rules
        self.errors = builder.errors
        self.warnings = builder.warnings
        self.notes = builder.notes
        self.diagnostics = builder.diagnostics.appending(contentsOf: systemBuildRules.diagnostics)
        self.targetDiagnostics = builder.targetDiagnostics

        func effectiveSupportedPlatforms(sdkRegistry: (any SDKRegistryLookup)?) -> Set<BuildVersion.Platform> {
            // Everything in SUPPORTED_PLATFORMS
            let supportedPlatforms: [BuildVersion.Platform] = (globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS).compactMap { try? sdkRegistry?.lookup($0, activeRunDestination: parameters.activeRunDestination) }.compactMap { $0.targetBuildVersionPlatform() })

            // macCatalyst, if any of the SUPPORTS_* macros are set
            let macCatalyst: [BuildVersion.Platform] = (Settings.supportsMacCatalyst(scope: globalScope, core: workspaceContext.core) ? [.macCatalyst] : [])

            // The original SDK before overridden by the run destination
            let originalSDK: [BuildVersion.Platform] = boundProperties.preOverrides.sdk?.targetBuildVersionPlatform().map { [$0] } ?? []

            // The current SDK, if not otherwise captured for any reason
            let currentSDK: [BuildVersion.Platform] = boundProperties.sdk?.targetBuildVersionPlatform(sdkVariant: boundProperties.sdkVariant).map { [$0] } ?? []

            return Set(supportedPlatforms + macCatalyst + originalSDK + currentSDK)
        }

        self.supportedBuildVersionPlatforms = effectiveSupportedPlatforms(sdkRegistry: sdkRegistry)

        self.constructionComponents = builder.constructionComponents
    }

    public var infoForBuildSettingsEditor: BuildSettingsEditorInfoPayload {
        // FIXME: Annoyingly this probably needs to have both String and [String] values.
        func assignedValues(for table: MacroValueAssignmentTable?) -> [String: String]? {
            guard let table else {
                return nil
            }
            var result = [String: String]()
            for (settingName, assignment) in table.valueAssignments {
                // We walk all of the assignments in the linked list, adding the first one we see of each set of conditions.
                var asgn: MacroValueAssignment? = assignment
                while let a = asgn {
                    var settingAndConditions = settingName.name
                    if let c = a.conditions {
                        settingAndConditions = settingAndConditions + c.description
                    }
                    if result[settingAndConditions] == nil {
                        result[settingAndConditions] = a.expression.stringRep
                    }
                    asgn = a.next
                }
            }
            return result
        }

        func resolvedValues(for table: MacroValueAssignmentTable?) -> [String: String]? {
            guard let table else {
                return nil
            }
            var conditionParameterValues = [MacroConditionParameter: [String]]()
            if let targetConfiguration {
                conditionParameterValues[BuiltinMacros.configurationCondition] = [targetConfiguration.name]
            }
            // We don't set any other condition parameters because they would get in the way of showing settings across all condition parameters as the editor wants to do.
            let scope = MacroEvaluationScope(table: table, conditionParameterValues: conditionParameterValues)
            var result = [String: String]()
            for (settingName, assignment) in table.valueAssignments {
                // We walk all of the assignments in the linked list, adding the first one we see of each set of conditions.
                var asgn: MacroValueAssignment? = assignment
                while let a = asgn {
                    var settingAndConditions = settingName.name
                    var effectiveScope = scope
                    if let c = a.conditions {
                        settingAndConditions = settingAndConditions + c.description

                        // If we have any conditions in the assignment, then we create a subscope which uses those conditions as the subscope's condition parameters to evaluate the value.  Because this is the best information we have to get a resolved value.
                        for condition in c.conditions.sorted(by: { $0.parameter.name < $1.parameter.name }) {
                            effectiveScope = effectiveScope.subscope(binding: condition.parameter, to: condition.valuePattern)
                        }
                    }
                    if result[settingAndConditions] == nil {
                        // This is a bit unintuitive: We don't want to evaluate the setting itself here, because that won't work right in the case of conditions.  Instead we evaluate the value assignment's expression.
                        // This is extra-tricky because we want to evaluate it as a string, but the expression may be a string-list, and MacroEvaluationScope doesn't provide a generic method to evaluate a MacroExpression.
                        result[settingAndConditions] = evaluateAsString(a, macro: settingName, scope: effectiveScope)
                    }
                    asgn = a.next
                }
            }
            return result
        }

        return BuildSettingsEditorInfoPayload(
            // Assigned values
            targetSettingAssignments: assignedValues(for: constructionComponents.targetSettings),
            targetXcconfigSettingAssignments: assignedValues(for: constructionComponents.targetXcconfigSettings),
            projectSettingAssignments: assignedValues(for: constructionComponents.projectSettings),
            projectXcconfigSettingAssignments: assignedValues(for: constructionComponents.projectXcconfigSettings),

            // Resolved values
            targetResolvedSettingsValues: resolvedValues(for: constructionComponents.upToTargetSettings),
            targetXcconfigResolvedSettingsValues: resolvedValues(for: constructionComponents.upToTargetXcconfigSettings),
            projectResolvedSettingsValues: resolvedValues(for: constructionComponents.upToProjectSettings),
            projectXcconfigResolvedSettingsValues: resolvedValues(for: constructionComponents.upToProjectXcconfigSettings),
            defaultsResolvedSettingsValues: resolvedValues(for: constructionComponents.upToDefaultsSettings)
        )
    }
}

extension WorkspaceContext {
    @_spi(Testing) public func createExecutableSearchPaths(platform: Platform?, toolchains: [Toolchain]) -> StackedSearchPath {
        workspaceSettingsCache.getCachedStackedSearchPath(context: #function, platform: platform, toolchains: toolchains) { platform, toolchains in
            var paths = OrderedSet<Path>()

            // Add from __XCODE_BUILT_PRODUCTS_DIR_PATHS, if present.
            if let value = userInfo?.buildSystemEnvironment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
                for item in value.split(separator: ":") {
                    // Only honor absolute paths.
                    let path = Path(item)
                    if path.isAbsolute {
                        paths.append(path)
                    }
                }
            }

            @preconcurrency @PluginExtensionSystemActor func searchPaths() -> [Path] {
                core.pluginManager.extensions(of: SpecificationsExtensionPoint.self).flatMap { ext in
                    ext.specificationSearchPaths(resourceSearchPaths: core.resourceSearchPaths).compactMap { try? $0.filePath }
                }.sorted()
            }

            // Add the search paths from each loaded plugin.
            paths.append(contentsOf: searchPaths())

            // Add the binary paths for each toolchain.
            for toolchain in toolchains {
                // FIXME: Implement.
                for path in toolchain.executableSearchPaths.paths {
                    paths.append(path)
                }
            }

            // Add the platform search paths.
            for path in platform?.executableSearchPaths.paths ?? [] {
                paths.append(path)
            }

            // Add the standard search paths.
            switch core.developerPath {
            case .xcode(let path), .fallback(let path):
                paths.append(path.join("usr").join("bin"))
                paths.append(path.join("usr").join("local").join("bin"))
            case .swiftToolchain(let path, let xcodeDeveloperPath):
                paths.append(path.join("usr").join("bin"))
                paths.append(path.join("usr").join("local").join("bin"))
                if let xcodeDeveloperPath {
                    paths.append(xcodeDeveloperPath.join("usr").join("bin"))
                    paths.append(xcodeDeveloperPath.join("usr").join("local").join("bin"))
                }
            }

            // Add the entries from PATH.
            if let value = userInfo?.buildSystemEnvironment["PATH"] {
                for item in value.split(separator: ":") {
                    // Only honor absolute paths.
                    let path = Path(item)
                    if path.isAbsolute {
                        paths.append(path)
                    }
                }
            }

            return StackedSearchPath(paths: [Path](paths), fs: fs)
        }
    }

    func createFallbackFrameworkSearchPaths(platform: Platform?, toolchains: [Toolchain]) -> StackedSearchPath {
        workspaceSettingsCache.getCachedStackedSearchPath(context: #function, platform: platform, toolchains: toolchains) { platform, toolchains in
            var paths = OrderedSet<Path>()

            // Add the framework paths for each toolchain.
            for toolchain in toolchains {
                for path in toolchain.fallbackFrameworkSearchPaths.paths {
                    paths.append(path)
                }
            }

            // Add the entries from DYLD_FALLBACK_FRAMEWORK_PATH.
            if let value = userInfo?.buildSystemEnvironment["DYLD_FALLBACK_FRAMEWORK_PATH"] {
                for item in value.split(separator: ":") {
                    // Only honor absolute paths.
                    let path = Path(item)
                    if path.isAbsolute {
                        paths.append(path)
                    }
                }
            }

            return StackedSearchPath(paths: [Path](paths), fs: fs)
        }
    }

    func createFallbackLibrarySearchPaths(platform: Platform?, toolchains: [Toolchain]) -> StackedSearchPath {
        workspaceSettingsCache.getCachedStackedSearchPath(context: #function, platform: platform, toolchains: toolchains) { platform, toolchains in
            var paths = OrderedSet<Path>()

            // Add the library paths for each toolchain.
            for toolchain in toolchains {
                for path in toolchain.fallbackLibrarySearchPaths.paths {
                    paths.append(path)
                }
            }

            // Add the entries from DYLD_FALLBACK_LIBRARY_PATH.
            if let value = userInfo?.buildSystemEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] {
                for item in value.split(separator: ":") {
                    // Only honor absolute paths.
                    let path = Path(item)
                    if path.isAbsolute {
                        paths.append(path)
                    }
                }
            }

            return StackedSearchPath(paths: [Path](paths), fs: fs)
        }
    }
}

/// Settings extension to expose private data for testing purposes.
extension Settings {
    /// Make the table available for testing.
    @_spi(Testing) public var tableForTesting: MacroValueAssignmentTable {
        return self.table
    }
}

/// Enum which indicates the purpose of the `Settings` object.
public enum SettingsPurpose: String, Sendable {
    /// The `Settings` object was created to evaluate macros in the context of a build.
    case build
    /// The `Settings` object was created to be used by the build settings editor.
    /// - remark: This case is needed to avoid calling `bindConditionParameters()` when constructing a `Settings` object because the editor wants to show data for all SDKs, not just the bound one.
    case editor

    /// If `true`, then the `Settings` object has been bound to its effective SDK in several ways (e.g., so condition parameters will be resolved using the SDK), such that some information in the tables used to construct it has been discarded.
    var bindToSDK: Bool {
        switch self {
        case .build:
            return true
        case .editor:
            return false
        }
    }

    /// If `true`, then the `Settings` object includes overrides (settings above the target level). If `false`, then these are not included.
    var includeOverrides: Bool {
        switch self {
        case .build:
            return true
        case .editor:
            return false
        }
    }
}

public struct SettingsContext: Sendable {
    let purpose: SettingsPurpose
    let project: Project?
    let target: Target?

    init(_ purpose: SettingsPurpose, project: Project? = nil, target: Target? = nil) {
        self.purpose = purpose
        self.project = project
        self.target = target
    }
}

/// This class is responsible for construction of the build settings to use when evaluate macros for a project or target.
private class SettingsBuilder {
    /// This struct wraps properties which are bound as a result of the input parameters and then used to compute the full settings.
    struct BoundProperties {

        /// This struct captures select build setting values evaluated during the compotation of bound properties
        struct BoundSettings {
            let stringDeclarations: [StringMacroDeclaration: String]
            let stringListDeclarations: [StringListMacroDeclaration: Array<String>]
            let pathDeclarations: [PathMacroDeclaration: String]
            let pathListDeclarations: [PathListMacroDeclaration: Array<String>]

            init(_ scope: MacroEvaluationScope,
                 _ stringDeclarations: [StringMacroDeclaration],
                 _ stringListDeclarations: [StringListMacroDeclaration],
                 _ pathDeclarations: [PathMacroDeclaration],
                 _ pathListDeclarations: [PathListMacroDeclaration]
            ) {
                self.stringDeclarations = Dictionary(uniqueKeysWithValues: stringDeclarations.map { ($0, scope.evaluate($0)) })
                self.stringListDeclarations = Dictionary(uniqueKeysWithValues: stringListDeclarations.map { ($0, scope.evaluate($0)) })
                self.pathDeclarations = Dictionary(uniqueKeysWithValues: pathDeclarations.map { ($0, scope.evaluate($0).str) })
                self.pathListDeclarations = Dictionary(uniqueKeysWithValues: pathListDeclarations.map { ($0, scope.evaluate($0)) })
            }

            subscript(_ decl: StringMacroDeclaration) -> String? {
                return stringDeclarations[decl]
            }

            subscript(_ decl: StringListMacroDeclaration) -> Array<String>? {
                return stringListDeclarations[decl]
            }
            subscript(_ decl: PathMacroDeclaration) -> String? {
                return pathDeclarations[decl]
            }

            subscript(_ decl: PathListMacroDeclaration) -> Array<String>? {
                return pathListDeclarations[decl]
            }
        }

        /// The SDK to use, if any.
        let sdk: SDK?

        /// The optional SDK variant to use, if any.
        let sdkVariant: SDKVariant?

        /// The platform to use, if any.
        let platform: Platform?

        /// The toolchains to use.
        let toolchains: [Toolchain]

        /// The sparse SDKs to use.
        let sparseSDKs: [SDK]

        /// The SDK and platform values before they were overridden by the active run destination.
        ///
        /// We use these to decide if we want to include the TOOLCHAINS from the SDK settings.
        fileprivate let preOverrides: PreOverridesSettings

        /// A collection of precalculated settings that need to be used during the full construction of the settings.
        let settings: BoundSettings
    }

    /// This struct captures bound deployment target information for the settings.
    struct BoundDeploymentTarget {
        /// The platform's deployment target macro.
        let platformDeploymentTargetMacro: StringMacroDeclaration?

        /// The bound platform deployment target.
        let platformDeploymentTarget: Version?

        /// The SDK variant's deployment target macro.  Will be nil if the SDK variant doesn't use a deployment target macro different from the platform.
        let sdkVariantDeploymentTargetMacro: StringMacroDeclaration?

        /// The bound SDK variant deployment target.  Will be nil if the SDK variant doesn't use a deployment target macro different from the platform.
        let sdkVariantDeploymentTarget: Version?

        init(platformDeploymentTargetMacro: StringMacroDeclaration? = nil, platformDeploymentTarget: Version? = nil, sdkVariantDeploymentTargetMacro: StringMacroDeclaration? = nil, sdkVariantDeploymentTarget: Version? = nil) {
            self.platformDeploymentTargetMacro = platformDeploymentTargetMacro
            self.platformDeploymentTarget = platformDeploymentTarget
            self.sdkVariantDeploymentTargetMacro = sdkVariantDeploymentTargetMacro
            self.sdkVariantDeploymentTarget = sdkVariantDeploymentTarget
        }
    }

    // Properties the builder was initialized with.

    let workspaceContext: WorkspaceContext
    let buildRequestContext: BuildRequestContext
    let sdkRegistry: any SDKRegistryLookup
    let parameters: BuildParameters
    let settingsContext: SettingsContext

    var project: Project? {
        return settingsContext.project
    }

    var target: Target? {
        return settingsContext.target
    }

    let provisioningTaskInputs: ProvisioningTaskInputs?

    /// Whether this builder was constructed specifically for binding properties (versus for general table construction).
    let forBindingProperties: Bool

    // FIXME: This exists only for performance reasons, if it was cheap/free we wouldn't be concerned with this. Try and make it so, or find a way to eliminate the need completely.
    //
    /// Whether this builder instance tracks exported macro information.
    let includeExports: Bool

    /// The namespace for user macros.  Its parent is the namespace of the `WorkspaceContext` for the settings.
    let userNamespace: MacroNamespace


    // Properties derived from the properties the builder was initialized with.

    /// The bound build configuration for the target.
    var targetConfiguration: BuildConfiguration? = nil


    // Bound properties of the builder.  These will sometimes come from the BoundProperties struct and are included here for convenience.  The builder should be careful not to access these methods before they are added.
    // FIXME: We should find some compile-time way to enforce that these properties can't be used before they are added.

    /// The bound product and package, once added in addTargetProductSettings().
    var productType: ProductTypeSpec? = nil
    var packageType: PackageTypeSpec? = nil

    /// The computed preferred architecture, once added in getCommonTargetTaskOverrides().
    var preferredArch: String?

    /// The bound signing settings, once added in computeSigningSettings().
    var signingSettings: Settings.SigningSettings? = nil


    // Mutable state of the builder as we're building up the settings table.

    /// The table we build up of macro assignments.
    var _table: MacroValueAssignmentTable

    var exportedMacroNames = Set<MacroDeclaration>()
    var exportedNativeMacroNames = Set<MacroDeclaration>()
    var exportedMacroIDs = Set<Int>()
    var exportedNativeIDs = Set<Int>()

    var errors = OrderedSet<String>()
    var warnings =  OrderedSet<String>()
    var notes =  OrderedSet<String>()
    var diagnostics = OrderedSet<Diagnostic>()

    /// Target-specific counterpart of `diagnostics`.
    var targetDiagnostics = OrderedSet<Diagnostic>()

    // FIXME: Shouldn't this be separated into sets for each base xcconfig file used (project level, target level, xcodebuild override level)?  A given xcconfig might be #included separately at multiple levels, but it will only be reflected here at the lowest level due to the way this set if built up.  But maybe for what this set is used for that doesn't materially matter.
    //
    /// The list of XCConfigs used by the receiver.
    ///
    /// This is an ordered set because each #included xcconfig file is only used once and the order of inclusion is significant.
    var macroConfigPaths = OrderedSet<Path>()

    /// The signature of the XCConfigs used by the receiver.
    var macroConfigSignature: FilesSignature { return macroConfigSignatureCache.getValue(self) }
    var macroConfigSignatureCache = LazyCache { (builder: SettingsBuilder) -> FilesSignature in
        return builder.workspaceContext.fs.filesSignature(builder.macroConfigPaths.elements)
    }

    var core: Core {
        return workspaceContext.core
    }
    var coreSettings: CoreSettings {
        return core.coreSettings
    }

    private var projectXcconfigPath: Path? = nil
    private var projectXcconfigSettings: MacroValueAssignmentTable? = nil
    private var projectSettings: MacroValueAssignmentTable? = nil
    private var targetXcconfigPath: Path? = nil
    private var targetXcconfigSettings: MacroValueAssignmentTable? = nil
    private var targetSettings: MacroValueAssignmentTable? = nil
    /// Convenient array for iterating over all defined settings tables in the project for this target, from lowest to highest.
    private var allProjectSettingsLevels: [(table: MacroValueAssignmentTable?, path: Path?, level: String)] {
        return [
            (projectXcconfigSettings, projectXcconfigPath, "project-xcconfig"),
            (projectSettings, nil, "project"),
            (targetXcconfigSettings, targetXcconfigPath, "target-xcconfig"),
            (targetSettings, nil, "target"),
        ]
    }

    private var upToDefaultsSettings: MacroValueAssignmentTable? = nil
    private var upToProjectXcconfigSettings: MacroValueAssignmentTable? = nil
    private var upToProjectSettings: MacroValueAssignmentTable? = nil
    private var upToTargetXcconfigSettings: MacroValueAssignmentTable? = nil
    private var upToTargetSettings: MacroValueAssignmentTable? = nil

    /// The project model components which were used to construct the settings made by this builder.
    var constructionComponents: Settings.ConstructionComponents {
        return Settings.ConstructionComponents(
            projectXcconfigPath: self.projectXcconfigPath,
        	projectXcconfigSettings: self.projectXcconfigSettings,
            projectSettings: self.projectSettings,
            targetXcconfigPath: self.targetXcconfigPath,
            targetXcconfigSettings: self.targetXcconfigSettings,
            targetSettings: self.targetSettings,
            upToDefaultsSettings: self.upToDefaultsSettings,
            upToProjectXcconfigSettings: upToProjectXcconfigSettings,
            upToProjectSettings: upToProjectSettings,
            upToTargetXcconfigSettings: upToTargetXcconfigSettings,
            upToTargetSettings: upToTargetSettings
        )
    }

    init(_ workspaceContext: WorkspaceContext, _ buildRequestContext: BuildRequestContext, _ parameters: BuildParameters, _ settingsContext: SettingsContext, _ provisioningTaskInputs: ProvisioningTaskInputs? = nil, includeExports: Bool = true, forBindingProperties: Bool = false, _ sdkRegistry: (any SDKRegistryLookup)?) {
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.sdkRegistry = sdkRegistry ?? workspaceContext.sdkRegistry
        self.parameters = parameters
        self.settingsContext = settingsContext
        self.provisioningTaskInputs = provisioningTaskInputs
        // FIXME: We should almost certainly not be creating a namespace here, but instead should use an already bound one.
        self.userNamespace = MacroNamespace(parent: workspaceContext.workspace.userNamespace, debugDescription: "settings")
        self._table = MacroValueAssignmentTable(namespace: userNamespace)
        self.forBindingProperties = forBindingProperties
        self.includeExports = includeExports && !forBindingProperties
    }


    // MARK: Settings construction

    /// Construct the settings data.
    func construct(_ impartedBuildProperties: [ImpartedBuildProperties]? = nil) -> (BoundProperties, BoundDeploymentTarget) {
        precondition(!forBindingProperties)

        // Compute the effective configurations to build with.
        let effectiveProjectConfig = project.map { project in project.getEffectiveConfiguration(self.parameters.configuration, packageConfigurationOverride: self.parameters.packageConfigurationOverride)! }
        targetConfiguration = project.map { project in target?.getEffectiveConfiguration(self.parameters.configuration, defaultConfigurationName: project.isPackage ? (self.parameters.packageConfigurationOverride ?? project.defaultConfigurationName) : project.defaultConfigurationName) } ?? nil

        // Require that a target configuration is available if a target is defined.
        if let target = self.target, targetConfiguration == nil, target.type != .packageProduct {
            self.warnings.append("missing target configuration for '\(target.name)'")
        }

        // Compute the SDK, platform, and toolchains to use, using an auxiliary builder.
        //
        // Even though the initialization that will be done by this builder is very similar to the initialization we do, we cannot simply do the initialization, bind the properties, and then continue, because some of the settings which are derived from the bound objects are injected at varying points in the process (this dates from Xcode's injecting these settings into different tiers).
        //
        // FIXME: This is unfortunate, as it makes settings construction about twice as expensive as it otherwise could be. We should eventually try to devise a roadmap in which the binding can happen much more simply, so we don't need to do this.
        let bindingBuilder = SettingsBuilder(self.workspaceContext, self.buildRequestContext, self.parameters, self.settingsContext, forBindingProperties: true, sdkRegistry)
        let boundProperties = bindingBuilder.computeBoundProperties(effectiveProjectConfig, targetConfiguration)
        self.errors.append(contentsOf: bindingBuilder.errors)
        self.warnings.append(contentsOf: bindingBuilder.warnings)
        self.notes.append(contentsOf: bindingBuilder.notes)
        self.diagnostics.append(contentsOf: bindingBuilder.diagnostics)

        // For historical reasons, the SettingsBuilder uses the core's SpecRegistry even after it's bound the platform.
        // !!!:mhr:20221118: I think there's only one SpecRegistry in the process, exposed through many different protocols, but I'm reluctant to test that theory in the large platform-optionality project that's adding this SpecLookupContext.
        let specLookupContext = SpecLookupCtxt(specRegistry: core.specRegistry, platform: boundProperties.platform)

        // Now we can start constructing the settings table.

        // Add the basic builtin settings.
        addBuiltins(domain: specLookupContext.domain)

        // Add the platform settings.
        addPlatformSettings(specLookupContext.platform)

        // Add the toolchain settings.
        //
        // We push in reverse order to honor the precedence correctly.
        for (idx,toolchain) in boundProperties.toolchains.enumerated().reversed() {
            addToolchainSettings(toolchain, isPrimary: idx == 0)
        }

        do {
            var table = MacroValueAssignmentTable(namespace: userNamespace)

            // The order should match the order of TOOLCHAINS.
            table.push(BuiltinMacros.EFFECTIVE_TOOLCHAINS_DIRS, literal: boundProperties.toolchains.map{ $0.path.str })

            push(table)
        }

        // Add the SDK settings.
        // FIXME: Resolve per-arch SDKROOTs, if we end up having to support them.
        // FIXME: Warning about missing SDKs? Did we do that already?
        if let sdk = boundProperties.sdk {
            addSDKSettings(sdk, boundProperties.sdkVariant, boundProperties.sparseSDKs)

            addPlatformSDKSettings(boundProperties.platform, sdk, boundProperties.sdkVariant)
            addSDKToolchains(sdk: sdk)

            // When building for SDK_VARIANT=iosmac, a default MACOSX_DEPLOYMENT_TARGET should be pushed based on the mapping, if available. We do it at this level so that the user can still provide an override for the value.
            if boundProperties.sdkVariant?.isMacCatalyst == true {
                if let iphoneosDeploymentTarget = boundProperties.settings[BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET], let iphoneosDeploymentVersion = try? Version(iphoneosDeploymentTarget) {
                    if let mappedVersion = sdk.versionMap["iOSMac_macOS"]?[iphoneosDeploymentVersion] {
                        var table = MacroValueAssignmentTable(namespace: userNamespace)
                        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: mappedVersion.description)
                        push(table)
                    }
                }
            }
        }

        addDynamicDefaultSettings(specLookupContext, boundProperties.settings, boundProperties.sdk)

        // Add the product and package settings.
        if let target = self.target {
            addTargetProductSettings(target, specLookupContext)
        }

        if boundProperties.sdkVariant?.isMacCatalyst == true {
            var table = MacroValueAssignmentTable(namespace: userNamespace)
            table.push(BuiltinMacros.TARGETED_DEVICE_FAMILY, literal: productType?.onlyPreferredAssets == true ? "2" : "2,6")
            push(table)
        }

        // Save the settings we've constructed to this point as the default settings in the construction components.
        self.upToDefaultsSettings = MacroValueAssignmentTable(copying: _table)

        // Add the project settings.
        if let effectiveProjectConfig {
            addProjectSettings(effectiveProjectConfig, boundProperties.sdk)
        }

        // Add the target settings, if configured.
        if let target = self.target, let config = targetConfiguration {
            addTargetSettings(target, specLookupContext, config, boundProperties.sdk, usesAutomaticSDK: boundProperties.settings[BuiltinMacros.SDKROOT] == "auto")
        }

        // If we're constructing a Settings object for use by the editor, then we stop here; we don't add any overrides.
        guard settingsContext.purpose.includeOverrides else {
            let boundDeploymentTarget = bindDeploymentTarget(boundProperties.platform, boundProperties.sdk, boundProperties.sdkVariant)
            return (boundProperties, boundDeploymentTarget)
        }

        // Add the SDK overrides.
        if let sdk = boundProperties.sdk {
            let scope = createScope(sdkToUse: sdk)
            let destinationIsMacCatalyst = parameters.activeRunDestination?.sdkVariant == MacCatalystInfo.sdkVariantName
            let supportsMacCatalyst = Settings.supportsMacCatalyst(scope: scope, core: core)
            if destinationIsMacCatalyst && supportsMacCatalyst {
                pushTable(.exported) {
                    $0.push(BuiltinMacros.SUPPORTED_PLATFORMS, BuiltinMacros.namespace.parseStringList(["$(inherited)", "macosx"]))
                }
            }

            addSDKOverridingSettings(sdk, boundProperties.sdkVariant)

            @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
                core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
            }
            for settingsExtension in settingsExtensions() {
                do {
                    let overridingSettings = try settingsExtension.addSDKOverridingSettings(sdk, boundProperties.sdkVariant, boundProperties.sparseSDKs, specLookupContext: specLookupContext)
                    pushTable(.exported) {
                        $0.pushContentsOf(createTableFromUserSettings(overridingSettings))
                    }
                } catch {
                    self.errors.append("unable to retrieve overriding SDK settings")
                }
            }

            validateSDK(sdk, sdkVariant: boundProperties.sdkVariant, scope: scope)
        }

        // Add the global overrides.
        addOverrides(sdk: boundProperties.sdk)

        // Add the SDK overriding properties.
        if let sdk = boundProperties.sdk {
            addSDKPathOverride(sdk)
            if let platform = boundProperties.platform {
                addDeploymentTargetFallbackIfNeeded(platform: platform, sdk: sdk)
            }
        }

        // Bind the deployment target, and push it if necessary.  This means that no further settings should affect the deployment target.
        let boundDeploymentTarget = bindDeploymentTarget(boundProperties.platform, boundProperties.sdk, boundProperties.sdkVariant)

        // Settings pushed after this point should generally be derived and not primary data passed in to the builder.  These methods have not been audited to ensure that this is so, and the ramifications that not being so are not known.

        // Constrain ARCHS_STANDARD for the platform based on the deployment target.
        addStandardArchitecturesOverride(specLookupContext, boundDeploymentTarget.platformDeploymentTarget, boundProperties.sdk)

        // Add architecture overrides from the active run destination.  This often depends on the value of ARCHS_STANDARD which was constrained above.
        // This will also add host target platform settings based on the run destination, if there is one.
        addRunDestinationSettingsArchitectures(boundProperties.sdk)

        if parameters.action == .indexBuild {
            addIndexBuildOverrides(boundProperties.sdkVariant)
        }

        // Add the target task overrides.  This is a large set of work broken up into several methods.
        if let target = self.target {
            addTargetTaskOverrides(target, specLookupContext, boundProperties.sparseSDKs, boundDeploymentTarget.platformDeploymentTarget, boundProperties.sdk)
        }

        // Push the target derived overriding settings.
        addTargetDerivedSettings(self.target, boundProperties.platform, boundProperties.sdk, boundProperties.sdkVariant)

        if boundDeploymentTarget.platformDeploymentTargetMacro == BuiltinMacros.DRIVERKIT_DEPLOYMENT_TARGET, let deploymentTarget = boundDeploymentTarget.platformDeploymentTarget, deploymentTarget < Version(20) {
            var table = MacroValueAssignmentTable(namespace: userNamespace)
            table.push(BuiltinMacros.INFOPLIST_OUTPUT_FORMAT, literal: "XML")
            push(table)
        }

        // Add the signing settings, if we have provisioning task inputs.
        if let inputs = provisioningTaskInputs {
            addSigningOverrides(specLookupContext, inputs, boundProperties.sdk)
        }

        // Perform some final adjustments to the exported names.
        exportedMacroNames.insert(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET)
        exportedMacroNames.remove(BuiltinMacros.DERIVED_DATA_DIR)

        // On-Demand Resources
        let scope = createScope(sdkToUse: boundProperties.sdk)
        if scope.evaluate(BuiltinMacros.ENABLE_ON_DEMAND_RESOURCES) {
            if let productType = self.productType, !scope.evaluate(BuiltinMacros.SUPPORTS_ON_DEMAND_RESOURCES) {
                self.errors.append("On-Demand Resources is enabled (ENABLE_ON_DEMAND_RESOURCES = YES), but is not supported for \(productType.name.lowercased()) targets")
            }
            else {
                if scope.evaluate(BuiltinMacros.WRAP_ASSET_PACKS_IN_SEPARATE_DIRECTORIES) {
                    self.errors.append("WRAP_ASSET_PACKS_IN_SEPARATE_DIRECTORIES=YES is not supported")
                }
            }
        }

        if scope.evaluate(BuiltinMacros.ENABLE_PLAYGROUND_RESULTS) {
            addPlaygroundSettings(specLookupContext.platform)
        }

        // Build settings imparted from packages.
        if let sdk = boundProperties.sdk, settingsContext.purpose.bindToSDK {
            for property in impartedBuildProperties ?? [] {
                // Imparted build properties are always from packages, so force allow platform filter conditionals.
                bindConditionParameters(property.buildSettings, sdk, forceAllowPlatformFilterCondition: true)
            }
        }

        if scope.evaluate(BuiltinMacros.ENABLE_PROJECT_OVERRIDE_SPECS), let projectOverrideSpec = core.specRegistry.findSpecs(ProjectOverridesSpec.self, domain: "").filter({ spec in
            spec.projectName == (scope.evaluate(BuiltinMacros.RC_ProjectName).nilIfEmpty ?? scope.evaluate(BuiltinMacros.SRCROOT).basename)
        }).only {
            push(projectOverrideSpec.buildSettings)
            self.warnings.append("Applying Swift Build settings override to project for \(projectOverrideSpec.bugReport).")
        }

        if let swiftSpec = try? specLookupContext.getSpec() as SwiftCompilerSpec {
            var swiftVersion = scope.evaluate(BuiltinMacros.SWIFT_VERSION)
            do {
                let parsedSwiftVersion = try Version(swiftVersion)
                switch swiftSpec.validateSwiftVersion(parsedSwiftVersion) {
                case .invalid:
                    swiftVersion = ""
                case .validMajor:
                    swiftVersion = "\(parsedSwiftVersion[0])"
                case .valid:
                    swiftVersion = parsedSwiftVersion.zeroTrimmed.description
                }
            } catch {
                swiftVersion = ""
            }

            pushTable(.none) {
                $0.push(BuiltinMacros.EFFECTIVE_SWIFT_VERSION, literal: swiftVersion)
            }
        }

        // At this point settings construction is finished.

        // Analyze the settings to generate any issues about them.
        analyzeSettings(specLookupContext, boundProperties.sdk, boundProperties.sdkVariant)

        return (boundProperties, boundDeploymentTarget)
    }


    // MARK: Computing the bound properties

    /// Compute the "bound" properties needed to build a complete settings table.  This is called on a separate instance of `SettingsBuilder` used to bind the properties.
    ///
    /// These are the properties like the SDK and platform which, historically, were computed using the table as it was being initialized and then were dynamically injected into different levels of the table.
    ///
    /// The table created for binding properties is by no means "real" - settings get pushed out of order compared to a real settings table.  So this table is only appropriate for binding settings for which the ordering used here works.
    func computeBoundProperties(_ effectiveProjectConfig: BuildConfiguration?, _ effectiveTargetConfig: BuildConfiguration?) -> BoundProperties {
        precondition(forBindingProperties)

        // Add the basic builtin settings.
        addBuiltins(domain: "")

        // Add the project settings.
        if let effectiveProjectConfig {
            addProjectSettings(effectiveProjectConfig)
        }

        // Add the target settings, if configured.
        if let target = self.target, let config = effectiveTargetConfig  {
            addTargetSettings(target, SpecLookupCtxt(specRegistry: core.specRegistry, platform: nil), config, nil)
        }

        var sdkLookupErrors: [any Error] = []

        // Capture the SDK and platform before they are overridden.
        var preOverrides = PreOverridesSettings(sdk: nil)
        do {
            do {
                preOverrides.sdk = try project.map { try sdkRegistry.lookup(nameOrPath: createScope(effectiveTargetConfig, sdkToUse: nil).evaluate(BuiltinMacros.SDKROOT).str, basePath: $0.sourceRoot, activeRunDestination: parameters.activeRunDestination) } ?? nil
            } catch {
                preOverrides.sdk = nil

                // Don't add the ambiguous-SDK error to `sdkLookupErrors`. If the only disambiguator for the SDK is in
                // the overrides (e.g. SDKROOT being passed as a command line override), then we naturally have to allow
                // the pre-override SDK lookup to "fail" silently so that the override can take effect.
                if !(error is AmbiguousSDKLookupError) {
                    sdkLookupErrors.append(error)
                }
            }
        }

        // Add the global overrides.
        addOverrides(sdk: nil)

        // Push host target platform settings before we bind the SDK.
        if let runDestination = parameters.activeRunDestination {
            pushHostTargetPlatformSettingsIfNeeded(for: runDestination, to: createScope(effectiveTargetConfig, sdkToUse: nil))
        }

        var sdk: SDK? = nil
        var sdkVariant: SDKVariant? = nil
        var platform: Platform? = nil

        // This happens twice:
        // - In the first pass, we add the target's configured SDK/Platform settings. This provides a default value for SUPPORTED_PLATFORMS.
        // - Then, we let the run destination override the SDK if needed.
        // - If the SDK or Platform changed, we do a second pass to add the new SDK/Platform settings. This ensures that we can resolve TOOLCHAINS accurately later.
        var sdkroot: String! = nil
        for i in 0 ..< 2 {
            // Perform the initial SDK resolution (this may drive the platform).
            sdkroot = createScope(effectiveTargetConfig, sdkToUse: sdk).evaluate(BuiltinMacros.SDKROOT).str

            // We will replace SDKROOT values of "auto" here if the run destination is compatible.
            let usesReplaceableAutomaticSDKRoot: Bool
            if sdkroot == "auto", let activePlatform = parameters.activeRunDestination?.platform {
                let destinationIsMacCatalyst = parameters.activeRunDestination?.sdkVariant == MacCatalystInfo.sdkVariantName

                let scope = createScope(effectiveTargetConfig, sdkToUse: sdk)
                let supportedPlatforms = scope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS)
                let runDestinationIsSupported = supportedPlatforms.contains(activePlatform)
                let supportsMacCatalyst = Settings.supportsMacCatalyst(scope: scope, core: core)
                if destinationIsMacCatalyst && supportsMacCatalyst {
                    usesReplaceableAutomaticSDKRoot = true
                }
                else {
                    usesReplaceableAutomaticSDKRoot = runDestinationIsSupported
                }
            } else {
                usesReplaceableAutomaticSDKRoot = false
            }
            if usesReplaceableAutomaticSDKRoot, let activeSDK = parameters.activeRunDestination?.sdk {
                sdkroot = activeSDK
            }

            do {
                sdk = try project.map { try sdkRegistry.lookup(nameOrPath: sdkroot, basePath: $0.sourceRoot, activeRunDestination: parameters.activeRunDestination) } ?? nil
            } catch {
                sdk = nil
                sdkLookupErrors.append(error)
            }
            if let s = sdk {
                // Evaluate the SDK variant, if there is one.
                let sdkVariantName: String
                if usesReplaceableAutomaticSDKRoot, let activeSDKVariant = parameters.activeRunDestination?.sdkVariant {
                    sdkVariantName = activeSDKVariant
                } else {
                    sdkVariantName = createScope(effectiveTargetConfig, sdkToUse: s).evaluate(BuiltinMacros.SDK_VARIANT)
                }
                sdkVariant = s.variant(for: sdkVariantName) ?? s.defaultVariant
                addSDKSettings(s, sdkVariant, [])
            }

            // Bind the platform to use.  This will be nil if we can't find one.
            platform = core.platformRegistry.lookup(name: createScope(effectiveTargetConfig, sdkToUse: sdk).evaluate(BuiltinMacros.PLATFORM_NAME))
            let specLookupContext = SpecLookupCtxt(specRegistry: core.specRegistry, platform: platform)

            // Add the platform settings.
            addBuiltins(domain: specLookupContext.domain)
            addPlatformSettings(platform)

            // If we didn't previously find an SDK, search again now that platform defaults are installed.
            //
            // FIXME: Disable for now, because I want to ensure we have a test case for the situation where this matters.
            #if false
                if sdk == nil {
                    sdk = sdkRegistry.lookup(nameOrPath: sdkroot, basePath: project.sourceRoot)
                    if let s = sdk {
                        addSDKSettings(s, nil, [])
                    }
                }
            #endif

            if let sdk {
                addPlatformSDKSettings(platform, sdk, sdkVariant)
                addSDKToolchains(sdk: sdk)
            }

            // Perform the additional normal settings initialization work (again).
            //
            // FIXME: All of the extra work here is just done so we can derive the toolchains, unfortunately.
            //
            // FIXME: This is also duplicated with the main setup path, so if we continue with this approach we need to refactor this into a common method.

            // Add the product and package settings.
            if let target = self.target {
                addTargetProductSettings(target, specLookupContext)
            }

            // Add the project settings.
            if let effectiveProjectConfig {
                addProjectSettings(effectiveProjectConfig)
            }

            // Add the target settings, if configured.
            if let target = self.target, let config = effectiveTargetConfig  {
                addTargetSettings(target, specLookupContext, config, nil)
            }

            // Add the SDK overrides.
            if let sdk {
                addSDKOverridingSettings(sdk, sdkVariant)
            }

            // Add the global overrides.
            addOverrides(sdk: sdk)

            // After the first pass, let the run destination override the SDK if needed.
            if i == 0 {
                func readState() -> (sdk: String, sdkVariant: String) {
                    let scope = createScope(sdkToUse: nil)
                    return (scope.evaluate(BuiltinMacros.SDKROOT).str, scope.evaluate(BuiltinMacros.SDK_VARIANT))
                }

                let before = readState()
                addRunDestinationSettingsPlatformSDK()

                // If it applied changes, we need to restart at the top of the loop. Otherwise we can exit early.
                if before == readState() { break }
            }
        }

        var foundAmbiguousErrors: Set<AmbiguousSDKLookupError> = []
        for error in sdkLookupErrors {
            switch error {
            case let error as AmbiguousSDKLookupError:
                if !foundAmbiguousErrors.contains(error) {
                    foundAmbiguousErrors.insert(error)
                    diagnostics.append(error.diagnostic)
                }
            default:
                errors.append("\(error)")
            }
        }

        // If we didn't fail due to an ambiguity, and we couldn't find either an SDK or a platform, then emit an error with the last SDKROOT we tried to look up.  (If we don't have an SDKROOT value here then something very strange has gone wrong.)
        if project != nil && foundAmbiguousErrors.isEmpty {
            if sdk == nil {
                errors.append("unable to find sdk '\(sdkroot!)'")
            }
            else if platform == nil {
                errors.append("unable to find platform for sdk '\(sdkroot!)'")
            }
        }

        // Push host target platform settings again after pushing the project and target settings. This means that the run destination will override these settings if defined at lower levels.
        if let runDestination = parameters.activeRunDestination {
            pushHostTargetPlatformSettingsIfNeeded(for: runDestination, to: createScope(effectiveTargetConfig, sdkToUse: nil))
        }

        // Resolve the sparse SDKs.
        let sparseSDKs = createScope(effectiveTargetConfig, sdkToUse: sdk).evaluate(BuiltinMacros.ADDITIONAL_SDKS).compactMap { sparseSDKLookupStr -> SDK? in
            guard let project else {
                return nil
            }

            // Look up the SDK from the workspace context's SDK registry.  Here we let the registry detect whether the string we're looking up is the name of the SDK, or the path to one.
            if let sdk = try? sdkRegistry.lookup(nameOrPath: sparseSDKLookupStr, basePath: project.sourceRoot, activeRunDestination: parameters.activeRunDestination) {
                return sdk
            }
            else {
                // If we didn't find an SDK, then we treat the lookup string as a path and look for it inside the project directory.
                let lookupPath = project.sourceRoot.join(sparseSDKLookupStr)
                if let sdk = sdkRegistry.lookup(lookupPath) {
                    return sdk
                }
                else {
                    self.warnings.append("can't find additional SDK '\(sparseSDKLookupStr)'")
                }
            }

            // If we get here, then we couldn't find an SDK for the lookup string.
            return nil
        }

        // Resolve the toolchains.
        var sdkTable = MacroValueAssignmentTable(namespace: _table.namespace)
        sdkTable.pushContentsOf(_table)
        for sdk in sparseSDKs {
            for directoryMacro in sdk.directoryMacros {
                sdkTable.push(directoryMacro, literal: sdk.path.str)
            }
        }
        var toolchains = createScope(effectiveTargetConfig, sdkToUse: sdk, table: sdkTable).evaluate(BuiltinMacros.TOOLCHAINS).compactMap { name -> Toolchain? in
            // Find the named toolchain.
            //
            // FIXME: We need to report an error here if the toolchain couldn't be found.
            return core.toolchainRegistry.lookup(name)
        }

        // If the build system was initialized as part of a swift toolchain, push that toolchain ahead of the default toolchain, if they are not the same (e.g. when on macOS where an Xcode install exists).
        if case .swiftToolchain(let path, xcodeDeveloperPath: _) = core.developerPath {
            if let developerPathToolchain = core.toolchainRegistry.toolchains.first(where: { $0.path.normalize() == path.normalize() }),
               developerPathToolchain != coreSettings.defaultToolchain {
                toolchains.append(developerPathToolchain)
            }
        }

        // Add the default toolchain at the end, if not present.
        if let defaultToolchain = coreSettings.defaultToolchain, toolchains.firstIndex(of: defaultToolchain) == nil {
            toolchains.append(defaultToolchain)
        }

        // Determine the deployment targets that would be used. For enabling macCatalyst, we need to know the pre-mapped versions so we can inject that as SDK overrides.
        let scope = createScope(effectiveTargetConfig, sdkToUse: sdk)
        let settings = BoundProperties.BoundSettings(scope, [BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET, BuiltinMacros.DEVELOPMENT_TEAM], [BuiltinMacros.OTHER_LDFLAGS,BuiltinMacros.PRODUCT_SPECIFIC_LDFLAGS],[BuiltinMacros.SDKROOT], [])

        return BoundProperties(sdk: sdk, sdkVariant: sdkVariant, platform: platform, toolchains: toolchains, sparseSDKs: sparseSDKs, preOverrides: preOverrides, settings: settings)
    }

    /// Create a temporary scope for evaluating with the current table contents.
    /// - parameter configToUse: The build configuration to use for the scope.  If nil, then the bound target configuration will be used (falling back to the computed project configuration).  Typically this is only overridden when computing bound properties.
    /// - parameter sdkToUse: The SDK to use for the scope. This might be `nil` early in the process of computing bound properties, but should typically be the bound SDK after.
    func createScope(_ configToUse: BuildConfiguration? = nil, sdkToUse: SDK?, table: MacroValueAssignmentTable? = nil) -> MacroEvaluationScope {
        var conditionParameterValues = [MacroConditionParameter: [String]]()
        // The scope always includes the configuration name as a condition parameter, if we can determine one.
        if let effectiveConfig = configToUse ?? targetConfiguration ?? project?.getEffectiveConfiguration(self.parameters.configuration, packageConfigurationOverride: self.parameters.packageConfigurationOverride) {
            conditionParameterValues[BuiltinMacros.configurationCondition] = [effectiveConfig.name]
        }
        // If there's a bound SDK, then the scope includes its condition parameter.
        if let sdk = sdkToUse {
            conditionParameterValues[BuiltinMacros.sdkCondition] = sdk.settingConditionValues
            if let aBuildVersion = sdk.productBuildVersion {
                conditionParameterValues[BuiltinMacros.sdkBuildVersionCondition] = [aBuildVersion]
            }
        }
        return MacroEvaluationScope(table: table ?? _table, conditionParameterValues: conditionParameterValues)
    }

    enum ExportType {
        /// Not exported.
        case none
        /// Exported for all shell scripts.
        case exported
        /// Exported only for native shell scripts (shell script build phases and build rules, but not external targets).
        case exportedForNative
    }

    /// Holds multiple macro assignment tables with different export types.
    struct MacroValueAssignmentTableSet {
        let namespace: MacroNamespace
        var tables: [ExportType: MacroValueAssignmentTable] = [:]

        init(namespace: MacroNamespace) {
            self.namespace = namespace
        }

        mutating func push(_ exportType: ExportType, _ macro: MacroDeclaration, _ value: MacroExpression) {
            tables[exportType, default: MacroValueAssignmentTable(namespace: namespace)].push(macro, value)
        }
    }

    func push(_ tableSet: MacroValueAssignmentTableSet) {
        for (exportType, table) in tableSet.tables {
            switch exportType {
            case .exported: push(table, .exported)
            case .exportedForNative: push(table, .exportedForNative)
            case .none: push(table, .none)
            }
        }
    }

    /// Utility for pushing a table and optionally tracking its contents for exported name purposes.
    func push(_ items: MacroValueAssignmentTable, _ exportType: ExportType = .none) {
        _table.pushContentsOf(items)

        if includeExports {
            // Add the export entries, if relevant.
            switch exportType {
            case .none: break
            case .exported:
                exportedMacroNames.formUnion(items.valueAssignments.keys)
            case .exportedForNative:
                exportedNativeMacroNames.formUnion(items.valueAssignments.keys)
            }
        }
    }

    func pushTable(_ exportType: ExportType, f: (inout MacroValueAssignmentTable) -> Void) {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        f(&table)
        push(table, exportType)
    }


    // MARK: Methods for pushing groups of properties

    /// Adds the base layer of build settings, including the environment and builtin defaults.
    func addBuiltins(domain: String) {
        let info = workspaceContext.workspaceSettings.builtinSettingsInfo(forTargetType: self.target?.type, domain: domain)
        push(info.table)
        // FIXME: <rdar://69032664> Remove rev-lock hack for new CopyStringsFile build setting
        pushTable(.exported) { $0.push(BuiltinMacros.STRINGS_FILE_INFOPLIST_RENAME, literal: true) }
        exportedMacroNames.formUnion(info.exportedMacros)
        errors.append(contentsOf:info.errors)

        if self.parameters.action == .indexBuild {
            pushTable(.exported) {
                $0.push(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA, literal: true)
                $0.push(BuiltinMacros.INDEX_PREPARED_MODULE_CONTENT_MARKER_PATH, Static { BuiltinMacros.namespace.parseString("$(TEMP_DIR)/$(PRODUCT_NAME)-preparedForIndex-module") })
                $0.push(BuiltinMacros.INDEX_PREPARED_TARGET_MARKER_PATH, Static { BuiltinMacros.namespace.parseString("$(TEMP_DIR)/$(PRODUCT_NAME)-preparedForIndex-target") })
            }
        }

        // Add shared output path for clang compile cache.
        if let casPath = UserDefaults.compilationCachingCASPath {
            pushTable(.exported) { $0.push(BuiltinMacros.COMPILATION_CACHE_CAS_PATH, literal: casPath) }
        } else {
            // Use `DERIVED_DATA_DIR` for scheme builds but when doing target builds use `CCHROOT` which may be set by clients.
            // Note that if `CCHROOT` is not set in a target build it will end up using the same path as `DERIVED_DATA_DIR` (some path in the user's cache directory).
            let compileCacheDirMacro = parameters.arena?.derivedDataPath != nil ? "DERIVED_DATA_DIR" : "CCHROOT"
            pushTable(.exported) { $0.push(BuiltinMacros.COMPILATION_CACHE_CAS_PATH, BuiltinMacros.namespace.parseString("$(\(compileCacheDirMacro))/CompilationCache.noindex")) }
        }

        // Default to preserving the cache directory.
        pushTable(.exported) {
            $0.push(BuiltinMacros.COMPILATION_CACHE_KEEP_CAS_DIRECTORY, literal: true)
            // Enable MCCAS outputs for desktop building.
            $0.push(BuiltinMacros.CLANG_CACHE_FINE_GRAINED_OUTPUTS, literal: .enabled)
        }

        // Add host platform.
        do {
            let hostOS = try workspaceContext.core.hostOperatingSystem.xcodePlatformName
            pushTable(.exported) {
                $0.push(BuiltinMacros.HOST_PLATFORM, literal: hostOS)

                // Only on non-macOS platforms to reduce risk for now.
                if workspaceContext.core.hostOperatingSystem != .macOS {
                    $0.push(BuiltinMacros.SDKROOT, Static { BuiltinMacros.namespace.parseString("$(HOST_PLATFORM)") })
                }
            }
        } catch {
            errors.append("Unable to determine host platform: \(error)")
        }

        @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
        }

        for settingsExtension in settingsExtensions() {
            let baseEnvironment = workspaceContext.userInfo?.buildSystemEnvironment ?? [:]

            do {
                let additionalBuiltins = try settingsExtension.addBuiltinDefaults(fromEnvironment: baseEnvironment, parameters: parameters)

                push(createTableFromUserSettings(additionalBuiltins), .exported)
            } catch {
                self.errors.append("unable to retrieve additional build property builtins")
            }
        }
    }

    /// Add the derived overriding settings for the target. These are settings whose values depend on the whole stack of build settings, and include settings which are forced to a value under certain conditions, and settings whose value is wholly derived from other settings.  They override settings from all lower levels, and thus cannot be overridden by (for example) xcodebuild or run destination overrides, so settings should only be assigned here when they represent true boundary conditions which users should never want to or be able to override.
    ///
    /// These are only added if we're constructing settings for a target.
    func addTargetDerivedSettings(_ target: Target?, _ platform: Platform?, _ sdk: SDK?, _ sdkVariant: SDKVariant?) {
        guard target != nil else {
            return
        }

        push(getTargetDerivedSettings(platform, sdk, sdkVariant), .exportedForNative)
        addSecondaryTargetDerivedSettings(sdk)
    }

    /// Add the core derived overriding settings for the target.
    ///
    /// This is called from `addTargetDerivedSettings().
    func getTargetDerivedSettings(_ platform: Platform?, _ sdk: SDK?, _ sdkVariant: SDKVariant?) -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = createScope(sdkToUse: sdk)

        // FIXME: Previously, both of these were handled with dynamic property expressions, so they could be pushed in the same place as Xcode in the tier-less model, and as a way to ensure the definition matched the intent. However, we move this until later and then do it in a manner close to what Xcode does, and if it suffices then we may want to stick with it just to avoid the complexity of dynamic expressions (which are tracked by: <rdar://problem/22981068> Add support for "dynamic" macro expressions).

        // If there is no INSTALL_PATH, then SKIP_INSTALL is set to YES.
        if scope.evaluate(BuiltinMacros.INSTALL_PATH).isEmpty {
            table.push(BuiltinMacros.SKIP_INSTALL, literal: true)
        }

        // If STRIP_INSTALLED_PRODUCT is unset (determined by looking for an empty evaluation), then set to the value of UNSTRIPPED_PRODUCT.  This is for compatibility for very old projects - STRIP_INSTALLED_PRODUCT is the setting exposed in the UI.
        if scope.evaluateAsString(BuiltinMacros.STRIP_INSTALLED_PRODUCT).isEmpty {
            table.push(BuiltinMacros.STRIP_INSTALLED_PRODUCT, literal: !scope.evaluate(BuiltinMacros.UNSTRIPPED_PRODUCT))
        }

        // If either the C or the Swift optimization levels are "none", then enable IS_UNOPTIMIZED_BUILD.  This setting has some overlap with DEPLOYMENT_POSTPROCESSING, but that setting essentially indicates whether this is an Archive build or not, while this setting is tied to compiler optimization level.
        //
        // FIXME: Arguably we should emit a warning if the optimization settings are out of sync, as the user may be getting weird results.  It's not clear if there are lots of old projects which might spuriously get such a warning, and this isn't a new state of affairs.
        table.push(BuiltinMacros.IS_UNOPTIMIZED_BUILD, literal: (scope.evaluate(BuiltinMacros.GCC_OPTIMIZATION_LEVEL) == "0" || scope.evaluate(BuiltinMacros.SWIFT_OPTIMIZATION_LEVEL) == "-Onone"))

        // If unset, infer the default SWIFT_LIBRARY_LEVEL from the INSTALL_PATH.
        if scope.evaluateAsString(BuiltinMacros.SWIFT_LIBRARY_LEVEL).isEmpty &&
           scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_dylib" {
            let privateInstallPaths = scope.evaluate(BuiltinMacros.__KNOWN_SPI_INSTALL_PATHS).map { Path($0) }
            let publicInstallPaths = [
                Path("/System/Library/Frameworks"),
                Path("/System/Library/SubFrameworks"),
                Path("/usr/lib"),
                Path("/System/iOSSupport/System/Library/Frameworks"),
                Path("/System/iOSSupport/System/Library/SubFrameworks"),
                Path("/System/iOSSupport/usr/lib"),]
            let installPath = scope.evaluate(BuiltinMacros.INSTALL_PATH)

            if table.contains(BuiltinMacros.SKIP_INSTALL) {
                // Build-time / IPI module, the compiler doesn't know about this mode yet.
            } else if privateInstallPaths.contains(where: { $0.isAncestorOrEqual(of: installPath) }) {
                // SPI module.
                table.push(BuiltinMacros.SWIFT_LIBRARY_LEVEL, literal: "spi")
            } else if publicInstallPaths.contains(where: { $0.isAncestorOrEqual(of: installPath) }) {
                // Public module.
                table.push(BuiltinMacros.SWIFT_LIBRARY_LEVEL, literal: "api")
            }
            // Else, leave it to the compiler's default.
        }

        // Overrides specific to building for Mac Catalyst.
        if platform?.familyName == "macOS", let sdkVariant, sdkVariant.isMacCatalyst {
            // macCatalyst does not support ODR, but Foundation supports ODR APIs in Mac Catalyst loading the resources from the app bundle itself.  Therefore, we simply disable ODR for Mac Catalyst.
            table.push(BuiltinMacros.ENABLE_ON_DEMAND_RESOURCES, literal: false)

            // Due to the way search paths for Mac Catalyst are implemented in the SDK, if the user has defined those search paths in their project or target without using $(inherited), then the required paths will not be included in the build lines.  We append those paths to the build settings so they will be searched even in that case.  This means these paths will appear twice in targets which *are* using $(inherited), but that should be safe.
            // c.f. <rdar://problem/50105209> for background on this logic.
            // Because the settings vary between SDKs, we grab the definition from the SDK variant's settings table, remove any $(inherited) component, and append the remainder to the setting.
            // We scan all search path settings even though some of them are not (at the time of writing) defined in the Mac Catalyst SDK variant.
            for setting in [
                BuiltinMacros.FRAMEWORK_SEARCH_PATHS,
                BuiltinMacros.HEADER_SEARCH_PATHS,
                BuiltinMacros.LIBRARY_SEARCH_PATHS,
                BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS,
                BuiltinMacros.SYSTEM_HEADER_SEARCH_PATHS,
            ] {
                if let assignment = sdkVariant.settings[setting.name], case .plString(var value) = assignment, !value.isEmpty {
                    // Remove the $(inherited) from the string since we don't know where exactly it will be.
                    // Note that this code assumes $(inherited) appears no more than once, which should be fine for the specialized nature of this algorithm.
                    if let range = value.range(of: "$(inherited)") {
                        value.removeSubrange(range)
                    }

                    // Add $(inherited) to the beginning of the string so the search paths will be last, then parse the string and add it to the table.
                    let parsedValue = table.namespace.parseForMacro(setting, value: "$(inherited) \(value)")
                    table.push(setting, parsedValue)
                }
            }
        }

        // watchOS applications using the public SDK are required to have WKApplication=YES in Info.plist.
        if let productType, platform?.familyName == "watchOS" && !scope.evaluate(BuiltinMacros.__SKIP_INJECT_INFOPLIST_KEY_WKApplication) && productType.conformsTo(identifier: "com.apple.product-type.application") && !productType.conformsTo(identifier: "com.apple.product-type.application.watchapp2") {
            table.push(BuiltinMacros.INFOPLIST_KEY_WKApplication, literal: true)
        }

        return table
    }

    /// Add derived settings for the target which are themselves derived from the core target derived settings computed above. (Whee!)
    ///
    /// This is called from `addTargetDerivedSettings().
    func addSecondaryTargetDerivedSettings(_ sdk: SDK?) {
        // Mergeable library/merged binary support.
        do {
            let scope = createScope(sdkToUse: sdk)
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

            switch scope.evaluate(BuiltinMacros.MERGED_BINARY_TYPE) {
            case .automatic:
                table.push(BuiltinMacros.AUTOMATICALLY_MERGE_DEPENDENCIES, literal: true)
            case .manual:
                table.push(BuiltinMacros.MERGE_LINKED_LIBRARIES, literal: true)
            case .none:
                break
            }

            push(table, .exportedForNative)
        }
        do {
            let scope = createScope(sdkToUse: sdk)
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

            // If we're automatically merging dependencies, then enable merging of libraries.
            if scope.evaluate(BuiltinMacros.AUTOMATICALLY_MERGE_DEPENDENCIES) {
                table.push(BuiltinMacros.MERGE_LINKED_LIBRARIES, literal: true)
            }

            // If this is a mergeable library, then build it as mergeable if this is a release build.
            if scope.evaluate(BuiltinMacros.MERGEABLE_LIBRARY), !scope.evaluate(BuiltinMacros.IS_UNOPTIMIZED_BUILD) {
                table.push(BuiltinMacros.MAKE_MERGEABLE, literal: true)
            }

            push(table, .exportedForNative)
        }
        do {
            let scope = createScope(sdkToUse: sdk)

            // If the product is being built as mergeable, then that overrides certain other settings.
            if scope.evaluate(BuiltinMacros.MAKE_MERGEABLE) {
                var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
                table.push(BuiltinMacros.STRIP_INSTALLED_PRODUCT, literal: false)
                push(table, .exportedForNative)
            }
        }
    }

    var usePerConfigurationBuildLocations: Bool {
        if let value = workspaceContext.userInfo?.buildSystemEnvironment["USE_PER_CONFIGURATION_BUILD_LOCATIONS"] {
            return ["yes", "1", "true"].contains(value.lowercased())
        }

        if let value = workspaceContext.userPreferences.usePerConfigurationBuildLocations {
            return value
        }

        return true
    }

    // FIXME: Find a better name for exactly what this table should map to, and why it exists at the layer it does.
    //
    /// Create and return the target-level dynamic settings.  These are overridden by the target's xcconfig's settings, and then by the target's own settings.  But, they override the project-level settings.
    func getTargetDynamicSettings(_ target: Target, _ config: BuildConfiguration, _ sdk: SDK?) -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        // FIXME: Xcode sets a "CLONE_HEADERS" setting here for external targets, but its value only changes in response to a user default. I suspect this is legacy code we have no need to support, delete this comment once we can be assured of that.

        table.push(BuiltinMacros.TARGET_NAME, literal: target.name)
        // FIXME: This setting is deprecated.
        table.push(BuiltinMacros.TARGETNAME, Static { BuiltinMacros.namespace.parseString("$(TARGET_NAME)") })

        // FIXME: We need to get rid of these style settings, which predate the availability of true per-arch or per-variant build settings.
        table.push(BuiltinMacros.PER_ARCH_CFLAGS, Static { BuiltinMacros.namespace.parseStringList("$(PER_ARCH_CFLAGS_$(CURRENT_ARCH))") })
        table.push(BuiltinMacros.PER_ARCH_LD, Static { BuiltinMacros.namespace.parseString("$(LD_$(CURRENT_ARCH))") })
        table.push(BuiltinMacros.PER_ARCH_LDPLUSPLUS, Static { BuiltinMacros.namespace.parseString("$(LDPLUSPLUS_$(CURRENT_ARCH))") })
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, Static { BuiltinMacros.namespace.parseString("$(OBJECT_FILE_DIR_$(CURRENT_VARIANT))/$(CURRENT_ARCH)") })
        table.push(BuiltinMacros.PER_VARIANT_CFLAGS, Static { BuiltinMacros.namespace.parseStringList("$(OTHER_CFLAGS_$(CURRENT_VARIANT))") })
        table.push(BuiltinMacros.PER_VARIANT_OBJECT_FILE_DIR, Static { BuiltinMacros.namespace.parseString("$(OBJECT_FILE_DIR_$(CURRENT_VARIANT))") })
        table.push(BuiltinMacros.PER_VARIANT_OTHER_LIPOFLAGS, Static { BuiltinMacros.namespace.parseStringList("$(OTHER_LIPOFLAGS_$(CURRENT_VARIANT))") })

        if let standardTarget = target as? StandardTarget {
            if let classPrefix = standardTarget.classPrefix.nilIfEmpty {
                table.push(BuiltinMacros.PROJECT_CLASS_PREFIX, literal: classPrefix)
            }

            table.push(BuiltinMacros.PRODUCT_TYPE, literal: standardTarget.productTypeIdentifier)
        }

        if target.type == .aggregate {
            // Aggregate targets are often used to enforce ordering relationships, so we should not opt them into eager compilation behavior.
            table.push(BuiltinMacros.EAGER_COMPILATION_ALLOW_SCRIPTS, literal: false)
        }

        if target.type == .aggregate && parameters.action == .indexBuild {
            // For the index build setup aggregate targets as 'suitable' for multiple platforms.
            table.push(BuiltinMacros.SDKROOT, literal: "auto")
            table.push(BuiltinMacros.SDK_VARIANT, literal: "auto")
            table.push(BuiltinMacros.SUPPORTED_PLATFORMS, Static { BuiltinMacros.namespace.parseStringList("$(AVAILABLE_PLATFORMS)") })
            table.push(BuiltinMacros.ALLOW_TARGET_PLATFORM_SPECIALIZATION, literal: true)
        }

        // Add additional settings which only apply to non-standard targets.
        //
        // FIXME: This is gross, and similar logic happens in at least two other places (in the target "dynamic defaults" and in the target "overrides" settings). We should clean it all up once we have a solid base to test against.
        if target.type != .standard {
            // FIXME: This is bogus, we are creating a scope here and evaluating a setting, but in Xcode this ends up behaving very differently because of what has been pushed into the tiers. It isn't clear yet how much this matters in practice.
            let scope = createScope(sdkToUse: sdk)
            if parameters.action.isInstallAction || scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
                // Determine if we are skipping the install, by inspecting the configuration directly.
                let skipInstall: Bool
                if target.type == .external {
                    // External targets are special - they only look to see if SKIP_INSTALL is enabled in the target itself, and ignore the value of $(INSTALL_PATH).
                    skipInstall = MacroEvaluationScope(table: config.buildSettings).evaluate(BuiltinMacros.SKIP_INSTALL)
                }
                else {
                    skipInstall = scope.evaluate(BuiltinMacros.SKIP_INSTALL) || scope.evaluate(BuiltinMacros.INSTALL_PATH).isEmpty
                }
                // If we're skipping the install (or don't have a path to install to), then TARGET_BUILD_DIR is set to an UninstalledProducts location.  Note that the external
                if skipInstall {
                    let targetBuildDir: MacroStringExpression
                    // If we're building with per-configuration build folders, then we append $(PLATFORM_NAME) to the path for the uninstalled products in case the build is building the same framework twice for different platforms.
                    if usePerConfigurationBuildLocations {
                        targetBuildDir = Static { BuiltinMacros.namespace.parseString("$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)$(TARGET_BUILD_SUBPATH)") }
                    } else {
                        targetBuildDir = Static { BuiltinMacros.namespace.parseString("$(UNINSTALLED_PRODUCTS_DIR)$(TARGET_BUILD_SUBPATH)") }
                    }
                    table.push(BuiltinMacros.TARGET_BUILD_DIR, targetBuildDir)
                } else {
                    // If we're not skipping the install, then TARGET_BUILD_DIR is set to the destination location. $(INSTALL_ROOT) defaults to $(DSTROOT).
                    table.push(BuiltinMacros.TARGET_BUILD_DIR, Static { BuiltinMacros.namespace.parseString("$(INSTALL_ROOT)/$(INSTALL_PATH)$(TARGET_BUILD_SUBPATH)") })
                }

                // INSTALLED_PRODUCT_ASIDES is set to YES in the environment, then we append a 'BuiltProducts' component to BUILT_PRODUCTS_DIR.
                if let installedProductAsides = workspaceContext.userInfo?.buildSystemEnvironment["INSTALLED_PRODUCT_ASIDES"]?.boolValue, installedProductAsides {
                    table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, Static { BuiltinMacros.namespace.parseString("$(CONFIGURATION_BUILD_DIR)/BuiltProducts") })
                } else {
                    table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, Static { BuiltinMacros.namespace.parseString("$(CONFIGURATION_BUILD_DIR)") })
                }
            }

            // Handle support for not using per-configuration build directories.
            if !usePerConfigurationBuildLocations {
                table.push(BuiltinMacros.CONFIGURATION_BUILD_DIR, Static { BuiltinMacros.namespace.parseString("$(BUILD_DIR") })
                table.push(BuiltinMacros.CONFIGURATION_TEMP_DIR, Static { BuiltinMacros.namespace.parseString("$(PROJECT_TEMP_DIR")})
            }
        }

        return table
    }

    func addPlaygroundSettings(_ platform: Platform?) {
        guard let platform else {
            return
        }

        var table = MacroValueAssignmentTable(namespace: userNamespace)
        let platformFrameworksDir = platform.path.join("Developer/Library/Frameworks").str

        let otherSwiftFlags = [
            "-Xfrontend",
            "-playground",
            "-enable-experimental-feature",
            "PlaygroundExtendedCallbacks",
            "-Xfrontend",
            "-import-module",
            "-Xfrontend",
            "LiveExecutionResultsLogger",
            "-F",
            "\(platformFrameworksDir)"
        ]

        table.push(BuiltinMacros.OTHER_SWIFT_FLAGS, BuiltinMacros.namespace.parseStringList(["$(inherited)"] + otherSwiftFlags))
        table.push(BuiltinMacros.FRAMEWORK_SEARCH_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)"] + [platformFrameworksDir]))
        /// Setting this in `LD_RUNPATH_SEARCH_PATHS` should work (and does at build/link time but not at runtime).
        table.push(BuiltinMacros.OTHER_LDFLAGS, BuiltinMacros.namespace.parseStringList(["$(inherited)"] + ["-rpath", platformFrameworksDir]))

        push(table)
    }

    /// Add the platform settings.
    func addPlatformSettings(_ platform: Platform?) {
        // FIXME: We should cache this table somewhere.
        var platformTable = MacroValueAssignmentTable(namespace: userNamespace)
        let specLookupContext = SpecLookupCtxt(specRegistry: core.specRegistry, platform: platform)

        // Add computed platform properties which have a lower precedence than the platform settings.

        // Add arch properties. We set NATIVE_ARCH_ACTUAL to the host CPU type, and NATIVE_ARCH_32_BIT and NATIVE_ARCH_64_BIT to the 32-bit and 64-bit equivalents of that.
        // NATIVE_ARCH is set to NATIVE_ARCH_ACTUAL to match PBX, although it used to be equivalent to NATIVE_ARCH_32_BIT in an earlier version of PBX. We ignore CPU
        // subtypes in all cases (x86_64h, arm64e, etc.). Also, NXGetLocalArchInfo is not guaranteed to include the CPU_ARCH_ABI64 mask in its returned cputype
        // (for example on a non-Haswell CPU we get a general x86 CPU subtype which won't infer 64-bit like Haswell does), so we manually add the mask if the CPU is 64-bit capable.
        let fallbackArch = "undefined_arch"
        if core.hostOperatingSystem == .macOS {
            platformTable.push(BuiltinMacros.NATIVE_ARCH_ACTUAL, literal: Architecture.host.stringValue ?? fallbackArch)
            platformTable.push(BuiltinMacros.NATIVE_ARCH_32_BIT, literal: Architecture.host.as32bit.stringValue ?? fallbackArch)
            platformTable.push(BuiltinMacros.NATIVE_ARCH_64_BIT, literal: Architecture.host.as64bit.stringValue ?? fallbackArch)
            platformTable.push(BuiltinMacros.NATIVE_ARCH, literal: Architecture.host.stringValue ?? fallbackArch)
        } else {
            platformTable.push(BuiltinMacros.NATIVE_ARCH_ACTUAL, literal: Architecture.hostStringValue ?? fallbackArch)
            platformTable.push(BuiltinMacros.NATIVE_ARCH, literal: Architecture.hostStringValue ?? fallbackArch)
        }

        // Add the platform deployment target defaults, for real platforms.
        //
        // FIXME: For legacy compatibility, we only do this when configuring settings for a target. This distinction most likely isn't important, and should just be eliminated.
        if self.target != nil {
            for (deploymentTargetSettingName, defaultDeploymentTarget) in core.platformRegistry.defaultDeploymentTargets {
                try? platformTable.push(platformTable.namespace.declareStringMacro(deploymentTargetSettingName), literal: defaultDeploymentTarget.canonicalDeploymentTargetForm.description)
            }
        }

        // Add the platform settings themselves, if we have a platform.

        if let platform {
            // Add the platform extended-info driven settings.  Some of these are overridden for Mac Catalyst.
            if let macro = platform.deploymentTargetMacro {
                platformTable.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: macro.name)
            }
            if let correspondingPlatform = platform.correspondingDevicePlatform {
                platformTable.push(BuiltinMacros.CORRESPONDING_DEVICE_PLATFORM_NAME, literal: correspondingPlatform.name)
                platformTable.push(BuiltinMacros.CORRESPONDING_DEVICE_PLATFORM_DIR, literal: correspondingPlatform.path.str)
                if let correspondingSDKName = correspondingPlatform.sdkCanonicalName,
                    let correspondingSDK = try? sdkRegistry.lookup(correspondingSDKName, activeRunDestination: parameters.activeRunDestination) {
                    platformTable.push(BuiltinMacros.CORRESPONDING_DEVICE_SDK_NAME, literal: correspondingSDK.canonicalName)
                    platformTable.push(BuiltinMacros.CORRESPONDING_DEVICE_SDK_DIR, literal: correspondingSDK.path.str)
                }
            }
            if let correspondingPlatform = platform.correspondingSimulatorPlatform {
                platformTable.push(BuiltinMacros.CORRESPONDING_SIMULATOR_PLATFORM_NAME, literal: correspondingPlatform.name)
                platformTable.push(BuiltinMacros.CORRESPONDING_SIMULATOR_PLATFORM_DIR, literal: correspondingPlatform.path.str)
                if let correspondingSDKName = correspondingPlatform.sdkCanonicalName,
                    let correspondingSDK = try? sdkRegistry.lookup(correspondingSDKName, activeRunDestination: parameters.activeRunDestination) {
                    platformTable.push(BuiltinMacros.CORRESPONDING_SIMULATOR_SDK_NAME, literal: correspondingSDK.canonicalName)
                    platformTable.push(BuiltinMacros.CORRESPONDING_SIMULATOR_SDK_DIR, literal: correspondingSDK.path.str)
                }
            }

            // Add the default for SUPPORTED_PLATFORMS.
            platformTable.push(BuiltinMacros.SUPPORTED_PLATFORMS, literal: core.platformRegistry.platforms.compactMap {
                    return $0.familyName == platform.familyName ? $0.name : nil
                })


            // Add the platform default settings.
            platformTable.pushContentsOf(platform.defaultSettingsTable)

            let isMacOS = platform.identifier == "com.apple.platform.macosx"

            // Add the additional computed platform properties.
            platformTable.push(BuiltinMacros.PLATFORM_NAME, literal: platform.name)
            platformTable.push(BuiltinMacros.PLATFORM_FAMILY_NAME, literal: platform.familyName)
            platformTable.push(BuiltinMacros.PLATFORM_DISPLAY_NAME, literal: platform.displayName)
            platformTable.push(BuiltinMacros.PLATFORM_DIR, literal: platform.path.str)
            if isMacOS {
                platformTable.push(BuiltinMacros.EFFECTIVE_PLATFORM_NAME, literal: "")
            } else {
                platformTable.push(BuiltinMacros.EFFECTIVE_PLATFORM_NAME, literal: "-\(platform.name)")
            }
            if platform.name.hasSuffix("simulator") {
                platformTable.push(BuiltinMacros.EFFECTIVE_PLATFORM_SUFFIX, literal: "simulator")
            } else {
                platformTable.push(BuiltinMacros.EFFECTIVE_PLATFORM_SUFFIX, literal: "os")
            }
            if let productBuildVersion = platform.productBuildVersion {
                platformTable.push(BuiltinMacros.PLATFORM_PRODUCT_BUILD_VERSION, literal: productBuildVersion)
            }

            // Note that this setting is generally of limited utility and is currently only used in two places:
            // as a fallback in the project planner when there is no preferred arch for the platform
            // (this should never be the case in practice), and in the index build arena where targets
            // are configured for _all_ platforms regardless of the run destination and must pick a single
            // architecture for indexing. Neither of these scenarios are ideal, especially because
            // PLATFORM_PREFERRED_ARCH is fixed and doesn't adapt to the context, like preferring arm64
            // for macOS and simulator platforms on Apple Silicon hosts.
            // <rdar://problem/65011964> Should PLATFORM_PREFERRED_ARCH be dynamic?
            if let preferredArch = platform.preferredArch {
                platformTable.push(BuiltinMacros.PLATFORM_PREFERRED_ARCH, literal: preferredArch)
            }

            // Add platform hard-coded paths.
            //
            // FIXME: These macOS paths no longer make sense, they should point to the macOS platform.
            if isMacOS {
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_APPLICATIONS_DIR, Static { BuiltinMacros.namespace.parseString("$(DEVELOPER_APPLICATIONS_DIR)") })
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_TOOLS_DIR, Static { BuiltinMacros.namespace.parseString("$(DEVELOPER_TOOLS_DIR)") })
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_LIBRARY_DIR, Static { BuiltinMacros.namespace.parseString("$(DEVELOPER_LIBRARY_DIR)") })
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_USR_DIR, Static { BuiltinMacros.namespace.parseString("$(DEVELOPER_USR_DIR)") })
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_BIN_DIR, Static { BuiltinMacros.namespace.parseString("$(DEVELOPER_BIN_DIR)") })
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_SDK_DIR, Static { BuiltinMacros.namespace.parseString("$(DEVELOPER_SDK_DIR)") })
            } else {
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_APPLICATIONS_DIR, literal: "\(platform.path.str)/Developer/Applications")
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_TOOLS_DIR, literal: "\(platform.path.str)/Developer/Tools")
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_LIBRARY_DIR, literal: "\(platform.path.str)/Developer/Library")
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_USR_DIR, literal: "\(platform.path.str)/Developer/usr")
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_BIN_DIR, literal: "\(platform.path.str)/Developer/usr/bin")
                platformTable.push(BuiltinMacros.PLATFORM_DEVELOPER_SDK_DIR, literal: "\(platform.path.str)/Developer/SDKs")
            }
        } else {
            // Fallback to a separate directory so that the MacOS directory (which has no suffix) isn't stomped.
            platformTable.push(BuiltinMacros.EFFECTIVE_PLATFORM_NAME, literal: "-unknown")
        }

        // Add the correct value for VALID_ARCHS.
        let archSpecs = specLookupContext.findSpecs(ArchitectureSpec.self).sorted(by: \.identifier)
        platformTable.push(BuiltinMacros.VALID_ARCHS, literal: archSpecs.compactMap { $0.isRealArch ? $0.canonicalName : nil })

        // Add the build settings which are defined in architecture specs.
        for spec in archSpecs {
            guard let macro = spec.archSetting else { continue }
            guard let realArchs = spec.realArchs else { continue }
            platformTable.push(macro, realArchs)
        }

        // Push the table.
        push(platformTable, .exported)
    }

    /// Add the toolchain settings.  This will bind and parse the assignments for the settings.
    func addToolchainSettings(_ toolchain: Toolchain, isPrimary: Bool) {
        // FIXME: We should parse tables when we first load the toolchain (to improve performance, but it also gives us a better place to report parse errors)
        // FIXME: What's the right namespace to use here? Does it depend on if it's a builtin vs. an external toolchain?
        // FIXME: We should address all of these FIXMEs in <rdar://problem/36364112> Bind & parse default settings for toolchain at Core creation time

        // Add the toolchains's default settings.
        do {
            let toolchainTable = try userNamespace.parseTable(toolchain.defaultSettings, allowUserDefined: true)
            push(toolchainTable, .exported)
        } catch {
            self.errors.append("unable to load toolchain default settings: '\(error)'")
        }

        // Add the toolchains's default settings, when primary.
        if isPrimary {
            do {
                let toolchainTable = try userNamespace.parseTable(toolchain.defaultSettingsWhenPrimary, allowUserDefined: true)
                push(toolchainTable, .exported)
            } catch {
                self.errors.append("unable to load toolchain default settings: '\(error)'")
            }
        }
    }

    /// Add the SDK default settings.
    func addSDKSettings(_ sdk: SDK, _ variant: SDKVariant?, _ sparseSDKs: [SDK]) {
        // Add the SDK's default settings.
        var sdkTable = MacroValueAssignmentTable(namespace: userNamespace)
        if let defaultSettingsTable = sdk.defaultSettingsTable {
            sdkTable.pushContentsOf(defaultSettingsTable)
        }

        // Set IOS_UNZIPPERED_TWIN_PREFIX_PATH to the Mac Catalyst variant's prefix path, even for the macOS variant.
        if let macCatalystVariant = sdk.variant(for: MacCatalystInfo.sdkVariantName) {
            sdkTable.push(BuiltinMacros.IOS_UNZIPPERED_TWIN_PREFIX_PATH, literal: macCatalystVariant.systemPrefix)
        }

        // Add the settings provided by the SDK variant, if there is one.
        if let variant {
            // Late-bound by `SDKRegistry.loadExtendedInfo` and may be nil if an error (which will have already been reported) was encountered during loading.
            if let settingsTable = variant.settingsTable {
                sdkTable.pushContentsOf(settingsTable)
            }

            sdkTable.push(BuiltinMacros.SYSTEM_PREFIX, literal: variant.systemPrefix)

            sdkTable.push(BuiltinMacros.LINK_OBJC_RUNTIME, literal: variant.isMacCatalyst ? true : localFS.exists(sdk.path.join(variant.systemPrefix, preserveRoot: true).join("usr/lib/libobjc.tbd")))

            // Add ObjC ARC support for Apple platforms.
            if let project, project.isPackage, variant.llvmTargetTripleVendor == "apple" {
                sdkTable.push(BuiltinMacros.CLANG_ENABLE_OBJC_ARC, literal: true)
            }

            if let llvmTargetTripleVendor = variant.llvmTargetTripleVendor {
                sdkTable.push(BuiltinMacros.LLVM_TARGET_TRIPLE_VENDOR, literal: llvmTargetTripleVendor)
            }

            if let llvmTargetTripleSys = variant.llvmTargetTripleSys {
                sdkTable.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: llvmTargetTripleSys)
            }

            if let llvmTargetTripleEnvironment = variant.llvmTargetTripleEnvironment?.nilIfEmpty {
                sdkTable.push(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX, literal: "-\(llvmTargetTripleEnvironment)")
            }

            if let recommendedDeploymentTarget = variant.recommendedDeploymentTarget {
                if variant.isMacCatalyst {
                    sdkTable.push(sdkTable.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, "RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET"), sdkTable.namespace.parseLiteralString(recommendedDeploymentTarget.zeroTrimmed.zeroPadded(toMinimumNumberOfComponents: 2).description))

                    // Add the mapped deployment target if we have a version mapping
                    if !sdk.versionMap.isEmpty {
                        if let otherDeploymentTarget = sdk.versionMap["iOSMac_macOS"]?[recommendedDeploymentTarget] {
                            sdkTable.push(sdkTable.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, "RECOMMENDED_MACOSX_DEPLOYMENT_TARGET"), sdkTable.namespace.parseLiteralString(otherDeploymentTarget.zeroTrimmed.zeroPadded(toMinimumNumberOfComponents: 2).description))
                        } else {
                            errors.append("Could not find an equivalent macOS deployment target for Mac Catalyst deployment target \(recommendedDeploymentTarget.zeroTrimmed.zeroPadded(toMinimumNumberOfComponents: 2).description)")
                        }
                    }
                } else if let settingName = variant.deploymentTargetSettingName {
                    sdkTable.push(sdkTable.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, "RECOMMENDED_\(settingName)"), sdkTable.namespace.parseLiteralString(recommendedDeploymentTarget.zeroTrimmed.zeroPadded(toMinimumNumberOfComponents: 2).description))
                }
            }

            if variant.isMacCatalyst {
                sdkTable.push(BuiltinMacros.EFFECTIVE_PLATFORM_NAME_MAC_CATALYST_USE_DISTINCT_BUILD_DIR, literal: true)
                sdkTable.push(sdkTable.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, "EFFECTIVE_PLATFORM_NAME_MAC_CATALYST_USE_DISTINCT_BUILD_DIR_YES"), sdkTable.namespace.parseLiteralString(MacCatalystInfo.publicSDKBuiltProductsDirSuffix))
                sdkTable.push(BuiltinMacros.EFFECTIVE_PLATFORM_NAME, BuiltinMacros.namespace.parseString("$(EFFECTIVE_PLATFORM_NAME_MAC_CATALYST_USE_DISTINCT_BUILD_DIR_$(EFFECTIVE_PLATFORM_NAME_MAC_CATALYST_USE_DISTINCT_BUILD_DIR):default=$(inherited))"))
            }

            let imageFormat: ImageFormat
            if variant.buildVersionPlatformID != nil {
                imageFormat = .macho
            } else if variant.llvmTargetTripleSys == "windows" {
                imageFormat = .pe
            } else {
                imageFormat = .elf
            }

            sdkTable.push(BuiltinMacros.DYNAMIC_LIBRARY_EXTENSION, literal: imageFormat.dynamicLibraryExtension)
            sdkTable.push(BuiltinMacros.PLATFORM_REQUIRES_SWIFT_AUTOLINK_EXTRACT, literal: imageFormat.requiresSwiftAutolinkExtract)
            sdkTable.push(BuiltinMacros.PLATFORM_REQUIRES_SWIFT_MODULEWRAP, literal: imageFormat.requiresSwiftModulewrap)
        }

        // Add additional SDK default settings.
        sdkTable.push(BuiltinMacros.SDK_NAME, literal: sdk.canonicalName)
        sdkTable.push(BuiltinMacros.SDK_NAMES, literal: sparseSDKs.map({ $0.canonicalName }) + [sdk.canonicalName])
        sdkTable.push(BuiltinMacros.SDK_DIR, literal: sdk.path.str)

        sdkTable.push(BuiltinMacros.SDK_STAT_CACHE_DIR, BuiltinMacros.namespace.parseString("$(DERIVED_DATA_DIR)"))
        sdkTable.push(BuiltinMacros.SDK_STAT_CACHE_PATH, BuiltinMacros.namespace.parseString("$(SDK_STAT_CACHE_DIR)/SDKStatCaches.noindex/\(sdk.canonicalName)-\(sdk.productBuildVersion ?? "none")-$(TOOLCHAINS:__md5)$(SDKROOT:__md5).sdkstatcache"))

        // Add the SDK_DIR_<identifier> settings.
        for directoryMacro in sdk.directoryMacros {
            sdkTable.push(directoryMacro, literal: sdk.path.str)
        }

        // Add the version info.
        if let productBuildVersion = sdk.productBuildVersion {
            sdkTable.push(BuiltinMacros.SDK_PRODUCT_BUILD_VERSION, literal: productBuildVersion)
        }
        if let version = sdk.version {
            sdkTable.push(BuiltinMacros.SDK_VERSION, literal: "\(version[0]).\(version[1])")

            let minorStr = String(format: "%02d", version[1])
            let updateStr = String(format: "%02d", version[2])
            sdkTable.push(BuiltinMacros.SDK_VERSION_ACTUAL, literal: "\(version[0])\(minorStr)\(updateStr)")

            // Special case for macOS versions prior to 11, which treat the _MAJOR macro here as the second version number component (the first is always '10'). This is consistent with the MAC_OS_X version string.
            let isLegacyMacOS = sdk.canonicalName.hasPrefix("macosx") && version[0] <= 10
            if isLegacyMacOS {
                sdkTable.push(BuiltinMacros.SDK_VERSION_MAJOR, literal: "\(version[0])\(minorStr)00")
                sdkTable.push(BuiltinMacros.SDK_VERSION_MINOR, literal: "\(version[1])\(updateStr)")
            } else {
                sdkTable.push(BuiltinMacros.SDK_VERSION_MAJOR, literal: "\(version[0])0000")
                sdkTable.push(BuiltinMacros.SDK_VERSION_MINOR, literal: "\(version[0])\(minorStr)00")
            }
        }

        // Add settings for the sparse SDKs.  Since the highest-priority SDK is listed first, we iterate over them in reverse order.
        for sparseSDK in sparseSDKs.reversed() {
            if let defaultSettingsTable = sparseSDK.defaultSettingsTable {
                sdkTable.pushContentsOf(defaultSettingsTable)
            }
        }

        @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
        }
        for settingsExtension in settingsExtensions() {
            do {
                let additionalSettings = try settingsExtension.addSDKSettings(sdk, variant, sparseSDKs)
                sdkTable.pushContentsOf(createTableFromUserSettings(additionalSettings))
            } catch {
                self.errors.append("unable to retrieve additional SDK settings")
            }
        }

        // Push the table.
        push(sdkTable, .exportedForNative)
    }

    // FIXME: Why is this logic not part of loading the SDK in SDKRegistry.registerSDK()?  I think all of the information currently used by this method should be available there.
    func addPlatformSDKSettings(_ platform: Platform?, _ sdk: SDK, _ sdkVariant: SDKVariant?) {
        pushTable(.exported) { table in
            // Bitcode is no longer supported, so we want to continue to strip bitcode from non-simulator embedded platforms as we always have.
            if let platform, !platform.isSimulator, platform.correspondingSimulatorPlatformName != nil {
                table.push(BuiltinMacros.STRIP_BITCODE_FROM_COPIED_FILES, literal: true)
            }

            @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
                core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
            }

            func shouldPopulateValidArchs(platform: Platform) -> Bool {
                // For now, we only do this for some platforms to avoid behavior changes.
                // Later, we should extend this to more SDKs via <rdar://66001997>
                switch platform.name {
                case "macosx",
                    "iphoneos",
                    "iphonesimulator",
                    "appletvos",
                    "appletvsimulator",
                    "watchos",
                    "watchsimulator",
                    "xros",
                    "xrsimulator":
                    return false
                default:
                    for settingsExtension in settingsExtensions() {
                        if settingsExtension.shouldSkipPopulatingValidArchs(platform: platform) {
                            return false
                        }
                    }
                    return true
                }
            }

            // VALID_ARCHS should be based on the SDK's SupportedTargets dictionary.
            if let archs = sdkVariant?.archs, !archs.isEmpty, let platform, shouldPopulateValidArchs(platform: platform) {
                table.push(BuiltinMacros.VALID_ARCHS, literal: archs)
            }

            for settingsExtension in settingsExtensions() {
                table.pushContentsOf(createTableFromUserSettings(settingsExtension.addPlatformSDKSettings(platform, sdk, sdkVariant)))
            }
        }
    }

    func addSDKToolchains(sdk: SDK) {
        pushTable(.exportedForNative) { table in
            table.push(BuiltinMacros.TOOLCHAINS, literal: sdk.toolchains)
        }
    }

    /// Add the SDK overriding settings.
    func addSDKOverridingSettings(_ sdk: SDK, _ sdkVariant: SDKVariant?) {
        // Add the SDK's overriding settings.
        if let overrideSettingsTable = sdk.overrideSettingsTable {
            push(overrideSettingsTable)
        }

        let scope = createScope(sdkToUse: sdk)
        @preconcurrency @PluginExtensionSystemActor func sdkVariantInfoExtensions() -> [any SDKVariantInfoExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: SDKVariantInfoExtensionPoint.self)
        }
        var macCatalystDeriveBundleIDMacros: Set<String> = []
        for sdkVariantInfoExtension in sdkVariantInfoExtensions() {
            macCatalystDeriveBundleIDMacros.formUnion(sdkVariantInfoExtension.macCatalystDeriveBundleIDMacroNames)
        }
        let wantsDerivedMacCatalystBundleId = macCatalystDeriveBundleIDMacros.contains { scope.evaluate(scope.namespace.parseString("$(\($0)")).boolValue }
        if let sdkVariant, sdkVariant.isMacCatalyst {
            if wantsDerivedMacCatalystBundleId {
                pushTable(.exported) { table in
                    table.push(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER, BuiltinMacros.namespace.parseString(MacCatalystInfo.bundleIdPrefix + "$(inherited)"))
                }
            }

            // Only Mac Catalyst unzippered twins go in /System/iOSSupport.
            if scope.evaluate(BuiltinMacros.IS_ZIPPERED) {
                pushTable(.exported) { table in
                    table.push(BuiltinMacros.SYSTEM_PREFIX, literal: "")
                }
            }
        }
    }

    /// Replace SDKROOT with a path instead of a name, e.g. iphoneos -> /.../iPhoneOS.sdk
    func addSDKPathOverride(_ sdk: SDK) {
        pushTable(.exported) { table in
            table.push(BuiltinMacros.SDKROOT, literal: sdk.path.str)
        }
    }

    /// Push the SDK's default deployment target if the effective value of the platform's deployment target is empty.
    ///
    /// This is called in settings construction just after the SDK's *overriding* settings are pushed, the intent being to set a default value for the deployment target even if the project or target has set it to empty.
    func addDeploymentTargetFallbackIfNeeded(platform: Platform, sdk: SDK) {
        // If the minimum deployment version isn't set, set it to the default for the SDK.  The specific name of the build setting used depends on the platform.  We set it in the overrides tier because the setting that sets it to empty might be at the custom tier.
        guard let deploymentTargetMacro = platform.deploymentTargetMacro else { return }
        let scope = createScope(sdkToUse: sdk)
        if scope.evaluate(deploymentTargetMacro).isEmpty {
            // Fall back on the one from the SDK's build settings (but only if there is one).
            if let defaultDeploymentTargetForSDK = sdk.defaultSettingsTable?.lookupMacro(deploymentTargetMacro)?.expression {
                pushTable(.exported) { table in
                    table.push(deploymentTargetMacro, defaultDeploymentTargetForSDK)
                }
            }
        }
    }

    var allowPlatformFilterCondition: Bool {
        // Use of the platform filter condition is restricted to only packages for now.
        return project?.isPackage == true
    }

    /// Utility method to bind any SDK-conditional settings in `table` to the given `sdk` - taking into account the fallback condition values - and discard conditional assignments which don't match this SDK.
    ///
    /// This method is called on certain tables before those tables are pushed onto the final table, so it is not (at time of writing) applied to the entire table.
    ///
    /// - remark: This is to handle fallback setting conditions.  c.f. <rdar://problem/33851392>
    func bindConditionParameters(_ table: MacroValueAssignmentTable, _ sdk: SDK, forceAllowPlatformFilterCondition: Bool = false) {
        struct PlatformFilterConditionParameterCondition: MacroValueAssignmentTable.CustomConditionParameterCondition {
            let filter: PlatformFilter

            func matches(_ condition: MacroCondition) -> Bool {
                filter.matches(PlatformFilter.fromBuildConditionParameterString(condition.valuePattern))
            }
        }

        let sdkConditionalizedTable = table.bindConditionParameter(BuiltinMacros.sdkCondition, sdk.settingConditionValues)

        if allowPlatformFilterCondition || forceAllowPlatformFilterCondition, let filter = PlatformFilter(createScope(sdkToUse: sdk)) {
            push(sdkConditionalizedTable.bindConditionParameter(BuiltinMacros.platformCondition, PlatformFilterConditionParameterCondition(filter: filter)), .exported)
        } else {
            push(sdkConditionalizedTable, .exported)
        }
    }

    /// Add the regular project settings.
    func addProjectSettings(_ config: BuildConfiguration, _ sdk: SDK? = nil) {
        guard let project else {
            return
        }

        // Add the project-level dynamic settings.  These are overridden by the project's xcconfig's settings, and then by the project's own settings.
        if let projectDynamicSettings = getProjectDynamicSettings() {
            push(projectDynamicSettings, .exported)
        }

        do {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.CONFIGURATION, literal: config.effectiveName(for: project, parameters: parameters))
            table.push(BuiltinMacros.PROJECT_CLASS_PREFIX, literal: project.classPrefix)
            push(table, .exported)
        }

        // Add the project's base .xcconfig settings, if used.
        if let configFileRef = config.baseConfigurationFileReference(workspaceContext.workspace) {
            // Resolve the path.
            //
            // FIXME: It is unfortunate that we need to create a custom file path resolver just for this case (which will not use any cached values). This is also unfortunate from a user perspective, as it is not at all clear what settings could be used in an xcconfig file path. We should consider defining this more formally in a way that can also efficiently be evaluated.
            let resolver = FilePathResolver(scope: createScope(sdkToUse: sdk))
            let path = resolver.resolveAbsolutePath(configFileRef)
            macroConfigPaths.append(path)

            // Load and push a settings table from the file.
            let info = buildRequestContext.getCachedMacroConfigFile(path, project: project, context: .baseConfiguration)
            if let sdk = sdk, settingsContext.purpose.bindToSDK {
                bindConditionParameters(info.table, sdk)
            }
            else {
                // No bound SDK, so push the project's build settings unmodified.
                push(info.table, .exported)
            }
            self.diagnostics.append(contentsOf: info.diagnostics)
            for path in info.dependencyPaths {
                macroConfigPaths.append(path)
            }

            // Save the settings table as part of the construction components.
            self.projectXcconfigPath = path
            self.projectXcconfigSettings = info.table

            // Also save the table we've constructed so far.
            self.upToProjectXcconfigSettings = MacroValueAssignmentTable(copying: _table)
        }

        // Add application preferences build settings.
        do {
            let appPrefBuildSettings = try userNamespace.parseTable(project.appPreferencesBuildSettings, allowUserDefined: true)
            push(appPrefBuildSettings, .exported)
        } catch {
            self.errors.append("unable to parse application preferences build settings: '\(error)'")
        }

        // Add the project's config settings.
        if let sdk, settingsContext.purpose.bindToSDK {
            bindConditionParameters(config.buildSettings, sdk)
        }
        else {
            // No bound SDK, so push the project's build settings unmodified.
            push(config.buildSettings, .exported)
        }

        // Save the settings table as part of the construction components.
        self.projectSettings = config.buildSettings

        // Also save the table we've constructed so far.
        self.upToProjectSettings = MacroValueAssignmentTable(copying: _table)
    }

    func validateSDK(_ sdk: SDK, sdkVariant: SDKVariant?, scope: MacroEvaluationScope) {
        if sdkVariant?.isMacCatalyst ?? false {
            @preconcurrency @PluginExtensionSystemActor func sdkVariantInfoExtensions() -> [any SDKVariantInfoExtensionPoint.ExtensionProtocol] {
                core.pluginManager.extensions(of: SDKVariantInfoExtensionPoint.self)
            }
            var disallowedMacCatalystMacros: Set<String> = []
            for sdkVariantInfoExtension in sdkVariantInfoExtensions() {
                disallowedMacCatalystMacros.formUnion(sdkVariantInfoExtension.disallowedMacCatalystMacroNames)
            }

            for macro in disallowedMacCatalystMacros {
                if scope.evaluate(scope.namespace.parseString("$(\(macro)")).boolValue {
                    let message = "`\(macro)` is not supported. Remove the build setting and conditionalize `PRODUCT_BUNDLE_IDENTIFIER` instead."
                    if scope.evaluate(BuiltinMacros.__DIAGNOSE_DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER_ERROR) {
                        self.errors.append(message)
                    }
                    else {
                        self.warnings.append(message)
                    }
                }
            }
        }
    }

    /// Create and return the project-level dynamic settings.  These are overridden by the project's xcconfig's settings, and then by the project's own settings.
    func getProjectDynamicSettings() -> MacroValueAssignmentTable? {
        guard let project else {
            return nil
        }

        // FIXME: Cache this table somewhere.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        table.push(BuiltinMacros.WORKSPACE_DIR, literal: workspaceContext.workspace.path.dirname.str)
        table.push(BuiltinMacros.PROJECT_NAME, literal: project.name)
        table.push(BuiltinMacros.PROJECT_GUID, literal: project.guid)
        table.push(BuiltinMacros.PROJECT_FILE_PATH, literal: project.xcodeprojPath.str)
        table.push(BuiltinMacros.SRCROOT, literal: project.sourceRoot.str)
        table.push(BuiltinMacros.PROJECT_DIR, literal: project.sourceRoot.str)
        table.push(BuiltinMacros.PROJECT_TEMP_DIR, Static { BuiltinMacros.namespace.parseString("$(OBJROOT)/$(PROJECT_NAME).build") })

        if usePerConfigurationBuildLocations {
            table.push(BuiltinMacros.CONFIGURATION_BUILD_DIR, Static { BuiltinMacros.namespace.parseString("$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)") })
            table.push(BuiltinMacros.CONFIGURATION_TEMP_DIR, Static { BuiltinMacros.namespace.parseString("$(PROJECT_TEMP_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)") })
        } else {
            table.push(BuiltinMacros.CONFIGURATION_BUILD_DIR, Static { BuiltinMacros.namespace.parseString("$(BUILD_DIR)") })
            table.push(BuiltinMacros.CONFIGURATION_TEMP_DIR, Static { BuiltinMacros.namespace.parseString("$(PROJECT_TEMP_DIR)") })
        }
        table.push(BuiltinMacros.TARGET_TEMP_DIR, Static { BuiltinMacros.namespace.parseString("$(CONFIGURATION_TEMP_DIR)/$(TARGET_NAME).build") })
        table.push(BuiltinMacros.TARGET_BUILD_DIR, Static { BuiltinMacros.namespace.parseString("$(CONFIGURATION_BUILD_DIR)$(TARGET_BUILD_SUBPATH)") })
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, Static { BuiltinMacros.namespace.parseString("$(CONFIGURATION_BUILD_DIR)") })
        table.push(BuiltinMacros.DEVELOPMENT_LANGUAGE, literal: project.developmentRegion ?? "en")

        // Add the user and group settings, if we have user info.
        if let userInfo = workspaceContext.userInfo {
            table.push(BuiltinMacros.HOME, literal: userInfo.home.str)
            table.push(BuiltinMacros.USER, literal: userInfo.user)
            table.push(BuiltinMacros.GROUP, literal: userInfo.group)
            table.push(BuiltinMacros.UID, literal: "\(userInfo.uid)")
            table.push(BuiltinMacros.GID, literal: "\(userInfo.gid)")
        }

        // Add the OS version settings, if we have system info.
        if let systemInfo = workspaceContext.systemInfo, workspaceContext.core.hostOperatingSystem == .macOS {
            let osVersion = systemInfo.operatingSystemVersion.zeroPadded(toMinimumNumberOfComponents: 3)
            let majorStr = osVersion.rawValue[0].toString(format: "%02d")
            let minorStr = osVersion.rawValue[1].toString(format: "%02d")
            let updateStr = osVersion.rawValue[2].toString(format: "%02d")
            if osVersion.rawValue[0] <= 10 {
                table.push(BuiltinMacros.MAC_OS_X_VERSION_MAJOR, literal: majorStr + minorStr + "00")
                table.push(BuiltinMacros.MAC_OS_X_VERSION_MINOR, literal: minorStr + updateStr)
            } else {
                table.push(BuiltinMacros.MAC_OS_X_VERSION_MAJOR, literal: majorStr + "0000")
                table.push(BuiltinMacros.MAC_OS_X_VERSION_MINOR, literal: majorStr + minorStr + "00")
            }
            table.push(BuiltinMacros.MAC_OS_X_VERSION_ACTUAL, literal: majorStr + minorStr + updateStr)
            table.push(BuiltinMacros.MAC_OS_X_PRODUCT_BUILD_VERSION, literal: systemInfo.productBuildVersion)
        }

        #if !RC_PLAYGROUNDS
        // Xcode version settings.
        let xcodeMajorStr = (core.xcodeVersion[0] * 100).toString(format: "%04d")
        let xcodeMinorStr = (core.xcodeVersion[0] * 100 + core.xcodeVersion[1] * 10).toString(format: "%04d")
        let xcodeActualStr = (core.xcodeVersion[0] * 100 + core.xcodeVersion[1] * 10 + core.xcodeVersion[2]).toString(format: "%04d")
        table.push(BuiltinMacros.XCODE_VERSION_MAJOR, literal: xcodeMajorStr)
        table.push(BuiltinMacros.XCODE_VERSION_MINOR, literal: xcodeMinorStr)
        table.push(BuiltinMacros.XCODE_VERSION_ACTUAL, literal: xcodeActualStr)
        table.push(BuiltinMacros.XCODE_PRODUCT_BUILD_VERSION, literal: core.xcodeProductBuildVersionString)
        #endif

        // Backward compatibility settings.
        table.push(BuiltinMacros.BUILD_STYLE, Static { BuiltinMacros.namespace.parseString("$(CONFIGURATION)") })
        table.push(BuiltinMacros.PROJECT, Static { BuiltinMacros.namespace.parseString("$(PROJECT_NAME)") })
        table.push(BuiltinMacros.TEMP_DIR, Static { BuiltinMacros.namespace.parseString("$(TARGET_TEMP_DIR)") })

        return table
    }

    func addDynamicDefaultSettings(_ specLookupContext: any SpecLookupContext, _ boundSettings: BoundProperties.BoundSettings, _ sdk: SDK?) {
        guard let standardTarget = target as? StandardTarget else { return }

        let scope = createScope(sdkToUse: sdk)
        // FIXME: It is unfortunate that we need to create a custom file path resolver just for this case. See the similar comment for adding project settings.
        let filePathResolver = FilePathResolver(scope: scope, projectDir: self.project?.sourceRoot ?? Path("/"))
        if standardTarget.linksAnyFramework(names: ["XCTest", "StoreKitTest", "Testing"], in: scope, workspaceContext: workspaceContext, specLookupContext: specLookupContext, boundSettings: boundSettings.stringListDeclarations, filePathResolver: filePathResolver) {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.ENABLE_TESTING_SEARCH_PATHS, literal: true)
            push(table, .exported)
        }
    }

    func addTargetProductSettings(_ genericTarget: Target, _ specLookupContext: any SpecLookupContext) {
        // If this is not a standard target, it has no specific product or package.
        guard let target = genericTarget as? StandardTarget else { return }

        // We still perform the lookup - in the default domain - even if we don't have a platform, so that clients (such as indexing) which want a product type even in that case can have one if one is available.  But since the default domain isn't a platform we don't report the domain in the error if we can't find one.
        let platformErrorSuffix = specLookupContext.platform.map({ platform in " for platform '\(platform.displayName)'" }) ?? ""

        if let productType = specLookupContext.getSpec(target.productTypeIdentifier) as? ProductTypeSpec {
            // Check for a deprecated product type.
            if let deprecationInfo = productType.deprecationInfo {
                let base = "deprecated product type '\(target.productTypeIdentifier)'\(platformErrorSuffix)."

                switch deprecationInfo.level {
                case .warning: self.warnings.append("\(base) \(deprecationInfo.reason)")
                case .error: self.errors.append("\(base) \(deprecationInfo.reason)")
                }
            }

            if let packageType = specLookupContext.getSpec(productType.defaultPackageTypeIdentifier) as? PackageTypeSpec {
                push(packageType.buildSettings, .exportedForNative)

                // Save the bound package type.
                self.packageType = packageType
            } else {
                self.errors.append("unable to resolve package type '\(productType.defaultPackageTypeIdentifier)'\(platformErrorSuffix)")
            }

            push(productType.buildSettings, .exportedForNative)

            @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
                core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
            }

            for settingsExtension in settingsExtensions() {
                push(createTableFromUserSettings(settingsExtension.addProductTypeDefaults(productType: productType)), .exportedForNative)
            }

            // Save the bound product type.
            self.productType = productType
        } else {
            self.errors.append("unable to resolve product type '\(target.productTypeIdentifier)'\(platformErrorSuffix)")
        }
    }

    /// Add the regular target settings.
    func addTargetSettings(_ target: Target, _ specLookupContext: any SpecLookupContext, _ config: BuildConfiguration, _ sdk: SDK?, usesAutomaticSDK: Bool = false) {
        // Add the target-level dynamic settings.  These are overridden by the target's xcconfig's settings, and then by the target's own settings.
        push(getTargetDynamicSettings(target, config, sdk), .exported)

        // Add the target's base .xcconfig settings, if used.
        if let configFileRef = config.baseConfigurationFileReference(workspaceContext.workspace) {
            // Resolve the path.
            //
            // FIXME: It is unfortunate that we need to create a custom file path resolver just for this case. See the similar comment for adding project settings.
            let resolver = FilePathResolver(scope: createScope(sdkToUse: sdk))
            let path = resolver.resolveAbsolutePath(configFileRef)
            macroConfigPaths.append(path)

            // Load and push a settings table from the file.
            let info = buildRequestContext.getCachedMacroConfigFile(path, project: project, context: .baseConfiguration)
            if let sdk = sdk, settingsContext.purpose.bindToSDK {
                bindConditionParameters(info.table, sdk)
            }
            else {
                // No bound SDK, so push the target xcconfig's build settings unmodified.
                push(info.table, .exported)
            }
            self.targetDiagnostics.append(contentsOf: info.diagnostics)
            for path in info.dependencyPaths {
                macroConfigPaths.append(path)
            }

            // Save the settings table as part of the construction components.
            self.targetXcconfigPath = path
            self.targetXcconfigSettings = info.table

            // Save the table we've constructed so far.
            self.upToTargetXcconfigSettings = MacroValueAssignmentTable(copying: _table)
        }

        // Add the targets's config settings.
        //
        // FIXME: Cache this table, but we can only do that once we share the namespace.
        if let sdk, settingsContext.purpose.bindToSDK {
            bindConditionParameters(config.buildSettings, sdk)
        }
        else {
            // No bound SDK, so push the target's build settings unmodified.
            push(config.buildSettings, .exported)
        }

        addSpecializationOverrides(sdk: sdk, usesAutomaticSDK: usesAutomaticSDK)

        if let target = target as? StandardTarget, target.buildPhases.compactMap({ $0 as? ShellScriptBuildPhase }).contains(where: { $0.sandboxingOverride == .forceDisabled }), createScope(sdkToUse: nil).evaluate(BuiltinMacros.ENABLE_USER_SCRIPT_SANDBOXING) {
            // If at least one shell script phase in the target opts out of sandboxing, opt the target out of eager compilation behavior.
            self.targetDiagnostics.append(.init(behavior: .note, location: .unknown, data: .init("A script phase disables sandboxing, forcing `EAGER_COMPILATION_ALLOW_SCRIPTS` to off")))
            pushTable(.exported) {
                $0.push(BuiltinMacros.EAGER_COMPILATION_ALLOW_SCRIPTS, literal: false)
            }
        }

        // Save the settings table as part of the construction components.
        self.targetSettings = config.buildSettings

        // Also save the table we've constructed so far.
        self.upToTargetSettings = MacroValueAssignmentTable(copying: _table)
    }

    func addSpecializationOverrides(sdk: SDK?, usesAutomaticSDK: Bool) {
        let scope = createScope(sdkToUse: sdk)
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        if Settings.targetPlatformSpecializationEnabled(scope: scope) {
            // The SDK might not be known yet during the push of the target settings (especially true for top-level targets), but the usage of a suffixed SDK might be known from the macro scope. This is a side-effect of the multiple calls to `addTargetSettings()` we make during settings construction...
            // The `SPECIALIZATION_SDK_OPTIONS` needs to be set here, primarily so that top-level targets are handled correctly when they are specialized. Otherwise, the original intent of the SDK choice can be lost due to how the `SDKROOT` is imposed.
            if let suffix = sdk?.canonicalNameSuffix?.nilIfEmpty ?? (try? SDK.parseSDKName(scope.evaluate(BuiltinMacros.SDKROOT).str, pluginManager: core.pluginManager).suffix) {
                table.push(BuiltinMacros.SPECIALIZATION_SDK_OPTIONS, literal: [suffix])
            }
        }

        if usesAutomaticSDK {
            table.push(BuiltinMacros.ALLOW_TARGET_PLATFORM_SPECIALIZATION, literal: true)
        }

        push(table)
    }

    /// Add the various overriding settings.
    func addOverrides(sdk: SDK?) {
        push(getWorkspacePathOverrides(), .none)

        // Add the overriding build settings.
        push(createTableFromUserSettings(parameters.overrides), .exported)

        // Add overrides from places other than the build parameters.
        pushTable(.exported) { table in
            table.push(BuiltinMacros.CLANG_MODULES_BUILD_SESSION_FILE, table.namespace.parseString(workspaceContext.getModuleSessionFilePath(parameters).str))
        }

        // Add the command line build settings.
        push(createTableFromUserSettings(parameters.commandLineOverrides), .exported)

        // Add in command line build settings from extensions

        @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
        }

        for settingsExtension in settingsExtensions() {
            // FIXME: We should do something better here if the environment cannot be retrieved
            let baseEnvironment = workspaceContext.userInfo?.buildSystemEnvironment ?? [:]

            do {
                let additionalOverrides = try settingsExtension.addOverrides(fromEnvironment: baseEnvironment, parameters: parameters)

                push(createTableFromUserSettings(additionalOverrides), .exported)
            } catch {
                self.errors.append("unable to retrieve additional build property overrides")
            }

            // We have no path for the file contents. For now just pass in nil. This means that included files with relative paths will not be found.
            push(buildRequestContext.loadSettingsFromConfig(data: settingsExtension.xcconfigOverrideData(fromParameters: self.parameters), path: nil, namespace: workspaceContext.workspace.userNamespace, searchPaths: project.map { [$0.sourceRoot] } ?? []).table, .exported)
        }

        // Add the command line xcconfig-based build settings.
        if let path = parameters.commandLineConfigOverridesPath {
            let info = buildRequestContext.getCachedMacroConfigFile(path, project: project, context: .commandLineConfiguration)
            push(info.table, .exported)
            self.diagnostics.append(contentsOf: info.diagnostics)
        } else {
            push(createTableFromUserSettings(parameters.commandLineConfigOverrides), .exported)
        }

        // Add the environment xcconfig-based build settings.
        if let path = parameters.environmentConfigOverridesPath {
            let info = buildRequestContext.getCachedMacroConfigFile(path, project: project, context: .environmentConfiguration)
            push(info.table, .exported)
            self.diagnostics.append(contentsOf: info.diagnostics)
        } else {
            push(createTableFromUserSettings(parameters.environmentConfigOverrides), .exported)
        }

        // Toolchain override
        if let toolchain = self.parameters.toolchainOverride {
            let toolchainName = core.toolchainRegistry.lookup(toolchain)?.displayName ?? toolchain
            self.notes.append("Using global toolchain override '\(toolchainName)'.")
            pushTable(.exported) { table in
                table.push(BuiltinMacros.TOOLCHAINS, userNamespace.parseStringList([toolchain, "$(inherited)"]))
            }
        }

        addDevelopmentAssets()

        addPreviewsOverrides(sdk: sdk)

        // Ignore BUILD_LIBRARY_FOR_DISTRIBUTION for tool targets as this is only supported for libraries.
        // This allows the setting to be set at a project level and inherited by all targets.
        do {
            let scope = createScope(sdkToUse: sdk)
            if scope.evaluate(BuiltinMacros.BUILD_LIBRARY_FOR_DISTRIBUTION) && productType?.conformsTo(identifier: "com.apple.product-type.tool") == true {
                pushTable(.exported) { table in
                    table.push(BuiltinMacros.BUILD_LIBRARY_FOR_DISTRIBUTION, literal: false)
                }
            }
        }

        // Push any override settings from the toolchain definition. These should the last things pushed as these should *always* be in effect when using any given toolchain.
        let toolchainIdentifier = self.parameters.toolchainOverride ?? "default"
        if let toolchain = core.toolchainRegistry.lookup(toolchainIdentifier), !toolchain.overrideSettings.isEmpty {
            do {
                push(try userNamespace.parseTable(toolchain.overrideSettings, allowUserDefined: true), .exported)
            }
            catch {
                self.errors.append("unable to create override build settings table from toolchain `\(toolchainIdentifier)`")
            }
        }
    }

    func addDevelopmentAssets() {
        let scope = createScope(sdkToUse: nil)

        // add development resources to excluded file names
        let shouldExcludeDevelopmentAssets = parameters.action.isInstallAction || scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING)
        if shouldExcludeDevelopmentAssets {
            var developmentAssetsPathsToExclude: [String] = []
            for developmentAssetsPath in scope.evaluate(BuiltinMacros.DEVELOPMENT_ASSET_PATHS) {
                // each path could either be a directory or a file path and needs to exist on the filesystem
                let projectDir = scope.evaluate(BuiltinMacros.PROJECT_DIR)
                let absolutePath = projectDir.join(developmentAssetsPath)

                // TODO: 50493364 (Development Resources: Check for accidentally added files)
                if workspaceContext.fs.isDirectory(absolutePath) {
                    developmentAssetsPathsToExclude.append(absolutePath.join("*").str)
                } else {
                    developmentAssetsPathsToExclude.append(absolutePath.str)
                }
            }

            guard !developmentAssetsPathsToExclude.isEmpty else { return }

            pushTable(.exported) { table in
                let newValue = table.namespace.parseStringList(["$(inherited)"] + developmentAssetsPathsToExclude)
                table.push(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES, newValue)
            }
        }
    }

    enum PreviewDisablingReason: CustomStringConvertible {
        case swiftNotEnabled
        case swiftOptimizationLevel(String)
        case action(action: BuildAction)

        var shouldLog: Bool {
            switch self {
            case .swiftNotEnabled, .action, .swiftOptimizationLevel:
                false
            }
        }

        var description: String {
            switch self {
            case .swiftNotEnabled:
                return "Swift not enabled."
            case .swiftOptimizationLevel(let optLevel):
                return "\(BuiltinMacros.SWIFT_VERSION.name) is set and \(BuiltinMacros.SWIFT_OPTIMIZATION_LEVEL.name)=\(optLevel), expected -Onone"
            case .action(let action):
                return "\(BuiltinMacros.ACTION.name)=\(action.actionName)"
            }
        }
    }

    // These are checks that disable previews even if a user manually enabled it in their xcconfig/project/target
    func shouldDisablePreviewsWithReason() -> PreviewDisablingReason? {
        let scope = createScope(sdkToUse: nil)

        guard !scope.evaluate(BuiltinMacros.SWIFT_VERSION).isEmpty else {
            return .swiftNotEnabled
        }

        // Users should be able to enable previews without conditionalizing on their debug configuration
        let optLevel = scope.evaluate(BuiltinMacros.SWIFT_OPTIMIZATION_LEVEL)
        guard optLevel == "-Onone" else {
            return .swiftOptimizationLevel(optLevel)
        }

        // Archiving should disable previews
        guard parameters.action == .build else { return .action(action: parameters.action) }

        return nil
    }

    func addPreviewsOverrides(sdk: SDK?) {
        // Skip this entirely if we're constructing settings for the workspace object, which has no context of a specific target. This will prevent emitting a confusing "Disabling previews because ..." error message even though previews isn't being disabled for any specific target.
        if target == nil {
            return
        }

        let scope = createScope(sdkToUse: sdk)

        guard let previewStyle = scope.previewStyle else {
            return
        }

        if let reason = shouldDisablePreviewsWithReason() {
            if reason.shouldLog {
                let message = "Disabling previews because \(reason)"
                if !notes.contains(message) {
                    notes.append(message)
                }
            }

            pushTable(.exported) { table in
                table.push(BuiltinMacros.ENABLE_PREVIEWS, literal: false)
                table.push(BuiltinMacros.ENABLE_XOJIT_PREVIEWS, literal: false)
                table.push(BuiltinMacros.ENABLE_DEBUG_DYLIB, literal: false)
            }

            return
        }

        let isExecutableProduct = scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_execute"

        // Previews are on, so what follows are adjustments we need to make to support previews

        // <rdar://59605442> Xcode preview app crashes when Thread Sanitizer is enabled
        // rdar://59606050 tracks re-enabling TSan.
        switch previewStyle {
        case .dynamicReplacement:
            pushTable(.exported) { table in
                table.push(BuiltinMacros.ENABLE_THREAD_SANITIZER, literal: false)
            }

            if isExecutableProduct {
                // Enables thunks to use C symbols in mixed C/ObjC/Swift targets
                pushTable(.exported) { table in
                    table.push(BuiltinMacros.GCC_SYMBOLS_PRIVATE_EXTERN, literal: false)
                    table.push(BuiltinMacros.LD_EXPORT_GLOBAL_SYMBOLS, literal: true)
                    table.push(BuiltinMacros.STRIP_INSTALLED_PRODUCT, literal: false)
                }
            }
        case .xojit:
            let targetRequiresPreviewsDylib: Bool = {
                // Only executable targets should be considered for adding the previews dylib.
                guard isExecutableProduct else {
                    return false
                }

                // Oblige targets that have requested to opt-out of the dylib mode.
                guard scope.evaluate(BuiltinMacros.ENABLE_DEBUG_DYLIB) else {
                    return false
                }

                // If this internal setting is YES, then we will skip the platform check and assume
                // the target wants to use the previews dylib. This is going to be used to work on
                // bringing up support for the commented out platforms below.
                if scope.evaluate(BuiltinMacros.ENABLE_DEBUG_DYLIB_OVERRIDE) || scope.evaluate(BuiltinMacros.ENABLE_PREVIEWS_DYLIB_OVERRIDE) {
                    return true
                }

                let platformName = scope.evaluate(BuiltinMacros.PLATFORM_NAME)
                switch platformName {
                case "iphoneos",
                    "iphonesimulator",
                    "appletvos",
                    "appletvsimulator",
                    "watchos",
                    "watchsimulator",
                    "xros",
                    "xrsimulator",
                    "macosx":
                    break
                default:
                    return false
                }

                @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
                    core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
                }

                for settingsExtension in settingsExtensions() {
                    if settingsExtension.shouldDisableXOJITPreviews(platformName: platformName, sdk: sdk) {
                        return false
                    }
                }

                // If we've reached this point, we've cross the gauntlet and we should use previews dylib mode!
                return true
            }()

            if targetRequiresPreviewsDylib {
                pushTable(.exported) { table in
                    // The debug dylib has a stable path relative to the executable. It is the
                    // executable name with a `.debug.dylib` suffix. Some built-in tooling depends on
                    // this in Xcode 16.
                    table.push(
                        BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH,
                        table.namespace.parseString("$(EXECUTABLE_PATH:dir)$(EXECUTABLE_NAME).debug.dylib")
                    )
                    if let clientName = scope.evaluate(BuiltinMacros.LD_CLIENT_NAME).nilIfEmpty {
                        // rdar://127733311 (Use stable debug dylib name when `LD_CLIENT_NAME` is specified on the executable target)
                        //
                        // If `LD_CLIENT_NAME` is used for the target, then it is expected to satisfy an
                        // `-allowable_client` requirement. Dylibs cannot have a `-client_name` and the
                        // install name is used to check if the link is allowed. We can set the install
                        // name to have the client name to satisfy this requirement. But then the path on
                        // disk of the debug dylib must also be named the same or it cannot be found at
                        // runtime during linker loading.
                        //
                        // We can work around this by computing a "mapped install name" that gets set in an
                        // `$ld$previous` symbol to communicate to the linker that we have a dylib at a
                        // specific install name path but the internal install name will be something else.
                        //
                        // The net result is the linker writes the actual path into the load command of the
                        // stub executor so it can be found at runtime, but the debug dylib has an actual
                        // identity as the specified client name. It therefore can successfully link against
                        // libraries with allowable client restrictions of the same name.
                        table.push(
                            BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME,
                            table.namespace.parseString("@rpath/\(clientName).debug.dylib")
                        )
                        table.push(
                            BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_MAPPED_INSTALL_NAME,
                            table.namespace.parseString("@rpath/$(EXECUTABLE_NAME).debug.dylib")
                        )

                        let sdkVariant = sdk?.variant(for: scope.evaluate(BuiltinMacros.SDK_VARIANT))
                        let platform = sdk?.targetBuildVersionPlatform(sdkVariant: sdkVariant)

                        // Platform version identifiers used in `$ld$previous` mappings.
                        // Unknown values are specified with `0`.
                        let appleLDPreviousPlatform = platform?.rawValue ?? 0

                        table.push(
                            BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_MAPPED_PLATFORM,
                            table.namespace.parseLiteralString("\(appleLDPreviousPlatform)")
                        )
                    }
                    else {
                        table.push(
                            BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME,
                            table.namespace.parseString("@rpath/$(EXECUTABLE_NAME).debug.dylib")
                        )
                    }
                    table.push(
                        BuiltinMacros.EXECUTABLE_BLANK_INJECTION_DYLIB_PATH,
                        table.namespace.parseString("$(EXECUTABLE_PATH:dir)__preview.dylib")
                    )
                }
            }
        }

        if isExecutableProduct,
           scope.evaluate(BuiltinMacros.ENABLE_HARDENED_RUNTIME),
           // Check for ad-hoc
           scope.evaluate(BuiltinMacros.CODE_SIGN_IDENTITY) == "-"
        {
            // Hardened runtime was enabled with ad-hoc codesigning. This is not compatible
            // with debug dylib mode so we'll ignore it and emit a note.
            pushTable(.exported) { table in
                table.push(BuiltinMacros.ENABLE_HARDENED_RUNTIME, literal: false)
            }

            let message = "Disabling hardened runtime with ad-hoc codesigning."
            if !notes.contains(message) {
                notes.append(message)
            }
        }
    }

    static func targetSupportedPlatforms(scope: MacroEvaluationScope, core: Core, runDestinationPlatform: Platform, emitWarning: (String) -> Void = { _ in }) -> [Platform] {
        let targetSupportedPlatforms = scope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS).compactMap{ core.platformRegistry.lookup(name: $0) }

        // Warn if we couldn't find a supported platform for the given list.
        if targetSupportedPlatforms.isEmpty {
            emitWarning("Did not find any platform for SUPPORTED_PLATFORMS '\(scope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS).joined(separator: ", "))'")
        }

        return targetSupportedPlatforms
    }

    func addRunDestinationSettingsPlatformSDK() {
        // ignore run destination if requested
        guard !UserDefaults.skipRunDestinationOverride else { return }

        // If the target supports specialization and it already has an SDK, then we need to use that instead of attempting to override the SDK with the run destination information. This is very important in scenarios where the destination is Mac Catalyst, but the target is building for iphoneos. The target will be re-configured for macosx/iosmac.
        do {
            let scope = createScope(sdkToUse: nil)
            let sdk = try sdkRegistry.lookup(scope.evaluate(BuiltinMacros.SDKROOT).str, activeRunDestination: nil)
            if Settings.targetPlatformSpecializationEnabled(scope: scope) && sdk != nil {
                return
            }
        } catch { /* fallthrough */ }

        // Destination info: since runDestination.{platform,sdk} were set by the IDE, we expect them to resolve in Swift Build correctly
        guard let runDestination = self.parameters.activeRunDestination else { return }
        guard let destinationPlatform: Platform = self.core.platformRegistry.lookup(name: runDestination.platform) else {
            self.errors.append("unable to resolve run destination platform: '\(runDestination.platform)'")
            return
        }
        let destinationSDK: SDK
        do {
            guard let sdk = try sdkRegistry.lookup(runDestination.sdk, activeRunDestination: runDestination) else {
                self.errors.append("unable to resolve run destination SDK: '\(runDestination.sdk)'")
                return
            }
            destinationSDK = sdk
        } catch let error as AmbiguousSDKLookupError {
            self.diagnostics.append(error.diagnostic)
            return
        } catch {
            self.errors.append("\(error)")
            return
        }

        let destinationPlatformIsMacOS = destinationPlatform.name == "macosx"
        let destinationPlatformIsLinux = destinationPlatform.name == "linux"
        let destinationPlatformIsDevice = destinationPlatform.correspondingSimulatorPlatformName != nil && !destinationPlatformIsMacOS
        let destinationPlatformIsDeviceOrSimulator = destinationPlatformIsDevice || destinationPlatform.isSimulator

        // Target info
        guard self.target != nil else { return }

        do {
            let scope = createScope(sdkToUse: nil)
            let destinationIsMacCatalyst = runDestination.sdkVariant == MacCatalystInfo.sdkVariantName
            let supportsMacCatalyst = Settings.supportsMacCatalyst(scope: scope, core: core)
            if destinationIsMacCatalyst && supportsMacCatalyst {
                pushTable(.exported) {
                    $0.push(BuiltinMacros.SUPPORTED_PLATFORMS, BuiltinMacros.namespace.parseStringList(["$(inherited)", "macosx"]))
                    $0.push(BuiltinMacros.SDK_VARIANT, literal: MacCatalystInfo.sdkVariantName)
                }
            }
        }

        let scope = createScope(sdkToUse: nil)
        guard let project, let targetSDK = try? sdkRegistry.lookup(nameOrPath: scope.evaluate(BuiltinMacros.SDKROOT).str, basePath: project.sourceRoot, activeRunDestination: parameters.activeRunDestination) else {
            return
        }
        let targetPlatform = core.platformRegistry.lookup(name: scope.evaluate(BuiltinMacros.PLATFORM_NAME))
        let targetSupportedPlatforms = SettingsBuilder.targetSupportedPlatforms(scope: scope, core: core, runDestinationPlatform: destinationPlatform) { warning in
            self.warnings.append(warning)
        }

        // Determine if the target supports the destination platform and, if so, what SDK to use for it (if there should even be an override SDK supplied).

        var requiredSDKCanonicalName: String? = nil
        let targetSupportsDestinationPlatform = targetSupportedPlatforms.contains { $0 === destinationPlatform }

        func getLatestSDKCanonicalName(for platform: Platform) -> String? {
            guard let canonicalBaseName = platform.sdkCanonicalName else {
                return nil
            }
            let suffix = targetSDK.canonicalNameSuffix?.nilIfEmpty
            if let suffix {
                return "\(canonicalBaseName).\(suffix)"
            } else {
                return canonicalBaseName
            }
        }

        if targetSupportsDestinationPlatform {
            if destinationPlatformIsDevice, targetPlatform == nil || targetPlatform === destinationPlatform {
                // iOS: If the target specifies an SDK for the destination platform, always override the SDK to be the one from the active run destination.
                if let targetSuffix = targetSDK.canonicalNameSuffix?.nilIfEmpty, destinationSDK.canonicalNameSuffix?.nilIfEmpty == nil {
                    requiredSDKCanonicalName = "\(destinationSDK.canonicalName).\(targetSuffix)"
                } else {
                    requiredSDKCanonicalName = destinationSDK.canonicalName
                }
            }
            else if destinationPlatform.isSimulator, targetPlatform == nil || (targetPlatform !== destinationPlatform && targetPlatform?.familyName == destinationPlatform.familyName) {
                // Simulator: If the target specifies an SDK for a platform in the destination platform family, use the equivalent SDK for the destination platform.  For example, if the target specifies iphoneos4.2 as its SDK, use iphonesimulator4.2 if such an SDK exists.
                let targetSuffix = targetSDK.canonicalNameSuffix?.nilIfEmpty.map { ".\($0)" } ?? ""
                let candidates: [String] = [
                    "\(destinationPlatform.name)\(targetSDK.version?.description ?? "")\(targetSuffix)",
                    "\(destinationPlatform.name)\(targetSDK.version?.description ?? "")",
                    "\(destinationPlatform.name)\(targetSuffix)",
                    destinationPlatform.name,
                ]

                let resolvedCandidates = candidates.map { ($0, try? sdkRegistry.lookup($0, activeRunDestination: runDestination)?.canonicalName) }

                requiredSDKCanonicalName = resolvedCandidates.compactMap { $0.1 }.first
            }
            else if (destinationPlatformIsMacOS || destinationPlatformIsLinux || destinationPlatform.isSimulator) && targetPlatform === destinationPlatform {
                // If the target specifies an SDK for the destination platform, don't override its choice of SDK.
            }
            else {
                // The target specifies an SDK not for the destination platform, but claims to support the destination platform.
                requiredSDKCanonicalName = getLatestSDKCanonicalName(for: destinationPlatform)
            }
        }
        else if destinationPlatformIsDeviceOrSimulator {
            // For multiplatform builds, we want to ensure consistency between simulator- vs non-simulator environments, so if this target supports a platform that matches the simulator-ness of the destination platform, then use it.
            let isDeployment = destinationPlatform.isDeploymentPlatform

            if let supportedPlatform = (targetSupportedPlatforms.first { isDeployment == $0.isDeploymentPlatform }) {
                requiredSDKCanonicalName = getLatestSDKCanonicalName(for: supportedPlatform)
            }
        }

        guard let newSDKCanonicalName = requiredSDKCanonicalName else { return }

        // If pushing a new SDKROOT wouldn't change what the target is already configured with, don't bother.
        // Also check aliases, which is important for DriverKit suffixed SDKs so that we don't reset a platform
        // specific DriverKit suffixed SDK to the platform-neutral DriverKit suffixed SDK ("driverkit.foo")
        // making the concrete SDK resolution ambiguous again. Thus without considering aliases, we could end up
        // changing the SDKROOT of a target configured with driverkit.macosx.foo back to driverkit.foo,
        // and if the run destination were NOT macOS, we could end up changing the platform-ness of the SDK.
        guard newSDKCanonicalName != targetSDK.canonicalName && !targetSDK.aliases.contains(newSDKCanonicalName) else {
            return
        }

        pushTable(.exported) { $0.push(BuiltinMacros.SDKROOT, literal: newSDKCanonicalName) }
    }

    /// Add architecture overrides from the active run destination.
    func addRunDestinationSettingsArchitectures(_ sdk: SDK?) {
        // ignore run destination if requested
        guard !UserDefaults.skipRunDestinationOverride else { return }

        // Destination info: since runDestination.{platform,sdk} were set by the IDE, we expect them to resolve in Swift Build correctly
        guard let runDestination = self.parameters.activeRunDestination else { return }
        guard let destinationPlatform: Platform = self.core.platformRegistry.lookup(name: runDestination.platform) else {
            self.errors.append("unable to resolve run destination platform: '\(runDestination.platform)'")
            return
        }

        // Target info
        guard self.target != nil else { return }
        let scope = createScope(sdkToUse: sdk)
        let targetSupportedPlatforms = SettingsBuilder.targetSupportedPlatforms(scope: scope, core: core, runDestinationPlatform: destinationPlatform)
        let targetSupportsDestinationPlatform: Bool = targetSupportedPlatforms.contains { $0 === destinationPlatform }

        if !targetSupportsDestinationPlatform || runDestination.disableOnlyActiveArch {
            pushTable(.exported) { $0.push(BuiltinMacros.ONLY_ACTIVE_ARCH, literal: false) }
        }

        pushHostTargetPlatformSettingsIfNeeded(for: runDestination, to: scope)
    }

    func pushHostTargetPlatformSettingsIfNeeded(for runDestination: RunDestinationInfo, to scope: MacroEvaluationScope) {
        if let hostTargetedPlatform = runDestination.hostTargetedPlatform,
           scope.evaluate(BuiltinMacros.SUPPORTED_HOST_TARGETED_PLATFORMS).contains(hostTargetedPlatform) {
            pushTable(.exported) { $0.push(BuiltinMacros.HOST_TARGETED_PLATFORM_NAME, literal: hostTargetedPlatform) }
        }
    }

    /// Compute the bound signing settings.
    func computeSigningSettings(_ specLookupContext: any SpecLookupContext, _ inputs: ProvisioningTaskInputs, _ sdk: SDK?) {
        assert(self.signingSettings == nil)

        // Exit early
        guard let platform = specLookupContext.platform else { return }
        guard let sdk else { return }
        guard let target = self.target else { return }
        guard let productType = self.productType else { return }

        let scope = createScope(sdkToUse: sdk)

        assert(!scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).isEmpty)
        assert(!scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).isEmpty)
        assert(!scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).isEmpty)

        guard scope.evaluate(BuiltinMacros.CODE_SIGNING_ALLOWED) else { return }
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

        // ProvisioningTaskInputs issues
        do {
            // FIXME: These diagnostics come from the signing and provisioning subsystem. We should attach only the specific appropriate build setting(s) to each diagnostic, but we don't get that data alongside the diagnostic messages. For now, just add all of them, which will do what we want: make the click action navigate to the signing editor in the UI.
            let signingDiagnosticsLocation = Diagnostic.Location.buildSettings([
                BuiltinMacros.CODE_SIGN_IDENTITY,
                BuiltinMacros.CODE_SIGN_STYLE,
                BuiltinMacros.DEVELOPMENT_TEAM,
                BuiltinMacros.ENABLE_APP_SANDBOX,
                BuiltinMacros.ENABLE_HARDENED_RUNTIME,
                BuiltinMacros.PROVISIONING_PROFILE_SPECIFIER,
            ])

            targetDiagnostics.append(contentsOf: inputs.warnings.map {
                Diagnostic(behavior: .warning, location: signingDiagnosticsLocation, data: DiagnosticData($0))
            })

            let errors = inputs.errors.map { error -> String in
                var errorString = error.description
                if let recoverySuggestion = error.recoverySuggestion, !recoverySuggestion.isEmpty {
                    if !errorString.hasSuffix(".") {
                        errorString += ":"
                    }
                    errorString += " \(recoverySuggestion)"
                }

                return errorString
            }

            targetDiagnostics.append(contentsOf: errors.map {
                Diagnostic(behavior: UserDefaults.disableSigningProvisioningErrors ? .warning : .error, location: signingDiagnosticsLocation, data: DiagnosticData($0))
            })

            if !errors.isEmpty {
                return
            }
        }

        // Some of our unit test infrastructure seems to rely on this behavior as well instead of passing in full profile information.
        let codeSignEntitlements = scope.evaluate(BuiltinMacros.CODE_SIGN_ENTITLEMENTS)
        let codeSignEntitlementsContents = scope.evaluate(BuiltinMacros.CODE_SIGN_ENTITLEMENTS_CONTENTS)

        let product = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME))

        // Provisioning profile
        let profile: Settings.SigningSettings.Profile? = {
            // Get the path to the profile file from the provisioning task inputs.
            guard let profileInputPath = inputs.profilePath else { return nil }

            guard let project else { return nil }

            let defaultWorkingDirectory = project.xcodeprojPath.dirname
            guard let profileOutputPath = scope.evaluate(BuiltinMacros.EMBEDDED_PROFILE_NAME).nilIfEmpty.flatMap({ defaultWorkingDirectory.join(scope.evaluate(BuiltinMacros.PROVISIONING_PROFILE_DESTINATION_PATH)).join($0) }) else { return nil }

            return Settings.SigningSettings.Profile(input: profileInputPath, output: profileOutputPath)
        }()

        // Identity
        let identity: Settings.SigningSettings.Identity = {
            var identityHash = inputs.identityHash ?? ""
            var identityName = inputs.identityName ?? ""

            let fileType = specLookupContext.lookupFileType(fileName: product.basename) ?? specLookupContext.lookupFileType(identifier: "file")!
            let platformRequiresEntitlements = platform.signingContext.requiresEntitlements(scope, hasProfile: profile != nil, productFileType: fileType)

            // If we have entitlements, but signing is disabled, then warn and fall back to ad hoc signing
            if !inputs.signedEntitlements.isEmpty && identityHash.isEmpty {
                if platform.signingContext.useAdHocSigningIfSigningIsRequiredButNotSpecified(scope) {
                    identityHash = "-"
                    identityName = "Ad Hoc"

                    warnings.append("\(target.name) isn't code signed but requires entitlements. Falling back to ad hoc signing.")
                }
                else if !platformRequiresEntitlements {
                    // Warn the user when code signing is disabled, is not required, but they are specifying entitlements that cannot be used without code signing.
                    warnings.append("\(target.name) isn't code signed but requires entitlements. It is not possible to add entitlements to a binary without signing it.")
                }
            }

            // If ad hoc signing is specified but not allowed, emit an error
            if identityHash == "-" && !platform.signingContext.adHocSigningAllowed(scope) {
                var adhocSignError = "Ad Hoc code signing is not allowed with SDK '\(sdk.displayName)'."
                if let supplementalMessage = scope.evaluate(BuiltinMacros.__AD_HOC_CODE_SIGNING_NOT_ALLOWED_SUPPLEMENTAL_MESSAGE).nilIfEmpty {
                    adhocSignError += supplementalMessage
                }
                errors.append(adhocSignError)
            }

            if platformRequiresEntitlements {
                // If the platform requires entitlements and we don't have a valid identity, emit an error.
                if identityHash.isEmpty {
                    errors.append("An empty code signing identity is not valid when signing a binary for the '\(productType.name)' product type.")
                }

                // Emit an error if we are missing entitlements since they are required for the platform.
                if inputs.signedEntitlements.isEmpty && codeSignEntitlements.isEmpty && codeSignEntitlementsContents.isEmpty {
                    errors.append("Entitlements are required for product type '\(productType.name)' in SDK '\(sdk.displayName)'.")
                }
            }

            return Settings.SigningSettings.Identity(hash: identityHash, name: identityName)
        }()

        guard !identity.hash.isEmpty else { return }

        // Entitlements
        func computeEntitlementsSetting(entitlements: PropertyListItem, entitlementsVariant: EntitlementsVariant) -> Settings.SigningSettings.Entitlements? {
            // If there are no entitlements but we're dealing with the simulated case, we avoid emitting an empty entitlements file. However, we only do this if `CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION` is turned off, because we still want to create the entitlements task in that case as the modified entitlements may cause the resulting dictionary to be non-empty.
            if entitlements.isEmpty && !scope.evaluate(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION) && entitlementsVariant == .simulated {
                return nil
            }

            // If we have no entitlements and no CODE_SIGN_ENTITLEMENTS setting, also avoid emitting an empty entitlements file.
            if entitlements.isEmpty && codeSignEntitlements.isEmpty && codeSignEntitlementsContents.isEmpty {
                return nil
            }

            // Otherwise we emit an entitlements file (even if it's empty).
            let pathSuffix: String
            switch entitlementsVariant {
            case .signed:
                pathSuffix = ".xcent"
            case .simulated:
                pathSuffix = "-Simulated.xcent"
            }

            let outputDir = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).normalize()
            return Settings.SigningSettings.Entitlements(
                output: outputDir.join(product.basename + pathSuffix),
                outputDer: outputDir.join(product.basename + pathSuffix + ".der")
            )
        }

        let signedEntitlements = computeEntitlementsSetting(entitlements: inputs.entitlements(for: .signed), entitlementsVariant: .signed)
        let simulatedEntitlements = computeEntitlementsSetting(entitlements: inputs.entitlements(for: .simulated), entitlementsVariant: .simulated)

        // Launch constraints
        let launchConstraints: Settings.SigningSettings.LaunchConstraints = {
            let processPath = Path(scope.evaluate(BuiltinMacros.LAUNCH_CONSTRAINT_SELF)).nilIfEmpty
            let parentProcessPath = Path(scope.evaluate(BuiltinMacros.LAUNCH_CONSTRAINT_PARENT)).nilIfEmpty
            let responsibleProcessPath = Path(scope.evaluate(BuiltinMacros.LAUNCH_CONSTRAINT_RESPONSIBLE)).nilIfEmpty

            return Settings.SigningSettings.LaunchConstraints(process: processPath, parentProcess: parentProcessPath, responsibleProcess: responsibleProcessPath)
        }()

        let libraryConstraint = Path(scope.evaluate(BuiltinMacros.LIBRARY_LOAD_CONSTRAINT)).nilIfEmpty

        self.signingSettings = Settings.SigningSettings(inputs: inputs, identity: identity, profile: profile, signedEntitlements: signedEntitlements, simulatedEntitlements: simulatedEntitlements, launchConstraints: launchConstraints, libraryConstraint: libraryConstraint)
    }

    func addSigningOverrides(_ specLookupContext: any SpecLookupContext, _ inputs: ProvisioningTaskInputs, _ sdk: SDK?) {
        computeSigningSettings(specLookupContext, inputs, sdk)
        guard let signingSettings = self.signingSettings else { return }

        // Set the overrides.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY, BuiltinMacros.namespace.parseString(signingSettings.identity.hash))
        table.push(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY_NAME, BuiltinMacros.namespace.parseString(signingSettings.identity.name))
        table.push(BuiltinMacros.EXPANDED_PROVISIONING_PROFILE, literal: inputs.profileUUID ?? "")
        // Nothing in Xcode currently consumes this, but some third party developer workflows do
        // <rdar://problem/26869443> Missing $(AppIdentifierPrefix)
        table.push(BuiltinMacros.AppIdentifierPrefix, BuiltinMacros.namespace.parseString(inputs.appIdentifierPrefix ?? ""))
        table.push(BuiltinMacros.TeamIdentifierPrefix, BuiltinMacros.namespace.parseString(inputs.teamIdentifierPrefix ?? ""))
        table.push(BuiltinMacros.CODE_SIGN_KEYCHAIN, BuiltinMacros.namespace.parseString(inputs.keychainPath ?? ""))

        // Set the linker entitlements section if appropriate.
        if specLookupContext.platform?.isSimulator == true {
            if let path = signingSettings.simulatedEntitlements?.output {
                table.push(BuiltinMacros.LD_ENTITLEMENTS_SECTION, literal: path.str)
            }

            if let path = signingSettings.simulatedEntitlements?.outputDer {
                table.push(BuiltinMacros.LD_ENTITLEMENTS_SECTION_DER, literal: path.str)
            }
        }

        push(table, .exported)
    }

    private func addIndexBuildOverrides(_ variant: SDKVariant?) {
        precondition(parameters.action == .indexBuild)

        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        table.push(BuiltinMacros.INDEX_DIRECTORY_REMAP_VFS_FILE, Static { BuiltinMacros.namespace.parseString("$(OBJROOT)/index-overlay.yaml") })

        if let arena = parameters.arena,
           let productsPath = arena.indexRegularBuildProductsPath,
           let intermediatesPath = arena.indexRegularBuildIntermediatesPath {
            table.push(BuiltinMacros.INDEX_REGULAR_BUILD_PRODUCTS_DIR, BuiltinMacros.namespace.parseString(productsPath.str))
            table.push(BuiltinMacros.INDEX_REGULAR_BUILD_INTERMEDIATES_DIR, BuiltinMacros.namespace.parseString(intermediatesPath.str))
        }

        // Force all targets in the workspace see the same `CONFIGURATION` string, independent of whether they support the requested configuration name or not.
        // `CONFIGURATION` setting is used to form the products build directory and it is important to be uniform to ensure dependencies of targets can be imported even if the configurations they support are not completely aligned.
        // Only overriding `CONFIGURATION_BUILD_DIR` is not sufficient because projects (like CocoaPods) may be using `CONFIGURATION` to form build directory paths, instead of always using `CONFIGURATION_BUILD_DIR`.
        let configName = parameters.configuration ?? "Debug"
        table.push(BuiltinMacros.CONFIGURATION, literal: configName)

        // Disable `-index-store-path`. We are going to be building Swift modules with minimal typechecking (skipping function bodies), so we can't generate index data via module creation.
        table.push(BuiltinMacros.SWIFT_INDEX_STORE_ENABLE, literal: false)
        // Generate Swift modules with a whole-module invocation. It is fast enough, since it is skipping function bodies, and we'll avoid the fragility problems of the `merge-modules` invocation (which is bound to be deprecated in the future).
        table.push(BuiltinMacros.SWIFT_COMPILATION_MODE, literal: "wholemodule")
        // We are not generating native code for the index build so this doesn't affect much, but make it clear to Swift that we don't need any SIL optimizations running.
        table.push(BuiltinMacros.SWIFT_OPTIMIZATION_LEVEL, literal: "-Onone")

        // Ensure the index build uses the effective platform build directories and not install ones.
        // This is to avoid conflicts of outputs of a target configured for multiple platforms, and to avoid using same build directory outputs as a normal build.
        table.push(BuiltinMacros.DEPLOYMENT_LOCATION, literal: false)

        if let variant, variant.isMacCatalyst {
            // Some projects force EFFECTIVE_PLATFORM_NAME to be the same for macOS vs macCatalyst, but they need to be distinct for the index build, otherwise there will be conflicting tasks.
            table.push(BuiltinMacros.EFFECTIVE_PLATFORM_NAME, literal: MacCatalystInfo.publicSDKBuiltProductsDirSuffix)
        }

        table.push(BuiltinMacros.SWIFT_ENABLE_EXPLICIT_MODULES, literal: .disabled)
        table.push(BuiltinMacros._EXPERIMENTAL_SWIFT_EXPLICIT_MODULES, literal: .disabled)
        table.push(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES, literal: false)
        table.push(BuiltinMacros._EXPERIMENTAL_CLANG_EXPLICIT_MODULES, literal: false)

        push(table, .exported)
    }

    /// Add the workspace-related path overrides.
    func getWorkspacePathOverrides() -> MacroValueAssignmentTable {
        // FIXME: Cache this.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        // Compute the derived data path to use.
        var derivedDataPath = parameters.arena?.derivedDataPath
        if derivedDataPath == nil {
            // If we don't have one, fallback on adjacent to the PCH path.
            if let p = parameters.arena?.pchPath {
                derivedDataPath = p.dirname
            } else {
                // Otherwise, use the cache directory.
                derivedDataPath = workspaceContext.workspaceSettings.getCacheRoot()
            }

            // If there is no DerivedData then intentionally remove the MODULE_CACHE_DIR setting (which is defined in terms of it).
            table.push(BuiltinMacros.MODULE_CACHE_DIR, literal: "")
        }

        table.push(BuiltinMacros.DERIVED_DATA_DIR, BuiltinMacros.namespace.parseString(derivedDataPath!.str))
        if let arena = parameters.arena {
            for (macro,path) in [(BuiltinMacros.SYMROOT, arena.buildProductsPath),
                                 (BuiltinMacros.OBJROOT, arena.buildIntermediatesPath),
                                 (BuiltinMacros.SHARED_PRECOMPS_DIR, arena.pchPath),
                                 (BuiltinMacros.INDEX_PRECOMPS_DIR, arena.indexPCHPath)] {
                if !path.isEmpty {
                    table.push(macro, BuiltinMacros.namespace.parseString(path.str))
                }
            }

            if let path = arena.indexDataStoreFolderPath {
                table.push(BuiltinMacros.INDEX_DATA_STORE_DIR, BuiltinMacros.namespace.parseString(path.str))
            }

            if arena.indexEnableDataStore {
                table.push(BuiltinMacros.INDEX_ENABLE_DATA_STORE, literal: true)
            }
        }

        return table
    }

    // FIXME: Figure out a better name and clearer decomposition of these settings.
    //
    /// Add the target task overrides.  Most of these are *not* exported to scripts unless the settings have been marked to be exported elsewhere.
    private func addTargetTaskOverrides(_ target: Target, _ specLookupContext: any SpecLookupContext, _ sparseSDKs: [SDK], _ deploymentTarget: Version?, _ sdk: SDK?) {
        // Add the common overrides (which may effect the target specific ones).
        push(getCommonTargetTaskOverrides(specLookupContext, deploymentTarget, sdk))

        do {
            // Also set each a build setting with the name of each architecture to `YES`.
            // This is much more amenable to composable build setting names than using `ARCHS`.
            var table = MacroValueAssignmentTable(namespace: userNamespace)
            for arch in createScope(sdkToUse: sdk).evaluate(BuiltinMacros.ARCHS) {
                let decl = table.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, arch)
                table.push(decl, table.namespace.parseForMacro(decl, value: "YES"))
            }
            push(table)
        }

        // Add the target-specific overrides.
        push(getTargetTaskOverrides(target, specLookupContext, sparseSDKs, sdk))

        // Add the product specific task overrides.
        push(getProductSpecificTargetTaskOverrides(target, sdk))

        // Add the SDK-specific path overrides.
        //
        // FIXME: This is broken for per-arch SDKROOTs, which we try so hard to support earlier.
        //
        // FIXME: This is gross, aside from just calling it multiple times mostly redundantly, we are also rewriting a build setting which means it doesn't behave exactly as others do w.r.t. subsequent table modifications.
        //
        // FIXME: We push this separately, because it re-modifies the search paths variables set up above in the overrides.
        if target is StandardTarget, let sdk {
            push(getSDKSpecificPathOverrides(sdk, sparseSDKs))
        }
    }

    /// Constrain `ARCHS_STANDARD` based on the platform deployment target.
    private func addStandardArchitecturesOverride(_ specLookupContext: any SpecLookupContext, _ deploymentTarget: Version?, _ sdk: SDK?) {
        let scope = createScope(sdkToUse: sdk)

        // Constrain ARCHS_STANDARD
        let archsStandard = scope.evaluate(BuiltinMacros.ARCHS_STANDARD)
        var archsStandardFiltered = archsStandard.filter { arch in
            guard let spec = specLookupContext.getSpec(arch) as? ArchitectureSpec else { return true }
            guard let range = spec.deploymentTargetRange else { return true }
            guard let deploymentTarget else { return true }
            return range.contains(deploymentTarget)
        }

        // Add potential pointer authenticated versions
        if scope.evaluate(BuiltinMacros.ENABLE_POINTER_AUTHENTICATION), archsStandardFiltered.contains("arm64"), !archsStandardFiltered.contains("arm64e") {
            archsStandardFiltered.append("arm64e")
        }

        if archsStandard != archsStandardFiltered {
            pushTable(.exported) { table in
                table.push(BuiltinMacros.ARCHS_STANDARD, literal: archsStandardFiltered)
            }
        }
    }

    /// Get overriding settings common to all targets (so this method has no target parameter).
    ///
    /// This is called from `addTargetTaskOverrides()`.
    private func getCommonTargetTaskOverrides(_ specLookupContext: any SpecLookupContext, _ deploymentTarget: Version?, _ sdk: SDK?) -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        table.push(BuiltinMacros.ACTION, literal: parameters.action.actionName)
        table.push(BuiltinMacros.BUILD_COMPONENTS, literal: parameters.action.buildComponents)
        if parameters.action.isInstallAction || SWBFeatureFlag.useHierarchicalBuiltProductsDir.value {
            table.push(BuiltinMacros.DEPLOYMENT_LOCATION, literal: true)
        }
        if parameters.action.isInstallAction {
            table.push(BuiltinMacros.DEPLOYMENT_POSTPROCESSING, literal: true)
        }

        // Push a setting which can be used to conditionalize on whether we are building in InstallAPI mode.
        if parameters.action.buildComponents.contains("api") {
            // We expect "api" and "build" to be mutually exclusive.
            assert(!parameters.action.buildComponents.contains("build"))
            table.push(BuiltinMacros.INSTALLAPI_MODE_ENABLED, literal: true)
        }

        // Compute the effective archs.
        let scope = createScope(sdkToUse: sdk)
        let originalArchs = scope.evaluate(BuiltinMacros.ARCHS)
        let rcArchs = scope.evaluate(BuiltinMacros.RC_ARCHS)
        let requestedArchs: [String] = !rcArchs.isEmpty ? rcArchs : originalArchs

        // Compute the valid archs, taking compatibility into account: If an arch is in VALID_ARCHS, then all of its compatibility archs are in VALID_ARCHS.
        //
        // FIXME: This should be efficient, and cached.
        var compatibilityArchMap: [String: [String]] = [:]
        if scope.evaluate(BuiltinMacros.__POPULATE_COMPATIBILITY_ARCH_MAP) {
            for arch in specLookupContext.findSpecs(ArchitectureSpec.self) {
                for compatArch in arch.compatibilityArchs {
                    compatibilityArchMap[compatArch] = (compatibilityArchMap[compatArch] ?? []) + [arch.identifier]
                }
            }
        }
        var validArchs = Set<String>()
        func addValidArch(_ name: String) {
            if !validArchs.contains(name) {
                validArchs.insert(name)
                compatibilityArchMap[name]?.forEach(addValidArch)
            }
        }
        for arch in scope.evaluate(BuiltinMacros.VALID_ARCHS) {
            addValidArch(arch)
        }

        // Get the excluded archs.  Unlike valid archs, we do not use compatibility archs here - if an arch is marked as excluded, its compatibility archs will still be valid unless they are also explicitly added.
        let excludedArchs = scope.evaluate(BuiltinMacros.EXCLUDED_ARCHS)

        // Compute the effective archs, by removing archs *not* in VALID_ARCHS, and removing archs in EXCLUDED_ARCHS.
        // This, with some further processing below, will be used to set ARCHS.
        // Note that we do not respect VALID_ARCHS if ENFORCE_VALID_ARCHS = NO.
        let enforceValidArchs = scope.evaluate(BuiltinMacros.ENFORCE_VALID_ARCHS)
        var effectiveArchs = requestedArchs
        if enforceValidArchs {
            effectiveArchs = effectiveArchs.filter({
                validArchs.contains($0)
            })
        }
        effectiveArchs = effectiveArchs.filter({
            !excludedArchs.contains($0)
        })

        /// Returns the preferred architecture from the given list of architectures.
        ///
        /// This returns the computed preferred architecture if present in the supplied list of architectures, otherwise `nil`.
        /// It is used to compute both the "active" architecture for the purposes of `ONLY_ACTIVE_ARCH` as well as the
        /// "preferred" architecture used for indexing and single-file actions.
        func getPreferredArch(_ archs: [String]) -> String? {
            let archsSet = Set(archs)

            if let activeRunDestination = parameters.activeRunDestination {
                // If the run destination's target arch is in the proposed archs list, use that.
                // This is the typical case, for example an arm64 macOS run destination with ARCHS_STANDARD.
                if archsSet.contains(activeRunDestination.targetArchitecture) {
                    return activeRunDestination.targetArchitecture
                }

                // Otherwise, if the intersection of the run destination's supported archs and the proposed archs list
                // contains only a single architecture, use that. This is the code path for generic run destinations,
                // where the supportedArchitectures should not be treated as priority-ordered.
                if activeRunDestination.disableOnlyActiveArch,
                    let supportedArch = Set(activeRunDestination.supportedArchitectures).intersection(archsSet).only {
                    return supportedArch
                }

                // Otherwise, use the first arch in the run destination's (priority-ordered) supported archs list
                // which is also in the proposed archs list. This is the code path for concrete run destinations,
                // where the supportedArchitectures should be treated as priority-ordered.
                if !activeRunDestination.disableOnlyActiveArch,
                    let supportedArch = activeRunDestination.supportedArchitectures.first(where: archsSet.contains) {
                    return supportedArch
                }

                // If we're in an index build, we should *always* resolve a single architecture.
                if parameters.action == .indexBuild {
                    // Have a matching compatible architecture, so use that (eg. arm64e when the run destination is
                    // arm64).
                    if let compatibleArchs = compatibilityArchMap[activeRunDestination.targetArchitecture],
                       let compatibleArch = Set(compatibleArchs).intersection(archsSet).only {
                        return compatibleArch
                    }

                    // No compatible architecture, just use the first request architecture to be consistent.
                    return archs.first
                }
            }

            // If we have an active architecture, use that.
            // NOTE: This is a legacy property that predates run destinations and is now effectively
            // redundant with the run destination's target architecture; consider removing it.
            if let activeArch = parameters.activeArchitecture, archsSet.contains(activeArch) {
                return activeArch
            }

            // Lastly, if we only have one arch anyways, use that.
            return archsSet.only
        }

        // Support ONLY_ACTIVE_ARCH
        var onlyActiveArchApplied = false
        if scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH) {
            if let arch = getPreferredArch(effectiveArchs) {
                effectiveArchs = [arch]
                onlyActiveArchApplied = true
            } else if effectiveArchs.count > 1 {
                warnings.append("ONLY_ACTIVE_ARCH=YES requested with multiple ARCHS and no active architecture could be computed; building for all applicable architectures")
            }
        }

        // Emit issues if effectiveArchs contains deprecated archs
        if sdk != nil, scope.evaluate(BuiltinMacros.__DIAGNOSE_DEPRECATED_ARCHS) {
            effectiveArchs = effectiveArchs.filter { arch in
                guard let spec = specLookupContext.getSpec(arch) as? ArchitectureSpec else { return true }

                let supportedArchDeploymentTarget: Bool = {
                    guard let deploymentTarget = deploymentTarget, let range = spec.deploymentTargetRange else { return true }
                    return range.contains(deploymentTarget)
                }()

                let deploymentTargetDisplayString = (deploymentTarget ?? Version()).canonicalDeploymentTargetForm.description
                let deprecatedArchMessage = "The \(arch) architecture is deprecated. You should update your ARCHS build setting to remove the \(arch) architecture."
                let deprecatedArchDeploymentTargetMessage = "The \(arch) architecture is deprecated for your deployment target (\(specLookupContext.platform?.familyDisplayName ?? "no platform") \(deploymentTargetDisplayString)). You should update your ARCHS build setting to remove the \(arch) architecture."
                if spec.deprecatedError {
                    errors.append(deprecatedArchMessage)
                    return false
                }
                else if !supportedArchDeploymentTarget && spec.errorOutsideDeploymentTargetRange {
                    errors.append(deprecatedArchDeploymentTargetMessage)
                    return false
                }
                else if spec.deprecated {
                    warnings.append(deprecatedArchMessage)
                    return true
                }
                else if !supportedArchDeploymentTarget {
                    warnings.append(deprecatedArchDeploymentTargetMessage)
                    return true
                }

                return true
            }
        }

        // Determine a preferred architecture for indexing, single-file actions, and the static analyzer.
        self.preferredArch = getPreferredArch(effectiveArchs)

        // Set `ARCHS` to the list of architectures we ended up with, and save the original value.
        table.push(BuiltinMacros.__ARCHS__, literal: originalArchs)
        table.push(BuiltinMacros.ARCHS, literal: effectiveArchs.removingDuplicates())

        // The set of Swift module-only architectures should be a set of valid architectures that's disjoint from the
        // set of effective architectures. We don't necessarily care about these architectures being deprecated as this
        // setting will primarily be used to support building Swift modules for deprecated (or at least unsupported)
        // architectures.
        let originalModuleOnlyArchs = scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS)
        let moduleOnlyArchs = onlyActiveArchApplied ? [] : originalModuleOnlyArchs
            .filter { validArchs.contains($0) }
            .filter { !excludedArchs.contains($0) }
            .filter { !effectiveArchs.contains($0) }
            .removingDuplicates()

        table.push(BuiltinMacros.__SWIFT_MODULE_ONLY_ARCHS__, literal: originalModuleOnlyArchs)
        table.push(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS, literal: moduleOnlyArchs)

        // FIXME: There is a more random, but questionable stuff here. To be added in a test case driven fashion.

        // Resolve some of the key path settings to be absolute.
        //
        // This is important, because they can be used to derive paths via xcspecs, and we want those paths to be absolute.
        //
        // FIXME: This is a bad way to enforce this, it doesn't have any type safety. What would be much better would be to introduce new macro evaluation features that let us write the specs to clearly demarcate paths.
        //
        // FIXME: <rdar://problem/41339901> In Xcode, this also does tilde expansion. We should support that (and test exactly where we want it to work).
        // Now that these are paths not really required.
        let macrosToNormalize = [
            BuiltinMacros.SRCROOT, BuiltinMacros.SYMROOT, BuiltinMacros.OBJROOT, BuiltinMacros.DSTROOT,
            BuiltinMacros.LOCROOT, BuiltinMacros.LOCSYMROOT,
            BuiltinMacros.CCHROOT,
            BuiltinMacros.CONFIGURATION_BUILD_DIR, BuiltinMacros.SHARED_PRECOMPS_DIR,
            BuiltinMacros.CONFIGURATION_TEMP_DIR, BuiltinMacros.TARGET_TEMP_DIR, BuiltinMacros.TEMP_DIR,
            BuiltinMacros.PROJECT_DIR, BuiltinMacros.BUILT_PRODUCTS_DIR
        ]
        for macro in macrosToNormalize {
            table.push(macro, literal: (project?.sourceRoot ?? workspaceContext.workspace.path.dirname).join(scope.evaluate(macro), normalize: true).str)
        }


        // FIXME: Xcode also normalizes SDKROOT to an absolute path here, although native targets also do this (in a different place).

        // Compute the resolved value for GCC_VERSION, if not otherwise set.
        if scope.evaluate(BuiltinMacros.GCC_VERSION).isEmpty {
            table.push(BuiltinMacros.GCC_VERSION, literal: "com.apple.compilers.llvm.clang.1_0")
        }

        if let project, project.isPackage, project.developmentRegion != nil {
            table.push(BuiltinMacros.LOCALIZATION_EXPORT_SUPPORTED, literal: true)
            table.push(BuiltinMacros.SWIFT_EMIT_LOC_STRINGS, literal: true)
        }

        return table
    }

    /// Get overriding settings for a specific target.
    ///
    /// This is called from `addTargetTaskOverrides()`.
    private func getTargetTaskOverrides(_ target: Target, _ specLookupContext: any SpecLookupContext, _ sparseSDKs: [SDK], _ sdk: SDK?) -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        let scope = createScope(sdkToUse: sdk)
        if target is StandardTarget {
            if parameters.action.isInstallAction || scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
                if scope.evaluate(BuiltinMacros.RETAIN_RAW_BINARIES) {
                    table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, Static { BuiltinMacros.namespace.parseString("$(CONFIGURATION_BUILD_DIR)/BuiltProducts") })
                }
            }
        }

        if target is ExternalTarget {
            // Create a special macro ALL_SETTINGS that external targets can use to pass the same settings passed to xcodebuild to their external tool.

            // If there are any settings that are being overridden, these need to be passed along as well.
            var overrides = createTableFromUserSettings(parameters.commandLineOverrides)
            let sdkrootOverridden = overrides.lookupMacro(BuiltinMacros.SDKROOT) != nil

            // Remove these settings, if present, so that we can explicitly set them with fully evaluated versions.
            let speciallyHandledMacros = [BuiltinMacros.DSTROOT, BuiltinMacros.OBJROOT, BuiltinMacros.SDKROOT, BuiltinMacros.SRCROOT, BuiltinMacros.SYMROOT]
            for specialMacro in speciallyHandledMacros {
                overrides.remove(specialMacro)
            }

            // Determine all of the macros that need to be passed along to the tool.
            var macros = (overrides.valueAssignments.keys.map { $0.name } + speciallyHandledMacros.map { $0.name }).sorted()

            // The SDKROOT is only passed along if it has been overridden.
            if !sdkrootOverridden { _ = macros.removeAll { $0 == BuiltinMacros.SDKROOT.name } }

            let shellCodec: any CommandSequenceEncodable = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .argumentsOnly)

            table.push(BuiltinMacros.ALL_SETTINGS, literal: macros.map({ macro in
                "\(macro)=" + shellCodec.encode([scope.evaluate(scope.namespace.parseString("$\(macro)"))])
            }))
        }

        // If testability is enabled, then that overrides certain other settings, and in a way that the user cannot override: They're either using testability, or they're not.
        if scope.evaluate(BuiltinMacros.ENABLE_TESTABILITY) {
            table.push(BuiltinMacros.GCC_SYMBOLS_PRIVATE_EXTERN, literal: false)
            table.push(BuiltinMacros.SWIFT_ENABLE_TESTABILITY, literal: true)
            table.push(BuiltinMacros.LD_EXPORT_GLOBAL_SYMBOLS, literal: true)       // So symbols are available for testing even when LTO is enabled
            table.push(BuiltinMacros.STRIP_INSTALLED_PRODUCT, literal: false)
        }

        if scope.evaluate(BuiltinMacros.ENABLE_TESTING_SEARCH_PATHS) {
            table.push(BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)", "$(TEST_FRAMEWORK_SEARCH_PATHS$(TEST_BUILD_STYLE))"]))
            table.push(BuiltinMacros.LIBRARY_SEARCH_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)", "$(TEST_LIBRARY_SEARCH_PATHS$(TEST_BUILD_STYLE))"]))
            table.push(BuiltinMacros.SWIFT_INCLUDE_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)", "$(TEST_LIBRARY_SEARCH_PATHS$(TEST_BUILD_STYLE))"]))

            // If the toolchain contains a copy of Swift Testing, prefer it.
            let toolchainPath = Path(scope.evaluateAsString(BuiltinMacros.TOOLCHAIN_DIR))
            if let toolchain = core.toolchainRegistry.toolchains.first(where: { $0.path == toolchainPath }) {
                let platformName = scope.evaluate(BuiltinMacros.PLATFORM_NAME)
                if let testingLibrarySearchPath = toolchain.testingLibrarySearchPath(forPlatformNamed: platformName) {
                    table.push(BuiltinMacros.TEST_LIBRARY_SEARCH_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)", testingLibrarySearchPath.str]))
                }
            }

            if scope.evaluate(BuiltinMacros.ENABLE_PRIVATE_TESTING_SEARCH_PATHS) {
                table.push(BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)", "$(TEST_PRIVATE_FRAMEWORK_SEARCH_PATHS$(TEST_BUILD_STYLE))"]))
            }

            let pluginFlags = getTargetTestingSwiftPluginFlags(scope)
            if !pluginFlags.isEmpty {
                table.push(BuiltinMacros.OTHER_SWIFT_FLAGS, BuiltinMacros.namespace.parseStringList(["$(inherited)"] + pluginFlags))
            }
        }

        // Set up the build phase target task overrides.
        if let buildPhaseTarget = target as? BuildPhaseTarget {
            table.pushContentsOf(getBuildPhaseTargetTaskOverrides(buildPhaseTarget, specLookupContext, sparseSDKs, scope, sdk))
        }

        return table
    }

    /// Get the testing-related compiler plugin flags for a target, based on its
    /// other build settings.
    ///
    /// - Parameters:
    /// 	- scope: The macro evaluation scope of the target for which testing
    ///     	plugin flags are being requested.
    ///
    /// - Returns: An array of Swift compiler flags, intended to be appended to
    /// 	a build setting such as `OTHER_SWIFT_FLAGS`.
    ///
    /// Testing compiler plugins allow Swift macros to be located by targets
    /// which require testing search paths (indicated by having
    /// `ENABLE_TESTING_SEARCH_PATHS` set to true).
    ///
    /// Whenever possible, this logic prefers using the non-external
    /// `-plugin-path` flag since it is more efficient. There are situations
    /// where it is not possible, though, and we must use
    /// `-external-plugin-path` to ensure the macro plugin is used from the
    /// relevant toolchain using the `swift-plugin-server` executable from that
    /// same toolchain.
    private func getTargetTestingSwiftPluginFlags(_ scope: MacroEvaluationScope) -> [String] {
        // First, query settings extensions to see if they provide their own Swift testing flags.
        var flags: [String] = []
        @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
        }
        for settingsExtension in settingsExtensions() {
            flags.append(contentsOf: settingsExtension.getTargetTestingSwiftPluginFlags(scope, toolchainRegistry: core.toolchainRegistry, sdkRegistry: core.sdkRegistry, activeRunDestination: parameters.activeRunDestination, project: project))
        }
        guard flags.isEmpty else {
            return flags
        }

        let toolchainPath = Path(scope.evaluateAsString(BuiltinMacros.TOOLCHAIN_DIR))
        guard let toolchain = core.toolchainRegistry.toolchains.first(where: { $0.path == toolchainPath }) else {
            return []
        }

        enum ToolchainStyle {
            case xcodeDefault
            case other

            init(_ toolchain: Toolchain) {
                if toolchain.identifier == ToolchainRegistry.defaultToolchainIdentifier {
                    self = .xcodeDefault
                } else {
                    self = .other
                }
            }
        }

        let testingPluginsPath = "/usr/lib/swift/host/plugins/testing"
        switch (ToolchainStyle(toolchain)) {
        case .xcodeDefault:
            // This target is building using the same toolchain as the one used
            // to build the testing libraries which it is using, so it can use
            // non-external plugin flags.
            return ["-plugin-path", "$(TOOLCHAIN_DIR)\(testingPluginsPath)"]
        case .other:
            // This target is using the testing libraries from Xcode,
            // which were built using the XcodeDefault toolchain, but it's using
            // a different toolchain itself. Use external plugin flags which
            // reference plugins from the XcodeDefault toolchain.
            return ["-external-plugin-path", "\(toolchain.path.str)\(testingPluginsPath)#\(toolchain.path.str)/usr/bin/swift-plugin-server"]
        }
    }

    /// Get overrides common to build phase type targets ("standard" and aggregate).
    private func getBuildPhaseTargetTaskOverrides(_ target: BuildPhaseTarget, _ specLookupContext: any SpecLookupContext, _ sparseSDKs: [SDK], _ scope: MacroEvaluationScope, _ baseSDK: SDK?) -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: userNamespace)

        // Ensure only a single variant is set if we're in an index build - either the first from `BUILD_VARIANTS` or `INDEX_BUILD_VARIANT` if it's set.
        var variants: [String] = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        if parameters.action == .indexBuild,
           let firstVariant = variants.first {
            let indexVariant = scope.evaluate(BuiltinMacros.INDEX_BUILD_VARIANT)
            if indexVariant.isEmpty || !variants.contains(indexVariant) {
                variants = [firstVariant]
            } else {
                variants = [indexVariant]
            }
            table.push(BuiltinMacros.BUILD_VARIANTS, literal: variants)
        }

        // Set up the per-variant conditional bindings.
        for variant in variants {
            let variantCondition = MacroConditionSet(conditions: [MacroCondition(parameter: BuiltinMacros.variantCondition, valuePattern: variant)])
            // Bind 'variant[variant=$(variant)] = value'.
            table.push(BuiltinMacros.variant, literal: variant, conditions: variantCondition)

            // Set up per-variant OBJECT_FILE_DIR_<variant> macros.
            //
            // FIXME: Eliminate this (requires project changes).
            do {
                // Compute the value to use.  If any sanitizers are enabled, then we put the object files in different folders, to reduce rebuild times when switching between having them on and off.
                var variantObjectFileDir = "$(OBJECT_FILE_DIR)-\(variant)"
                if scope.evaluate(BuiltinMacros.ENABLE_ADDRESS_SANITIZER) {
                    variantObjectFileDir += "-asan"
                }
                if scope.evaluate(BuiltinMacros.ENABLE_THREAD_SANITIZER) {
                    variantObjectFileDir += "-tsan"
                }
                if scope.evaluate(BuiltinMacros.ENABLE_UNDEFINED_BEHAVIOR_SANITIZER) {
                    variantObjectFileDir += "-ubsan"
                }

                // We push the value here with an embedded literal, since this can be referenced in places when the variant condition itself may not be active (e.g., shell scripts).
                let macro = userNamespace.lookupOrDeclareMacro(UserDefinedMacroDeclaration.self, "OBJECT_FILE_DIR_\(variant)")
                table.push(macro, BuiltinMacros.namespace.parseStringList([variantObjectFileDir]))
                exportedMacroNames.insert(macro)
            }

            // FIXME: Set up the additional per-variant settings, like the per-variant OBJECT_FILE_DIR_... and OTHER_CFLAGS_....
            table.push(BuiltinMacros.EXECUTABLE_VARIANT_SUFFIX, literal: (variant == "normal" ? "" : "_\(variant)"), conditions: variantCondition)

            // For non-normal variants of wrapped products, we sign the varianted binary inside the product.
            if variant != "normal", productType?.isWrapper ?? false {
                table.push(BuiltinMacros.CODESIGNING_FOLDER_PATH, Static { BuiltinMacros.namespace.parseString("$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)") }, conditions: variantCondition)
            }
        }

        // Set up the per-arch conditional bindings.
        let combinedArchs = scope.evaluate(BuiltinMacros.ARCHS) + scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS)
        for arch in combinedArchs {
            // Bind 'arch[arch=$(arch)] = arch' (and similarly for CURRENT_ARCH).
            table.push(BuiltinMacros.arch, literal: arch, conditions: MacroConditionSet(conditions: [MacroCondition(parameter: BuiltinMacros.archCondition, valuePattern: arch)]))
            table.push(BuiltinMacros.CURRENT_ARCH, literal: arch, conditions: MacroConditionSet(conditions: [MacroCondition(parameter: BuiltinMacros.archCondition, valuePattern: arch)]))
        }

        // FIXME: Set up the per-variant object directories.

        // Define ADDITIONAL_SDK_DIRS.
        table.push(BuiltinMacros.ADDITIONAL_SDK_DIRS, literal: sparseSDKs.map({ $0.path.str }))

        // Add the SDK_DIR_<identifier> settings for each sparse SDKs.  We also check against the base SDK, if any.
        // If multiple SDKs define the same setting then we emit a warning because only one can 'win'.  Such an issue likely needs to be fixed in one or more of the SDKs (although there's a small chance the project is doing something weird), and since SDK definition is something of the Wild West at time of writing, we don't want to break projects due to this issue, but we do want to provide a driver to get things cleaned up.
        let allSDKs: [SDK]
        if let baseSDK {
            allSDKs = [baseSDK].appending(contentsOf: sparseSDKs)
        }
        else {
            allSDKs = sparseSDKs
        }
        // Collect all the macros and SDKs into a map of [macro: [(macro, sdk)] entries, so we know if there are any collisions.
        let pairs = allSDKs.flatMap {
            sdk in sdk.directoryMacros.map { macro in (macro: macro, sdk: sdk) }
        }
        let map = Dictionary(grouping: pairs, by: { $0.macro })
        // Add the settings, but emit a warning if any setting has more than one SDK defining it.
        for (macro, pairs) in map {
            if pairs.count > 1 {
                warnings.append("Multiple SDKs define the setting '\(macro.name)'; either the target is using multiple SDKs which shouldn't be used together, or some of these SDKs need their 'CanonicalName' key updated to avoid this collision: " + pairs.map({ $0.sdk.path.str }).joined(separator: ", "))
            }
            // Push all the paths for this macro.  If there are multiple, then the last one will win, which likely means the last one defined in ADDITIONAL_SDKs.  But we push all of them in case it's useful for debugging.
            for sdk in pairs.map({ $0.sdk }) {
                // Skip the base SDK since we already pushed those in addSDKSettings().
                if let baseSDK, sdk === baseSDK {
                    continue
                }
                table.push(macro, literal: sdk.path.str)
            }
        }

        // If we don't have an input Info.plist at all (e.g. INFOPLIST_FILE is empty and DONT_GENERATE_INFOPLIST_FILE is YES), or we're a bundle product type, don't try to embed a plist in the binary.
        if scope.effectiveInputInfoPlistPath().isEmpty || productType?.isWrapper == true {
            table.push(BuiltinMacros.CREATE_INFOPLIST_SECTION_IN_BINARY, literal: false)
        }

        // For native targets, set up some DEPLOYMENT_LOCATION specific things. Resolve with other code to handle deployment location stuff.
        //
        // FIXME: Note the similar logic in getTargetDynamicSettings(), for non-standard targets. This should be reconciled.
        if scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
            if scope.evaluate(BuiltinMacros.SKIP_INSTALL) || scope.evaluate(BuiltinMacros.INSTALL_PATH).isEmpty {
                // If we're building with per-configuration build folders, then we append $(PLATFORM_NAME) to
                // the path for the uninstalled products in case the build is
                // building the same framework twice for different platforms.
                let targetBuildDir = usePerConfigurationBuildLocations ? "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)$(TARGET_BUILD_SUBPATH)" : "$(UNINSTALLED_PRODUCTS_DIR)$(TARGET_BUILD_SUBPATH)"
                table.push(BuiltinMacros.TARGET_BUILD_DIR, BuiltinMacros.namespace.parseString(targetBuildDir))
            } else {
                // Use __stripslash because $(INSTALL_PATH) may or may not be absolute, and if it is we want to avoid having two slashes '//' in the path.  Probably we need automatic normalization of paths when evaluating build settings to do something better.
                // $(INSTALL_ROOT) defaults to $(DSTROOT).
                let targetBuildDir = "$(INSTALL_ROOT)/$(INSTALL_PATH:__stripslash)$(TARGET_BUILD_SUBPATH)"
                table.push(BuiltinMacros.TARGET_BUILD_DIR, BuiltinMacros.namespace.parseString(targetBuildDir))
            }

            // If RETAIN_RAW_BINARIES is set, put built products in a subdirectory of the build folder.
            //
            // FIXME: Note the very similar logic to this previously
            if scope.evaluate(BuiltinMacros.RETAIN_RAW_BINARIES) {
                table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: scope.evaluate(BuiltinMacros.CONFIGURATION_BUILD_DIR).join("BuiltProducts").str)
            } else {
                table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: scope.evaluate(BuiltinMacros.CONFIGURATION_BUILD_DIR).str)
            }
        }

        // Add overrides from the product type.
        // The test target type overrides the deployment location overrides above, so this logic has to come after that.
        if let target = target as? StandardTarget, let productType = specLookupContext.getSpec(target.productTypeIdentifier) as? ProductTypeSpec {
            let overrides = productType.overridingBuildSettings(createScope(sdkToUse: baseSDK), platform: specLookupContext.platform)
            if let table = overrides.table {
                push(table, .exportedForNative)
            }
            warnings.append(contentsOf: overrides.warnings)
            errors.append(contentsOf: overrides.errors)

            @preconcurrency @PluginExtensionSystemActor func settingsExtensions() -> [any SettingsBuilderExtensionPoint.ExtensionProtocol] {
                core.pluginManager.extensions(of: SettingsBuilderExtensionPoint.self)
            }
            for settingsExtension in settingsExtensions() {
                let overrides = settingsExtension.overridingBuildSettings(createScope(sdkToUse: baseSDK), platform: specLookupContext.platform, productType: productType)
                pushTable(.exported) {
                    $0.pushContentsOf(createTableFromUserSettings(overrides))
                }
            }
        }
        return table
    }

    /// Get overriding settings for the product.
    ///
    /// This is called from `addTargetTaskOverrides()`.
    func getProductSpecificTargetTaskOverrides(_ target: Target, _ sdk: SDK?) -> MacroValueAssignmentTableSet {
        var tableSet = MacroValueAssignmentTableSet(namespace: userNamespace)

        // Set up the variant/arch-specific SWIFT_RESPONSE_FILE_PATH_/LINK_FILE_LIST_... macros.
        //
        // FIXME: Eliminate this. It would also be nice to be able to avoid the user defined type here, but I don't believe it is safe to inject this into the internal namespace.
        let scope = createScope(sdkToUse: sdk)
        let combinedArchs = scope.evaluate(BuiltinMacros.ARCHS) + scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS)
        for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
            for arch in combinedArchs {

                func defineMacro(prefix: String, fileExtension: String, exportType: ExportType = .none) {
                    let macro = userNamespace.lookupOrDeclareMacro(UserDefinedMacroDeclaration.self, "\(prefix)_\(variant)_\(arch)")
                    tableSet.push(exportType, macro, BuiltinMacros.namespace.parseStringList(["$(OBJECT_FILE_DIR)-\(variant)/\(arch)/$(PRODUCT_NAME).\(fileExtension)"]))
                    exportedMacroNames.insert(macro)
                }

                // We push the value here with an embedded literal, since this can be referenced in places when the arch and variant conditions may not be active (e.g., shell scripts).
                // FIXME: Use object-file macro. Note that we must parse as a string list here given the expression type.
                defineMacro(prefix: "LINK_FILE_LIST", fileExtension: "LinkFileList")
                defineMacro(prefix: "SWIFT_RESPONSE_FILE_PATH", fileExtension: "SwiftFileList", exportType: .exported)
                defineMacro(prefix: "LM_AUX_CONST_METADATA_LIST_PATH", fileExtension: "SwiftConstValuesFileList")
            }
        }

        // If any sanitizer is enabled, and this product type has a runpath to its Frameworks directory defined, then we want to add that path to the runpath search path if it's not already present.
        if scope.evaluate(BuiltinMacros.ENABLE_ADDRESS_SANITIZER) || scope.evaluate(BuiltinMacros.ENABLE_THREAD_SANITIZER) || scope.evaluate(BuiltinMacros.ENABLE_UNDEFINED_BEHAVIOR_SANITIZER)
        {
            if let frameworksRunpath = productType?.frameworksRunpathSearchPath(in: scope)?.str {
                if !scope.evaluate(BuiltinMacros.LD_RUNPATH_SEARCH_PATHS).contains(frameworksRunpath) {
                    tableSet.push(.none, BuiltinMacros.LD_RUNPATH_SEARCH_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)", frameworksRunpath]))
                }
            }
        }

        // Prepend $(BUILT_PRODUCTS_DIR) to the search paths.
        if target is StandardTarget && scope.evaluate(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS) {
            for searchPathMacro in [
                BuiltinMacros.HEADER_SEARCH_PATHS,
                BuiltinMacros.FRAMEWORK_SEARCH_PATHS,
                BuiltinMacros.LIBRARY_SEARCH_PATHS,
                BuiltinMacros.REZ_SEARCH_PATHS,
                BuiltinMacros.SWIFT_INCLUDE_PATHS,
            ] {
                let macroName = "\(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS.name)_IN_\(searchPathMacro.name)"
                guard let macro = userNamespace.lookupMacroDeclaration(macroName) as? BooleanMacroDeclaration else {
                    core.delegate.error("internal error: Build setting \(macroName) is not of boolean type")
                    continue
                }
                // Note that this implies if the macro is unset or set to empty then it defaults to YES, which is the opposite of most macros, but probably fine for this very niche functionality.  If this becomes an issue then we should declare all of these macros in CoreBuildSystem.xcspec with default values of YES, or maybe $(ENABLE_DEFAULT_SEARCH_PATHS).
                if scope.evaluateAsString(macro).isEmpty || scope.evaluate(macro) {
                    switch searchPathMacro {
                    case BuiltinMacros.HEADER_SEARCH_PATHS:
                        tableSet.push(.none, searchPathMacro, Static { BuiltinMacros.namespace.parseStringList(["$(BUILT_PRODUCTS_DIR)/include", "$(inherited)"]) } )
                    default:
                        tableSet.push(.none, searchPathMacro, Static { BuiltinMacros.namespace.parseStringList(["$(BUILT_PRODUCTS_DIR)", "$(inherited)"]) } )
                    }
                }
            }
        }

        return tableSet
    }

    /// Get overriding path settings for the SDKs.
    ///
    /// This is called from `addTargetTaskOverrides()`.
    func getSDKSpecificPathOverrides(_ sdk: SDK, _ sparseSDKs: [SDK]) -> MacroValueAssignmentTable {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)

        // Alter all of the search paths to point into the SDK, if the path exists there.  For each search path, that path will be remapped into the base SDK and any sparse SDKs in which the search path exists.
        //
        // FIXME: This is bogus and causes problems for our users (e.g., because it cannot be directly controlled), but is necessary for now for backwards compatibility.
        //
        // NOTE: We intentionally exclude SYSTEM_HEADER_SEARCH_PATHS and SYSTEM_FRAMEWORK_SEARCH_PATHS from this list, because they are already prefixed with the SDK path if appropriate.
        let scope = createScope(sdkToUse: sdk)
        for macro in [BuiltinMacros.HEADER_SEARCH_PATHS, BuiltinMacros.PRODUCT_TYPE_HEADER_SEARCH_PATHS, BuiltinMacros.FRAMEWORK_SEARCH_PATHS, BuiltinMacros.PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS, BuiltinMacros.REZ_SEARCH_PATHS, BuiltinMacros.LIBRARY_SEARCH_PATHS, BuiltinMacros.PRODUCT_TYPE_LIBRARY_SEARCH_PATHS] {

            /// Helper function to remap `path` into the sdk `sdk`.  Remapping will occur if `path` exists inside `sdk`.
            /// - returns: The remapped path, or `nil` if the path does not exist inside the sdk.
            func remapIfNecessary(_ path: Path, into sdk: SDK) -> Path? {
                // Ignore relative paths.
                if !path.isAbsolute { return nil }

                // Check if the path exists in the SDK, and remap it if so.
                let remapped = sdk.path.join(path, preserveRoot: true)
                if workspaceContext.fs.exists(remapped) {
                    return remapped
                } else {
                    return nil
                }
            }

            /// Helper function to process the SDK remapping for a specific `variant` and `arch`.
            func processRemapping(_ scope: MacroEvaluationScope, _ originalValues: [Path], variant: String? = nil, arch: String? = nil) {
                // Get the evaluated paths for this search path build setting, and remap them into the SDKs as appropriate.
                let values = originalValues.flatMap{ (path: Path) -> [Path] in
                    var results = [Path]()

                    // Remap into the sparse SDKs.  This effectively adds search paths into the sparse SDKs.
                    if !sparseSDKs.isEmpty {
                        // If the path is already prepended with the base SDK, then remove the base SDK, so we only consider the path relative to the base SDK when looking inside the sparse SDKs.
                        let relPath: Path
                        if sdk.path.isAncestor(of: path) {
                            if let subpath = path.relativeSubpath(from: sdk.path) {
                                relPath = Path("/").join(subpath)
                            } else {
                                relPath = path
                            }
                        } else {
                            relPath = path
                        }
                        for sparseSDK in sparseSDKs {
                            if let remapped = remapIfNecessary(relPath, into: sparseSDK) {
                                results.append(remapped)
                            }
                        }
                    }

                    // Remap into the base SDK.
                    if let remapped = remapIfNecessary(path, into: sdk) {
                        results.append(remapped)
                    } else {
                        results.append(path)
                    }

                    return results
                }

                // If the value was changed, push it into the overrides.
                if values != originalValues {
                    // If arch and variant are present, add them as conditions under which the overrided values should be valid.
                    var conditions: MacroConditionSet? = nil
                    if let variant = variant, let arch = arch {
                        conditions = MacroConditionSet(conditions: [
                            MacroCondition(parameter: BuiltinMacros.variantCondition, valuePattern: variant),
                            MacroCondition(parameter: BuiltinMacros.archCondition, valuePattern: arch),
                        ])
                    }
                    table.push(macro, literal: values.map{ $0.str }, conditions: conditions)
                }
            }

            // Evaluate the macro while checking if CURRENT_VARIANT and CURRENT_ARCH are being used.
            var currentMacroFound = false
            let originalValues = scope.evaluate(macro) { macro in
                if [BuiltinMacros.CURRENT_VARIANT, BuiltinMacros.CURRENT_ARCH].contains(macro) {
                    currentMacroFound = true
                }
                return nil
            }

            if currentMacroFound {
                // If a CURRENT_* macro was found, then iterate over variants and archs to create evaluated versions
                // of the macros under those conditions. Check rdar://problem/46039547 for more details.
                let archs: [String] = scope.evaluate(BuiltinMacros.ARCHS)
                let buildVariants = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
                for variant in buildVariants {
                    let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
                    for arch in archs {
                        let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
                        let originalValues = scope.evaluate(macro)
                        processRemapping(scope, originalValues.map{ Path($0) }, variant: variant, arch: arch)
                    }
                }
            } else {
                // If CURRENT_* macros were not found while evaluating the macro, then use the original values already parsed
                // to process the remapping.
                processRemapping(scope, originalValues.map{ Path($0) })
            }
        }

        // Alter GCC_PREFIX_HEADER, if present. Some projects use an actual file from the SDK as their prefix file, for example AppKit.h.
        for macro in [BuiltinMacros.GCC_PREFIX_HEADER] {
            let value = scope.evaluate(macro)
            if !value.isEmpty {
                let remapped = sdk.path.join(value, preserveRoot: true)
                if workspaceContext.fs.exists(remapped) {
                    table.push(macro, literal: remapped.str)
                }
            }
        }

        return table
    }

    /// Computes the deployment target and both binds it to the build setting defined in `self.deploymentTargetMacro`, and pushes it on the settings table.
    private func bindDeploymentTarget(_ platform: Platform?, _ sdk: SDK?, _ sdkVariant: SDKVariant?) -> BoundDeploymentTarget {
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = createScope(sdkToUse: sdk)

        // Bind the platform deployment target macro.  If we can't bind one, then there's nothing to do.
        guard let platformDeploymentTargetMacro = platform?.deploymentTargetMacro else {
            return BoundDeploymentTarget()
        }

        // Get the assigned platform deployment target and use it to seed the candidate deployment target.
        let platformDeploymentTargetString = scope.evaluate(platformDeploymentTargetMacro)
        var platformDeploymentTarget = try? Version(platformDeploymentTargetString)
        // FIXME: Should we emit a warning or something if the deployment target can't be parsed?
        // We don't return here because we might set the deployment target farther below.

        /// Utility function to validate the deployment target and emit a warning if it's not a valid value.
        func validateDeploymentTarget(_ deploymentTarget: Version?, isInRange range: VersionRange, deploymentTargetMacro: StringMacroDeclaration, buildTarget: String) {
            guard let deploymentTarget else {
                // Should we emit a warning here if the deployment target is nil?
                return
            }
            if !range.contains(deploymentTarget) {
                let start = range.start?.description ?? "0.0"
                let end = range.end?.description ?? "future"
                self.targetDiagnostics.append(Diagnostic(behavior: .warning, location: .buildSetting(deploymentTargetMacro), data: DiagnosticData("The \(buildTarget) deployment target '\(deploymentTargetMacro.name)' is set to \(deploymentTarget), but the range of supported deployment target versions is \(start) to \(end).", component: .targetIntegrity)))
            }
        }

        // Bind the SDK variant deployment target macro & value.  Presently this is only done for macCatalyst.
        let sdkVariantDeploymentTargetMacro: StringMacroDeclaration?
        let sdkVariantDeploymentTarget: Version?
        if platform?.familyName == "macOS", let sdkVariant, sdkVariant.isMacCatalyst {
            let buildTarget = BuildVersion.Platform.macCatalyst.displayName(infoLookup: core)

            // macCatalyst's deployment target is IPHONEOS_DEPLOYMENT_TARGET.
            sdkVariantDeploymentTargetMacro = BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET

            // Bind the deployment target.
            // 13.0 is a backstop in case anything isn't defined here.
            let assignedSDKVariantDeploymentTargetString = scope.evaluate(sdkVariantDeploymentTargetMacro!)
            let defaultSDKVariantDeploymentTarget = sdkVariant.defaultDeploymentTarget ?? Version(13, 0)
            let assignedSDKVariantDeploymentTarget: Version
            if let deploymentTarget = try? Version(assignedSDKVariantDeploymentTargetString) {
                assignedSDKVariantDeploymentTarget = deploymentTarget
            }
            else {
                self.notes.append("The \(buildTarget) deployment target '\(sdkVariantDeploymentTargetMacro!.name)' is set to '\(assignedSDKVariantDeploymentTargetString)' - setting to default value '\(defaultSDKVariantDeploymentTarget.description)'.")
                assignedSDKVariantDeploymentTarget = defaultSDKVariantDeploymentTarget
            }
            var candidateSDKVariantDeploymentTarget = assignedSDKVariantDeploymentTarget

            // Limit the deployment target to the minimum version in the SDK's TargetInfo.
            // 13.0 is a backstop in case anything isn't defined here.
            let minimumDeploymentTarget = sdkVariant.minimumDeploymentTarget ?? Version(13, 0)
            if candidateSDKVariantDeploymentTarget < minimumDeploymentTarget {
                candidateSDKVariantDeploymentTarget = minimumDeploymentTarget
            }

            // Limit the deployment target to the maximum version in the SDK's TargetInfo.
            // NOTE: We don't use maximumDeploymentTarget here because of <rdar://49361471>
            if let maximumDeploymentTarget = sdkVariant.validDeploymentTargets?.last, candidateSDKVariantDeploymentTarget > maximumDeploymentTarget {
                candidateSDKVariantDeploymentTarget = maximumDeploymentTarget
            }

            // Validate that the deployment target is in the range specified by the SDK's TargetInfo.
            validateDeploymentTarget(candidateSDKVariantDeploymentTarget, isInRange: sdkVariant.deploymentTargetRange, deploymentTargetMacro: sdkVariantDeploymentTargetMacro!, buildTarget: buildTarget)

            // Bind the SDK variant deployment target.  If it is different from the assigned one then push it onto the table.
            sdkVariantDeploymentTarget = candidateSDKVariantDeploymentTarget
            if candidateSDKVariantDeploymentTarget != assignedSDKVariantDeploymentTarget {
                table.push(sdkVariantDeploymentTargetMacro!, literal: candidateSDKVariantDeploymentTarget.description)
            }

            // If the macOS deployment target is not already set, then set it.
            assert(platformDeploymentTargetMacro == BuiltinMacros.MACOSX_DEPLOYMENT_TARGET)
            let assignedMacOSDeploymentTarget = scope.evaluate(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET)
            var getMacOSDeploymentTargetFromIOSDeploymentTarget = false
            // If we're  building zippered then we only set the macOS deployment target if it's empty.  If we aren't building zippered then we set it to the one that matches the iOS deployment target.
            if scope.evaluate(BuiltinMacros.IS_ZIPPERED) {
                if assignedMacOSDeploymentTarget.isEmpty {
                    getMacOSDeploymentTargetFromIOSDeploymentTarget = true
                }
                // If macOS deployment target is already defined, we do not check it against a macCatalyst-specific minimum value.  Building a macCatalyst target with a macOS deployment target earlier than the release in which macCatalyst first shipped (10.15) is allowed for zippered products.
            }
            else {
                getMacOSDeploymentTargetFromIOSDeploymentTarget = true
            }
            if getMacOSDeploymentTargetFromIOSDeploymentTarget {
                // 10.15 is a backstop in case anything isn't defined here.
                let macOSDeploymentTarget = sdk?.versionMap["iOSMac_macOS"]?[candidateSDKVariantDeploymentTarget] ?? Version(10, 15)
                platformDeploymentTarget = macOSDeploymentTarget
                table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: macOSDeploymentTarget.description)
            }
        }
        else {
            sdkVariantDeploymentTargetMacro = nil
            sdkVariantDeploymentTarget = nil

            // If IS_ZIPPERED is yes and our sdk has an macCatalyst variant, then perform some checks on IPHONEOS_DEPLOYMENT_TARGET.
            if platform?.familyName == "macOS", scope.evaluate(BuiltinMacros.IS_ZIPPERED) {
                let iOSDeploymentTargetMacro = BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET

                let assignediOSDeploymentTarget = try? Version(scope.evaluate(iOSDeploymentTargetMacro))
                // Should we emit a warning if the iOS deployment target string couldn't be parsed?
                var candidateiOSDeploymentTarget = assignediOSDeploymentTarget

                // If we don't have a valid iOS deployment target, then infer it from the macOS deployment target.
                if candidateiOSDeploymentTarget == nil {
                    if let macOSDeploymentTarget = platformDeploymentTarget {
                        // 13.0 is a backstop in case anything isn't defined here.
                        candidateiOSDeploymentTarget = sdk?.versionMap["macOS_iOSMac"]?[macOSDeploymentTarget] ?? Version(13, 0)
                    }
                    else {
                        candidateiOSDeploymentTarget = Version(13, 0)
                    }
                }

                // If the iOS deployment target is lower than the minimum version in the macCatalyst target info, then limit it to that version
                let minimumDeploymentTarget = sdk?.variant(for: MacCatalystInfo.sdkVariantName)?.minimumDeploymentTarget ?? Version(13, 0)
                if candidateiOSDeploymentTarget! < minimumDeploymentTarget {
                    candidateiOSDeploymentTarget = minimumDeploymentTarget
                }

                // Limit the deployment target to the maximum version in the SDK's TargetInfo.
                // NOTE: We don't use maximumDeploymentTarget here because of <rdar://49361471>
                if let maximumDeploymentTarget = sdk?.variant(for: MacCatalystInfo.sdkVariantName)?.validDeploymentTargets?.last, candidateiOSDeploymentTarget! > maximumDeploymentTarget {
                    candidateiOSDeploymentTarget = maximumDeploymentTarget
                }

                // If the candidate value is different from the assigned value, then push it onto the table.
                if candidateiOSDeploymentTarget != assignediOSDeploymentTarget {
                    table.push(iOSDeploymentTargetMacro, literal: candidateiOSDeploymentTarget!.description)
                }
            }
        }

        // Validate the platform deployment target against the range defined in the platform.  For Mac Catalyst this means MACOSX_DEPLOYMENT_TARGET (IPHONEOS_DEPLOYMENT_TARGET is checked above in either the SDK variant branch, or the IS_ZIPPERED branch), for other platforms this means the platform's defined deployment target.
        if let platform {
            validateDeploymentTarget(platformDeploymentTarget, isInRange: platform.deploymentTargetRange, deploymentTargetMacro: platformDeploymentTargetMacro, buildTarget: platform.displayName)
        }

        // If our table is not empty, then push it onto the primary table.
        if !table.isEmpty {
            push(table, .exported)
        }

        // Return the bound properties.
        return BoundDeploymentTarget(platformDeploymentTargetMacro: platformDeploymentTargetMacro, platformDeploymentTarget: platformDeploymentTarget, sdkVariantDeploymentTargetMacro: sdkVariantDeploymentTargetMacro, sdkVariantDeploymentTarget: sdkVariantDeploymentTarget)
    }

    // FIXME: <rdar://84686692> We shouldn't be doing this analysis and storing issue strings for every Settings object.  We should generate these "after the table is fully constructed" issues on demand when the build starts.
    //
    /// Analyze the fully-constructed Settings table to generate any issues we find with it.
    private func analyzeSettings(_ specLookupContext: any SpecLookupContext, _ sdk: SDK?, _ sdkVariant: SDKVariant?) {
        let scope = createScope(sdkToUse: sdk)

        struct ProductTypePlatformAnalysisContext: PlatformBuildContext {
            let platform: Platform?
            let sdk: SDK?
            let sdkVariant: SDKVariant?
        }

        if let target = target as? StandardTarget, let buildPlatforms = ProductTypePlatformAnalysisContext(platform: specLookupContext.platform, sdk: sdk, sdkVariant: sdkVariant).targetBuildVersionPlatforms(in: scope), let productType = specLookupContext.getSpec(target.productTypeIdentifier) as? ProductTypeSpec, !core.productTypeSupportsPlatform(productType: productType, platform: specLookupContext.platform) {
            targetDiagnostics.append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(Diagnostic.unavailableTargetTypeDiagnosticString(targetTypeDescription: productType.name, platformInfoLookup: core, buildPlatforms: buildPlatforms), component: .targetIntegrity)))
        }

        // Opt-in checks.
        if scope.evaluate(BuiltinMacros.WARN_ON_VALID_ARCHS_USAGE) {
            for setting in [
                // We should move the check for ONLY_ACTIVE_ARCH here from getCommonTargetTaskOverrides().
                //BuiltinMacros.ONLY_ACTIVE_ARCH,
                BuiltinMacros.VALID_ARCHS,
            ] {
                let definedAtLevels = allProjectSettingsLevels.compactMap { settings in
                    settings.table?.contains(setting) == true ? settings.level : nil
                }
                if !definedAtLevels.isEmpty {
                    warnings.append("Project analysis: \(setting.name) assigned at level" + (definedAtLevels.count > 1 ? "s" : "") + ": " + definedAtLevels.joined(separator: ", "))
                }
            }
        }

        // For checks which need to examine the table at each definition level specifically, add those checks to this loop.
        for settings in allProjectSettingsLevels {
            let levelScope = createScope(sdkToUse: sdk, table: settings.table)

            // Warn if SDKROOT is defined as conditional on sdk=, as it will be ignored.
            do {
                var sdkrootAsgn = settings.table?.valueAssignments[BuiltinMacros.SDKROOT]
                while sdkrootAsgn != nil {
                    if let conditionSet = sdkrootAsgn?.conditions {
                        // We report each distinct condition set at this level which has an [sdk=] condition.  It's not uncommon to have multiple conditionalized settings, especially in xcconfig files, so this hopefully will help users cut down on the numbers of builds they have to do to shake out all of these warnings.
                        if conditionSet.conditions.contains(where: { $0.parameter.name == "sdk" }) {
                            warnings.append("SDK condition on SDKROOT is unsupported, so the SDKROOT\(conditionSet) assignment at the \(settings.level) level will be ignored.")
                        }
                    }
                    sdkrootAsgn = sdkrootAsgn?.next
                }
            }

            analyzeExcludedLocalizationFiles(inLevelWithTable: settings.table, scope: levelScope, name: settings.level, generalScope: scope)
        }

        // Diagnose unknown specialization options on targets. This is a warning and not an error so that if we introduce a new option, using it will not necessarily break compatibility with older Xcodes.
        if target != nil {
            let unknownSpecializationOptions = Set(scope.evaluate(BuiltinMacros.SPECIALIZATION_SDK_OPTIONS)).subtracting(["internal"])
            if !unknownSpecializationOptions.isEmpty {
                for unknownOption in unknownSpecializationOptions {
                    warnings.append("unknown specialization option '\(unknownOption)' will be ignored")
                }
            }
        }

        func settingDefinedAtLevels(_ setting: MacroDeclaration) -> [String]? {
            let levels = allProjectSettingsLevels.compactMap { settings in
                settings.table?.contains(setting) == true ? settings.level : nil
            }
            return levels.isEmpty ? nil : levels
        }

        let moduleOnlyMessage = "Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project."
        for setting in [
            BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS,
            BuiltinMacros.SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET,
            BuiltinMacros.SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET,
            BuiltinMacros.SWIFT_MODULE_ONLY_TVOS_DEPLOYMENT_TARGET,
            BuiltinMacros.SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET,
        ] {
            if let definedAtLevels = settingDefinedAtLevels(setting) {
                warnings.append("\(setting.name) assigned at level" + (definedAtLevels.count > 1 ? "s" : "") + ": " + definedAtLevels.joined(separator: ", ") + ". " + moduleOnlyMessage)
            }
        }

        // Check settings which should either not be defined at all, or which we warn if defined to a specific value.
        for (setting, values, explanation): (MacroDeclaration, [String]?, String?) in [
            // We no longer ship libstdc++ so we warn about it specifically.  c.f. <rdar://83768231>
            (BuiltinMacros.CLANG_CXX_LIBRARY, ["libstdc++"], "The 'libstdc++' C++ Standard Library is no longer available, and this setting can be removed."),
        ] {
            if let values, !values.isEmpty {
                // If values is not empty, then we only emit warnings is we detect that the setting is defined to one of the given values.
                for value in values {
                    let assignedValue = scope.evaluateAsString(setting)
                    if assignedValue == value {
                        let explanation = explanation ?? "This value is not valid."
                        warnings.append("\(setting.name) is set to '\(assignedValue)': \(explanation)")
                        break
                    }
                }
            }
            else {
                // If values is empty then we emit a warning if the setting is defined at all.
                let assignedValue = scope.evaluateAsString(setting)
                if !assignedValue.isEmpty {
                    let explanation = explanation ?? "This setting is not supported."
                    warnings.append("\(setting.name) is set to '\(assignedValue)': \(explanation)")
                }
            }
        }

        // Emit an error if ARCHS contains an architecture which doesn't support mergeable libraries but a relevant setting is enabled.
        for setting in [
            BuiltinMacros.MERGED_BINARY_TYPE,
            BuiltinMacros.AUTOMATICALLY_MERGE_DEPENDENCIES,
            BuiltinMacros.MERGE_LINKED_LIBRARIES,
            BuiltinMacros.MERGEABLE_LIBRARY,
            BuiltinMacros.MAKE_MERGEABLE,
        ] {
            if let definedAtLevels = settingDefinedAtLevels(setting) {
                for arch in scope.evaluate(BuiltinMacros.ARCHS) {
                    if let archSpec: ArchitectureSpec = try? specLookupContext.getSpec(arch), !archSpec.supportsMergeableLibraries {
                        errors.append("Mergeable libraries are not supported for architecture '\(arch)', but \(setting.name) is assigned at level" + (definedAtLevels.count > 1 ? "s" : "") + ": " + definedAtLevels.joined(separator: ", ") + ".")
                    }
                }
            }
        }

        struct SettingMutability: OptionSet {
            let rawValue: Int

            static let none = Self([])
            static let prepend = Self(rawValue: 1 << 0)
            static let append = Self(rawValue: 1 << 1)
            static let extend: Self = [.prepend, .append]
        }

        // Check settings which should be treated as read-only to various extents.
        for (setting, mutability) in [
            // .append because this setting is commonly used to work around rdar://73504582
            (BuiltinMacros.PRODUCT_SPECIFIC_LDFLAGS, .append),

            (BuiltinMacros.__108704016_DEVELOPER_TOOLCHAIN_DIR_MISUSE_IS_WARNING, .none), // don't allow this to be overridden at the project level
            (BuiltinMacros.RESCHEDULE_INDEPENDENT_HEADERS_PHASES, .none), // don't allow this to be overridden at the project level
        ] as [(MacroDeclaration, SettingMutability)] {
            let definedAtLevels = allProjectSettingsLevels.compactMap { settings -> String? in
                guard let assignment = settings.table?.valueAssignments[setting] else {
                    return nil
                }

                let tokens = assignment.expression.stringRep.split(separator: " ")
                if mutability.contains(.prepend) && mutability.contains(.append) {
                    return tokens.contains("$(inherited)") ? nil : settings.level
                } else if mutability.contains(.prepend) {
                    return tokens.last == "$(inherited)" ? nil : settings.level
                } else if mutability.contains(.append) {
                    return tokens.first == "$(inherited)" ? nil : settings.level
                } else {
                    return settings.level
                }
            }
            if !definedAtLevels.isEmpty {
                let phrase: String
                if mutability.contains(.prepend) && mutability.contains(.append) {
                    phrase = "extend-only and cannot be overridden without adding $(inherited)"
                } else if mutability.contains(.prepend) {
                    phrase = "prepend-only and cannot be overridden without appending $(inherited)"
                } else if mutability.contains(.append) {
                    phrase = "append-only and cannot be overridden without prepending $(inherited)"
                } else {
                    phrase = "read-only and cannot be overridden"
                }
                errors.append("\(setting.name) assigned at level" + (definedAtLevels.count > 1 ? "s" : "") + ": " + definedAtLevels.joined(separator: ", ") + ". " + "This setting is \(phrase).")
            }
        }

        if productType is ApplicationExtensionProductTypeSpec && !scope.evaluate(BuiltinMacros.APPLICATION_EXTENSION_API_ONLY) {
            let message = "Application extensions and any libraries they link to must be built with the `\(BuiltinMacros.APPLICATION_EXTENSION_API_ONLY.name)` build setting set to YES."

            // Remove __APPLICATION_EXTENSION_API_DOWNGRADE_APPEX_ERROR feature flag
            if scope.evaluate(BuiltinMacros.__APPLICATION_EXTENSION_API_DOWNGRADE_APPEX_ERROR) {
                warnings.append(message)
            } else {
                errors.append(message)
            }
        }

        // Map of settings to maps of settings which can't be used to evaluate the value of said setting, and the settings that should be used instead. This is used to block projects from incorrectly swapping developer directory and toolchain settings for the opposite purpose.
        let environmentIndependentVerificationData = [
            BuiltinMacros.DEVELOPER_DIR: BuiltinMacros.DEVELOPER_INSTALL_DIR,
            BuiltinMacros.TOOLCHAIN_DIR: BuiltinMacros.DT_TOOLCHAIN_DIR,
        ]
        let environmentDependentVerificationData = [
            BuiltinMacros.DEVELOPER_INSTALL_DIR: BuiltinMacros.DEVELOPER_DIR,
            BuiltinMacros.DT_TOOLCHAIN_DIR: BuiltinMacros.TOOLCHAIN_DIR,
        ]
        let verifySettings = [
            // Settings whose paths must always be environment-independent because they refer to paths which will become part of the products themselves or where the products will be located in the DSTROOT.
            BuiltinMacros.INSTALL_PATH: environmentIndependentVerificationData,

            // Ideally we don't want to use the "runtime" versions either, because rpaths _shouldn't_ be absolute, but that may be desired for debug builds, or tools used only during the build.
            BuiltinMacros.LD_RUNPATH_SEARCH_PATHS: environmentDependentVerificationData,

            // Settings whose paths must always be environment-dependent because they refer to paths in the build environment which won't become part of the products themselves.
            BuiltinMacros.DSYMUTIL_DSYM_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.FRAMEWORK_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.HEADER_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.KERNEL_EXTENSION_HEADER_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.LIBRARY_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.PRODUCT_TYPE_HEADER_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.PRODUCT_TYPE_LIBRARY_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.PRODUCT_TYPE_SWIFT_INCLUDE_PATHS: environmentDependentVerificationData,
            BuiltinMacros.REZ_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.SYSTEM_HEADER_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.TAPI_EXTRACT_API_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.TAPI_HEADER_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.TEST_FRAMEWORK_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.TEST_LIBRARY_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.TEST_PRIVATE_FRAMEWORK_SEARCH_PATHS: environmentDependentVerificationData,
            BuiltinMacros.USER_HEADER_SEARCH_PATHS: environmentDependentVerificationData,
        ]

        let allow108704016 = scope.evaluate(BuiltinMacros.__108704016_DEVELOPER_TOOLCHAIN_DIR_MISUSE_IS_WARNING)
        for (settingToVerify, verificationData) in verifySettings {
            _ = scope.evaluateAsString(settingToVerify) { decl in
                // DEVELOPER_INSTALL_DIR is defined in terms of DEVELOPER_DIR, so return its value directly as a literal string instead of recursively evaluating into DEVELOPER_DIR, which would erroneously make it look as if DEVELOPER_DIR were being used when it was not.
                if decl == BuiltinMacros.DEVELOPER_INSTALL_DIR {
                    return scope.namespace.parseLiteralString(scope.evaluate(BuiltinMacros.DEVELOPER_INSTALL_DIR).str)
                }

                for (prohibitedSetting, replacementSetting) in verificationData {
                    if decl == prohibitedSetting {
                        let message = "\(prohibitedSetting.name) cannot be used to evaluate \(settingToVerify.name), use \(replacementSetting.name) instead"
                        if allow108704016 {
                            self.warnings.append(message)
                        } else {
                            self.errors.append(message)
                        }
                    }
                }

                return nil
            }
        }
    }

    /// The xcstrings file paths in the target, cached here for performance during `analyzeExcludedLocalizationFiles()`.
    ///
    /// An outer `nil` means we haven't computed this yet. An inner `nil` means we computed it but the result was `nil`, perhaps because these are project settings. `[]` means this is for a target but no direct xcstrings files.
    private var _xcstringsPathsInTarget: [Path]??

    /// The xcstrings file paths in the target for which we are constructing settings.
    ///
    /// Returns `nil` if we're not constructed settings for a particular target.
    private func xcstringsPathsInTarget(scope: MacroEvaluationScope) -> [Path]? {
        if let _xcstringsPathsInTarget {
            return _xcstringsPathsInTarget
        }

        guard let target else {
            // Perhaps this is a project-level settings builder, but we aren't going to crawl the entire project.
            // It's fine to catch this when we get to building settings for a particular target.
            _xcstringsPathsInTarget = .some(nil)
            return nil
        }

        guard let standardTarget = target as? StandardTarget else {
            // Perhaps this was a non-standard target, in which case it wouldn't contain xcstrings files in a meaningful and analyzable way.
            _xcstringsPathsInTarget = []
            return []
        }

        // For performance, we're only going to check the Resources build phase because that's where xcstrings are expected to hang out.
        let buildFiles = standardTarget.resourcesBuildPhase?.buildFiles ?? []

        let resolver = FilePathResolver(scope: scope)

        let paths: [Path] = buildFiles.compactMap { buildFile in
            // Considering only file references.
            guard case let .reference(guid) = buildFile.buildableItem,
                  let reference = workspaceContext.workspace.lookupReference(for: guid),
                  let fileRef = reference as? FileReference else {
                return nil
            }

            // We could also use a file type spec, but this saves us from needing to create a spec lookup context for it.
            // We're already looking at file extensions in here.
            guard fileRef.fileTypeIdentifier == "text.json.xcstrings" else {
                return nil
            }

            // Note that we intentionally don't check this with a filtering context because we are already using these paths in the context of analyzing the validity of EXCLUDED/INCLUDED_SOURCE_FILE_NAMES.
            return resolver.resolveAbsolutePath(fileRef)
        }

        _xcstringsPathsInTarget = paths
        return paths
    }

    /// Analyzes patterns in `EXCLUDED/INCLUDED_SOURCE_FILE_NAMES` to detect cases where only a strict subset of localization file extensions are excluded.
    ///
    /// - Parameters:
    ///   - table: The level's assignment table.
    ///   - levelScope: The leve's scope.
    ///   - name: The level's name.
    ///   - generalScope: A scope for determining the severity of this validation and resolving files within, not necessarily equal to the narrowed-down `levelScope`.
    private func analyzeExcludedLocalizationFiles(inLevelWithTable table: MacroValueAssignmentTable?, scope levelScope: MacroEvaluationScope, name levelName: String, generalScope: MacroEvaluationScope) {
        // Warn if EXCLUDED/INCLUDED_SOURCE_FILE_NAMES accounts for only a strict subset of the localization file extensions.
        // This is usually unintentional and can lead to leaking files.
        let locFileExtensions: Set<String> = ["strings", "stringsdict", "xcstrings"]

        let warnLevel = generalScope.evaluate(BuiltinMacros.DIAGNOSE_LOCALIZATION_FILE_EXCLUSION)
        guard warnLevel != .no else {
            return
        }

        /// Returns the index of a "." in `pattern` that would serve as the file extension prefix.
        ///
        /// If `pattern` does not contain a file extension suffix, returns `nil`.
        func indexOfFileExtensionDot(inPattern pattern: String) -> String.Index? {
            for idx in pattern.indices.reversed() {
                if pattern[idx] == "." {
                    return idx
                }
                if pattern[idx] == Path.pathSeparator {
                    break
                }
            }
            return nil
        }

        func analyzePatterns(in setting: MacroDeclaration) {
            // We will output a warning for each assignment entry, to make it easier to detect all instances of this in a single build.
            var patternsAssignment = table?.valueAssignments[setting]
            while let assignment = patternsAssignment {
                var patterns = [String]()
                if let stringListExpr = assignment.expression as? MacroStringListExpression {
                    patterns = levelScope.evaluate(stringListExpr)
                } else if let stringExpr = assignment.expression as? MacroStringExpression {
                    patterns = [levelScope.evaluate(stringExpr)]
                }
                patterns = patterns.filter { !$0.isEmpty }

                patternsAssignment = assignment.next

                guard !patterns.isEmpty else {
                    continue
                }

                // We want to analyze the pattern list to see if there are hypothetical file names that would be excluded
                // when they have certain localization file extensions but not others.

                // A pattern prefix here is a pattern up to but not including the file extension suffix.
                var fileExtensionsToMatchingPatternPrefixes: [String: Set<Substring>] = Dictionary(uniqueKeysWithValues: locFileExtensions.map({ locExtension in
                    return (locExtension, [])
                }))
                for pattern in patterns {
                    guard let fileExtensionDotIndex = indexOfFileExtensionDot(inPattern: pattern) else {
                        continue
                    }
                    let fileExtensionPattern = String(pattern[pattern.index(after: fileExtensionDotIndex)...])
                    let patternPrefix = pattern[..<fileExtensionDotIndex]

                    for locExtension in locFileExtensions where (try? fnmatch(pattern: fileExtensionPattern, input: locExtension)) == true {
                        fileExtensionsToMatchingPatternPrefixes[locExtension]?.insert(patternPrefix)
                    }
                }

                let allMatchingPatternPrefixes = fileExtensionsToMatchingPatternPrefixes.values.reduce(Set()) { $0.union($1) }
                for patternPrefix in allMatchingPatternPrefixes.sorted() {
                    let fileExtensionsForPrefix = fileExtensionsToMatchingPatternPrefixes.filter({ $0.value.contains(patternPrefix) }).keys
                    let allExtensionsAreExcluded = fileExtensionsForPrefix.count == locFileExtensions.count
                    let onlyXCStringsIsExcluded = fileExtensionsForPrefix.count == 1 && fileExtensionsForPrefix.first == "xcstrings"

                    if allExtensionsAreExcluded || onlyXCStringsIsExcluded {
                        // If all extensions are excluded, there is nothing to warn about.
                        // If only xcstrings is excluded, that's also fine since that's the modern file type and it's less likely they will be reverting back to .strings.
                        continue
                    }

                    let nonMatchingExtensions = locFileExtensions.subtracting(fileExtensionsForPrefix)
                    assert(!nonMatchingExtensions.isEmpty)

                    // Oftentimes, nonMatchingExtensions will include stringsdict.
                    // We definitely want to warn in that case because stringsdict can be added in localization project builds even when they weren't otherwise in the project.

                    if nonMatchingExtensions == ["xcstrings"] && !generalScope.evaluate(BuiltinMacros.LOCALIZATION_PREFERS_STRING_CATALOGS) {
                        // .strings and .stringsdict are properly excluded, but not .xcstrings.
                        // In this case, we only want to yell if the project has actually adopted xcstrings in such a way that there could be an xcstrings file that would match this pattern.

                        // Looks like LOCALIZATION_PREFERS_STRING_CATALOGS is NO, so the only way there might be an xcstrings file matching this pattern is if there is an explicit one in the project.
                        let patternToMatch = String(patternPrefix) + ".xcstrings"
                        let xcstringsPaths = xcstringsPathsInTarget(scope: generalScope)
                        if xcstringsPaths == nil /* must be project-level */ || !(xcstringsPaths!.contains(where: { $0.matchesFilenamePattern(patternToMatch) })) {
                            // We might be building settings for a project and not a target, in which case we don't need to warn about missing xcstrings exclusion.
                            // We'll defer that to when we build settings for targets.

                            // OR maybe we are building settings for a target but that target didn't contain any matching xcstrings files anyway.
                            // In that case, don't warn about missing xcstrings exclusion since it doesn't matter.
                            continue
                        }
                    }

                    func formattedList(_ list: [String]) -> String {
                        switch list.count {
                        case 0:
                            return ""
                        case 1:
                            return list[0]
                        case 2:
                            return "\(list[0]) and \(list[1])"
                        default:
                            return list.dropLast().joined(separator: ", ") + ", and \(list.last!)"
                        }
                    }

                    let message = "The pattern with prefix '\(patternPrefix)' in \(setting.name) at the \(levelName) level matches \(formattedList(fileExtensionsForPrefix.sorted())) files, but not \(formattedList(nonMatchingExtensions.sorted())) files. Consider using a file extension pattern such as '.*' or '.*strings*'"
                    if warnLevel == .yes {
                        warnings.append(message)
                    } else if warnLevel == .yesError {
                        errors.append(message)
                    }
                }
            }
        }

        analyzePatterns(in: BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES)
        analyzePatterns(in: BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES)
    }

    // FIXME: Eliminate this, or find a home for it. It is also calling a rather inefficient method.
    private func createTableFromUserSettings(_ settings: [String: String]) -> MacroValueAssignmentTable {
        do {
            return try userNamespace.parseTable(settings, allowUserDefined: true)
        } catch {
            self.errors.append("unable to parse user build settings: '\(error)'")
            return MacroValueAssignmentTable(namespace: userNamespace)
        }
    }
}

extension BuildConfiguration {
    /// This will either return the name of the used configuration or if we are building a package target with an override, it will return the name of the configuration regular targets are building with. This ensures that package targets build into the same location as regular targets even when an override is being used.
    func effectiveName(for project: Project, parameters: BuildParameters) -> String {
        if let `default` = parameters.configuration, parameters.packageConfigurationOverride != nil, project.isPackage {
            return `default`
        } else {
            return name
        }
    }
}

extension StandardTarget {
    public func linksAnyFramework(names: [String], in scope: MacroEvaluationScope, workspaceContext: WorkspaceContext, specLookupContext: any SpecLookupContext, boundSettings: [StringListMacroDeclaration:[String]], filePathResolver: FilePathResolver) -> Bool {
        // Look for an explicit reference to any of the frameworks in the target's linked frameworks
        let frameworkNames = names.map({ return "\($0).framework" })
        if let frameworkFileType = specLookupContext.lookupFileType(identifier: "wrapper.framework"),
            let buildPhase = frameworksBuildPhase,
            buildPhase.containsFiles(ofType: frameworkFileType, workspaceContext.workspace, specLookupContext, scope, filePathResolver, { fileRef in
                if let basename = fileRef.path.asLiteralString.map(Path.init)?.basename {
                    return frameworkNames.contains(basename)
                }
                return false
            }) {
            return true
        }

        // Look for a linkage to any of the frameworks in the target's linker flags

        let ldFlagsMacros = [BuiltinMacros.OTHER_LDFLAGS, BuiltinMacros.PRODUCT_SPECIFIC_LDFLAGS]
        let frameworkArgs = ["-framework", "-weak_framework", "-reexport_framework", "-lazy_framework"]

        return ldFlagsMacros.contains(where: {
            guard let value = boundSettings[$0] else { return false }
            return frameworkArgs.contains(where: { flag in
                return names.contains(where: { name in
                    return value.contains([flag, name])
                })
            })
        })
    }
}

extension Settings {
    /// Temporary hack to phase in support for running InstallAPI even for targets skipped for installing.
    /// <rdar://problem/70499898> Remove INSTALLAPI_IGNORE_SKIP_INSTALL and enable by default
    public func allowInstallAPIForTargetsSkippedInInstall(in scope: MacroEvaluationScope) -> Bool {
        return !scope.evaluate(BuiltinMacros.SKIP_INSTALL) || scope.evaluate(BuiltinMacros.INSTALLAPI_IGNORE_SKIP_INSTALL) || scope.evaluate(BuiltinMacros.BUILD_PACKAGE_FOR_DISTRIBUTION)
    }
}

extension OperatingSystem {
    public var xcodePlatformName: String {
        get throws {
            switch self {
            case .macOS:
                return "macosx"
            case let .iOS(simulator):
                return simulator ? "iphonesimulator" : "iphoneos"
            case let .tvOS(simulator):
                return simulator ? "appletvsimulator" : "appletvos"
            case let .watchOS(simulator):
                return simulator ? "watchsimulator" : "watchos"
            case let .visionOS(simulator):
                return simulator ? "xrsimulator" : "xros"
            case .windows:
                return "windows"
            case .linux:
                return "linux"
            case .android:
                return "android"
            case .unknown:
                throw StubError.error("unknown platform")
            }
        }
    }
}

extension MacroEvaluationScope {
    public var previewStyle: PreviewStyle? {
        switch (evaluate(BuiltinMacros.ENABLE_PREVIEWS), evaluate(BuiltinMacros.ENABLE_XOJIT_PREVIEWS)) {
        case (true, false):
            return .dynamicReplacement
        case (false, true):
            return .xojit
        case (true, true):
            assertionFailure("XOJIT and dynamic replacement previews cannot be enabled simultaneously")
            return nil
        case (false, false):
            return nil
        }
    }
}
