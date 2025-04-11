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

package import Foundation

@_spi(Testing) package import SWBCore

package import SWBUtil
package import SWBMacro

package struct MockCommandProducer: CommandProducer, Sendable {
    let core: Core
    package let platform: Platform?
    package let sdk: SDK?
    package let sdkVariant: SDKVariant?
    package var specRegistry: SpecRegistry {
        return core.specRegistry
    }
    package let productType: ProductTypeSpec?
    package let executableSearchPaths: StackedSearchPath
    package let toolchains: [Toolchain]
    package let discoveredCommandLineToolSpecInfoCache = DiscoveredCommandLineToolSpecInfoCache(processExecutionCache: ProcessExecutionCache())
    package var userPreferences: UserPreferences {
        UserPreferences.defaultForTesting
    }
    package var hostOperatingSystem: OperatingSystem {
        core.hostOperatingSystem
    }

    package init(core: Core, productTypeIdentifier: String, platform platformName: String?, useStandardExecutableSearchPaths: Bool = false, toolchain: Toolchain? = nil, fs: any FSProxy = localFS) throws {
        self.core = core
        let platform = platformName.map(core.platformRegistry.lookup(name:)) ?? nil
        self.platform = platform
        self.sdk = (platform?.sdkCanonicalName).map(core.sdkRegistry.lookup) ?? nil
        self.sdkVariant = self.sdk?.defaultVariant
        self.productType = try core.specRegistry.getSpec(productTypeIdentifier, domain: platform?.name ?? "") as ProductTypeSpec

        // Construct some executable search paths if instructed, by mimicking part of what Settings.createExecutableSearchPaths() does, specifically:
        //  - Add from __XCODE_BUILT_PRODUCTS_DIR_PATHS, if present.
        //  - Add the binary paths for the default toolchain.
        //  - Add the platform search paths.
        //  - Add the standard search paths.
        // But we don't add the entries from __XCODE_BUILT_PRODUCTS_DIR_PATHS or from PATH, to ensure a consistent test experience.
        // The filesystem in which to search is always the local file system.
        var paths = OrderedSet<Path>()
        if useStandardExecutableSearchPaths {
            for path in core.toolchainRegistry.defaultToolchain?.executableSearchPaths.paths ?? [] {
                paths.append(path)
            }
            for path in platform?.executableSearchPaths.paths ?? [] {
                paths.append(path)
            }
            switch core.developerPath {
            case .xcode(let path), .fallback(let path):
                paths.append(path.join("usr").join("bin"))
                paths.append(path.join("usr").join("local").join("bin"))
            case .swiftToolchain(let path, xcodeDeveloperPath: let xcodeDeveloperPath):
                paths.append(path.join("usr").join("bin"))
                paths.append(path.join("usr").join("local").join("bin"))
                if let xcodeDeveloperPath {
                    paths.append(xcodeDeveloperPath.join("usr").join("bin"))
                    paths.append(xcodeDeveloperPath.join("usr").join("local").join("bin"))
                }
            }
        }
        self.executableSearchPaths = StackedSearchPath(paths: [Path](paths), fs: fs)
        self.toolchains = toolchain.map { [$0] } ?? []

        // Work around compiler (can't use self.getSpec before self initialization)
        func getSpec<T: Spec>(_ identifier: String) throws -> T {
            try core.specRegistry.getSpec(identifier, domain: platform?.name ?? "")
        }

        func getSpec<T: Spec & IdentifiedSpecType>() throws -> T {
            try getSpec(T.identifier)
        }

        self.clangSpec = try getSpec() as ClangCompilerSpec
        self.clangAssemblerSpec = try getSpec() as ClangAssemblerSpec
        self.clangPreprocessorSpec = try getSpec() as ClangPreprocessorSpec
        self.clangStaticAnalyzerSpec = try getSpec() as ClangStaticAnalyzerSpec
        self.clangModuleVerifierSpec = try getSpec() as ClangModuleVerifierSpec
        self.diffSpec = try getSpec("com.apple.build-tools.diff") as CommandLineToolSpec
        self.stripSpec = try getSpec("com.apple.build-tools.strip") as StripToolSpec
        self.ldLinkerSpec = try getSpec() as LdLinkerSpec
        self.libtoolLinkerSpec = try getSpec() as LibtoolLinkerSpec
        self.lipoSpec = try getSpec() as LipoToolSpec
        self.codesignSpec = try getSpec("com.apple.build-tools.codesign") as CodesignToolSpec
        self.copySpec = try getSpec() as CopyToolSpec
        self.copyPngSpec = try getSpec("com.apple.build-tasks.copy-png-file") as CommandLineToolSpec
        self.copyTiffSpec = try getSpec("com.apple.build-tasks.copy-tiff-file") as CommandLineToolSpec
        self.writeFileSpec = try getSpec("com.apple.build-tools.write-file") as WriteFileSpec
        self.createBuildDirectorySpec = try getSpec("com.apple.tools.create-build-directory") as CreateBuildDirectorySpec
        self.unifdefSpec = try getSpec("public.build-task.unifdef") as UnifdefToolSpec
        self.mkdirSpec = try getSpec("com.apple.tools.mkdir") as MkdirToolSpec
        self.swiftCompilerSpec = try getSpec() as SwiftCompilerSpec
        self.processSDKImportsSpec = try getSpec(ProcessSDKImportsSpec.identifier) as ProcessSDKImportsSpec
    }

    package let specDataCaches = Registry<Spec, any SpecDataCache>()

    package var configuredTarget: ConfiguredTarget? {
        return nil
    }

    package var preferredArch: String? {
        return nil
    }

    package var sparseSDKs: [SDK] {
        return []
    }

    package let clangSpec: ClangCompilerSpec
    package let clangAssemblerSpec: ClangCompilerSpec
    package let clangPreprocessorSpec: ClangCompilerSpec
    package let clangStaticAnalyzerSpec: ClangCompilerSpec
    package let clangModuleVerifierSpec: ClangCompilerSpec
    package let diffSpec: CommandLineToolSpec
    package let stripSpec: StripToolSpec
    package let ldLinkerSpec: LdLinkerSpec
    package let libtoolLinkerSpec: LibtoolLinkerSpec
    package let lipoSpec: LipoToolSpec
    package let codesignSpec: CodesignToolSpec
    package let copySpec: CopyToolSpec
    package let copyPngSpec: CommandLineToolSpec
    package let copyTiffSpec: CommandLineToolSpec
    package let writeFileSpec: WriteFileSpec
    package let createBuildDirectorySpec: CreateBuildDirectorySpec
    package let unifdefSpec: UnifdefToolSpec
    package let mkdirSpec: MkdirToolSpec
    package let swiftCompilerSpec: SwiftCompilerSpec
    package let processSDKImportsSpec: ProcessSDKImportsSpec

    package var defaultWorkingDirectory: Path {
        return Path("/tmp")
    }

    package var moduleInfo: ModuleInfo? {
        return nil
    }

    package var needsVFS: Bool {
        return true
    }

    package var generateAssemblyCommands: Bool {
        return false
    }

    package var generatePreprocessCommands: Bool {
        return false
    }

    package var filePathResolver: FilePathResolver {
        fatalError("tests should never access CommandProducer.filePathResolver")
    }

    package func lookupReference(for guid: String) -> Reference? {
        fatalError("unexpected API use")
    }

    package var signingSettings: Settings.SigningSettings? {
        return nil
    }

    package var xcodeProductBuildVersion: ProductBuildVersion? {
        return nil
    }

    package func expandedSearchPaths(for items: [String], scope: MacroEvaluationScope) -> [String] {
        return items
    }

    package func onDemandResourcesAssetPack(for tags: ODRTagSet) -> ODRAssetPackInfo? {
        return nil
    }

    package func targetSwiftDependencyScopes(for target: ConfiguredTarget, arch: String, variant: String) -> [MacroEvaluationScope] {
        return []
    }

    package var swiftMacroImplementationDescriptors: Set<SWBCore.SwiftMacroImplementationDescriptor>? {
        nil
    }

    package func supportsEagerLinking(scope: MacroEvaluationScope) -> Bool {
        false
    }

    package func projectHeaderInfo(for target: Target) -> ProjectHeaderInfo? {
        return nil
    }

    package func discoveredCommandLineToolSpecInfo(_ delegate: any SWBCore.CoreClientTargetDiagnosticProducingDelegate, _ toolName: String, _ path: Path, _ process: @Sendable (Data) async throws -> any SWBCore.DiscoveredCommandLineToolSpecInfo) async throws -> any SWBCore.DiscoveredCommandLineToolSpecInfo {
        try await discoveredCommandLineToolSpecInfoCache.run(delegate, toolName, path, process)
    }

    package func discoveredCommandLineToolSpecInfo(_ delegate: any SWBCore.CoreClientTargetDiagnosticProducingDelegate, _ toolName: String?, _ commandLine: [String], _ process: @Sendable (Processes.ExecutionResult) async throws -> any SWBCore.DiscoveredCommandLineToolSpecInfo) async throws -> any SWBCore.DiscoveredCommandLineToolSpecInfo {
        try await discoveredCommandLineToolSpecInfoCache.run(delegate, toolName, commandLine, process)
    }

    package func shouldUseSDKStatCache() async -> Bool {
        false
    }

    package var canConstructAppIntentsMetadataTask: Bool {
        return false
    }

    package var canConstructAppIntentsSSUTask: Bool {
        return false
    }

    package var targetRequiredToBuildForIndexing: Bool {
        return false
    }

    package var targetShouldBuildModuleForInstallAPI: Bool {
        false
    }

    package var supportsCompilationCaching: Bool {
        false
    }

    package var systemInfo: SystemInfo? {
        return nil
    }
    package func lookupLibclang(path: SWBUtil.Path) -> (libclang: SWBCore.Libclang?, version: Version?) {
        (nil, nil)
    }
    package func lookupPlatformInfo(platform: BuildVersion.Platform) -> (any PlatformInfoProvider)? {
        core.lookupPlatformInfo(platform: platform)
    }
}
