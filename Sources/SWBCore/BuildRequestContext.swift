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

public import SWBProtocol
public import SWBUtil
public import SWBMacro
import Foundation

/// Encapsulates the context relevant to the work needed to construct a build description for an incoming build request.
///
/// This object manages caches which are relevant to the lifetime of that build request + build description.
public final class BuildRequestContext: Sendable {
    private let workspaceContext: WorkspaceContext

    public init(workspaceContext: WorkspaceContext) {
        self.workspaceContext = workspaceContext
    }

    private let filesSignatureCache = Registry<[Path], Lazy<FilesSignature>>()

    /// Gets the file signature for the specified set of paths. This is cached for the lifetime of the build request.
    private func filesSignature(for paths: [Path]) -> FilesSignature {
        filesSignatureCache.getOrInsert(paths) { workspaceContext.fs.filesSignature(paths) }
    }

    public var fs: any FSProxy {
        workspaceContext.fs
    }

    /// Returns the path in which the `XCBuildData` directory will live. That location is used to cache build descriptions for a particular workspace and request, the manifest, and the `build.db` database for llbuild.
    package func cacheDirectory(for request: BuildRequest) throws -> Path {
        // Make this more efficient for index queries if the index build arena is enabled.
        if request.enableIndexBuildArena, let arena = request.parameters.arena {
            return arena.buildIntermediatesPath
        }

        // Get settings for the sole project if there is only one, otherwise the workspace-global settings.
        let settings: Settings = {
            if let onlyProject = workspaceContext.workspace.projects.only {
                return getCachedSettings(request.parameters, project: onlyProject)
            }
            // FIXME: For project-style builds (no workspace arena), we shouldn't grab the first project, because "first" doesn't have any special meaning. Ideally we'd pick the top-level project specifically. However, that is not currently possible due to the fact that the PIF is flattened. So we preserve existing behavior for now to avoid breaking the non-workspace, nested-projects use case.
            if let firstProject = workspaceContext.workspace.projects.first, !(request.parameters.arena?.buildIntermediatesPath.isAbsolute ?? false) {
                return getCachedSettings(request.parameters, project: firstProject)
            }
            return getCachedSettings(request.parameters)
        }()

        // This is an override to specifically enable a legacy build location workflow for some projects (rdar://52005109). It should not be leveraged, relied upon, or in any way considered a good thing to build upon.
        let overrideDir = settings.globalScope.evaluate(BuiltinMacros.BUILD_DESCRIPTION_CACHE_DIR)
        if !overrideDir.isEmpty {
            return Path(overrideDir)
        }

        // NOTE: The way that `Path()` works is that any absolute paths provided via `join()` will essentially disregard the path information before it. This is subtle and *is* relied upon here by other places in the build system where `OBJROOT` is provided as an absolute path
        let objroot = settings.globalScope.evaluate(BuiltinMacros.SRCROOT).join(settings.globalScope.evaluate(BuiltinMacros.OBJROOT))
        if objroot.isAbsolute {
            return objroot
        }

        // Fall back to the arena info if the objroot wasn't absolute. This can happen if we have a Settings for a workspace and SRCROOT therefore isn't absolute itself.
        if let arena = request.parameters.arena {
            guard arena.buildIntermediatesPath.isAbsolute else {
                throw StubError.error("The workspace arena does not have an absolute build intermediates path to contain the build cache directory.")
            }
            return arena.buildIntermediatesPath
        }

        throw StubError.error("There is no workspace arena to determine the build cache directory path.")
    }

    // Cache toolset.json access per-build request. Don't cache at the session level because toolsets may change between builds.
    private let toolsetCache = Registry<Path, SwiftSDK.Toolset>()
    public func loadToolset(_ path: Path) throws -> SwiftSDK.Toolset {
        try toolsetCache.getOrInsert(path) {
            let data = try Data(fs.read(path))
            let toolset = try JSONDecoder().decode(SwiftSDK.Toolset.self, from: data)
            guard toolset.schemaVersion == "1.0" else {
                throw StubError.error("Unknown schema version \(toolset.schemaVersion) for toolset at \(path.str)")
            }
            return toolset
        }
    }

    public func keepAliveSettingsCache<R>(_ f: () throws -> R) rethrows -> R {
        try workspaceContext.workspaceSettingsCache.keepAlive(f)
    }

    public func keepAliveSettingsCache<R>(_ f: () async throws -> R) async rethrows -> R {
        try await workspaceContext.workspaceSettingsCache.keepAlive(f)
    }

    /// Get the cached settings for the given parameters, without considering the context of any project/target.
    package func getCachedSettings(_ parameters: BuildParameters) -> Settings {
        workspaceContext.workspaceSettingsCache.getCachedSettings(parameters, buildRequestContext: self, purpose: .build, filesSignature: filesSignature(for:))
    }

    /// Get the cached settings for the given parameters and project.
    package func getCachedSettings(_ parameters: BuildParameters, project: Project, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs? = nil) -> Settings {
        getCachedSettings(parameters, project: project, target: nil, purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: nil, artifactBundleInfo: nil, ipiClangModuleNames: nil)
    }

    /// Get the cached settings for the given parameters and target.
    package func getCachedSettings(_ parameters: BuildParameters, target: Target, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs? = nil, impartedBuildProperties: [ImpartedBuildProperties]? = nil, artifactBundleInfo: [ArtifactBundleInfo]? = nil, ipiClangModuleNames: [String]? = nil) -> Settings {
        getCachedSettings(parameters, project: workspaceContext.workspace.project(for: target), target: target, purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildProperties, artifactBundleInfo: artifactBundleInfo, ipiClangModuleNames: ipiClangModuleNames)
    }

    /// Private method to get the cached settings for the given parameters, project, and target.
    ///
    /// - remark: This is private so that clients don't somehow call this with a project which doesn't match the target.  There are public methods covering this one.
    private func getCachedSettings(_ parameters: BuildParameters, project: Project, target: Target?, purpose: SettingsPurpose = .build, provisioningTaskInputs: ProvisioningTaskInputs?, impartedBuildProperties: [ImpartedBuildProperties]?, artifactBundleInfo: [ArtifactBundleInfo]?, ipiClangModuleNames: [String]?) -> Settings {
        workspaceContext.workspaceSettingsCache.getCachedSettings(parameters, project: project, target: target, purpose: purpose, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildProperties, artifactBundleInfo: artifactBundleInfo, ipiClangModuleNames: ipiClangModuleNames, buildRequestContext: self, filesSignature: filesSignature(for:))
    }

    @_spi(Testing) public func getCachedMacroConfigFile(_ path: Path, project: Project? = nil, context: MacroConfigLoadContext) -> MacroConfigInfo {
        workspaceContext.workspaceSettingsCache.getCachedMacroConfigFile(path, project: project, context: context, filesSignature: filesSignature(for:))
    }

    @_spi(Testing) public func loadSettingsFromConfig(data: ByteString, path: Path?, namespace: MacroNamespace, searchPaths: [Path]) -> MacroConfigInfo {
        workspaceContext.macroConfigFileLoader.loadSettingsFromConfig(data: data, path: path, namespace: namespace, searchPaths: searchPaths, filesSignature: filesSignature(for:))
    }

    public func getCachedMachOInfo(at path: Path) throws -> MachOInfo {
        try workspaceContext.machOInfoCache.get(at: path, filesSignature: filesSignature(for: [path]))
    }

    public func getCachedXCFramework(at path: Path) throws -> XCFramework {
        try workspaceContext.xcframeworkCache.get(at: path, filesSignature: filesSignature(for: [path]))
    }

    public func getKnownTestingLibraryPathSuffixes() async -> [Path] {
        var suffixes: [Path] = []
        suffixes.append(contentsOf: [
            Path("libXCTestBundleInject.dylib"),
            Path("libXCTestSwiftSupport.dylib"),
            Path("lib_TestingInterop.dylib"),
        ])
        let frameworkNames = [
            "Testing",
            "_Testing_Foundation",
            "XCTAutomationSupport",
            "XCTestSupport",
            "XCTest",
            "XCTestCore",
            "XCUIAutomation",
            "XCUnit"
        ]

        suffixes.append(contentsOf: frameworkNames.flatMap { name in
            [Path("\(name).framework/\(name)"), Path("/\(name).framework/Versions/A/\(name)")]
        })

        for platformExtension in workspaceContext.core.pluginManager.extensions(of: PlatformInfoExtensionPoint.self) {
            suffixes.append(contentsOf: platformExtension.additionalKnownTestLibraryPathSuffixes())
        }
        return suffixes
    }
}

extension BuildRequestContext {
    /// Certain file types allow multiple files with the same name, in which case we unique the output file.
    private static let fileTypesWhichUseUniquing = [ "sourcecode.c.c", "sourcecode.c.objc", "sourcecode.cpp.cpp", "sourcecode.cpp.objcpp", "sourcecode.asm" ]

    private func computeOutputParameters(for input: FileToBuild, command: BuildCommand, settings: Settings, lookup: @escaping (MacroDeclaration) -> (MacroExpression?)) -> (Path, String) {
        let outputDir = settings.globalScope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, lookup: lookup)
        switch command {
        case .generateAssemblyCode:
            return (outputDir, ".s")
        case .generatePreprocessedFile:
            return (outputDir, input.fileType.languageDialect?.preprocessedSourceFileNameSuffix ?? "")
        default:
            // <rdar://44880449> Make single-file compilation machinery more generic
            if input.fileType.conformsTo(identifier: SpecRegistry.metalFileTypeIdentifier) {
                return (settings.globalScope.evaluate(BuiltinMacros.TARGET_TEMP_DIR, lookup: lookup).join("Metal"), ".air")
            }

            // Check Clang static analyzer flag last, because it should not take precedence over single file actions like assembly/preprocess
            if settings.globalScope.evaluate(BuiltinMacros.RUN_CLANG_STATIC_ANALYZER, lookup: lookup) {
                return (Path(settings.globalScope.evaluate(ClangStaticAnalyzerSpec.outputFileExpression, lookup: lookup)), ".plist")
            }

            return (outputDir, ".o")
        }
    }

    /// Compute output paths for a source file in a specific target. There may be multiple results if the build is a multi-arch build.
    public func computeOutputPaths(for inputPath: Path, workspace: Workspace, target: BuildRequest.BuildTargetInfo, command: BuildCommand, parameters: BuildParameters? = nil) -> [String] {
        let settings = getCachedSettings(parameters ?? target.parameters, target: target.target)
        let effectiveArchs = settings.globalScope.evaluate(BuiltinMacros.ARCHS)

        // We only generate analyze, assemble and preprocess commands for the preferred architecture.
        let usedArchs: [String]
        if let preferredArch = settings.preferredArch {
            usedArchs = [preferredArch]
        } else {
            usedArchs = effectiveArchs
        }

        let currentPlatformFilter = PlatformFilter(settings.globalScope)

        // FIXME: It is a bit unfortunate that we need to compute all this for the `uniquingSuffix` behavior.
        var sourceCodeFileToBuildableReference = [Path:Reference]()
        if let target = target.target as? StandardTarget {
            if let buildableReferences = try! target.sourcesBuildPhase?.buildFiles.compactMap({ (buildFile) -> Reference? in
                guard currentPlatformFilter.matches(buildFile.platformFilters) else { return nil }
                return try workspace.resolveBuildableItemReference(buildFile.buildableItem)
            }) {
                for ref in buildableReferences {
                    let sourceCodeFile = settings.filePathResolver.resolveAbsolutePath(ref)
                    sourceCodeFileToBuildableReference[sourceCodeFile] = ref
                }
            }
        }

        // Use lowercased basenames for duplicate detection to match FilesBasedBuildPhaseTaskProducer.groupAndAddTasksForFiles.
        let sourceCodeBasenames = sourceCodeFileToBuildableReference.keys.map { $0.basenameWithoutSuffix.lowercased() }
        return usedArchs.map({ arch in
            let lookup = { return $0 == BuiltinMacros.CURRENT_ARCH ? settings.globalScope.namespace.parseLiteralString(arch) : nil }
            do {
                let file = inputPath
                let ref = sourceCodeFileToBuildableReference[file]
                let specLookupContext = SpecLookupCtxt(specRegistry: workspaceContext.core.specRegistry, platform: settings.platform)
                let input: FileToBuild
                if let ref, let fileRef = ref as? FileReference {
                    input = FileToBuild(absolutePath: file, fileType: specLookupContext.lookupFileType(identifier: fileRef.fileTypeIdentifier) ?? specLookupContext.lookupFileType(identifier: "file")!)
                } else {
                    input = FileToBuild(absolutePath: file, inferringTypeUsing: specLookupContext)
                }
                let (outputDir, outputSuffix) = computeOutputParameters(for: input, command: command, settings: settings, lookup: lookup)
                let uniquingSuffix: String
                if let ref, sourceCodeBasenames.filter({ $0 == file.basenameWithoutSuffix.lowercased() }).count > 1 && Self.fileTypesWhichUseUniquing.contains(input.fileType.identifier) {
                    uniquingSuffix = "-" + BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: file)
                } else {
                    uniquingSuffix = ""
                }
                return outputDir.join(file.basenameWithoutSuffix).str + "\(uniquingSuffix)\(outputSuffix)"
            }
        })
    }

    /// Given the targets configured for multiple platforms, select the most appropriate one for the index service to use.
    public func selectConfiguredTargetForIndex(_ lhs: ConfiguredTarget, _ rhs: ConfiguredTarget, hasEnabledIndexBuildArena: Bool, runDestination: RunDestinationInfo?) -> ConfiguredTarget {
        struct PlatformAndSDKVariant {
            let platform: Platform?
            let sdkVariant: String?
        }
        func platformAndSDKVariant(for target: ConfiguredTarget) -> PlatformAndSDKVariant {
            if hasEnabledIndexBuildArena,
               let activeRunDestination = target.parameters.activeRunDestination,
               let platform = workspaceContext.core.platformRegistry.lookup(name: activeRunDestination.platform) {
                // Configured targets include their platform in parameters, we can use it directly and avoid the expense of `getCachedSettings()` calls.
                // If in future `ConfiguredTarget` carries along an instance of its Settings, we can avoid this check and go back to using `Settings` without the cost of `getCachedSettings`.
                return PlatformAndSDKVariant(platform: platform, sdkVariant: activeRunDestination.sdkVariant)
            } else {
                let settings = getCachedSettings(target.parameters, target: target.target)
                return PlatformAndSDKVariant(platform: settings.platform, sdkVariant: settings.sdkVariant?.name)
            }
        }

        let lhsPlatform = platformAndSDKVariant(for: lhs)
        let rhsPlatform = platformAndSDKVariant(for: rhs)

        func matchesPlatform(_ platformAndVar: PlatformAndSDKVariant, platformName: String, sdkVariant: String?) -> Bool {
            guard platformAndVar.platform?.name == platformName else { return false }
            guard let settingsSDKVar = platformAndVar.sdkVariant, let sdkVariant else { return true }
            return settingsSDKVar == sdkVariant
        }

        func selectWithoutRunDestination() -> ConfiguredTarget {
            if lhsPlatform.platform?.name == rhsPlatform.platform?.name {
                guard let lhsSDKVar = lhsPlatform.sdkVariant else { return rhs }
                guard let rhsSDKVar = rhsPlatform.sdkVariant else { return lhs }
                // Prefer non-Catalyst over Catalyst.
                if lhsSDKVar == MacCatalystInfo.sdkVariantName { return rhs }
                if rhsSDKVar == MacCatalystInfo.sdkVariantName { return lhs }
                // It doesn't matter much which variant to choose, just be consistent about it.
                return lhsSDKVar <= rhsSDKVar ? lhs : rhs
            }
            func order(for platformAndVar: PlatformAndSDKVariant) -> Int {
                // The order of this is significant, if the selected run destination doesn’t match the compared targets, the preferred target will be the one with the platform in this order.
                // The rationale for the order is sim>device because usually you do development using simulator, and iphone>appletv>watch, because there must be deterministic order, and this seems as good of a choice as any.
                let orderedSDKs: [(String, String?)] = [
                    ("macosx", "macos"),
                    ("iphonesimulator", nil),
                    ("iphoneos", nil),
                    ("appletvsimulator", nil),
                    ("appletvos", nil),
                    ("watchsimulator", nil),
                    ("watchos", nil),
                    ("macosx", "iosmac"),
                ]
                return orderedSDKs.firstIndex(where: { (curPlatform, curSDKVar) -> Bool in
                    return matchesPlatform(platformAndVar, platformName: curPlatform, sdkVariant: curSDKVar)
                }) ?? orderedSDKs.count
            }
            return order(for: lhsPlatform) <= order(for: rhsPlatform) ? lhs : rhs
        }

        guard let destination = runDestination else {
            return selectWithoutRunDestination()
        }

        let platform = destination.platform
        let sdkVariant = destination.sdkVariant
        if matchesPlatform(lhsPlatform, platformName: platform, sdkVariant: sdkVariant) { return lhs }
        if matchesPlatform(rhsPlatform, platformName: platform, sdkVariant: sdkVariant) { return rhs }
        guard let destinationPlatform = workspaceContext.core.platformRegistry.lookup(name: platform) else {
            return selectWithoutRunDestination()
        }
        if lhsPlatform.platform?.familyName != rhsPlatform.platform?.familyName {
            func matchesFamily(_ platformAndVar: PlatformAndSDKVariant) -> Bool {
                return platformAndVar.platform?.familyName == destinationPlatform.familyName
            }
            if matchesFamily(lhsPlatform) { return lhs }
            if matchesFamily(rhsPlatform) { return rhs }
        }
        if destinationPlatform.isSimulator && lhsPlatform.platform?.isSimulator != rhsPlatform.platform?.isSimulator {
            return lhsPlatform.platform?.isSimulator == true ? lhs : rhs
        }
        return selectWithoutRunDestination()
    }
}
