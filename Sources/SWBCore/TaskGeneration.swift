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

public import Foundation
public import SWBUtil
public import SWBProtocol
public import SWBMacro

/// Base class for spec cache types.
///
/// This protocol is only used for making it explicit which types serve as spec data caches.
public protocol SpecDataCache: Sendable {
    init()
}

/// Descriptor for the user-module status of an individual target.
//
// FIXME: It is rather unfortunate that we need to expose this at this level. Only Swift uses this, currently.
public struct ModuleInfo {
    /// Whether the user-module is only created via the implicit definition from Swift.
    public let forSwiftOnly: Bool

    /// Whether the target exports the Swift generated ObjC API.
    public let exportsSwiftObjCAPI: Bool

    /// The name of the umbrella header to be used in module.modulemap file generation, if it should be generated.
    public let umbrellaHeader: String

    public struct ModuleMapPathInfo {
        /// The path of the .modulemap file in the sources.
        ///
        /// If the source file is defined but empty, then the producer will emit an error.  This will be the same as .moduleMapTmpPath if the module map is synthesized.
        public let sourcePath: Path

        /// The path of the .modulemap file in the staging location for the build.
        ///
        /// If the source file is defined but empty, then the producer will emit an error.
        public let tmpPath: Path

        /// The path of the .modulemap file in the built product location.
        ///
        /// If the source file is defined but empty, then the producer will emit an error.
        public let builtPath: Path
    }

    /// Various paths of the module.modulemap file.
    public let moduleMapPaths: ModuleMapPathInfo

    /// Various paths of the module.private.modulemap file.  Will be nil if there is no private modulemap.
    public let privateModuleMapPaths: ModuleMapPathInfo?

    /// The name of Clang module(s) known to be defined by this target, if any. The list may not be complete in the presence of build scripts, hand authored modulemaps, etc.
    public let knownClangModuleNames: [String]

    public init(forSwiftOnly: Bool, exportsSwiftObjCAPI: Bool, umbrellaHeader: String, moduleMapSourcePath: Path, privateModuleMapSourcePath: Path?, moduleMapTmpPath: Path, privateModuleMapTmpPath: Path?, moduleMapBuiltPath: Path, privateModuleMapBuiltPath: Path?, knownClangModuleNames: [String]) {
        self.forSwiftOnly = forSwiftOnly
        self.exportsSwiftObjCAPI = exportsSwiftObjCAPI
        self.umbrellaHeader = umbrellaHeader
        self.moduleMapPaths = ModuleMapPathInfo(sourcePath: moduleMapSourcePath, tmpPath: moduleMapTmpPath, builtPath: moduleMapBuiltPath)
        if let src = privateModuleMapSourcePath, let tmp = privateModuleMapTmpPath, let built = privateModuleMapBuiltPath {
            self.privateModuleMapPaths = ModuleMapPathInfo(sourcePath: src, tmpPath: tmp, builtPath: built)
        } else {
            self.privateModuleMapPaths = nil
        }
        self.knownClangModuleNames = knownClangModuleNames
    }
}

public protocol PlatformBuildContext {
    var sdk: SDK? { get }
    var sdkVariant: SDKVariant? { get }
    var platform: Platform? { get }
}

extension PlatformBuildContext {
    public var targetBuildVersionPlatform: BuildVersion.Platform? {
        return sdk?.targetBuildVersionPlatform(sdkVariant: sdkVariant)
    }

    public func targetBuildVersionPlatforms(in scope: MacroEvaluationScope) -> Set<BuildVersion.Platform>? {
        if let platform = targetBuildVersionPlatform {
            if (platform == .macOS || platform == .macCatalyst) && scope.evaluate(BuiltinMacros.IS_ZIPPERED) {
                return [.macOS, .macCatalyst]
            }
            return [platform]
        }
        return nil
    }
}

/// Protocol describing the interface producers use to communicate information to the command build context.
public protocol CommandProducer: PlatformBuildContext, SpecLookupContext, ReferenceLookupContext, PlatformInfoLookup {
    /// The configured target the command is being produced for, if any.
    var configuredTarget: ConfiguredTarget? { get }

    /// The product type being built. (Only `StandardTarget`s have product types.)
    var productType: ProductTypeSpec? { get }

    /// The SDK in effect, if any.
    var sdk: SDK? { get }

    /// The SDK variant in effect, if any.
    var sdkVariant: SDKVariant? { get }

    /// The platform in effect.
    var platform: Platform? { get }

    /// The preferred arch for the target.
    ///
    /// This is currently used for indexing.
    var preferredArch: String? { get }

    /// The list of toolchains (in priority order) in effect.
    var toolchains: [Toolchain] { get }

    /// The sparse SDKs in effect.
    var sparseSDKs: [SDK] { get }

    /// The executable search paths to use.
    var executableSearchPaths: StackedSearchPath { get }

    // FIXME: Move these specs out of here, we should just pre-bind these in the core so no one ever needs to look things like that up.

    /// The Clang compiler spec to use.
    var clangSpec: ClangCompilerSpec { get }

    /// The Clang assembler spec to use.
    var clangAssemblerSpec: ClangCompilerSpec { get }

    /// The Clang preprocessor spec to use.
    var clangPreprocessorSpec: ClangCompilerSpec { get }

    /// The Clang static analyzer tool spec to use.
    var clangStaticAnalyzerSpec: ClangCompilerSpec { get }

    /// The Clang modules verifier tool spec to use.
    var clangModuleVerifierSpec: ClangCompilerSpec { get }

    /// The diff spec to use.
    var diffSpec: CommandLineToolSpec { get }

    /// The strip spec to use.
    var stripSpec: StripToolSpec { get }

    /// The swift compiler tool spec to use.
    var swiftCompilerSpec: SwiftCompilerSpec { get }

    /// The linker spec to use.
    var ldLinkerSpec: LdLinkerSpec { get }

    /// The libtool spec to use.
    var libtoolLinkerSpec: LibtoolLinkerSpec { get }

    /// The lipo spec to use.
    var lipoSpec: LipoToolSpec { get }

    /// The code sign tool spec to use.
    var codesignSpec: CodesignToolSpec { get }

    /// The copy tool spec to use.
    var copySpec: CopyToolSpec { get }

    /// The copy-png spec to use.
    var copyPngSpec: CommandLineToolSpec { get }

    /// The copy-tiff spec to use.
    var copyTiffSpec: CommandLineToolSpec { get }

    /// The unifdef spec to use.
    var unifdefSpec: UnifdefToolSpec { get }

    /// The auxiliary file spec to use.
    var writeFileSpec: WriteFileSpec { get }

    /// The mkdir spec to use.
    var mkdirSpec: MkdirToolSpec { get }

    /// The create-build-directory spec to use.
    var createBuildDirectorySpec: CreateBuildDirectorySpec { get }

    var processSDKImportsSpec: ProcessSDKImportsSpec { get }

    /// The default working directory to use for a task, if it doesn't have a stronger preference.
    var defaultWorkingDirectory: Path { get }

    /// Resolve a file reference GUID.
    func lookupReference(for guid: String) -> Reference?

    /// The registry used for spec data caches.
    ///
    /// This is not generally intended to be used directly, clients of task generation should use `getSpecDataCache`.
    var specDataCaches: Registry<Spec, any SpecDataCache> { get }

    /// The module info for the target, if available.
    var moduleInfo: ModuleInfo? { get }

    /// Whether or not the build is using a VFS.
    var needsVFS: Bool { get }

    /// Whether or not to generate additional commands for producing assembly code.
    var generateAssemblyCommands: Bool { get }

    /// Whether or not to generate additional commands for producing preprocessed files.
    var generatePreprocessCommands: Bool { get }

    /// The file path resolver in effect.
    ///
    /// This is exposed primarily so that tool specifications can resolve paths of related references they discover, for example other references in a variant group beyond the primary one being processed.
    var filePathResolver: FilePathResolver { get }

    /// The specification registry.
    var specRegistry: SpecRegistry { get }

    /// Code signing & provisioning settings
    var signingSettings: Settings.SigningSettings? { get }

    /// The product build version of Xcode.
    var xcodeProductBuildVersion: ProductBuildVersion? { get }

    /// Information about the runtime system
    var systemInfo: SystemInfo? { get }

    /// Compute the expanded search path list (i.e. with recursive entries expanded) for the given macro.
    func expandedSearchPaths(for items: [String], scope: MacroEvaluationScope) -> [String]

    /// If On-Demand Resources is enabled, provides an asset pack for the given tag set.
    func onDemandResourcesAssetPack(for tags: ODRTagSet) -> ODRAssetPackInfo?

    /// Macro evaluation scopes of all dependencies of this target, direct and transitive.
    /// Used to query dependency information such as its Swiftmodule output path.
    func targetSwiftDependencyScopes(for target: ConfiguredTarget, arch: String, variant: String) -> [MacroEvaluationScope]

    /// Swift macro implementation descriptors to be applied to this target.
    var swiftMacroImplementationDescriptors: Set<SwiftMacroImplementationDescriptor>? { get }

    func supportsEagerLinking(scope: MacroEvaluationScope) -> Bool

    /// Returns information on the headers referenced by an individual project, identified by one of the targets in that project.
    /// - Parameter target: A target in the project to return header information for.
    /// - Returns: Information on the headers referenced by the project that the given target is a part of.
    func projectHeaderInfo(for target: Target) async -> ProjectHeaderInfo?

    /// Whether or not an SDK stat cache should be used for the build of this target.
    func shouldUseSDKStatCache() async -> Bool

    func discoveredCommandLineToolSpecInfo(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String, _ path: Path, _ process: @Sendable (_ contents: Data) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> any DiscoveredCommandLineToolSpecInfo

    func discoveredCommandLineToolSpecInfo(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String?, _ commandLine: [String], _ process: @Sendable (_ processResult: Processes.ExecutionResult) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> any DiscoveredCommandLineToolSpecInfo

    var canConstructAppIntentsMetadataTask: Bool { get }

    var canConstructAppIntentsSSUTask: Bool { get }

    var targetRequiredToBuildForIndexing: Bool { get }

    var targetShouldBuildModuleForInstallAPI: Bool { get }

    var supportsCompilationCaching: Bool { get }

    func lookupLibclang(path: Path) -> (libclang: Libclang?, version: Version?)

    var userPreferences: UserPreferences { get }

    var hostOperatingSystem: OperatingSystem { get }
}

extension CommandProducer {
    /// Whether the current context is targeting an Apple platform, based on the target triple's vendor being "apple".
    public var isApplePlatform: Bool {
        sdkVariant?.llvmTargetTripleVendor == "apple"
    }

    package func discoveredCommandLineToolSpecInfo<T: DiscoveredCommandLineToolSpecInfo>(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String, _ path: Path, _ process: @Sendable (_ contents: Data) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> T {
        let info = try await discoveredCommandLineToolSpecInfo(delegate, toolName, path, process)
        guard let info = info as? T else {
            throw StubError.error("Expected value of type \(type(of: T.self)) but found \(type(of: info))")
        }
        return info
    }

    package func discoveredCommandLineToolSpecInfo<T: DiscoveredCommandLineToolSpecInfo>(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String?, _ commandLine: [String], _ process: @Sendable (_ processResult: Processes.ExecutionResult) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> T {
        let info = try await discoveredCommandLineToolSpecInfo(delegate, toolName, commandLine, process)
        guard let info = info as? T else {
            throw StubError.error("Expected value of type \(type(of: T.self)) but found \(type(of: info))")
        }
        return info
    }
}

extension CommandProducer {
    /// Get or create the per-tool cache for the given spec.
    ///
    /// This allows individual tool implementations to store a cache for use across multiple invocations. The cache is specific to the given spec, unique for any individual `configuredTarget`, but shared for all command production using the same producer. It persists for the lifetime of the producer.
    ///
    /// NOTE: Only one cache type can be stored per spec.
    func getSpecDataCache<T: SpecDataCache>(_ spec: Spec, cacheType: T.Type) -> T {
        let cache = specDataCaches.getOrInsert(spec) {
            return cacheType.init() as T
        }
        return cache as! T
    }

    /// Compute the expanded search path list (i.e. with recursive entries expanded) for the given macro.
    func expandedSearchPaths(for macro: PathListMacroDeclaration, scope: MacroEvaluationScope) -> [String] {
        return expandedSearchPaths(for: scope.evaluate(macro), scope: scope)
    }
}

/// Describes the context in which an individual invocation of a command line spec is being built.
public struct CommandBuildContext {
    /// The settings context the command is being evaluated in.
    public let producer: any CommandProducer

    /// The scope to use for evaluating build settings.
    public let scope: MacroEvaluationScope

    /// The list of input items.
    public let inputs: [FileToBuild]

    /// The sole input item.  This method asserts that there is exactly one.
    public var input: FileToBuild {
        precondition(inputs.count == 1, "Expected only a single input for this command invocation; found \(inputs.count): \(inputs)")
        return inputs[0]
    }

    /// The list of output paths.  Currently, this can only be empty, or contain a single item.
    public let outputs: [Path]

    // FIXME: This is only used by some specs, it would be nice to have some enforcement that it is passed to the ones that require it.
    //
    /// The path of the sole output, if specified.  This property asserts that an output exists and that there is only one.
    public var output: Path {
        precondition(outputs.count == 1, "Expected an output for this command invocation; found nil")
        return outputs[0]
    }

    // FIXME: This mechanism is only used in _very_ limited circumstances currently to provide a way to enforce additional ordering between tasks (which is required by our current mutable output handling), when no other ordering is in place (i.e. no build phase is in between the producer and consumer).
    //
    /// Nodes to treat as additional inputs to tasks created with this context, for ordering purposes.
    public let commandOrderingInputs: [any PlannedNode]

    // FIXME: This mechanism is only used in _very_ limited circumstances currently to provide a way to enforce additional ordering between tasks (which is required by our current mutable output handling), when no other ordering is in place (i.e. no build phase is in between the producer and consumer).
    //
    /// Nodes to treat as additional outputs of tasks created with this context, for ordering purposes.
    public let commandOrderingOutputs: [any PlannedNode]

    /// The context to use for the task being produced.
    public let buildPhaseInfo: (any BuildPhaseInfoForToolSpec)?

    /// The path of the resources directory, if specified.
    public let resourcesDir: Path?

    /// The path of the temporary resources directory, if specified.
    public let tmpResourcesDir: Path?

    /// The path of the unlocalized resources directory, if specified.
    public let unlocalizedResourcesDir: Path?

    /// True if this is the preferred arch among all the archs we're building for same inputs.
    public let isPreferredArch: Bool

    /// Whether this command is needed for index preparation.
    public var preparesForIndexing: Bool

    /// The spec of the current arch in a per-arch task
    public let currentArchSpec: ArchitectureSpec?

    public init(
        producer: any CommandProducer, scope: MacroEvaluationScope,
        inputs: [FileToBuild], isPreferredArch: Bool = true,
        currentArchSpec: ArchitectureSpec? = nil,
        output: Path? = nil,
        commandOrderingInputs: [any PlannedNode] = [],
        commandOrderingOutputs: [any PlannedNode] = [],
        buildPhaseInfo: (any BuildPhaseInfoForToolSpec)? = nil,
        resourcesDir: Path? = nil, tmpResourcesDir: Path? = nil,
        unlocalizedResourcesDir: Path? = nil,
        preparesForIndexing: Bool = false
    ) {
        self.init(
            producer: producer, scope: scope, inputs: inputs,
            isPreferredArch: isPreferredArch,
            currentArchSpec: currentArchSpec,
            outputs: output.map { [$0] } ?? [],
            commandOrderingInputs: commandOrderingInputs,
            commandOrderingOutputs: commandOrderingOutputs,
            buildPhaseInfo: buildPhaseInfo, resourcesDir: resourcesDir,
            tmpResourcesDir: tmpResourcesDir,
            unlocalizedResourcesDir: unlocalizedResourcesDir,
            preparesForIndexing: preparesForIndexing
        )
    }

    public init(
        producer: any CommandProducer, scope: MacroEvaluationScope,
        inputs: [FileToBuild], isPreferredArch: Bool = true,
        currentArchSpec: ArchitectureSpec? = nil,
        outputs: [Path],
        commandOrderingInputs: [any PlannedNode] = [],
        commandOrderingOutputs: [any PlannedNode] = [],
        buildPhaseInfo: (any BuildPhaseInfoForToolSpec)? = nil,
        resourcesDir: Path? = nil, tmpResourcesDir: Path? = nil,
        unlocalizedResourcesDir: Path? = nil,
        preparesForIndexing: Bool = false
    ) {
        // We normalize paths here so their normalized forms are consistently available to CommandLineToolSpec instances.  The old build system normalized paths in almost all cases.
        self.producer = producer
        self.scope = scope
        self.isPreferredArch = isPreferredArch
        self.preparesForIndexing = preparesForIndexing
        self.currentArchSpec = currentArchSpec
        self.inputs = inputs
        self.outputs = outputs.map({ $0.normalize() })
        self.commandOrderingInputs = commandOrderingInputs
        self.commandOrderingOutputs = commandOrderingOutputs
        self.buildPhaseInfo = buildPhaseInfo
        self.resourcesDir = resourcesDir?.normalize()
        self.tmpResourcesDir = tmpResourcesDir?.normalize()
        self.unlocalizedResourcesDir = unlocalizedResourcesDir?.normalize()
    }
}

extension CommandBuildContext {
    /// Indicates whether the "normal" variant is being processed, or if the variant being processed is the only variant.
    /// In the case where there is no "normal" variant, we choose the first one among the list.
    ///
    /// FIXME: This is a hack designed to easily allow constructing variant-neutral tasks (tasks for which there should be only one instance of per-product, regardless of the number of variants) until we have first-class support for this (rdar://45330111).
    var isNeutralVariant: Bool {
        let variants = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        let current = scope.evaluate(BuiltinMacros.CURRENT_VARIANT)
        return variants.count == 1 || current == "normal" || (!variants.contains("normal") && variants.first == current)
    }

    /// Indicates whether the product being built in the current command context is a framework (dynamically or statically linked).
    public var isFramework: Bool {
        return scope.isFramework
    }

    /// Make an input path absolute, resolving relative to the default
    /// working directory.
    func makeAbsolute(_ path: Path) -> Path {
        producer.defaultWorkingDirectory.join(path)
    }

    /// Returns a new `CommandBuildContext` with the specified outputs appended to its outputs array.
    public func appendingOutputs(_ outputs: [Path]) -> Self {
        Self(producer: producer, scope: scope, inputs: inputs, isPreferredArch: isPreferredArch, currentArchSpec: currentArchSpec, outputs: self.outputs + outputs, commandOrderingInputs: commandOrderingInputs, commandOrderingOutputs: commandOrderingOutputs, buildPhaseInfo: buildPhaseInfo, resourcesDir: resourcesDir, tmpResourcesDir: tmpResourcesDir, unlocalizedResourcesDir: unlocalizedResourcesDir)
    }
}

extension MacroEvaluationScope {
    var isFramework: Bool {
        let type = evaluate(BuiltinMacros.PRODUCT_TYPE)
        return type == "com.apple.product-type.framework" || type == "com.apple.product-type.framework.static"
    }
}

/// Options passed when creating a task that determine how it should be ordered within its own target and with respect to other targets. These are primarily used when creating tasks when eager compilation is enabled (which it is by default).
///
/// For use of these options, see `TaskProducerContext.additionalInputsForTask()` and `TaskProducerContext.additionalMustPrecedeTasksForTask()`.
///
/// This is an `OptionSet` because a few tasks need multiple options. For instance, compiling sources is both a compilation task and a requirement for compilation tasks of downstream targets.
public struct TaskOrderingOptions: OptionSet, CustomDebugStringConvertible, Sendable {
    public let rawValue: Int
    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(rawValue: Int) {
        self.init(rawValue)
    }

    // TASK TYPE DESCRIPTIONS: These options describe a kind of task, which may cause them to have a defined relationship to other kinds of tasks.

    /// Tasks that perform compilation, and can start before upstream targets have finished building.  They can start running once all tasks in upstream targets marked `compilationRequirement` have run.
    public static let compilation = TaskOrderingOptions(1 << 0)

    /// Tasks for compiling an indexable source file.
    public static let compilationForIndexableSourceFile = TaskOrderingOptions(1 << 2)

    /// Tasks that perform linking, and can start once all tasks in upstream targets marked `linkingRequirement` have run.
    public static let linking = TaskOrderingOptions(1 << 7)

    // UPSTREAM REQUIREMENTS: These are options which prevent these tasks from running until certain upstream tasks have finished running.

    /// Tasks that can be run immediately, without waiting for any tasks in their target or any other targets to run. If such a task is constructed as part of a build phase, it may still be ordered relative to other phases.
    public static let immediate = TaskOrderingOptions(1 << 3)

    /// Tasks that are blocked by headers of the same target completed copying
    public static let blockedByTargetHeaders = TaskOrderingOptions(1 << 4)

    // DOWNSTREAM REQUIREMENTS: These are options which prevent certain kinds of downstream tasks from running until these tasks have finished running.  By convention, these tasks end with the word 'requirement', to distinguish them from upstream requirements.

    /// Tasks that need to run before downstream targets can start compiling their sources. This includes installing module maps, copying headers, and - because of Swift - compiling sources. This option is also used when creating tasks which execute shell scripts, as we want to be conservative with such scripts and not assume they won't impact downstream compilation.
    public static let compilationRequirement = TaskOrderingOptions(1 << 5)

    /// Tasks that need to run before the unsigned product is considered to be finished.
    public static let unsignedProductRequirement = TaskOrderingOptions(1 << 6)

    /// Tasks that need to run before downstream targets can begin linking. This includes tasks which emit text-based dylibs  to unblock downstream linking if supported by the target, or the linking task itself.
    public static let linkingRequirement = TaskOrderingOptions(1 << 8)

    /// Tasks that scan a target (via libclang or Swift driver) need to be blocked on each other, adding this ordering option will guarantee this
    public static let scanning = TaskOrderingOptions(1 << 9)

    /// Tasks which are constructed as part of a build phase, but are ordered independently of all build phases.
    public static let ignorePhaseOrdering = TaskOrderingOptions(1 << 10)

    public var debugDescription: String {
        return "<TaskOrderingOptions [" + [
            "compilation": .compilation,
            "compilationForIndexableSourceFile": .compilationForIndexableSourceFile,
            "linking": .linking,

            "immediate": TaskOrderingOptions.immediate,
            "blockedByTargetHeaders": .blockedByTargetHeaders,

            "compilationRequirement": .compilationRequirement,
            "unsignedProductRequirement": .unsignedProductRequirement,
            "linkingRequirement": .linkingRequirement,
            "scanning": .scanning,
            "ignorePhaseOrdering": .ignorePhaseOrdering,
            ].compactMap { (description, rawValue) -> String? in
                return self.contains(rawValue) ? description : nil
        }.joined(separator: ", ") + "]>"
    }
}

/// A utility for constructing generated tasks.
public struct PlannedTaskBuilder {
    /// The target the task runs on behalf of, if known.
    public var forTarget: ConfiguredTarget? = nil

    /// The type of task being generated.
    public let type: any TaskTypeDescription

    /// Information emitted by the execution of this task, which will allow additional dependency information be discovered.
    public var dependencyData: DependencyDataStyle? = nil

    /// The task type specific payload, if present.
    public var payload: (any TaskPayload)? = nil

    /// The rule signature for the task.
    public var ruleInfo: [String]

    /// Additional arbitrary data used to contribute to the task's change-tracking signature.
    public var additionalSignatureData: String

    /// The command line for the task.
    public var commandLine: [CommandLineArgument]

    /// Additional output that should be displayed for the task. Each element will be emitted on a separate line.
    ///
    /// This will be emitted after the  rule info and after the `cd` and `export` directives in the transcript, but before the command line.
    public var additionalOutput: [String]

    /// The environment to use to evaluate the task.
    public var environment: EnvironmentBindings

    /// The working directory for the task.
    //
    // FIXME: Make this optional
    public var workingDirectory: Path = Path("/")

    /// The list of task inputs.
    public var inputs: [any PlannedNode]

    /// The list of task outputs.
    public var outputs: [any PlannedNode]

    /// The list of tasks this task must run before.
    public var mustPrecede: [any PlannedTask]

    /// The action to use to execute the task.
    public var action: (any PlannedTaskAction)? = nil

    /// The description to use when executing the task.
    public var execDescription: String? = nil

    public var priority: TaskPriority

    /// List of target dependencies related to this task. This is used by target gate tasks.
    public var targetDependencies = [ResolvedTargetDependency]()

    public var additionalTaskOrderingOptions: TaskOrderingOptions

    /// Whether or not the task is required to run when preparing to index.
    public var preparesForIndexing: Bool = false

    /// Whether the llbuild control file descriptor is disabled for this task
    public var llbuildControlDisabled: Bool = false

    /// Whether or not this is a gate task.
    public fileprivate(set) var isGate = false

    public var usesExecutionInputs = false

    /// Allows a task to always be executed.
    public var alwaysExecuteTask: Bool

    /// Whether the task should show its environment in logs.
    public var showEnvironment: Bool = true

    public fileprivate(set) var showInLog: Bool

    public fileprivate(set) var showCommandLineInLog: Bool

    public var enableSandboxing: Bool

    public var repairViaOwnershipAnalysis: Bool

    public init(type: any TaskTypeDescription, ruleInfo: [String], additionalSignatureData: String = "", commandLine: [CommandLineArgument], additionalOutput: [String] = [], environment: EnvironmentBindings = EnvironmentBindings(), inputs: [any PlannedNode] = [], outputs: [any PlannedNode] = [], mustPrecede: [any PlannedTask] = [], deps: DependencyDataStyle? = nil, additionalTaskOrderingOptions: TaskOrderingOptions = [], usesExecutionInputs: Bool = false, alwaysExecuteTask: Bool = false, showInLog: Bool = true, showCommandLineInLog: Bool = true, priority: TaskPriority = .unspecified, enableSandboxing: Bool = false, repairViaOwnershipAnalysis: Bool = false) {
        self.type = type
        self.ruleInfo = ruleInfo
        self.additionalSignatureData = additionalSignatureData
        self.commandLine = commandLine
        self.additionalOutput = additionalOutput
        self.environment = environment
        self.inputs = inputs
        self.outputs = outputs
        self.mustPrecede = mustPrecede
        self.dependencyData = deps
        self.additionalTaskOrderingOptions = additionalTaskOrderingOptions
        self.usesExecutionInputs = usesExecutionInputs
        self.alwaysExecuteTask = alwaysExecuteTask
        self.showInLog = showInLog
        self.showCommandLineInLog = showCommandLineInLog
        self.priority = priority
        self.enableSandboxing = enableSandboxing
        self.repairViaOwnershipAnalysis = repairViaOwnershipAnalysis
    }

    public mutating func makeGate() {
        isGate = true
        showInLog = false
    }
}

/// Interface by which core classes can request information from the client.
public protocol CoreClientDelegate {
    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> ExternalToolResult
}

public protocol CoreClientTargetDiagnosticProducingDelegate: AnyObject, TargetDiagnosticProducingDelegate, ActivityReporter {
    /// Delegate which can be used to query the client for needed information for task generation.
    var coreClientDelegate: any CoreClientDelegate { get }
}

/// Interface by which command line specs can describe tasks to build.
public protocol TaskGenerationDelegate: AnyObject, TargetDiagnosticProducingDelegate, CoreClientTargetDiagnosticProducingDelegate, ActivityReporter {
    // FIXME: It would be nice to support diagnostics specific to an individual command build.

    /// Create a virtual node.
    func createVirtualNode(_ name: String) -> PlannedVirtualNode

    /// Create a node for the given path.
    func createNode(_ path: Path) -> PlannedPathNode

    /// Create a node representing a directory on the file system.
    ///
    /// - absolutePath: The input path, which must be absolute.
    /// - excluding: The fnmatch-style patterns to ignore.
    func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode

    /// Create a node representing a top-level directory used by the build.
    ///
    /// This is used for ensuring these directories are only created once across the entire build.
    /// If a node for `path` already exists, the existing instance will be returned.
    ///
    /// - parameter absolutePath: The input path, which must be absolute.
    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode

    /// Declare an output path for possible reprocessing.
    func declareOutput(_ file: FileToBuild)

    /// Declare a generated source file.
    ///
    /// This file will be added to the generated files headermap.
    //
    // FIXME: Could we handle this automatically based simply on the declared outputs? We know from the file type which are source files.
    func declareGeneratedSourceFile(_ path: Path)

    /// Declare a generated info plist addition.
    func declareGeneratedInfoPlistContent(_ path: Path)

    func declareGeneratedPrivacyPlistContent(_ path: Path)

    /// Declare a custom TBD file.
    func declareGeneratedTBDFile(_ path: Path, forVariant variant: String)

    /// Declare a generated Swift Objective-C interface file.
    func declareGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String)

    /// Declare a generated Swift Supplementary compile-time value Metadata file.
    func declareGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String)

    var buildDirectories: Set<Path> { get }

    /// The set of additional inputs for codesigning. These are tracked explicitly on the codesign task and are captured during the `.planning` phase.
    var additionalCodeSignInputs: OrderedSet<Path> { get }

    /// Create a new task with a reference to the task type and scope, and with fully expanded rule info, command line, and optional input/output dependencies.
    func createTask(_ builder: inout PlannedTaskBuilder)

    /// Create a gate task for use in controlling task ordering.
    ///
    /// Gate tasks don't actually execute any work, but instead are used to realize an ordering constraint between the inputs and the output.
    func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void)

    /// Delegate which can create different kinds of `TaskAction` objects.
    var taskActionCreationDelegate: any TaskActionCreationDelegate { get }

    /// Delegate which can be used to query the client for needed information for task generation.
    var clientDelegate: any CoreClientDelegate { get }

    /// Looks up `key` in a concurrency-safe mapping associated with the product plan; if a node is associated with that key, it is simply returned; otherwise, the block is invoked to create a node, and then that node is returned after associating it with the key.  This is intended for shareable intermediate artifacts, such as header precompilation tasks, that are created the first time they are needed and that can then be referenced by any other case that needs the same intermediate node.
    /// FIXME: This is arguably a bit esoteric, but creating API that explicitly deals with precompiled headers seemed wrong here.  Rather, this is intended to be a way to provide generalized sharing of nodes that are created in quite specialized ways.
    /// FIXME: The name of this method is also a bit awkward.  We could probably do better.
    func createOrReuseSharedNodeWithIdentifier(_ ident: String, creator: () -> (any PlannedNode, any Sendable)) -> (any PlannedNode, any Sendable)

    /// Adds the accessed path to the list of paths which invalidate the build description.
    func access(path: Path)

    /// Reads the contents of the file at `path` and returns its contents as a byte string, and adds the path to the list of paths which invalidate the build description.
    func readFileContents(_ path: Path) throws -> ByteString

    /// Returns true if a file exists at `path`, and adds the path to the list of paths which invalidate the build description.
    func fileExists(at path: Path) -> Bool

    /// Record an arbitrary attachment as part of the build description, which can be accessed at the returned path.
    func recordAttachment(contents: ByteString) -> Path

    /// User preferences
    var userPreferences: UserPreferences { get }
}

extension TaskGenerationDelegate {
    /// Create a node representing a directory on the file system.
    ///
    /// - absolutePath: The input path, which must be absolute.
    public func createDirectoryTreeNode(_ path: Path) -> PlannedDirectoryTreeNode {
        return createDirectoryTreeNode(path, excluding: [])
    }

    public var coreClientDelegate: any CoreClientDelegate {
        clientDelegate
    }
}

extension CoreClientTargetDiagnosticProducingDelegate {
    public func executeExternalTool(commandLine: [String], workingDirectory: String? = nil, environment: [String: String] = [:], executionDescription: String?) async throws -> Processes.ExecutionResult {
        try await withActivity(ruleInfo: "ExecuteExternalTool " + commandLine.joined(separator: " "), executionDescription: executionDescription ?? CommandLineToolSpec.fallbackExecutionDescription, signature: ByteString(encodingAsUTF8: "\(commandLine) \(String(describing: workingDirectory)) \(environment)"), target: nil, parentActivity: ActivityID.buildDescriptionActivity) { activity in
            try await coreClientDelegate.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
        }
    }
}

// Limit the number of concurrently-executing external processes on the host to the number of cores.
private let externalToolExecutionQueue = AsyncOperationQueue(concurrentTasks: ProcessInfo.processInfo.activeProcessorCount)

extension CoreClientDelegate {
    func executeExternalTool(commandLine: [String], workingDirectory: String? = nil, environment: [String: String] = [:]) async throws -> Processes.ExecutionResult {
        switch try await executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment) {
        case .deferred:
            guard let url = commandLine.first.map(URL.init(fileURLWithPath:)) else {
                throw StubError.error("Cannot execute empty command line.")
            }

            return try await externalToolExecutionQueue.withOperation {
                try await Process.getOutput(url: url, arguments: Array(commandLine.dropFirst()), currentDirectoryURL: workingDirectory.map(URL.init(fileURLWithPath:)), environment: Environment.current.addingContents(of: .init(environment)))
            }
        case let .result(status, stdout, stderr):
            return Processes.ExecutionResult(exitStatus: status, stdout: stdout, stderr: stderr)
        }
    }
}

public extension TaskGenerationDelegate {
    /// Create a new task with a reference to the task type and scope, and with fully expanded rule info, command line, and optional input/output dependencies.
    func createTask(type: any TaskTypeDescription, dependencyData: DependencyDataStyle?, payload: (any TaskPayload)?, ruleInfo: [String], additionalSignatureData: String, commandLine: [CommandLineArgument], additionalOutput: [String], environment: EnvironmentBindings, workingDirectory: Path, inputs: [any PlannedNode], outputs: [any PlannedNode], mustPrecede: [any PlannedTask], action: (any PlannedTaskAction)?, execDescription: String?, preparesForIndexing: Bool, enableSandboxing: Bool, llbuildControlDisabled: Bool, additionalTaskOrderingOptions: TaskOrderingOptions, usesExecutionInputs: Bool = false, isGate: Bool = false, alwaysExecuteTask: Bool = false, showInLog: Bool = true, showCommandLineInLog: Bool = true, showEnvironment: Bool = false, priority: TaskPriority = .unspecified, repairViaOwnershipAnalysis: Bool = false) {
        var builder = PlannedTaskBuilder(type: type, ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: commandLine, additionalOutput: additionalOutput, environment: environment, enableSandboxing: enableSandboxing)
        builder.dependencyData = dependencyData
        builder.payload = payload
        builder.workingDirectory = workingDirectory
        builder.inputs = inputs
        builder.outputs = outputs
        builder.mustPrecede = mustPrecede
        builder.action = action
        builder.execDescription = execDescription
        builder.preparesForIndexing = preparesForIndexing
        builder.llbuildControlDisabled = llbuildControlDisabled
        builder.additionalTaskOrderingOptions = additionalTaskOrderingOptions
        builder.usesExecutionInputs = usesExecutionInputs
        builder.isGate = isGate
        builder.alwaysExecuteTask = alwaysExecuteTask
        builder.showInLog = showInLog
        builder.showCommandLineInLog = showCommandLineInLog
        builder.showEnvironment = showEnvironment
        builder.priority = priority
        builder.repairViaOwnershipAnalysis = repairViaOwnershipAnalysis
        createTask(&builder)
    }

    func createTask(type: any TaskTypeDescription, dependencyData: DependencyDataStyle?, payload: (any TaskPayload)?, ruleInfo: [String], additionalSignatureData: String, commandLine: [ByteString], additionalOutput: [String], environment: EnvironmentBindings, workingDirectory: Path, inputs: [any PlannedNode], outputs: [any PlannedNode], mustPrecede: [any PlannedTask], action: (any PlannedTaskAction)?, execDescription: String?, preparesForIndexing: Bool, enableSandboxing: Bool, llbuildControlDisabled: Bool, additionalTaskOrderingOptions: TaskOrderingOptions, usesExecutionInputs: Bool = false, isGate: Bool = false, alwaysExecuteTask: Bool = false, showInLog: Bool = true, showCommandLineInLog: Bool = true, showEnvironment: Bool = false, priority: TaskPriority = .unspecified, repairViaOwnershipAnalysis: Bool = false) {
        createTask(type: type, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: commandLine.map { .literal($0) }, additionalOutput: additionalOutput, environment: environment, workingDirectory: workingDirectory, inputs: inputs, outputs: outputs, mustPrecede: mustPrecede, action: action, execDescription: execDescription, preparesForIndexing: preparesForIndexing, enableSandboxing: enableSandboxing, llbuildControlDisabled: llbuildControlDisabled, additionalTaskOrderingOptions: additionalTaskOrderingOptions, usesExecutionInputs: usesExecutionInputs, isGate: isGate, alwaysExecuteTask: alwaysExecuteTask, showInLog: showInLog, showCommandLineInLog: showCommandLineInLog, showEnvironment: showEnvironment, priority: priority, repairViaOwnershipAnalysis: repairViaOwnershipAnalysis)
    }

    /// Create a new task taking inputs and outputs as `Path` arrays.  They will be implicitly marshalled into `PlannedNode` arrays.
    func createTask(type: any TaskTypeDescription, dependencyData: DependencyDataStyle? = nil, payload: (any TaskPayload)? = nil, ruleInfo: [String], additionalSignatureData: String = "", commandLine: [ByteString], additionalOutput: [String] = [], environment: EnvironmentBindings, workingDirectory: Path, inputs: [Path], outputs: [Path], mustPrecede: [any PlannedTask] = [], action: (any PlannedTaskAction)? = nil, execDescription: String? = nil, preparesForIndexing: Bool = false, enableSandboxing: Bool, llbuildControlDisabled: Bool = false, additionalTaskOrderingOptions: TaskOrderingOptions = [], usesExecutionInputs: Bool = false, isGate: Bool = false, alwaysExecuteTask: Bool = false, showInLog: Bool = true, showCommandLineInLog: Bool = true, showEnvironment: Bool = false, priority: TaskPriority = .unspecified, repairViaOwnershipAnalysis: Bool = false) {
        return createTask(type: type, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: commandLine, additionalOutput: additionalOutput, environment: environment, workingDirectory: workingDirectory, inputs: inputs.map(createNode), outputs: outputs.map(createNode), mustPrecede: mustPrecede, action: action, execDescription: execDescription, preparesForIndexing: preparesForIndexing, enableSandboxing: enableSandboxing, llbuildControlDisabled: llbuildControlDisabled, additionalTaskOrderingOptions: additionalTaskOrderingOptions, usesExecutionInputs: usesExecutionInputs, isGate: isGate, alwaysExecuteTask: alwaysExecuteTask, showInLog: showInLog, showCommandLineInLog: showCommandLineInLog, showEnvironment: showEnvironment, priority: priority, repairViaOwnershipAnalysis: repairViaOwnershipAnalysis)
    }

    /// Create a new task taking a command line as a `String` array, and inputs and outputs as `Path` arrays.  The command line will be implicitly marshalled into a `ByteString` array, and the inputs and outputs into `PlannedNode` arrays.
    func createTask(type: any TaskTypeDescription, dependencyData: DependencyDataStyle? = nil, payload: (any TaskPayload)? = nil, ruleInfo: [String], additionalSignatureData: String = "", commandLine: [String], additionalOutput: [String] = [], environment: EnvironmentBindings, workingDirectory: Path, inputs: [Path], outputs: [Path], mustPrecede: [any PlannedTask] = [], action: (any PlannedTaskAction)? = nil, execDescription: String? = nil, preparesForIndexing: Bool = false, enableSandboxing: Bool, llbuildControlDisabled: Bool = false, additionalTaskOrderingOptions: TaskOrderingOptions = [], usesExecutionInputs: Bool = false, isGate: Bool = false, alwaysExecuteTask: Bool = false, showInLog: Bool = true, showCommandLineInLog: Bool = true, priority: TaskPriority = .unspecified, repairViaOwnershipAnalysis: Bool = false) {
        return createTask(type: type, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: commandLine.map{ ByteString(encodingAsUTF8: $0) }, additionalOutput: additionalOutput, environment: environment, workingDirectory: workingDirectory, inputs: inputs.map(createNode), outputs: outputs.map(createNode), mustPrecede: mustPrecede, action: action, execDescription: execDescription, preparesForIndexing: preparesForIndexing, enableSandboxing: enableSandboxing, llbuildControlDisabled: llbuildControlDisabled, additionalTaskOrderingOptions: additionalTaskOrderingOptions, usesExecutionInputs: usesExecutionInputs, isGate: isGate, alwaysExecuteTask: alwaysExecuteTask, showInLog: showInLog, showCommandLineInLog: showCommandLineInLog, priority: priority, repairViaOwnershipAnalysis: repairViaOwnershipAnalysis)
    }

    /// Create a new task taking a command line as a `String` array.  It will be implicitly marshalled into a `ByteString` array.
    func createTask(type: any TaskTypeDescription, dependencyData: DependencyDataStyle? = nil, payload: (any TaskPayload)? = nil, ruleInfo: [String], additionalSignatureData: String = "", commandLine: [String], additionalOutput: [String] = [], environment: EnvironmentBindings, workingDirectory: Path, inputs: [any PlannedNode], outputs: [any PlannedNode], mustPrecede: [any PlannedTask] = [], action: (any PlannedTaskAction)? = nil, execDescription: String? = nil, preparesForIndexing: Bool = false, enableSandboxing: Bool, llbuildControlDisabled: Bool = false, additionalTaskOrderingOptions: TaskOrderingOptions = [], usesExecutionInputs: Bool = false, isGate: Bool = false, alwaysExecuteTask: Bool = false, showInLog: Bool = true, showCommandLineInLog: Bool = true, showEnvironment: Bool = false, priority: TaskPriority = .unspecified, repairViaOwnershipAnalysis: Bool = false) {
        return createTask(type: type, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: commandLine.map{ ByteString(encodingAsUTF8: $0) }, additionalOutput: additionalOutput, environment: environment, workingDirectory: workingDirectory, inputs: inputs, outputs: outputs, mustPrecede: mustPrecede, action: action, execDescription: execDescription, preparesForIndexing: preparesForIndexing, enableSandboxing: enableSandboxing, llbuildControlDisabled: llbuildControlDisabled, additionalTaskOrderingOptions: additionalTaskOrderingOptions, usesExecutionInputs: usesExecutionInputs, isGate: isGate, alwaysExecuteTask: alwaysExecuteTask, showInLog: showInLog, showCommandLineInLog: showCommandLineInLog, showEnvironment: showEnvironment, priority: priority, repairViaOwnershipAnalysis: repairViaOwnershipAnalysis)
    }

    func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String? = nil, mustPrecede: [any PlannedTask] = [], payload: (any TaskPayload)? = nil, additionalSignatureData: String = "") {
        createGateTask(inputs: inputs, output: output, name: name, mustPrecede: mustPrecede) { builder in
            builder.payload = payload
            builder.additionalSignatureData = additionalSignatureData
        }
    }
}

// Helper protocol to partially simulate an "abstract class"
public protocol ConditionallyStartable {
    /// Whether the task should run in the context of the specified build command.
    func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool
}

extension ConditionallyStartable {
    public func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        if let target = task.forTarget, !target.target.approvedByUser {
            return false
        }
        if buildCommand.isPrepareForIndexing {
            return task.preparesForIndexing
        }

        return true
    }
}

/// Provides information and functionality for all occurrences of a particular type of task.  Every task has a reference to its task type description.
public protocol TaskTypeDescription: AnyObject, ConditionallyStartable, Sendable {
    /// Describes the concrete TaskPayload type for deserialization
    var payloadType: (any TaskPayload.Type)? { get }

    /// The aliases used by a command line tool. For e.g. lex reports itself as flex, and yacc as bison.
    var toolBasenameAliases: [String] { get }

    /// Get the serialized diagnostics used by a task, if any.
    func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path]

    /// Returns an indexing-information structure for each of the indexable sources of the task.
    func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput]

    /// Returns a preview-information structure for the source file specified by the preview-information input argument.
    func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput]

    /// Returns a documentation-information structure for the task.
    func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput]

    /// Returns a localization-information structure for the task.
    ///
    /// The returned outputs from this method are currently not expected to include .stringsdata paths, as those will be computed independently of the task type.
    func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput]

    /// Create a parser for the task output, if used.
    func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)?

    /// Any interesting path related to the task, for e.g., the file being compiled.
    func interestingPath(for task: any ExecutableTask) -> Path?

    /// The command line that should be used for the change-tracking signature, i.e.
    /// the command line with the output-agnostic arguments removed.
    func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]?

    /// Whether instances of this task are unsafe to interrupt.
    var isUnsafeToInterrupt: Bool { get }
}

public enum DependencyDataFormat: String, Sendable {
    case dependencyInfo
    case makefile
}

/// A style for how dependency information is communicated from a task.
public enum DependencyDataStyle: Equatable, Encodable, Sendable {
    /// A Darwin linker style dependency info file.
    case dependencyInfo(Path)

    /// A '.d'-style Makefile.
    case makefile(Path)

    /// A list of multiple '.d'-style Makefiles.
    case makefiles([Path])

    /// A '.d'-style makefile where all but the first output are ignored.
    case makefileIgnoringSubsequentOutputs(Path)
}

extension DependencyDataStyle: Serializable {
    private enum DependencyDataStyleCode: UInt, Serializable {
        case dependencyInfo = 0
        case makefile = 1
        case makefiles = 2
        case makefileIgnoringSubsequentOutputs = 3
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .dependencyInfo(let path):
                serializer.serialize(DependencyDataStyleCode.dependencyInfo)
                serializer.serialize(path)
            case .makefile(let path):
                serializer.serialize(DependencyDataStyleCode.makefile)
                serializer.serialize(path)
            case .makefiles(let paths):
                serializer.serialize(DependencyDataStyleCode.makefiles)
                serializer.serialize(paths)
            case .makefileIgnoringSubsequentOutputs(let path):
                serializer.serialize(DependencyDataStyleCode.makefileIgnoringSubsequentOutputs)
                serializer.serialize(path)
            }
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as DependencyDataStyleCode {
        case .dependencyInfo:
            self = .dependencyInfo(try deserializer.deserialize())
        case .makefile:
            self = .makefile(try deserializer.deserialize())
        case .makefiles:
            self = .makefiles(try deserializer.deserialize())
        case .makefileIgnoringSubsequentOutputs:
            self = .makefileIgnoringSubsequentOutputs(try deserializer.deserialize())
        }
    }
}

/// Provides a place for the TaskTypeDescription to store extra data for the task.
public protocol TaskPayload: Serializable, Sendable {
}

/// Defines the indexing information to be sent back to the client for a particular source file.
///
/// This protocol includes `PropertyListItemConvertible` to describe how the info is packaged up to send back to the client.  Someday we hope to transition this to sending the info in a strongly typed format.
public protocol SourceFileIndexingInfo: PropertyListItemConvertible {
}

/// The `SourceFileIndexingInfo` info returned when only output paths are requested.
public struct OutputPathIndexingInfo: SourceFileIndexingInfo {
    public let outputFile: Path

    public init(outputFile: Path) {
        self.outputFile = outputFile
    }

    /// The indexing info is packaged and sent to the client in a property list format.
    public var propertyListItem: PropertyListItem {
        return .plDict([
            "outputFilePath": .plString(outputFile.str),
            ] as [String: PropertyListItem])
    }
}

/// Input data for generating indexing info for a task.
public struct TaskGenerateIndexingInfoInput {
    public enum SourceFileRequest {
        case all
        case only(Path)

        public func contains(_ path: Path) -> Bool {
            switch self {
            case .all: return true
            case .only(let requestedPath): return path == requestedPath
            }
        }

        /// Returns the file path that the index info was requested for, or `nil` if the request was for all files.
        var singleFile: Path? {
            switch self {
            case .all: return nil
            case .only(let requestedPath): return requestedPath
            }
        }
    }

    /// The source file request to return indexing info for.
    public let requestedSourceFiles: SourceFileRequest

    /// Whether to return only the output path associated with the source file(s).
    public let outputPathOnly: Bool

    /// Whether the index request had enabled the dedicated index build arena.
    let enableIndexBuildArena: Bool

    /// Provide input for index info request.
    /// - Parameters:
    ///   - requestedSourceFile: a specific file to get info for or `nil` for all files of a target
    ///   - outputPathOnly: Whether to return only the output path associated with the source file(s).
    public init(requestedSourceFile: Path?, outputPathOnly: Bool, enableIndexBuildArena: Bool = false) {
        if let file = requestedSourceFile {
            self.requestedSourceFiles = .only(file)
        } else {
            self.requestedSourceFiles = .all
        }
        self.outputPathOnly = outputPathOnly
        self.enableIndexBuildArena = enableIndexBuildArena
    }

    public var withEnableIndexBuildArena: TaskGenerateIndexingInfoInput {
        return .init(requestedSourceFile: self.requestedSourceFiles.singleFile, outputPathOnly: self.outputPathOnly, enableIndexBuildArena: true)
    }

    public static var fullInfo: TaskGenerateIndexingInfoInput {
        return .init(requestedSourceFile: nil, outputPathOnly: false, enableIndexBuildArena: false)
    }

    public static var outputPathInfo: TaskGenerateIndexingInfoInput {
        return .init(requestedSourceFile: nil, outputPathOnly: true, enableIndexBuildArena: false)
    }
}

public struct TaskGenerateIndexingInfoOutput {
    public let path: Path
    public let indexingInfo: any SourceFileIndexingInfo

    public init(path: Path, indexingInfo: any SourceFileIndexingInfo) {
        self.path = path
        self.indexingInfo = indexingInfo
    }
}

/// Input data for generating preview info for a task.
public enum TaskGeneratePreviewInfoInput: Equatable {
    /// - parameter sourceFile: The source file that is being edited during the preview.
    /// - parameter thunkVariantSuffix: Suffix for disambiguating different thunk variants.
    case thunkInfo(sourceFile: Path, thunkVariantSuffix: String)

    case targetDependencyInfo
}

/// Output data for generating preview info for a task.
public struct TaskGeneratePreviewInfoOutput: Sendable {
    public struct DependencyInfo: Sendable {
        public let objectFileInputMap: [String: Set<String>]
    }

    /// Types of tasks that support preview info.
    public enum TaskType: Sendable {
        case Ld
        case Swift
    }

    /// The architecture being built for.
    public let architecture: String
    /// The build variant being built.
    public let buildVariant: String
    /// The commandline to run to update the thunk.
    public let commandLine: [String]
    /// Working directory of the task
    public let workingDirectory: Path
    /// Input path of the task.
    public let input: Path
    /// Output path of the task.
    public let output: Path
    /// Type of task that is being run.
    public let type: TaskType
}

/// Input data for generating documentation info for a task.
///
/// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
public struct TaskGenerateDocumentationInfoInput {
    // No extra input is needed. Everything is passed in the payload.
    public init() {}
}

/// Output data for generating documentation info for a task.
///
/// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
public struct TaskGenerateDocumentationInfoOutput {
    /// The bundle identifier of the documentation.
    public let bundleIdentifier: String
    /// The output path where the built documentation will be written.
    public let outputPath: Path
    /// The identifier of the target associated with the documentation we're building for.
    public let targetIdentifier: String?
}

/// Input data for generating localization info for a task.
public struct TaskGenerateLocalizationInfoInput {
    /// A set of Target GUIDs (not ConfiguredTarget GUIDs) that localization info is specifically being requested for.
    ///
    /// If `nil`, data for all targets is returned.
    public let targetIdentifiers: Set<String>?

    public init(targetIdentifiers: Set<String>?) {
        self.targetIdentifiers = targetIdentifiers
    }
}

/// Describes attributes of a portion of a build, for example platform and architecture, that are relevant to distinguishing localized strings extracted during a build.
public struct LocalizationBuildPortion: Hashable, Sendable {
    /// The effective name of the platform we were building for.
    ///
    /// Catalyst should be treated as a separate platform.
    public let effectivePlatformName: String

    /// The name of the build variant, e.g. "normal"
    public let variant: String

    /// The name of the architecture we were building for.
    public let architecture: String

    public init(effectivePlatformName: String, variant: String, architecture: String) {
        self.effectivePlatformName = effectivePlatformName
        self.variant = variant
        self.architecture = architecture
    }

    /// Returns a platform name to use for localization info purposes.
    public static func effectivePlatformName(scope: MacroEvaluationScope, sdkVariant: SDKVariant?) -> String {
        if let sdkVariant, sdkVariant.isMacCatalyst {
            // Treat Catalyst as a separate platform.
            return MacCatalystInfo.localizationEffectivePlatformName
        }
        return scope.evaluate(BuiltinMacros.PLATFORM_NAME)
    }
}

/// Output data for generating localization info for a task.
///
/// A single instance of this object may not necessarily encapsulate all info for a given Task.
/// A Task's `generateLocalizationInfo` method returns an array of outputs. Combine them together to get a complete picture.
public struct TaskGenerateLocalizationInfoOutput {
    /// Paths to source .xcstrings files used as inputs to the task.
    ///
    /// This collection specifically contains compilable files, AKA files in a Resources phase (not a Copy Files phase).
    public let compilableXCStringsPaths: [Path]

    /// Paths to .stringsdata files produced by this task, grouped by build attributes such as platform and architecture.
    public let producedStringsdataPaths: [LocalizationBuildPortion: [Path]]

    /// Create output to describe some portion of localization info for a Task.
    ///
    /// - Parameters:
    ///   - compilableXCStringsPaths: Paths to input source .xcstrings files.
    ///   - producedStringsdataPaths: Paths to output .stringsdata files.
    public init(compilableXCStringsPaths: [Path] = [], producedStringsdataPaths: [LocalizationBuildPortion: [Path]] = [:]) {
        self.compilableXCStringsPaths = compilableXCStringsPaths
        self.producedStringsdataPaths = producedStringsdataPaths
    }
}

/// A progress reporter for subtasks.
///
/// This can be used to report the progress when parsing a task's output using `TaskOutputParser`.
public protocol SubtaskProgressReporter: AnyObject {
    /// Reports the number of subtasks that have started scanning.
    func subtasksScanning(count: Int, forTargetName targetName: String?)

    /// Reports the number of subtasks that have started execution.
    func subtasksStarted(count: Int, forTargetName targetName: String?)

    /// Reports the number of subtasks that did not need to run.
    func subtasksSkipped(count: Int, forTargetName targetName: String?)

    /// Reports the number of subtasks that finished execution.
    func subtasksFinished(count: Int, forTargetName targetName: String?)
}

/// A parser for the tasks output, which can be used to produce richer information as a result of a build operation.
public protocol TaskOutputParser: AnyObject {
    var workspaceContext: WorkspaceContext { get }
    var buildRequestContext: BuildRequestContext { get }
    var delegate: any TaskOutputParserDelegate { get }

    /// Create the parser.
    init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?)

    /// Pass bytes to the parser implementation.
    func write(bytes: ByteString)

    /// Close the output parser.
    ///
    /// This indicates that all data has been received, and the parser should perform any necessary finalization.
    func close(result: TaskResult?)
}

extension TaskOutputParserDelegate {
    func readSerializedDiagnostics(at path: Path, workingDirectory: Path, workspaceContext: WorkspaceContext) -> [Diagnostic] {
        do {
            // Using the default toolchain's libclang regardless of context should be sufficient, since we assume serialized diagnostics to be a stable format.
            let toolchain = workspaceContext.core.toolchainRegistry.defaultToolchain
            guard let libclangPath = toolchain?.librarySearchPaths.findLibrary(operatingSystem: workspaceContext.core.hostOperatingSystem, basename: "clang") ?? toolchain?.fallbackLibrarySearchPaths.findLibrary(operatingSystem: workspaceContext.core.hostOperatingSystem, basename: "clang") else {
                throw StubError.error("unable to find libclang")
            }
            guard let libclang = workspaceContext.core.lookupLibclang(path: libclangPath).libclang else {
                throw StubError.error("unable to open libclang: '\(libclangPath.str)'")
            }
            let serializedDiagnostics = try libclang.loadDiagnostics(filePath: path.str).map { Diagnostic($0, workingDirectory: workingDirectory, appendToOutputStream: false) }
            return serializedDiagnostics
        } catch {
            diagnosticsEngine.emit(Diagnostic(behavior: .warning, location: .path(path), data: DiagnosticData("Could not read serialized diagnostics file: \(error)")))
            return []
        }
    }

    @discardableResult func processSerializedDiagnostics(at path: Path, workingDirectory: Path, workspaceContext: WorkspaceContext) -> [Diagnostic] {
        let serializedDiagnostics = readSerializedDiagnostics(at: path, workingDirectory: workingDirectory, workspaceContext: workspaceContext)
        serializedDiagnostics.forEach(diagnosticsEngine.emit)
        return serializedDiagnostics
    }

    func processOptimizationRemarks(at objectFilePath: Path, workingDirectory: Path, workspaceContext: WorkspaceContext) {
        do {
            // Depending on how they are built, libRemarks may not be available. SWBCore weak-links with it, so if it's not there, bail out.
            guard Diagnostic.libRemarksAvailable else { return }
            guard workspaceContext.core.delegate.enableOptimizationRemarksParsing else { return }

            let remarks = try Diagnostic.remarks(forObjectPath: objectFilePath, fs: workspaceContext.fs, workingDirectory: workingDirectory)
            remarks.forEach(diagnosticsEngine.emit)
        } catch {
            diagnosticsEngine.emit(Diagnostic(behavior: .warning, location: .unknown, data: DiagnosticData("Could not read remarks from object file \(objectFilePath): \(error)")))
        }
    }
}

public struct BuildSystemOperationIdentifier: Hashable, Equatable, Sendable {
    public let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }
}

/// Delegate protocol for task output parser actions.
//
// FIXME: This protocol is similar to `TaskOutputDelegate`, but for layering purposes they are currently distinct. We should see if this can be cleaned up.
public protocol TaskOutputParserDelegate: AnyObject {
    /// The unique identifier for the associated build operation
    var buildOperationIdentifier: BuildSystemOperationIdentifier { get }

    /// The diagnostics engine to use.
    var diagnosticsEngine: DiagnosticsEngine { get }

    /// Report a skipped subtask.
    ///
    /// - Parameters:
    ///   - signature: A stable signature for the task (the same signature that would have been provided had the task run).
    func skippedSubtask(signature: ByteString)

    /// Create a subtask with the given identifier.
    ///
    /// The client *MUST* explicitly stop all started subtasks (via calling `taskCompleted`)  before the task is complete.
    ///
    /// - Parameters:
    ///   - signature: A stable signature for the task (the same signature that would have been provided had the task been skipped).
    /// - Returns: A new delegate to use for reporting status on the subtask.
    func startSubtask(buildOperationIdentifier: BuildSystemOperationIdentifier, taskName: String, id: ByteString, signature: ByteString, ruleInfo: String, executionDescription: String, commandLine: [ByteString], additionalOutput: [String], interestingPath: Path?, workingDirectory: Path?, serializedDiagnosticsPaths: [Path]) -> any TaskOutputParserDelegate

    /// Emit output log data.
    func emitOutput(_ data: ByteString)

    func close()

    /// Called to indicate the task is complete and supply the exit status for a task.
    ///
    /// Once this is invoked, no subsequent messages will be invoked on the delegate.
    func taskCompleted(exitStatus: Processes.ExitStatus)
}
