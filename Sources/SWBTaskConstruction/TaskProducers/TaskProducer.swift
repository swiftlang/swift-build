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
public import SWBCore
import struct SWBProtocol.BuildOperationTaskEnded
public import Foundation
public import SWBMacro

/// A `TaskProducer` has two distinct phases that are used to create the necessary planning work.
enum TaskProducerPhase {
    /// Used to denote that the task producer is not currently under any particular phase.
    case none

    /// The planning phase allows all task producers to add information to their `TaskProducerContext` via the `prepare()` method. This allows information to be shared from one task producer to another without needing to create any direct dependency ordering. The only guarantee for ordering is that `generateTasks()` will not be called before all of the task producers have finished with their `planning` phase.
    case planning

    /// The task generation phase allows all of the task producers to create their respective tasks.
    case taskGeneration
}

/// A TaskProducer embodies a set of work which needs to be done create the tasks which, when run, will generate all or part of the product of a ProductPlan.
package protocol TaskProducer
{
    /// Generate the provisional tasks for this task producer.
    static func provisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]

    /// Immutable data available to the task producer.
    var context: TaskProducerContext { get }

    /// Additional paths which invalidate the build description
    var invalidationPaths: [Path] { get }

    /// Generates the tasks to run.
    func generateTasks() async -> [any PlannedTask]

    /// Allows for tasks to pre-plan any work that needs to be done, primarily for exposure to other task producers.
    func prepare() async
}

extension TaskProducer
{
    package static func provisionalTasks(_ settings: Settings) -> [String: ProvisionalTask] { return [:] }

    /// By default, most task producers should not need to make use of this functionality.
    package func prepare() async {}
}

/// Context of immutable data available to a task producer.
///
/// This class configures the provisional tasks used by the producers.
public class TaskProducerContext: StaleFileRemovalContext, BuildFileResolution
{
    /// The workspace context.
    public let workspaceContext: WorkspaceContext

    /// The configured target the task producer is creating tasks for.
    public let configuredTarget: ConfiguredTarget?

    /// The current phase the task producer is in.
    var phase: TaskProducerPhase = .none

    /// The project this context is for.
    let project: Project?

    /// The high-level global build information.
    package let globalProductPlan: GlobalProductPlan

    var dynamicallyBuildingTargets: Set<Target> {
        return globalProductPlan.dynamicallyBuildingTargets
    }

    public var globalTargetInfoProvider: any GlobalTargetInfoProvider {
        return globalProductPlan
    }

    /// The delegate to use for creating tasks.
    ///
    /// This is private because clients should only interact with it via the exposed forwarding methods. This ensures that constraints on task construction (e.g., attachment to the target or phase ordering nodes) are followed.
    fileprivate let delegate: any TaskPlanningDelegate

    /// Tasks that mark that the 'prepare-for-index' module content output of a target is ready.
    /// This is only getting populated for an index build.
    var preparedForIndexModuleContentTasks: [any PlannedTask] = []

    // File type specs corresponding to compilation requirements
    let compilationRequirementOutputFileTypes: [FileTypeSpec]

    /// The build settings the task producer should use.
    public let settings: Settings

    /// Provisional tasks indexed by their identifying string.  This context is the owner of these provisional tasks.
    let provisionalTasks: [String: ProvisionalTask]

    /// The build rule set for file references (includes system rules as well as any custom rules).
    let buildRuleSet: any BuildRuleSet

    /// The default working directory path to use.
    ///
    /// This is the directory containing the .xcodeproj of the project for the configured target.
    public var defaultWorkingDirectory: Path

    // On-Demand Resources
    let onDemandResourcesEnabled: Bool
    let onDemandResourcesInitialInstallTags: Set<String>
    let onDemandResourcesPrefetchOrder: [String]
    private var onDemandResourcesAssetPacks: [ODRTagSet: ODRAssetPackInfo] = [:]
    private var onDemandResourcesAssetPackSubPaths: [String: Set<String>] = [:]

    /// The registry used for spec data caches.
    public var specDataCaches = Registry<Spec, any SpecDataCache>()

    /// The list of generated source files produced in this target.
    private var _generatedSourceFiles: [Path] = []

    /// The list of generated info plist additions produced in this target.
    private var _generatedInfoPlistContents: [Path] = []

    private var _generatedPrivacyContentFilePaths: [Path] = []

    /// The list of generated TBD files produced in this target.
    ///
    /// This is currently only ever done by Swift.
    private var _generatedTBDFiles: [String: [Path]] = [:]

    /// Whether a task planned by this producer has requested frontend command line emission.
    var emitFrontendCommandLines: Bool

    /// The map of architecture names to generated Swift Objective-C interface header files produced in this target.
    ///
    /// This is currently only ever done by Swift.
    private var _generatedSwiftObjectiveCHeaderFiles: [String: Path] = [:]

    /// The map of architecture names to generated Swift compile-time value metadata files produced in this target.
    /// Only ever done by Swift.
    private var _generatedGeneratedSwiftConstMetadataFiles: [String: [Path]] = [:]

    /// Virtual output nodes for shell script build phases that don't have any declared outputs.
    private var _shellScriptVirtualOutputs: [PlannedVirtualNode] = []

    /// The outputs of the tasks for this target prior to deferred task production.
    private var _outputsOfMainTaskProducers: [any PlannedNode] = []

    /// The map of top-level binaries path, keyed by variant.
    private var _producedBinaryPaths: [String: Path] = [:]

    /// The map of dSYM paths, keyed by variant.
    private var _producedDSYMPaths: [String: Path] = [:]

    /// The list of deferred task production blocks.
    private var _deferredProducers: [() async -> [any PlannedTask]] = []

    /// Whether we have transitioned to processing deferred tasks.
    private var _inDeferredMode = false

    /// Map of the files which are copied during the build, used for mapping diagnostics.
    private var _copiedPathMap: [String: Set<String>] = [:]

    /// The set of additional inputs for codesigning. These are tracked explicitly on the codesign task and are captured during the `.planning` phase.
    private var _additionalCodeSignInputs: OrderedSet<Path> = []

    /// Notes generated by the internal state of the task producer context.  These are harvested by the `BuildPlan` once all task producers have been run.
    ///
    /// This is an `OrderedSet` because the context is shared among all task producers for a target, and multiple producers could cause the same note to be emitted
    private(set) var notes = OrderedSet<String>()

    /// Warnings generated by the internal state of the task producer context.  These are harvested by the `BuildPlan` once all task producers have been run.
    ///
    /// This is an `OrderedSet` because the context is shared among all task producers for a target, and multiple producers could cause the same warning to be emitted
    private(set) var warnings = OrderedSet<String>()

    /// Errors generated by the internal state of the task producer context.  These are harvested by the `BuildPlan` once all task producers have been run.
    ///
    /// This is an `OrderedSet` because the context is shared among all task producers for a target, and multiple producers could cause the same error to be emitted .
    private(set) var errors = OrderedSet<String>()

    /// The queue used to serialize concurrent operations.
    let queue: SWBQueue

    // MARK: Bound Tool Specs.

    /// For a spec property which is represented by a `Result`, either return the concrete spec if it was found, or else log an error that an attempt to access a missing spec occurred and return nil.
    func specForResult<T: CommandLineToolSpec>(_ result: Result<T, any Error>) -> T? {
        switch result {
        case .success(let toolSpec):
            return toolSpec
        case .failure(let error):
            return queue.blocking_sync {
                errors.append("\(error)")
                return nil
            }
        }
    }

    public let appShortcutStringsMetadataCompilerSpec: AppShortcutStringsMetadataCompilerSpec
    let appleScriptCompilerSpec: CommandLineToolSpec
    public let clangSpec: ClangCompilerSpec
    public let clangAssemblerSpec: ClangCompilerSpec
    public let clangPreprocessorSpec: ClangCompilerSpec
    public let clangStaticAnalyzerSpec: ClangCompilerSpec
    public let clangModuleVerifierSpec: ClangCompilerSpec
    private let _clangStatCacheSpec: Result<ClangStatCacheSpec, any Error>
    var clangStatCacheSpec: ClangStatCacheSpec? { return specForResult(_clangStatCacheSpec) }
    public let codesignSpec: CodesignToolSpec
    private let _concatenateSpec: Result<ConcatenateToolSpec, any Error>
    var concatenateSpec: ConcatenateToolSpec? { return specForResult(_concatenateSpec) }
    public let copySpec: CopyToolSpec
    let copyPlistSpec: CommandLineToolSpec
    public let copyPngSpec: CommandLineToolSpec
    public let copyTiffSpec: CommandLineToolSpec
    let cppSpec: CommandLineToolSpec
    let createAssetPackManifestSpec: CreateAssetPackManifestToolSpec
    public let createBuildDirectorySpec: CreateBuildDirectorySpec
    public let diffSpec: CommandLineToolSpec
    let dsymutilSpec: DsymutilToolSpec
    let infoPlistSpec: InfoPlistToolSpec
    let mergeInfoPlistSpec: MergeInfoPlistSpec
    let launchServicesRegisterSpec: CommandLineToolSpec
    public let ldLinkerSpec: LdLinkerSpec
    public let libtoolLinkerSpec: LibtoolLinkerSpec
    public let lipoSpec: LipoToolSpec
    let masterObjectLinkSpec: CommandLineToolSpec
    public let mkdirSpec: MkdirToolSpec
    let modulesVerifierSpec: ModulesVerifierToolSpec
    let clangModuleVerifierInputGeneratorSpec: ClangModuleVerifierInputGeneratorSpec
    let productPackagingSpec: ProductPackagingToolSpec
    public let _registerExecutionPolicyExceptionSpec: Result<RegisterExecutionPolicyExceptionToolSpec, any Error>
    var registerExecutionPolicyExceptionSpec: RegisterExecutionPolicyExceptionToolSpec? { return specForResult(_registerExecutionPolicyExceptionSpec) }
    let setAttributesSpec: SetAttributesSpec
    let shellScriptSpec: ShellScriptToolSpec
    let signatureCollectionSpec: SignatureCollectionSpec
    public let stripSpec: StripToolSpec
    public let swiftCompilerSpec: SwiftCompilerSpec
    let swiftHeaderToolSpec: SwiftHeaderToolSpec
    let swiftStdlibToolSpec: SwiftStdLibToolSpec
    private let _swiftABICheckerToolSpec: Result<SwiftABICheckerToolSpec, any Error>
    var swiftABICheckerToolSpec: SwiftABICheckerToolSpec? { return specForResult(_swiftABICheckerToolSpec) }
    private let _swiftABIGenerationToolSpec: Result<SwiftABIGenerationToolSpec, any Error>
    var swiftABIGenerationToolSpec: SwiftABIGenerationToolSpec? { return specForResult(_swiftABIGenerationToolSpec) }
    let symlinkSpec: SymlinkToolSpec
    let tapiSpec: TAPIToolSpec
    let tapiMergeSpec: CommandLineToolSpec
    let tapiStubifySpec: CommandLineToolSpec
    let touchSpec: CommandLineToolSpec
    public let unifdefSpec: UnifdefToolSpec
    let validateEmbeddedBinarySpec: ValidateEmbeddedBinaryToolSpec
    let validateProductSpec: ValidateProductToolSpec
    let processXCFrameworkLibrarySpec: ProcessXCFrameworkLibrarySpec
    public let processSDKImportsSpec: ProcessSDKImportsSpec
    public let writeFileSpec: WriteFileSpec
    private let _documentationCompilerSpec: Result<CommandLineToolSpec, any Error>
    var documentationCompilerSpec: CommandLineToolSpec? { return specForResult(_documentationCompilerSpec) }
    private let _tapiSymbolExtractorSpec: Result<TAPISymbolExtractor, any Error>
    var tapiSymbolExtractor: TAPISymbolExtractor? { return specForResult(_tapiSymbolExtractorSpec) }
    private let _swiftSymbolExtractorSpec: Result<CommandLineToolSpec, any Error>
    var swiftSymbolExtractor: CommandLineToolSpec? { return specForResult(_swiftSymbolExtractorSpec) }
    private let _developmentAssetsSpec: Result<CommandLineToolSpec, any Error>
    public var developmentAssetsSpec: CommandLineToolSpec? { return specForResult(_developmentAssetsSpec) }
    private let _generateAppPlaygroundAssetCatalogSpec: Result<CommandLineToolSpec, any Error>
    var generateAppPlaygroundAssetCatalogSpec: CommandLineToolSpec? { return specForResult(_generateAppPlaygroundAssetCatalogSpec) }
    private let _realityAssetsCompilerSpec: Result<CommandLineToolSpec, any Error>
    public var realityAssetsCompilerSpec: CommandLineToolSpec? { return specForResult(_realityAssetsCompilerSpec) }

    /// Create the context for producing tasks independent of any particular target.
    ///
    /// - parameter workspaceContext: The containing workspace and context.
    /// - parameter globalProductPlan: The high-level global build information.
    /// - parameter delegate: The delegate to use for task construction.
    init(configuredTarget: ConfiguredTarget? = nil, workspaceContext: WorkspaceContext, globalProductPlan: GlobalProductPlan, delegate: any TaskPlanningDelegate)
    {
        self.workspaceContext = workspaceContext
        self.configuredTarget = configuredTarget
        self.globalProductPlan = globalProductPlan
        let settings = configuredTarget.map(globalProductPlan.getTargetSettings) ?? globalProductPlan.getWorkspaceSettings()
        self.settings = settings
        self.delegate = delegate
        self.queue = SWBQueue(label: "SWBTaskConstruction.TaskProducerContext.queue", qos: globalProductPlan.planRequest.buildRequest.qos, autoreleaseFrequency: .workItem)

        // Construct a build ruleset from the built-in system rules (which may be different for different platforms), and for any custom rules from the target.
        //
        // FIXME: We could cache these.
        let projectBuildRules: [(any BuildRuleCondition, any BuildRuleAction)]
        if let configuredTarget, let asStandardTarget = configuredTarget.target as? StandardTarget {
            let settings = self.settings
            projectBuildRules = asStandardTarget.buildRules.compactMap { rule in
                do {
                    // Create and return a build rule condition/action pair for the build rule item.  If a platform is given, any specifications mentioned in the build rule (such as file types or command line specs) will be bound from the point of view of that platform.
                    switch rule.actionSpecifier {
                    case let .compiler(compilerSpecificationIdentifier):
                        return try workspaceContext.core.createSpecBasedBuildRule(rule.inputSpecifier, compilerSpecificationIdentifier, platform: settings.platform)
                    case let .shellScript(contents, inputs, inputFileLists, outputs, outputFileLists, dependencyInfo, runOncePerArchitecture):
                        return try workspaceContext.core.createShellScriptBuildRule(rule.guid, rule.name, rule.inputSpecifier, contents, inputs, inputFileLists, outputs.map { ($0.path, $0.additionalCompilerFlags) }, outputFileLists, dependencyInfo, runOncePerArchitecture, platform: settings.platform, scope: settings.globalScope)
                    }
                } catch {
                    // FIXME: This probably should be an error, since the only case where the above calls can fail is if a spec is of the wrong type (code error) or fails to load (code error or potentially an Xcode installation issue). However, since projects could theoretically be relying on this behavior, we'll avoid changing it for now.
                    delegate.warning(.overrideTarget(configuredTarget), "\(error)")
                    return nil
                }
            }
        } else {
            projectBuildRules = []
        }
        self.buildRuleSet = LeveledBuildRuleSet(ruleSets: [
            BasicBuildRuleSet(rules: projectBuildRules),
            DisambiguatingBuildRuleSet(rules: settings.systemBuildRules, enableDebugActivityLogs: workspaceContext.userPreferences.enableDebugActivityLogs)
        ])

        self.project = configuredTarget.map { workspaceContext.workspace.project(for: $0.target) }
        self.defaultWorkingDirectory = settings.project?.sourceRoot ?? workspaceContext.workspace.path.dirname

        // On-Demand Resources
        self.onDemandResourcesEnabled = settings.globalScope.evaluate(BuiltinMacros.ENABLE_ON_DEMAND_RESOURCES)
        self.onDemandResourcesInitialInstallTags = Set(settings.globalScope.evaluate(BuiltinMacros.ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS))
        self.onDemandResourcesPrefetchOrder = settings.globalScope.evaluate(BuiltinMacros.ON_DEMAND_RESOURCES_PREFETCH_ORDER)

        // Populate the provisional tasks dictionary.
        self.provisionalTasks = configuredTarget?.target.provisionalTasks(settings) ?? [:]

        // Bind known tool specs.
        //
        // FIXME: These should really be bound even earlier, like in the spec cache. Or at least, we should throw here and just produce a dep graph error if any are missing.
        let domain = settings.platform?.name ?? ""
        self.appShortcutStringsMetadataCompilerSpec = workspaceContext.core.specRegistry.getSpec("com.apple.compilers.appshortcutstringsmetadata", domain: domain) as! AppShortcutStringsMetadataCompilerSpec
        self.appleScriptCompilerSpec = workspaceContext.core.specRegistry.getSpec("com.apple.compilers.osacompile", domain: domain) as! CommandLineToolSpec
        self.clangSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as ClangCompilerSpec
        self.clangAssemblerSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as ClangAssemblerSpec
        self.clangPreprocessorSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as ClangPreprocessorSpec
        self.clangStaticAnalyzerSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as ClangStaticAnalyzerSpec
        self.clangModuleVerifierSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as ClangModuleVerifierSpec
        self._clangStatCacheSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.compilers.clang-stat-cache") as ClangStatCacheSpec }
        self.codesignSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.codesign", domain: domain) as! CodesignToolSpec
        self._concatenateSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.concatenate") as ConcatenateToolSpec }
        self.copySpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as CopyToolSpec
        self.copyPlistSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tasks.copy-plist-file", domain: domain) as! CommandLineToolSpec
        self.copyPngSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tasks.copy-png-file", domain: domain) as! CommandLineToolSpec
        self.copyTiffSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tasks.copy-tiff-file", domain: domain) as! CommandLineToolSpec
        self.cppSpec = workspaceContext.core.specRegistry.getSpec("com.apple.compilers.cpp", domain: domain) as! CommandLineToolSpec
        self.createAssetPackManifestSpec = workspaceContext.core.specRegistry.getSpec(CreateAssetPackManifestToolSpec.identifier, domain: domain) as! CreateAssetPackManifestToolSpec
        self.createBuildDirectorySpec = workspaceContext.core.specRegistry.getSpec("com.apple.tools.create-build-directory", domain: domain) as! CreateBuildDirectorySpec
        self.diffSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.diff", domain: domain) as! CommandLineToolSpec
        self.dsymutilSpec = workspaceContext.core.specRegistry.getSpec("com.apple.tools.dsymutil", domain: domain) as! DsymutilToolSpec
        self.infoPlistSpec = workspaceContext.core.specRegistry.getSpec("com.apple.tools.info-plist-utility", domain: domain) as! InfoPlistToolSpec
        self.mergeInfoPlistSpec = workspaceContext.core.specRegistry.getSpec(MergeInfoPlistSpec.identifier, domain: domain) as! MergeInfoPlistSpec
        self.launchServicesRegisterSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tasks.ls-register-url", domain: domain) as! CommandLineToolSpec
        self.ldLinkerSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as LdLinkerSpec
        self.libtoolLinkerSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as LibtoolLinkerSpec
        self.lipoSpec = workspaceContext.core.specRegistry.getSpec("com.apple.xcode.linkers.lipo", domain: domain) as! LipoToolSpec
        self.masterObjectLinkSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.master-object-link", domain: domain) as! CommandLineToolSpec
        self.mkdirSpec = workspaceContext.core.specRegistry.getSpec("com.apple.tools.mkdir", domain: domain) as! MkdirToolSpec
        self.modulesVerifierSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.modules-verifier", domain: domain) as! ModulesVerifierToolSpec
        self.clangModuleVerifierInputGeneratorSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.module-verifier-input-generator", domain: domain) as! ClangModuleVerifierInputGeneratorSpec
        self.productPackagingSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as ProductPackagingToolSpec
        self._registerExecutionPolicyExceptionSpec = .init(workspaceContext, settings)
        self.setAttributesSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.set-attributes", domain: domain) as! SetAttributesSpec
        self.shellScriptSpec = workspaceContext.core.specRegistry.getSpec("com.apple.commands.shell-script", domain: domain) as! ShellScriptToolSpec
        self.signatureCollectionSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.signature-collection", domain: domain) as! SignatureCollectionSpec
        self.stripSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.strip", domain: domain) as! StripToolSpec
        self.swiftCompilerSpec = try! workspaceContext.core.specRegistry.getSpec(domain: domain) as SwiftCompilerSpec
        self.swiftHeaderToolSpec = workspaceContext.core.specRegistry.getSpec(SwiftHeaderToolSpec.identifier, domain: domain) as! SwiftHeaderToolSpec
        self.swiftStdlibToolSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.swift-stdlib-tool", domain: domain) as! SwiftStdLibToolSpec
        self._swiftABICheckerToolSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.swift-abi-checker", domain: domain) as SwiftABICheckerToolSpec }
        self._swiftABIGenerationToolSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.swift-abi-generation", domain: domain) as SwiftABIGenerationToolSpec }
        self.symlinkSpec = workspaceContext.core.specRegistry.getSpec("com.apple.tools.symlink", domain: domain) as! SymlinkToolSpec
        self.tapiSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.tapi.installapi", domain: domain) as! TAPIToolSpec
        self.tapiMergeSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.tapi.merge", domain: domain) as! CommandLineToolSpec
        self.tapiStubifySpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.tapi.stubify", domain: domain) as! CommandLineToolSpec
        self.touchSpec = workspaceContext.core.specRegistry.getSpec("com.apple.tools.touch", domain: domain) as! CommandLineToolSpec
        self.unifdefSpec = workspaceContext.core.specRegistry.getSpec("public.build-task.unifdef", domain: domain) as! UnifdefToolSpec
        self.validateEmbeddedBinarySpec = workspaceContext.core.specRegistry.getSpec("com.apple.tools.validate-embedded-binary-utility", domain: domain) as! ValidateEmbeddedBinaryToolSpec
        self.validateProductSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.platform.validate", domain: domain) as! ValidateProductToolSpec
        self.processXCFrameworkLibrarySpec = workspaceContext.core.specRegistry.getSpec(ProcessXCFrameworkLibrarySpec.identifier, domain: domain) as! ProcessXCFrameworkLibrarySpec
        self.processSDKImportsSpec = workspaceContext.core.specRegistry.getSpec(ProcessSDKImportsSpec.identifier, domain: domain) as! ProcessSDKImportsSpec
        self.writeFileSpec = workspaceContext.core.specRegistry.getSpec("com.apple.build-tools.write-file", domain: domain) as! WriteFileSpec
        self._documentationCompilerSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.compilers.documentation", domain: domain) as CommandLineToolSpec }
        self._tapiSymbolExtractorSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.compilers.documentation.objc-symbol-extract", domain: domain) as TAPISymbolExtractor }
        self._swiftSymbolExtractorSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.compilers.documentation.swift-symbol-extract", domain: domain) as CommandLineToolSpec }
        self._developmentAssetsSpec = Result { try workspaceContext.core.specRegistry.getSpec(ValidateDevelopmentAssets.identifier, domain: domain) as CommandLineToolSpec }
        self._generateAppPlaygroundAssetCatalogSpec = Result { try workspaceContext.core.specRegistry.getSpec(GenerateAppPlaygroundAssetCatalog.identifier, domain: domain) as CommandLineToolSpec }
        self._realityAssetsCompilerSpec = Result { try workspaceContext.core.specRegistry.getSpec("com.apple.build-tasks.compile-rk-assets.xcplugin", domain: domain) as CommandLineToolSpec }

        self.compilationRequirementOutputFileTypes = (SpecRegistry.headerFileTypeIdentifiers + [SpecRegistry.modulemapFileTypeIdentifier]).compactMap { workspaceContext.core.specRegistry.lookupFileType(identifier: $0, domain: domain) }
        self.emitFrontendCommandLines = settings.globalScope.evaluate(BuiltinMacros.EMIT_FRONTEND_COMMAND_LINES)

        for diagnostic in settings.diagnostics {
            delegate.emit(diagnostic)
        }

        for diagnostic in settings.targetDiagnostics {
            delegate.emit(configuredTarget.map { .overrideTarget($0) } ?? .default, diagnostic)
        }

        let context = configuredTarget.map { TargetDiagnosticContext.overrideTarget($0) } ?? .default

        // Report any issues detected while we were being constructed.
        for error in settings.errors {
            delegate.error(context, error)
        }
        for warning in settings.warnings {
            delegate.warning(context, warning)
        }
        for note in settings.notes {
            delegate.note(context, note)
        }
    }

    /// Make an input path absolute, resolving relative to the current project.
    func makeAbsolute(_ path: Path) -> Path {
        return defaultWorkingDirectory.join(path)
    }

    public func lookupReference(for guid: String) -> Reference? {
        return workspaceContext.workspace.lookupReference(for: guid)
    }

    /// Get the list of source files generated for this target.
    var generatedSourceFiles: [Path] {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _generatedSourceFiles
        }
    }

    /// Add a source file generated by this target.
    func addGeneratedSourceFile(_ path: Path) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            _generatedSourceFiles.append(path)
        }
    }

    /// Get the list of info plist additions generated for this target.
    var generatedInfoPlistContents: [Path] {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _generatedInfoPlistContents
        }
    }

    var generatedPrivacyContentFilePaths: [Path] {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _generatedPrivacyContentFilePaths
        }
    }

    /// Add an info plist addition generated by this target.
    func addGeneratedInfoPlistContent(_ path: Path) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            _generatedInfoPlistContents.append(path)
        }
    }

    func addPrivacyContentPlistContent(_ path: Path) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            _generatedPrivacyContentFilePaths.append(path)
        }
    }

    /// Get the produced binary path for the given variant, if any.
    func producedBinary(forVariant variant: String) -> Path? {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _producedBinaryPaths[variant]
        }
    }

    /// Add a produced binary path for the given variant.
    func addProducedBinary(path: Path, forVariant variant: String) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            assert(_producedBinaryPaths[variant] == nil || _producedBinaryPaths[variant] == path)
            _producedBinaryPaths[variant] = path
        }
    }

    /// Get the produced dSYM path for the given variant, if any.
    func producedDSYM(forVariant variant: String) -> Path? {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _producedDSYMPaths[variant]
        }
    }

    /// Add a produced dSYM path for the given variant.
    func addProducedDSYM(path: Path, forVariant variant: String) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            assert(_producedDSYMPaths[variant] == nil || _producedDSYMPaths[variant] == path)
            _producedDSYMPaths[variant] = path
        }
    }

    /// Add a file that was copied.
    func addCopiedPath(src: String, dst: String) {
        // This is async because we only need to read copied path map
        // after running all of the deferred task producers.
        queue.async {
            assert(!self._inDeferredMode)
            self._copiedPathMap[dst, default: []].insert(src)
        }
    }

    /// Get the map of the files which will be copied.
    func copiedPathMap() -> [String: Set<String>] {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _copiedPathMap
        }
    }

    /// Get the product custom TBD paths.
    func generatedTBDFiles(forVariant variant: String) -> [Path] {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _generatedTBDFiles[variant] ?? []
        }
    }

    /// Add a produced binary path for the given variant.
    func addGeneratedTBDFile(_ path: Path, forVariant variant: String) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            _generatedTBDFiles[variant, default: []].append(path)
        }
    }

    /// Get the product generated Swift Objective-C interface header files.
    func generatedSwiftObjectiveCHeaderFiles() -> [String: Path] {
        return queue.blocking_sync {
            //assert(_inDeferredMode)
            return _generatedSwiftObjectiveCHeaderFiles
        }
    }

    /// Add a generated Swift Objective-C interface header file.
    func addGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            _generatedSwiftObjectiveCHeaderFiles[architecture] = path
        }
    }

    /// Get the product generated Swift Objective-C interface header files.
    public func generatedSwiftConstMetadataFiles() -> [String: [Path]] {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _generatedGeneratedSwiftConstMetadataFiles
        }
    }

    /// Add a generated Swift supplementary const metadata file.
    func addGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            if _generatedGeneratedSwiftConstMetadataFiles[architecture] != nil {
                _generatedGeneratedSwiftConstMetadataFiles[architecture]?.append(path)
            } else {
                _generatedGeneratedSwiftConstMetadataFiles[architecture] = [path]
            }
        }
    }

    /// Virtual output nodes for shell script build phases that don't have any declared outputs.
    func shellScriptVirtualOutputs() -> [PlannedVirtualNode] {
        return queue.blocking_sync {
            assert(_inDeferredMode)
            return _shellScriptVirtualOutputs
        }
    }

    func addShellScriptVirtualOutput(_ virtualOutput: PlannedVirtualNode) {
        queue.async {
            assert(!self._inDeferredMode)
            self._shellScriptVirtualOutputs.append(virtualOutput)
        }
    }

    /// The outputs of the tasks for this target prior to deferred task production.
    var outputsOfMainTaskProducers: [any PlannedNode] {
        get {
            queue.blocking_sync {
                assert(_inDeferredMode)
                return _outputsOfMainTaskProducers
            }
        }
        set {
            queue.async {
                assert(!self._inDeferredMode)
                self._outputsOfMainTaskProducers = newValue
            }
        }
    }

    /// Add a deferred task production block.
    public func addDeferredProducer(_ body: @escaping () async -> [any PlannedTask]) {
        queue.blocking_sync {
            assert(!_inDeferredMode)
            _deferredProducers.append(body)
        }
    }

    /// Take the list of deferred producers.
    ///
    /// We model this as a "take" operation to ensure that any potential reference cycles through the producers are automatically discarded.
    func takeDeferredProducers() -> [() async -> [any PlannedTask]] {
        return queue.blocking_sync {
            assert(!_inDeferredMode)
            _inDeferredMode = true
            let result = _deferredProducers
            _deferredProducers.removeAll()
            return result
        }
    }

    /// Adds an additional codesign input that needs to be tracked.
    /// - parameter alwaysAdd: Skips the check for the input path existing on disk. This is defaulted to `false`.
    func addAdditionalCodeSignInput(_ path: Path, scope: MacroEvaluationScope, alwaysAdd: Bool = false) {
        // This API should only be used during the `planning` phase.
        assert(phase == .planning)

        // A feature guard to provide a fallback mechanism, primarily to alleviate risk.
        guard scope.evaluate(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING) else { return }

        queue.blocking_sync {
            assert(!_inDeferredMode)
            // This is a bit unfortunate, but to prevent workspace diagnostic issues downstream, silently ignore any missing items, it's necessary to allow callers to ignore files that do not actually exist on disk.
            if alwaysAdd || fs.exists(path) {
                _additionalCodeSignInputs.append(path)
            }
        }
    }

    /// Adds all of the appropriate build files as additional codesign inputs.
    func addAdditionalCodeSignInputs(_ buildFiles: [BuildFile], _ context: TaskProducerContext) {
        for buildFile in buildFiles {
            // A failure to resolve the build file reference is primarily when a file is being referenced that does not actually exist. There's not need to track that error here.
            if let (ref, path, _) = try? context.resolveBuildFileReference(buildFile) {
                // If the reference is coming from a product, we always add file to the signing input.
                let alwaysAdd = ref is ProductReference
                context.addAdditionalCodeSignInput(path, scope: context.settings.globalScope, alwaysAdd: alwaysAdd)
            }
        }
    }

    public func discoveredCommandLineToolSpecInfo(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String, _ path: Path, _ process: @Sendable (_ contents: Data) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> any DiscoveredCommandLineToolSpecInfo {
        try await workspaceContext.discoveredCommandLineToolSpecInfoCache.run(delegate, toolName, path, process)
    }

    public func discoveredCommandLineToolSpecInfo(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String?, _ commandLine: [String], _ process: @Sendable (_ processResult: Processes.ExecutionResult) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> any DiscoveredCommandLineToolSpecInfo {
        try await workspaceContext.discoveredCommandLineToolSpecInfoCache.run(delegate, toolName, commandLine, process)
    }

    public func shouldUseSDKStatCache() async -> Bool {
        guard UserDefaults.enableSDKStatCaching else { return false }
        if settings.globalScope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA) {
            return false
        }
        guard !Set(settings.globalScope.evaluate(BuiltinMacros.BUILD_COMPONENTS)).intersection(["build", "api"]).isEmpty else { return false }
        // clang-stat-cache will currently treat the fs as case-insensitive if `taskpolicy -x` was used to force case-sensitivity.
        guard !ProcessInfo.processInfo.isRunningUnderFilesystemCaseSensitivityIOPolicy else { return false }
        guard let sdk, !localFS.isOnPotentiallyRemoteFileSystem(sdk.path) else { return false }
        guard settings.globalScope.evaluate(BuiltinMacros.SDK_STAT_CACHE_ENABLE) else { return false }
        guard let clangInfo = await clangSpec.discoveredCommandLineToolSpecInfo(self, settings.globalScope, delegate) as? DiscoveredClangToolSpecInfo, clangInfo.toolFeatures.has(.vfsstatcache) else { return false }
        guard let standardTarget = configuredTarget?.target as? StandardTarget, let sourcesBuildPhase = standardTarget.sourcesBuildPhase, !sourcesBuildPhase.buildFiles.isEmpty else { return false }

        return true
    }

    /// Retrieves a read-only view of the additional codesign inputs. This returns a sorted array for stability reasons.
    var additionalCodeSignInputs: OrderedSet<Path> {
        // The data from this collection should only be used after the planning phase has been completed. Doing so before can lead to incorrect assumptions due to the un-ordered nature of task producers.
        assert(phase == .taskGeneration)
        return _additionalCodeSignInputs
    }

    // FIXME: <rdar://problem/30298464> This is something of a hack.  Uses in the ProductPostprocessingTaskProducer say this should be expressed instead on a check against a provisional task of the product, but as of this writing the future of provisional tasks is unclear.
    //
    /// Returns whether the product of the target is going to be produced.
    ///
    /// Presently wrapped products are considered to always be produced.  Standalone binary products are produced only if they will produce a binary.
    func willProduceProduct(_ scope: MacroEvaluationScope? = nil) -> Bool {
        // Non-standalone (i.e., wrapped) product types always produce a product.
        guard settings.productType is StandaloneExecutableProductTypeSpec else {
            return true
        }

        let scope = scope ?? settings.globalScope

        assert(scope.values(for: BuiltinMacros.variantCondition) == nil, "calls to willProduceProduct must NOT be done in a variant scope")
        assert(scope.values(for: BuiltinMacros.archCondition) == nil, "calls to willProduceProduct must NOT be done in an arch scope")

        return scope.evaluate(BuiltinMacros.BUILD_VARIANTS).contains(where: { variant in willProduceBinary(scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)) })
    }

    /// Returns whether a binary will be produced for the product.
    ///
    /// A wrapped product will always produce a product, but it may or may not produce a binary depending on whether there are sources included in the target and other factors.  This can affect some post-processing steps like codesigning.
    func willProduceBinary(_ scope: MacroEvaluationScope, forArch: Bool = false) -> Bool {
        assert(scope.values(for: BuiltinMacros.variantCondition) != nil, "calls to willProduceBinary must be done in a variant scope")
        assert((scope.values(for: BuiltinMacros.archCondition) != nil) == forArch)

        if !forArch {
            return scope.evaluate(BuiltinMacros.ARCHS).contains(where: { arch in willProduceBinary(scope.subscope(binding: BuiltinMacros.archCondition, to: arch), forArch: true) })
        }

        // If we're copying a stub binary for this target, then we have a binary.
        guard !scope.evaluate(BuiltinMacros.PRODUCT_TYPE_HAS_STUB_BINARY) else {
            return true
        }

        // If this target has no valid architectures, then it won't produce a binary because no files will be compiled.
        guard !scope.evaluate(BuiltinMacros.ARCHS).isEmpty else {
            return false
        }

        // If this target is generating a master object file, then we assume it will produce a binary.
        // FIXME: This is nasty.  See SourcesTaskProducer.generateTasks() for handling of GENERATE_MASTER_OBJECT_FILE.
        guard !scope.evaluate(BuiltinMacros.GENERATE_MASTER_OBJECT_FILE) else {
            return true
        }

        // Otherwise, we are producing a binary if we have a Sources build phase and either that phase is not empty or we're generating a versioning stub file.
        guard let target = configuredTarget?.target as? SWBCore.BuildPhaseTarget,
            let sourcesBuildPhase = target.sourcesBuildPhase else {
            return false
        }

        let context = BuildFilesProcessingContext(scope)

        let hasObjectProducingSources = sourcesBuildPhase.buildFiles.filter {
            guard let buildFile = try? resolveBuildFileReference($0), !context.isExcluded(buildFile.absolutePath, filters: $0.platformFilters) else {
                return false
            }

            // AppleScript files don't produce object files either directly or transitively, so they cannot (for most definitions of "cannot") contribute to a linked Mach-O being produced.
            if buildFile.fileType.identifier == "sourcecode.applescript" {
                return false
            }

            return true
        }.count > 0 || scope.generatesAppleGenericVersioningFile(context) || scope.generatesKernelExtensionModuleInfoFile(context, settings, sourcesBuildPhase)

        // We will produce a binary if we have sources.
        if hasObjectProducingSources {
            return true
        }

        // Check if there are any object files or package products in the framework build phase.
        if let frameworkBuildPhase = target.frameworksBuildPhase {
            let containsObjectFile = frameworkBuildPhase.buildFiles.contains {
                guard let buildFile = try? resolveBuildFileReference($0), !context.isExcluded(buildFile.absolutePath, filters: $0.platformFilters) else {
                    return false
                }

                // We will produce a product if the target type is a package product.
                if (buildFile.reference as? ProductReference)?.target?.type == .packageProduct {
                    return true
                }

                // Finally, check if this is an object file.
                return buildFile.fileType.identifier == "compiled.mach-o.objfile"
            }

            if containsObjectFile {
                return true
            }
        }

        return false
    }

    /// Returns true if we should emit errors when there are tasks that delay eager compilation.
    func requiresEagerCompilation(_ scope: MacroEvaluationScope) -> Bool {
        return scope.evaluate(BuiltinMacros.EAGER_COMPILATION_REQUIRE)
    }

    /// Returns true if we should emit errors when there are tasks that delay eager linking.
    func requiresEagerLinking(_ scope: MacroEvaluationScope) -> Bool {
        return scope.evaluate(BuiltinMacros.EAGER_LINKING_REQUIRE)
    }

    // MARK: Delegate Forwarding

    package func createNode(_ path: Path) -> PlannedPathNode {
        return delegate.createNode(absolutePath: makeAbsolute(path))
    }

    package func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        return delegate.createDirectoryTreeNode(absolutePath: path, excluding: excluding)
    }

    package func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return delegate.createVirtualNode(name)
    }

    package func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        return delegate.createBuildDirectoryNode(absolutePath: path)
    }

    func createGateTask(_ inputs: [any PlannedNode] = [], output: any PlannedNode, name: String? = nil, mustPrecede: [any PlannedTask] = [], taskConfiguration: (inout PlannedTaskBuilder) -> Void = { _ in }) -> any PlannedTask {
        return delegate.createGateTask(inputs, output: output, name: name ?? output.name, mustPrecede: mustPrecede, taskConfiguration: taskConfiguration)
    }

    func createTask(_ options: TaskOrderingOptions = [], _ builder: inout PlannedTaskBuilder) -> any PlannedTask {
        return delegate.createTask(&builder)
    }

    var phaseEndTasks: [any PlannedTask] = []
    func createPhaseEndTask(inputs: [any PlannedNode], output: any PlannedNode, mustPrecede: [any PlannedTask]) -> any PlannedTask {
        let task = createGateTask(inputs, output: output, mustPrecede: mustPrecede)
        // FIXME: This is a rather gross way to collect all of these tasks, just so they can be added via the "TargetOrderTaskProducer".
        phaseEndTasks.append(task)
        return task
    }

    func recordAttachment(contents: ByteString) -> Path {
        return delegate.recordAttachment(contents: contents)
    }

    /// Report a note from task construction.
    func note(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        if let configuredTarget {
            delegate.note(.overrideTarget(configuredTarget), message, location: location, component: component)
        } else {
            delegate.note(message, location: location, component: component)
        }
    }

    /// Report a warning from task construction.
    func warning(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        if let configuredTarget {
            delegate.warning(.overrideTarget(configuredTarget), message, location: location, component: component)
        } else {
            delegate.warning(message, location: location, component: component)
        }
    }

    /// Report an error from task construction.
    public func error(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        if let configuredTarget {
            delegate.error(.overrideTarget(configuredTarget), message, location: location, component: component)
        } else {
            delegate.error(message, location: location, component: component)
        }
    }

    /// Report a remark from task construction.
    func remark(_ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        if let configuredTarget {
            delegate.remark(.overrideTarget(configuredTarget), message, location: location, component: component)
        } else {
            delegate.remark(message, location: location, component: component)
        }
    }

    /// Report a diagnostic from task construction.
    func emit(_ kind: Diagnostic.Behavior, _ message: String, location: Diagnostic.Location = .unknown, component: Component = .default) {
        switch kind {
        case .error:
            error(message, location: location, component: component)
        case .warning:
            warning(message, location: location, component: component)
        case .note:
            note(message, location: location, component: component)
        case .remark:
            remark(message, location: location, component: component)
        case .ignored:
            break
        }
    }

    /// Report a diagnostic from task construction.
    private func emit(data: DiagnosticData, behavior: Diagnostic.Behavior, location: Diagnostic.Location = .unknown) {
        delegate.emit(Diagnostic(behavior: behavior, location: location, data: data))
    }

    /// Report an error that is caused by a missing package product.
    func missingPackageProduct(_ packageName: String, _ buildFile: BuildFile, _ buildPhase: BuildPhase) {
        error("Missing package product '\(packageName)'",
            location: .buildFile(buildFileGUID: buildFile.guid, buildPhaseGUID: buildPhase.guid, targetGUID: configuredTarget?.target.guid ?? ""),
            component: .packageResolution)
    }

    func missingNamedReference(_ name: String, _ buildFile: BuildFile, _ buildPhase: BuildPhase) {
        // TODO: Semantic build file locations end up going to the General tab in Xcode, but here we have our first use case where we ALWAYS want it to go to the Build Phases tab.
        // Will need to figure out a way to abstract this into the diagnostics model which doesn't directly map to Xcode's UI. Perhaps an `exact` flag?
        error("This \(buildPhase.name) build phase contains a reference to a missing file '\(name)'.",
            location: .buildFile(buildFileGUID: buildFile.guid, buildPhaseGUID: buildPhase.guid, targetGUID: configuredTarget?.target.guid ?? ""),
            component: .targetIntegrity)
    }

    func emitFileExclusionDiagnostic(_ exclusionReason: BuildFileExclusionReason, _ context: any BuildFileFilteringContext, _ path: Path, _ filters: Set<PlatformFilter>, _ buildFileLocation: Diagnostic.Location?) {
        guard workspaceContext.userPreferences.enableDebugActivityLogs else {
            return
        }

        switch exclusionReason {
        case .platformFilter:
            let filterString = filters.sorted().map(\.comparisonString).joined(separator: ", ").nilIfEmpty ?? "<none>"
            let currentFilterString = context.currentPlatformFilter?.comparisonString.nilIfEmpty ?? "<none>"
            self.emit(.note, "Skipping '\(path.str)' because its platform filter (\(filterString)) does not match the platform filter of the current context (\(currentFilterString)).", location: buildFileLocation ?? .unknown)
        case let .patternLists(excludePattern):
            let excl = context.excludedSourceFileNames.joined(separator: " ")
            let incl = context.includedSourceFileNames.joined(separator: " ")
            self.delegate.emit(configuredTarget.map { .overrideTarget($0) } ?? .default, Diagnostic(behavior: .note, location: buildFileLocation ?? .unknown, data: DiagnosticData("Skipping '\(path.str)' because it is excluded by EXCLUDED_SOURCE_FILE_NAMES pattern: \(excludePattern)"), childDiagnostics: [
                Diagnostic(behavior: .note, location: .buildSetting(name: BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES.name), data: DiagnosticData("EXCLUDED_SOURCE_FILE_NAMES: \(excl)")),
                Diagnostic(behavior: .note, location: .buildSetting(name: BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES.name), data: DiagnosticData("INCLUDED_SOURCE_FILE_NAMES: \(incl)")),
            ]))
        }
    }

    package var allOnDemandResourcesAssetPacks: [ODRAssetPackInfo] {
        return queue.blocking_sync { Array(onDemandResourcesAssetPacks.values) }
    }

    public func onDemandResourcesAssetPack(for tags: ODRTagSet) -> ODRAssetPackInfo? {
        guard onDemandResourcesEnabled else { return nil }
        if let r = (queue.blocking_sync { onDemandResourcesAssetPacks[tags] }) { return r }
        let maxPriority = tags.lazy.compactMap { self.onDemandResourcesAssetTagPriority(tag: $0) }.max()

        let productBundleIdentifier = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER)
        guard !productBundleIdentifier.isEmpty else {
            self.error("On-Demand Resources is enabled (ENABLE_ON_DEMAND_RESOURCES = YES), but the PRODUCT_BUNDLE_IDENTIFIER build setting is empty", location: .buildSetting(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER))
            return nil
        }

        let info = ODRAssetPackInfo(tags: tags, priority: maxPriority, productBundleIdentifier: productBundleIdentifier, settings.globalScope)
        queue.blocking_sync { onDemandResourcesAssetPacks[tags] = info }
        return info
    }

    public func onDemandResourcesAssetPack(for group: FileToBuildGroup) -> ODRAssetPackInfo? {
        guard onDemandResourcesEnabled else { return nil }
        let tags = Set(group.files.flatMap { $0.buildFile?.assetTags ?? Set() })
        guard !tags.isEmpty else { return nil }
        return onDemandResourcesAssetPack(for: tags)
    }

    package func didProduceAssetPackSubPath(_ assetPack: ODRAssetPackInfo, _ subPath: String) {
        _ = queue.blocking_sync { onDemandResourcesAssetPackSubPaths[assetPack.identifier, default: Set()].insert(subPath) }
    }

    package var allOnDemandResourcesAssetPackSubPaths: [String: Set<String>] {
        return queue.blocking_sync { onDemandResourcesAssetPackSubPaths }
    }

    private func onDemandResourcesAssetTagPriority(tag: String) -> Double? {
        if onDemandResourcesInitialInstallTags.contains(tag) {
            return 1.0
        }
        else if let index = onDemandResourcesPrefetchOrder.firstIndex(of: tag) {
            let count = onDemandResourcesPrefetchOrder.count
            if count == 1 {
                return 0.5
            }
            else {
                return (Double(count - 1 - index) / Double(count - 1)) * 0.9 + 0.05
            }
        }

        return nil
    }
}

public final class TargetTaskProducerContext: TaskProducerContext {
    private let targetTaskInfo: TargetTaskInfo

    /// A path node representing the tasks necessary to 'prepare-for-index' a target, before any compilation can occur.
    /// This is only set for an index build.
    var preparedForIndexPreCompilationNode: (any PlannedNode)? { targetTaskInfo.preparedForIndexPreCompilationNode }

    /// A virtual node representing that a target will be code signing its product in a later task.
    var willSignNode: any PlannedNode { targetTaskInfo.willSignNode }

    /// The target end task gate.
    let targetEndTask: any PlannedTask

    /// A task gate for when dependent targets can start building sources.
    ///
    /// This will ensure that headers and module maps are in place, and that any shell scripts in the target have been run. Targets that depend on this target should be able to start compiling sources once this task is complete.
    ///
    /// Worst case scenario, compilation tasks will wait for the end of previous targets like other tasks.
    let modulesReadyTask: any PlannedTask

    /// A task gate for when dependent targets can start linking against this target.
    ///
    /// This will ensure that either the
    let linkerInputsReadyTask: any PlannedTask

    /// A task gate for when dependent targets can start scanning.
    let scanInputsReadyTask: any PlannedTask

    /// A task gate from the target's start node to its unsigned-product-ready node.  Tasks which produce the substantive content of the product should be ordered before this task.
    let unsignedProductReadyTask: any PlannedTask

    /// A task gate from the target's unsigned-product-ready node to its will-sign node.  Task which need to run after the target is ready but before it is signed (or other mutating tasks which edit the unsigned product) should be ordered before this task.  In particular, targets which embed their content inside this target's product - such as tests hosted in an app - should be ordered before this node.
    let willSignTask: any PlannedTask

    /// Create the context for producing tasks within a particular target.
    ///
    /// - parameter configuredTarget: The target the context is for.
    /// - parameter workspaceContext: The containing workspace and context.
    /// - parameter targetTaskInfo: The high-level target task information.
    /// - parameter globalProductPlan: The high-level global build information.
    /// - parameter delegate: The delegate to use for task construction.
    init(configuredTarget: ConfiguredTarget, workspaceContext: WorkspaceContext, targetTaskInfo: TargetTaskInfo, globalProductPlan: GlobalProductPlan, delegate: any TaskPlanningDelegate) {
        self.targetTaskInfo = targetTaskInfo

        // Create the target end gate task, which connects the target's start node to its end node.
        // The target's start gate task is created in TargetOrderTaskProducer.createTargetBeginTask().
        self.targetEndTask = delegate.createGateTask([targetTaskInfo.startNode], output: targetTaskInfo.endNode, name: targetTaskInfo.endNode.name, mustPrecede: []) {
            $0.forTarget = configuredTarget
            $0.makeGate()
        }

        // Create the modules-ready gate task.  It depends on the start-compiling node because tasks which block compilation also block modules being ready.
        self.modulesReadyTask = delegate.createGateTask([targetTaskInfo.startCompilingNode], output: targetTaskInfo.modulesReadyNode, name: targetTaskInfo.modulesReadyNode.name, mustPrecede: []) {
            $0.forTarget = configuredTarget
            $0.makeGate()
        }

        self.linkerInputsReadyTask = delegate.createGateTask([targetTaskInfo.startCompilingNode], output: targetTaskInfo.linkerInputsReadyNode, name: targetTaskInfo.linkerInputsReadyNode.name, mustPrecede: []) {
            $0.forTarget = configuredTarget
            $0.makeGate()
        }

        self.scanInputsReadyTask = delegate.createGateTask([targetTaskInfo.startNode], output: targetTaskInfo.scanInputsReadyNode, name: targetTaskInfo.scanInputsReadyNode.name, mustPrecede: []) {
            $0.forTarget = configuredTarget
            $0.makeGate()
        }

        // Create the unsigned-product-ready gate task.
        self.unsignedProductReadyTask = delegate.createGateTask([targetTaskInfo.startCompilingNode], output: targetTaskInfo.unsignedProductReadyNode, name: targetTaskInfo.unsignedProductReadyNode.name, mustPrecede: []) {
            $0.forTarget = configuredTarget
            $0.makeGate()
        }

        // Create the will-sign gate task.
        // This depends on the unsigned-products-ready node, and also on the end nodes of all the targets whose products this target is hosting.
        let willSignTaskInputs = [targetTaskInfo.unsignedProductReadyNode] + (globalProductPlan.hostedTargetsForTargets[configuredTarget]?.compactMap({ globalProductPlan.targetTaskInfos[$0]?.endNode }) ?? [])
        self.willSignTask = delegate.createGateTask(willSignTaskInputs, output: targetTaskInfo.willSignNode, name: targetTaskInfo.willSignNode.name, mustPrecede: []) {
            $0.forTarget = configuredTarget
            $0.makeGate()
        }

        // Report any configuration issues detected in the target.
        for error in configuredTarget.target.errors {
            delegate.error(.overrideTarget(configuredTarget), error)
        }

        for warning in configuredTarget.target.warnings {
            delegate.warning(.overrideTarget(configuredTarget), warning)
        }

        super.init(configuredTarget: configuredTarget, workspaceContext: workspaceContext, globalProductPlan: globalProductPlan, delegate: delegate)
    }

    private func additionalInputsForGateTask(output: any PlannedNode) -> [any PlannedNode] {
        var inputs = [any PlannedNode]()
        if output !== targetTaskInfo.startCompilingNode && output !== targetTaskInfo.startImmediateNode && output !== targetTaskInfo.startLinkingNode {
            inputs.append(targetTaskInfo.startCompilingNode)
        }
        return inputs
    }

    /// Returns a list of nodes which will be added to the inputs to a task created by this `TaskProducer` to enforce dependencies.  This is where input dependencies for eager compilation are computed.
    private func additionalInputsForTask(options: TaskOrderingOptions) -> [any PlannedNode] {
        var inputs = [any PlannedNode]()

        if options.contains(.immediate) {
            // If using eager compilation, then tasks marked 'immediate' only depend on the start-immediate node for the target.
            inputs.append(targetTaskInfo.startImmediateNode)
        } else if options.contains(.compilation) {
            // If using eager compilation, then tasks marked 'compilation' depend on the start-compiling node for the target.
            inputs.append(targetTaskInfo.startCompilingNode)

            inputs.append(delegate.createVirtualNode("WorkspaceHeaderMapVFSFilesWritten"))
        } else if options.contains(.linking) {
            inputs.append(targetTaskInfo.startLinkingNode)
        } else if options.contains(.scanning) {
            inputs.append(targetTaskInfo.startScanningNode)
        } else {
            // Tasks not marked either 'immediate', 'compilation', or 'linking' always depend on the target-start node.
            inputs.append(targetTaskInfo.startNode)
        }

        return inputs
    }

    /// Returns a list of tasks which tasks created by this `TaskProducer` will be ordered before to enforce dependencies.  This is where output orderings for eager compilation are computed.
    private func additionalMustPrecedeTasksForTask(options: TaskOrderingOptions) -> [any PlannedTask] {
        var mustPrecede = [any PlannedTask]()

        // If using eager compilation, then tasks marked 'compilationRequirement' will be ordered before the modules-ready task for the target, so the target's own compilation tasks, as well as compilation tasks of downstream targets, must wait for it them to finish.
        if options.contains(.compilationRequirement) {
            mustPrecede.append(modulesReadyTask)
        }
        // If using eager linking, then tasks marked 'linkingRequirement' will be ordered before the linker-inputs-ready task.
        if options.contains(.linkingRequirement) {
            mustPrecede.append(linkerInputsReadyTask)
        }

        // Tasks marked as 'scanning' need to follow upstream scanning and modules ready
        if options.contains(.scanning) {
            mustPrecede.append(scanInputsReadyTask)
            mustPrecede.append(modulesReadyTask)
        }

        // All tasks are ordered before the target-end task.
        mustPrecede.append(targetEndTask)
        // Tasks which contribute to the unsigned product are ordered before the unsigned-product-ready task.
        if options.contains(.unsignedProductRequirement) {
            mustPrecede.append(unsignedProductReadyTask)
        }

        if options.contains(.compilationRequirement) {
            mustPrecede += preparedForIndexModuleContentTasks
        }

        return mustPrecede
    }

    override func createGateTask(_ inputs: [any PlannedNode] = [], output: any PlannedNode, name: String? = nil, mustPrecede: [any PlannedTask] = [], taskConfiguration: (inout PlannedTaskBuilder) -> Void = { _ in }) -> any PlannedTask {
        return delegate.createGateTask(inputs + additionalInputsForGateTask(output: output), output: output, name: name ?? output.name, mustPrecede: mustPrecede, taskConfiguration: taskConfiguration)
    }

    override func createTask(_ options: TaskOrderingOptions = [], _ builder: inout PlannedTaskBuilder) -> any PlannedTask {
        if let target = configuredTarget, globalProductPlan.targetsRequiredToBuildForIndexing.contains(target) {
            builder.preparesForIndexing = true
        }
        builder.inputs.append(contentsOf: additionalInputsForTask(options: options))
        builder.mustPrecede.append(contentsOf: additionalMustPrecedeTasksForTask(options: options))
        return delegate.createTask(&builder)
    }
}

/// `TaskProducerContext` uses reference hashing and equality semantics.
extension TaskProducerContext: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func ==(lhs: TaskProducerContext, rhs: TaskProducerContext) -> Bool {
        return lhs === rhs
    }
}

extension TaskProducerContext: CommandProducer {
    public func lookupPlatformInfo(platform: BuildVersion.Platform) -> (any PlatformInfoProvider)? {
        workspaceContext.core.lookupPlatformInfo(platform: platform)
    }
    
    public var preferredArch: String? {
        return settings.preferredArch
    }

    public var productType: ProductTypeSpec? {
        return settings.productType
    }

    public var sdk: SDK? {
        return settings.sdk
    }

    public var sdkVariant: SDKVariant? {
        return settings.sdkVariant
    }

    public var platform: SWBCore.Platform? {
        return settings.platform
    }

    public var toolchains: [Toolchain] {
        return settings.toolchains
    }

    public var sparseSDKs: [SDK] {
        return settings.sparseSDKs
    }

    public var executableSearchPaths: StackedSearchPath {
        return settings.executableSearchPaths
    }

    public var moduleInfo: ModuleInfo? {
        return globalProductPlan.getModuleInfo(configuredTarget!)
    }

    public var userPreferences: UserPreferences {
        workspaceContext.userPreferences
    }

    public var hostOperatingSystem: OperatingSystem {
        workspaceContext.core.hostOperatingSystem
    }

    public var needsVFS: Bool {
        return globalProductPlan.needsVFS
    }

    public var generateAssemblyCommands: Bool {
        if case .generateAssemblyCode = globalProductPlan.planRequest.buildRequest.buildCommand {
            return true
        } else {
            return false
        }
    }

    public var generatePreprocessCommands: Bool {
        if case .generatePreprocessedFile = globalProductPlan.planRequest.buildRequest.buildCommand {
            return true
        } else {
            return false
        }
    }

    public var filePathResolver: FilePathResolver {
        return settings.filePathResolver
    }

    public var specRegistry: SpecRegistry {
        return platform?.specRegistryProvider.specRegistry ?? globalProductPlan.planRequest.workspaceContext.core.specRegistry
    }

    public var signingSettings: Settings.SigningSettings? {
        return settings.signingSettings
    }

    public var xcodeProductBuildVersion: ProductBuildVersion? {
        return workspaceContext.core.xcodeProductBuildVersion
    }

    public func expandedSearchPaths(for items: [String], scope: MacroEvaluationScope) -> [String] {
        return globalProductPlan.expandedSearchPaths(for: items, relativeTo: defaultWorkingDirectory, scope: scope)
    }

    public func targetSwiftDependencyScopes(for target: ConfiguredTarget, arch: String, variant: String) -> [MacroEvaluationScope] {
        let initialDeps = globalProductPlan.dependencies(of: target)
        var (allDeps, _) = transitiveClosure(initialDeps) {
            globalProductPlan.dependencies(of: $0)
        }
        // transitiveClosure algorithm invoked above is not reflexive.
        allDeps.append(contentsOf: initialDeps)
        return allDeps.compactMap { targetDependency in
            let settings = globalProductPlan.getTargetSettings(targetDependency)
            let dependencyScope = settings.globalScope

            // Only vend scopes of target dependencies which contain Swift code.
            // FIXME: What we would really like to know is if this target contains tasks
            // which produce a .swiftmodule output. Seeing as there isn't currently
            // a facility for doing that, we approximate by checking if the target contains
            // any Swift sources.
            guard let standardTarget = targetDependency.target as? SWBCore.StandardTarget,
                  let sourcesBuildPhase = standardTarget.sourcesBuildPhase,
                  sourcesBuildPhase.containsSwiftSources(self.workspaceContext.workspace, self, dependencyScope, self.filePathResolver)
            else {
                return nil
            }

            if dependencyScope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) && !settings.allowInstallAPIForTargetsSkippedInInstall(in: dependencyScope) {
                return nil
            }

            var arch = arch
            // arch is a VALID_ARCHS of the dependency but it's not building for that arch, we need to find a compatible one
            let dependencyArchs = dependencyScope.evaluate(BuiltinMacros.ARCHS)
            if false == dependencyArchs.contains(arch) {
                guard let archSpec: ArchitectureSpec = try? workspaceContext.core.specRegistry.getSpec(arch) else {
                    return nil
                }
                // Currently there is no more than one compatibility arch; first might not be correct otherwise
                guard let compatibleArch = archSpec.compatibilityArchs.first(where: { compatibleArch in
                    dependencyArchs.contains(compatibleArch)
                }) else {
                    return nil
                }
                arch = compatibleArch
            }


            return dependencyScope
                .subscope(binding: BuiltinMacros.variantCondition, to: variant)
                .subscope(binding: BuiltinMacros.archCondition, to: arch)
        }
    }

    public var swiftMacroImplementationDescriptors: Set<SWBCore.SwiftMacroImplementationDescriptor>? {
        configuredTarget.flatMap { globalProductPlan.swiftMacroImplementationDescriptorsByTarget[$0] }
    }

    /// Returns true if eager linking is supported in this context and scope. The eager linking optimization is only permitted if certain criteria are met.
    public func supportsEagerLinking(scope: MacroEvaluationScope) -> Bool {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        // Currently, eager linking (using TBDs to unblock linking early within a build invocation) and building with installapi (using TBDs to unblock linking between build invocations) are mutually exclusive.
        return buildComponents.contains("build") &&
            !scope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API) &&
            scope.evaluate(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER) && // Prerequisite for eager linking
            !SwiftCompilerSpec.shouldUseWholeModuleOptimization(for: scope).result && // off for WMO
            scope.evaluate(BuiltinMacros.EAGER_LINKING) && // Optimization is currently opt-in via this build setting
            settings.productType?.supportsEagerLinking == true && // The optimization is only valid for supported product types
            compileSourcesExportOnlySwiftSymbols(scope: scope) && // All exported symbols from compile sources must be from Swift sources
            !linkedLibrariesMayIntroduceExportedSymbols(scope: scope) // We must not be linking anything that introduces exported symbols
    }

    public func projectHeaderInfo(for target: Target) async -> ProjectHeaderInfo? {
        return await workspaceContext.headerIndex.projectHeaderInfo[workspaceContext.workspace.project(for: target)]
    }

    public var canConstructAppIntentsMetadataTask: Bool {
        let scope = settings.globalScope
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let isBuild = buildComponents.contains("build")
        // We want to enable metadata generation during localization export so the Intent strings are included in the exported XLIFF
        let isLocExport = buildComponents.contains("exportLoc")
        let indexEnableBuildArena = scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        let isBundleProductType = productType?.conformsTo(identifier: "com.apple.product-type.bundle") ?? false
        let isStaticLibrary = scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "staticlib"
        let isObject = scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_object"
        let result = (isBuild || isLocExport)
            && !indexEnableBuildArena
            && (isBundleProductType || isStaticLibrary || isObject)
            && isApplePlatform

        return result
    }

    public var canConstructAppIntentsSSUTask: Bool {
        let scope = settings.globalScope
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let isBuild = buildComponents.contains("build")
        // We want to enable metadata generation during localization export so the Intent strings are included in the exported XLIFF
        let isLocInstall = buildComponents.contains("installLoc")
        let indexEnableBuildArena = scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        let machOType = scope.evaluate(BuiltinMacros.MACH_O_TYPE)
        let isBundleProductType = productType?.conformsTo(identifier: "com.apple.product-type.bundle") ?? false
        return ((isBuild || isLocInstall) &&
                !indexEnableBuildArena &&
                machOType != "staticlib" &&
                isBundleProductType)
    }

    public var targetRequiredToBuildForIndexing: Bool {
        guard let configuredTarget else { return false }
        return globalProductPlan.targetsRequiredToBuildForIndexing.contains(configuredTarget)
    }

    public var targetShouldBuildModuleForInstallAPI: Bool {
        guard let configuredTarget else { return false }
        return globalProductPlan.targetsWhichShouldBuildModulesDuringInstallAPI?.contains(configuredTarget) ?? false
    }

    public var supportsCompilationCaching: Bool {
        return Settings.supportsCompilationCaching(workspaceContext.core)
    }

    public var systemInfo: SystemInfo? {
        return workspaceContext.systemInfo
    }

    public func lookupLibclang(path: SWBUtil.Path) -> (libclang: SWBCore.Libclang?, version: Version?) {
        workspaceContext.core.lookupLibclang(path: path)
    }
}

extension TaskProducerContext {
    private func compileSourcesExportOnlySwiftSymbols(scope: MacroEvaluationScope) -> Bool {
        guard let buildPhaseTarget = configuredTarget?.target as? BuildPhaseTarget,
              let sourcesBuildPhase = buildPhaseTarget.sourcesBuildPhase else { return false }

        // Ensure that the sources build phase only includes swift source files or source files which won't contribute exported symbols.
        // FIXME: Various types of sources which generate code that doesn't export any symbols could probably be added here.
        guard let swiftFileType = lookupFileType(identifier: "sourcecode.swift") else { return false }
        guard let applescriptFileType = lookupFileType(identifier: "sourcecode.applescript") else { return false }
        guard let doccFileType = lookupFileType(identifier: "folder.documentationcatalog") else { return false }
        for archSpecificSubscope in scope.evaluate(BuiltinMacros.ARCHS).map({ arch in scope.subscope(binding: BuiltinMacros.archCondition, to: arch) }) {
            let context = BuildFilesProcessingContext(archSpecificSubscope)
            guard !sourcesBuildPhase.buildFiles.contains(where: { buildFile in
                guard let resolvedBuildFileInfo = try? resolveBuildFileReference(buildFile),
                      !context.isExcluded(resolvedBuildFileInfo.absolutePath, filters: buildFile.platformFilters) else { return false }

                var fileIsOfOtherType = true
                for type in [swiftFileType, applescriptFileType, doccFileType] {
                    if resolvedBuildFileInfo.fileType.conformsTo(type) == true {
                        fileIsOfOtherType = false
                        break
                    }
                }
                return fileIsOfOtherType
            }) else { return false }

            // Check that we're not generating any C sources with exported symbols based on build settings.
            guard !archSpecificSubscope.generatesKernelExtensionModuleInfoFile(context, settings, sourcesBuildPhase) else { return false }
            guard !archSpecificSubscope.generatesAppleGenericVersioningFile(context) ||
                    archSpecificSubscope.evaluate(BuiltinMacros.VERSION_INFO_EXPORT_DECL).split(separator: " ").contains("static") ||
                    ["", "apple-generic-hidden"].contains(scope.evaluate(BuiltinMacros.VERSIONING_SYSTEM)) else {
                return false
            }
        }

        return true
    }

    private func linkedLibrariesMayIntroduceExportedSymbols(scope: MacroEvaluationScope) -> Bool {
        let dylibFileType = lookupFileType(identifier: "compiled.mach-o.dylib")
        let frameworkFileType = lookupFileType(identifier: "wrapper.framework")
        return computeFlattenedFrameworksPhaseBuildFiles(BuildFilesProcessingContext(scope)).contains() {
            guard let resolvedBuildFileInfo = try? resolveBuildFileReference($0) else { return true }
            // FIXME: Depending on the contents, xcframeworks could be included here too.
            guard resolvedBuildFileInfo.fileType.conformsToAny([dylibFileType, frameworkFileType].compactMap({ $0 })) else { return true }
            return false
        }
    }

    /// Compute the flattened list of build files from the frameworks build phase after expanding package product targets.
    func computeFlattenedFrameworksPhaseBuildFiles(_ buildFilesContext: BuildFilesProcessingContext) -> [BuildFile] {
        guard let buildPhaseTarget = configuredTarget?.target as? BuildPhaseTarget,
              let frameworksPhase = buildPhaseTarget.frameworksBuildPhase else { return [] }

        // The ordered list of output files.
        var result = [BuildFile]()

        // The set of phases we have visited.
        var visitedPhases = Set<Ref<FrameworksBuildPhase>>()

        // The lists of seen references, for deduplication.
        var seenReferenceGUIDs = Set<String>()

        // Process the worklist.
        func visit(_ phase: FrameworksBuildPhase) {
            // If we have already visited this, we are done.
            guard visitedPhases.insert(Ref(phase)).inserted else { return }

            // Add entries for each item, if it is either unique or it is the top-level phase.
            let isTopLevel = phase === frameworksPhase
            for buildFile in phase.buildFiles {
                // If this is a package producer reference, visit it recursively.
                if case .targetProduct(let guid) = buildFile.buildableItem,
                   case let target as PackageProductTarget = workspaceContext.workspace.target(for: guid),
                   let frameworksBuildPhase = target.frameworksBuildPhase,
                   buildFilesContext.currentPlatformFilter.matches(buildFile.platformFilters) {
                    if globalProductPlan.dynamicallyBuildingTargets.contains(target) {
                        result.append(buildFile)
                    } else {
                        visit(frameworksBuildPhase)
                    }
                    continue
                }

                // Resolve the reference to get its path, but then skip it if it should be excluded.
                if let resolvedBuildFileInfo = try? resolveBuildFileReference(buildFile) {
                    // A file is excluded if it is in the exclusion list and not in the inclusion list.
                    if case let .excluded(exclusionReason) = buildFilesContext.filterState(of: resolvedBuildFileInfo.absolutePath, filters: buildFile.platformFilters) {
                        emitFileExclusionDiagnostic(exclusionReason, buildFilesContext, resolvedBuildFileInfo.absolutePath, buildFile.platformFilters, configuredTarget.map { configuredTarget in .buildFile(buildFileGUID: buildFile.guid, buildPhaseGUID: phase.guid, targetGUID: configuredTarget.target.guid) } ?? nil)
                        continue
                    }
                }
                // If it doesn't have a path at all, then we include it, since something downstream may be using shenanigans to add an argument which doesn't need a full path but rather finds it via search paths.

                // If this is the top-level, we always add all entries.
                if isTopLevel {
                    result.append(buildFile)
                    continue
                }

                // Otherwise, we must be traversing something reached via a package product, so we automatically deduplicate entries.
                switch buildFile.buildableItem {
                case .reference(let guid):
                    if seenReferenceGUIDs.insert(guid).inserted {
                        result.append(buildFile)
                    }
                case .targetProduct(let guid):
                    if seenReferenceGUIDs.insert(guid).inserted {
                        result.append(buildFile)
                    }

                    // If this is *specifically* reference to a static library or an object file used as a product, we also look through that target's own link references.
                    //
                    // NOTE: This is a little gross, it might be nicer to simply make this a property of a package specific library target (or even the default behavior for static libraries and object files!)
                    if case let target as StandardTarget = workspaceContext.workspace.target(for: guid) {
                        if target.productTypeIdentifier == "com.apple.product-type.library.static" || target.productTypeIdentifier == "com.apple.product-type.objfile", let phase = target.frameworksBuildPhase {
                            visit(phase)
                        }
                    }
                case .namedReference:
                    result.append(buildFile)
                }
            }
        }
        visit(frameworksPhase)

        return result
    }
}

/// This class adapts the TaskGenerationDelegate protocol used by the Core to that provided by the producer delegate API.
class ProducerBasedTaskGenerationDelegate: TaskGenerationDelegate {
    let producer: StandardTaskProducer
    let context: TaskProducerContext
    let taskOptions: TaskOrderingOptions
    var tasks: [any PlannedTask] = []
    var outputs: [FileToBuild] = []

    init(producer: StandardTaskProducer, context: TaskProducerContext, taskOptions: TaskOrderingOptions = []) {
        self.producer = producer
        self.context = context
        self.taskOptions = taskOptions
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return context.delegate.diagnosticsEngine(for: target)
    }

    var diagnosticContext: DiagnosticContextData {
        return DiagnosticContextData(target: context.configuredTarget)
    }

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        context.delegate.beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        context.delegate.endActivity(id: id, signature: signature, status: status)
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        context.delegate.emit(data: data, for: activity, signature: signature)
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        context.delegate.emit(diagnostic: diagnostic, for: activity, signature: signature)
    }

    var hadErrors: Bool {
        context.delegate.hadErrors
    }

    func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return context.createVirtualNode(name)
    }

    func createNode(_ path: Path) -> PlannedPathNode {
        return context.createNode(path)
    }

    func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        return context.createDirectoryTreeNode(path, excluding: excluding)
    }

    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        return context.createBuildDirectoryNode(absolutePath: path)
    }

    func declareOutput(_ file: FileToBuild) {
        outputs.append(file)
    }

    func declareGeneratedTBDFile(_ path: Path, forVariant variant: String) {
        context.addGeneratedTBDFile(path, forVariant: variant)
    }

    func declareGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String) {
        context.addGeneratedSwiftObjectiveCHeaderFile(path, architecture: architecture)
    }

    func declareGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String) {
        context.addGeneratedSwiftConstMetadataFile(path, architecture: architecture)
    }

    func declareGeneratedSourceFile(_ path: Path) {
        context.addGeneratedSourceFile(path)
    }

    func declareGeneratedInfoPlistContent(_ path: Path) {
        context.addGeneratedInfoPlistContent(path)
    }

    func declareGeneratedPrivacyPlistContent(_ path: Path) {
        context.addPrivacyContentPlistContent(path)
    }

    var additionalCodeSignInputs: OrderedSet<Path> {
        return context.additionalCodeSignInputs
    }

    var buildDirectories: Set<Path> {
        assert(context.phase == .taskGeneration)
        return context.globalProductPlan.buildDirectories.paths
    }

    func createTask(_ builder: inout PlannedTaskBuilder) {
        // Associate the target.
        builder.forTarget = context.configuredTarget

        let orderingOptions = self.taskOptions.union(builder.additionalTaskOrderingOptions)
        // A compilation or linking requirement should have a priority of at least `unblocksDownstreamTasks`
        if !orderingOptions.isDisjoint(with: [.compilationRequirement, .linkingRequirement]) {
            builder.priority = max(.unblocksDownstreamTasks, builder.priority)
        }

        if builder.enableSandboxing {
            context.sandbox(builder: &builder, delegate: self)
        }

        tasks.append(context.createTask(orderingOptions, &builder))
    }

    func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) {
        let gateTask = context.createGateTask(inputs, output: output, name: name, mustPrecede: mustPrecede) { builder in
            taskConfiguration(&builder)

            builder.forTarget = context.configuredTarget
        }

        tasks.append(gateTask)
    }

    var taskActionCreationDelegate: any TaskActionCreationDelegate { return context.delegate.taskActionCreationDelegate }

    var clientDelegate: any CoreClientDelegate { return context.delegate.clientDelegate }

    func createOrReuseSharedNodeWithIdentifier(_ ident: String, creator: () -> (any PlannedNode, any Sendable)) -> (any PlannedNode, any Sendable) {
        return context.globalProductPlan.sharedIntermediateNodes.getOrInsert(ident, creator)
    }

    func access(path: Path) {
        producer.access(path: path)
    }

    func readFileContents(_ path: Path) throws -> ByteString {
        return try producer.readFileContents(path)
    }

    func fileExists(at path: Path) -> Bool {
        return producer.fileExists(at: path)
    }

    func recordAttachment(contents: SWBUtil.ByteString) -> SWBUtil.Path {
        return producer.recordAttachment(contents: contents)
    }

    var userPreferences: UserPreferences {
        return context.workspaceContext.userPreferences
    }
}


/// This class adapts the TaskGenerationDelegate protocol used by the Core to that provided by the producer delegate API, to provide phase ordering among tasks created by different `PhasedTaskProducers`.
///
/// This delegate auto-attaches constructed tasks to the phase ordering gates.
class PhasedProducerBasedTaskGenerationDelegate: ProducerBasedTaskGenerationDelegate {
    let phaseStartNodes: [any PlannedNode]
    let phaseEndTask: any PlannedTask

    init(producer: PhasedTaskProducer, context: TaskProducerContext, taskOptions: TaskOrderingOptions = [], phaseStartNodes: [any PlannedNode], phaseEndTask: any PlannedTask) {
        self.phaseStartNodes = phaseStartNodes
        self.phaseEndTask = phaseEndTask
        super.init(producer: producer, context: context, taskOptions: taskOptions)
    }

    override func createTask(_ builder: inout PlannedTaskBuilder) {
        // Attach the phase.
        let orderingOptions = self.taskOptions.union(builder.additionalTaskOrderingOptions)
        if !orderingOptions.contains(.ignorePhaseOrdering) {
            builder.inputs += phaseStartNodes
        }
        builder.mustPrecede.append(phaseEndTask)

        super.createTask(&builder)
    }

    override func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) {
        super.createGateTask(inputs: inputs, output: output, name: name, mustPrecede: mustPrecede) { builder in
            taskConfiguration(&builder)

            // Attach the phase.
            builder.inputs += phaseStartNodes
            builder.mustPrecede.append(phaseEndTask)
        }
    }
}

fileprivate extension Result where Success: Spec & IdentifiedSpecType, Failure == any Error {
    init(_ workspaceContext: WorkspaceContext, _ settings: Settings) {
        self = Result { try workspaceContext.core.specRegistry.getSpec(domain: settings.platform?.name ?? "") }
    }
}
