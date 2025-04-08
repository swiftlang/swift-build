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

package import SWBCore
package import SWBUtil
import struct SWBProtocol.BuildOperationTaskEnded
import Foundation
package import SWBMacro

// Some things that should probably live in this task producer that might not be immediately obvious:
//      Emitting an error if PGO is turned on for a target containing Swift files.

/// This class adapts the TaskGenerationDelegate protocol used by the Core to that provided by the producer delegate API, for use inside the sources build phase.
///
/// This delegate auto-attaches constructed tasks to the generated headers completion ordering gates, and chains to another delegate for performing the actual work.
private final class SourcesPhaseBasedTaskGenerationDelegate: TaskGenerationDelegate {
    /// The producer we are operating on behalf of.
    let producer: SourcesTaskProducer

    /// The delegate to chain to.
    let delegate: any TaskGenerationDelegate

    let userPreferences: UserPreferences

    init(producer: SourcesTaskProducer, userPreferences: UserPreferences, delegate: any TaskGenerationDelegate) {
        self.producer = producer
        self.delegate = delegate
        self.userPreferences = userPreferences
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return delegate.diagnosticsEngine(for: target)
    }

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        delegate.beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        delegate.endActivity(id: id, signature: signature, status: status)
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        delegate.emit(data: data, for: activity, signature: signature)
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        delegate.emit(diagnostic: diagnostic, for: activity, signature: signature)
    }

    var hadErrors: Bool {
        delegate.hadErrors
    }

    var diagnosticContext: DiagnosticContextData {
        return delegate.diagnosticContext
    }

    func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return delegate.createVirtualNode(name)
    }

    func createNode(_ path: Path) -> PlannedPathNode {
        return delegate.createNode(path)
    }

    func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        return delegate.createDirectoryTreeNode(path, excluding: excluding)
    }

    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        return delegate.createBuildDirectoryNode(absolutePath: path)
    }

    func declareOutput(_ file: FileToBuild) {
        delegate.declareOutput(file)
    }

    func declareGeneratedSourceFile(_ path: Path) {
        delegate.declareGeneratedSourceFile(path)
    }

    func declareGeneratedInfoPlistContent(_ path: Path) {
        delegate.declareGeneratedInfoPlistContent(path)
    }

    func declareGeneratedPrivacyPlistContent(_ path: Path) {
        delegate.declareGeneratedPrivacyPlistContent(path)
    }

    func declareGeneratedTBDFile(_ path: Path, forVariant variant: String) {
        delegate.declareGeneratedTBDFile(path, forVariant: variant)
    }

    func declareGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String) {
        delegate.declareGeneratedSwiftObjectiveCHeaderFile(path, architecture: architecture)
    }

    func declareGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String) {
        delegate.declareGeneratedSwiftConstMetadataFile(path, architecture: architecture)
    }

    var additionalCodeSignInputs: OrderedSet<Path> {
        return delegate.additionalCodeSignInputs
    }

    var buildDirectories: Set<Path> {
        return delegate.buildDirectories
    }

    func createTask(_ builder: inout PlannedTaskBuilder) {
        // Determine if this is a task which needs to attach to the generated headers node.
        var producesHeader = false, mayConsumeHeader = false
        for output in builder.outputs {
            if [".o", ".gch"].contains(output.path.fileSuffix) {
                mayConsumeHeader = true
            } else if [".h", ".hpp", ".tpp", ".ipp", ".inc", ".pch"].contains(output.path.fileSuffix) {
                producesHeader = true
            }
        }

        for input in builder.inputs {
            if [".c", ".m", ".mm", ".cp", ".cpp", ".cxx", ".cc"].contains(input.path.fileSuffix) {
                mayConsumeHeader = true
            }
        }

        let hasSwiftInputs = builder.inputs.contains { $0.path.fileSuffix == ".swift" }

        // If this command is known to produce a header, ensure it precedes the generated headers completion node.
        if producesHeader {
            builder.mustPrecede.append(hasSwiftInputs ? producer.swiftGeneratedHeadersCompletionTask : producer.nonSwiftGeneratedHeadersCompletionTask)

            if !builder.additionalTaskOrderingOptions.contains(.blockedByTargetHeaders) {
                builder.mustPrecede.append(producer.copyHeadersCompletionTask)
            }
        } else if mayConsumeHeader {
            // If this command might consume a header, ensure it follows the generated headers completion node.
            if hasSwiftInputs {
                builder.inputs.append(producer.nonSwiftGeneratedHeadersCompletionNode)
            } else {
                builder.inputs.append(contentsOf: [producer.nonSwiftGeneratedHeadersCompletionNode, producer.swiftGeneratedHeadersCompletionNode])
            }
        }
        if builder.additionalTaskOrderingOptions.contains(.blockedByTargetHeaders) {
            builder.inputs.append(producer.copyHeadersCompletionNode)
        }

        // This calls into PhasedProducerBasedTaskGenerationDelegate.createTask(), which unifies this createTask() call with those from other task producers (for example, so they all use the TaskOrderingOptions for its producer).
        delegate.createTask(&builder)

        if builder.additionalTaskOrderingOptions.contains(.compilationForIndexableSourceFile) {
            producer.addPrepareForIndexInputs(builder.inputs)
        }
    }

    func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) {
        delegate.createGateTask(inputs: inputs, output: output, name: name, mustPrecede: mustPrecede, taskConfiguration: taskConfiguration)
    }

    var taskActionCreationDelegate: any TaskActionCreationDelegate {
        return delegate.taskActionCreationDelegate
    }

    var clientDelegate: any CoreClientDelegate {
        return delegate.clientDelegate
    }

    func createOrReuseSharedNodeWithIdentifier(_ ident: String, creator: () -> (any PlannedNode, any Sendable)) -> (any PlannedNode, any Sendable) {
        return delegate.createOrReuseSharedNodeWithIdentifier(ident, creator: creator)
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
        return delegate.recordAttachment(contents: contents)
    }
}

final class SourcesTaskProducer: FilesBasedBuildPhaseTaskProducerBase, FilesBasedBuildPhaseTaskProducer {
    typealias ManagedBuildPhase = SourcesBuildPhase

    /// A virtual node representing the (conservative) construction of all non-Swift-generated headers.
    let nonSwiftGeneratedHeadersCompletionNode: any PlannedNode

    /// A gate task driving the production of the non-Swift-generated headers order node.
    let nonSwiftGeneratedHeadersCompletionTask: any PlannedTask

    /// A virtual node representing the (conservative) construction of all Swift-generated headers.
    let swiftGeneratedHeadersCompletionNode: any PlannedNode

    /// A gate task driving the production of the Swift-generated headers order node.
    let swiftGeneratedHeadersCompletionTask: any PlannedTask

    /// A virtual node representing the completion of all tasks of a target that have (a) header file(s) as output
    let copyHeadersCompletionNode: any PlannedNode

    /// A gate task driving the completion of copying/generating all headers of a target
    let copyHeadersCompletionTask: any PlannedTask

    /// The frameworks build phase this task producer is working with.  This is optional since the target might not have one.
    unowned private(set) var frameworksBuildPhase: FrameworksBuildPhase?

    /// During source file processing, collects the tasks necessary to 'prepare-for-index' the target.
    /// This is only getting populated if `INDEX_ENABLE_BUILD_ARENA` was set to true.
    var prepareTargetForIndexInputs: [any PlannedNode] = []

    /// Used to efficiently check whether a `PlannedNode` has already been added to the `prepareTargetForIndexInputs` array.
    private var prepareTargetForIndexInputsObjectSet: Set<ObjectIdentifier> = []

    var hasEnabledIndexBuildArena: Bool { targetContext.preparedForIndexPreCompilationNode != nil }

    init(_ context: TargetTaskProducerContext, sourcesBuildPhase: SourcesBuildPhase, frameworksBuildPhase: FrameworksBuildPhase?, phaseStartNodes: [any PlannedNode], phaseEndNode: any PlannedNode, phaseEndTask: any PlannedTask) {
        self.frameworksBuildPhase = frameworksBuildPhase

        // Create a task to serve as the gate to order commands which may produce headers versus those that may consume them.
        //
        // We force this node to precede the target end task just to avoid it counting as a root in the graph.
        //
        // FIXME: We need a good way to make a unique -- but stable -- node name here, even across configured targets.
        nonSwiftGeneratedHeadersCompletionNode = context.createVirtualNode("\(context.configuredTarget!.guid)-generated-headers")
        nonSwiftGeneratedHeadersCompletionTask = context.createGateTask(output: nonSwiftGeneratedHeadersCompletionNode, mustPrecede: [context.targetEndTask])

        swiftGeneratedHeadersCompletionNode = context.createVirtualNode("\(context.configuredTarget!.guid)-swift-generated-headers")
        swiftGeneratedHeadersCompletionTask = context.createGateTask(output: swiftGeneratedHeadersCompletionNode, mustPrecede: [context.targetEndTask])

        copyHeadersCompletionNode = context.createVirtualNode("\(context.configuredTarget!.guid)-copy-headers-completion")
        copyHeadersCompletionTask = context.createGateTask(output: copyHeadersCompletionNode, mustPrecede: [context.targetEndTask])

        super.init(context, buildPhase: sourcesBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
    }

    override func additionalBuildFiles(_ scope: MacroEvaluationScope) -> [BuildFile] {
        let standardTarget = targetContext.configuredTarget?.target as? StandardTarget
        let sourceFiles = standardTarget?.sourcesBuildPhase?.buildFiles.count ?? 0
        if scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS) && (sourceFiles > 0) {
            // Add xcassets to Compile Sources phase to enable codegen.
            return standardTarget?.resourcesBuildPhase?.buildFiles.filter { buildFile in
                isAssetCatalog(scope: scope, buildFile: buildFile, context: targetContext, includeGenerated: true)
            } ?? []
        } else {
            return []
        }
    }

    override func additionalFilesToBuild(_ scope: MacroEvaluationScope) -> [FileToBuild] {
        var additionalFilesToBuild: [FileToBuild] = []
        let sourceFiles = (self.targetContext.configuredTarget?.target as? StandardTarget)?.sourcesBuildPhase?.buildFiles.count ?? 0
        if scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS) && sourceFiles > 0 && scope.evaluate(BuiltinMacros.APP_PLAYGROUND_GENERATE_ASSET_CATALOG) {
            // Add the generated xcassets if we're generating asset symbols since we'll be handling the other xcassets here as well.
            let assetCatalogToBeGenerated = scope.evaluate(BuiltinMacros.APP_PLAYGROUND_GENERATED_ASSET_CATALOG_FILE)
            additionalFilesToBuild.append(
                FileToBuild(absolutePath: assetCatalogToBeGenerated, inferringTypeUsing: context)
            )
        }
        return additionalFilesToBuild
    }

    /// The default `TaskOrderingOptions` are used for the compile tasks in the architecture-variant loop, as the default options are primarily concerned with compilation. Other tasks set up by this producer use the `nonCompilationTaskOrderingOptions` below.  But be mindful of which options are being used when adding new tasks to this producer.
    ///
    /// The rule of thumb is that using the default options imposes _more_ ordering constraints on a task.
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        let scope = self.context.settings.globalScope

        var options = [TaskOrderingOptions]()

        // This producer's tasks both require that its own modules be ready, and the modules of targets it depends on be ready, before they can run. (.compilation)
        if scope.evaluate(BuiltinMacros.EAGER_PARALLEL_COMPILATION_DISABLE) {
            // If eager parallel compilation is off, they must also block downstream compiling targets because Swift compilation generates a module. (.compilationRequirement)
            options.append(.compilation)
            options.append(.compilationRequirement)
        } else {
            // Swift will still use .compilationRequirement because it's compiling tasks are generating a module.
            options.append(.compilation)
        }
        return TaskOrderingOptions(options).union(nonCompilationTaskOrderingOptions)
    }

    /// Tasks which don't care about being ordered as compile tasks should usually use these options when calling `appendGeneratedTasks()`.  This will order tasks before the unsigned-products-ready gate task, which means that hosted targets (e.g., test targets using `TEST_HOST`) can rely on them being present.
    ///
    /// Note that tasks which genuinely don't care about this ordering (e.g., because nothing downstream depends on them) can have `appendGeneratedTasks()` passed no options.
    var nonCompilationTaskOrderingOptions: TaskOrderingOptions {
        return .unsignedProductRequirement
    }

    /// Convenience function for appending tasks using from a spec.
    ///
    /// We override this to auto-attach tasks to the generated headers completion ordering gate.
    @discardableResult
    override func appendGeneratedTasks( _ tasks: inout [any PlannedTask], options: TaskOrderingOptions? = nil, body: (any TaskGenerationDelegate) async -> Void) async -> (tasks: [any PlannedTask], outputs: [FileToBuild]) {
        return await super.appendGeneratedTasks(&tasks, options: options) { delegate in
            await body(SourcesPhaseBasedTaskGenerationDelegate(producer: self, userPreferences: context.workspaceContext.userPreferences, delegate: delegate))
        }
    }

    /// Returns `true` if the target which defines the settings in the given `scope` should generate a dSYM file.
    /// - remark: This method allows this task producer to ask this question about other targets by passing a `scope` for the target in question.
    private func shouldGenerateDSYM(_ scope: MacroEvaluationScope) -> Bool {
        let dSYMForDebugInfo = scope.evaluate(BuiltinMacros.GCC_GENERATE_DEBUGGING_SYMBOLS) && scope.evaluate(BuiltinMacros.DEBUG_INFORMATION_FORMAT) == "dwarf-with-dsym"
        // When emitting remarks, for now, a dSYM is required (<rdar://problem/45458590>)
        let dSYMForRemarks = scope.evaluate(BuiltinMacros.CLANG_GENERATE_OPTIMIZATION_REMARKS)
        let dSYM = dSYMForDebugInfo || dSYMForRemarks
        return dSYM && scope.evaluate(BuiltinMacros.MACH_O_TYPE) != "staticlib" && scope.evaluate(BuiltinMacros.MACH_O_TYPE) != "mh_object"
    }

    /// Computes and returns a list of libraries to include when linking.
    func computeLibraries(_ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope) -> [LinkerSpec.LibrarySpecifier] {
        guard let frameworksPhase = frameworksBuildPhase else { return [] }

        // Compute the flattened list of build files after expanding package product targets.
        let buildFiles = context.computeFlattenedFrameworksPhaseBuildFiles(buildFilesContext)

        // Add libraries specifiers for each item in the phase.
        //
        // FIXME: Xcode uses the filtered references here, but our implementation isn't yet factored in a way we can do that.
        return buildFiles.compactMap { buildFile -> LinkerSpec.LibrarySpecifier? in
            // Resolve the buildable reference.
            let (_, settingsForRef, absolutePath, fileType): (Reference, Settings?, Path, FileTypeSpec)

            switch buildFile.buildableItem {
            case .reference, .targetProduct:
                do {
                    (_, settingsForRef, absolutePath, fileType) = try self.context.resolveBuildFileReference(buildFile)
                } catch WorkspaceErrors.missingPackageProduct(let packageName) {
                    context.missingPackageProduct(packageName, buildFile, frameworksPhase)
                    return nil
                } catch {
                    context.error("Unable to resolve build file: \(buildFile) (\(error))")
                    return nil
                }
            case .namedReference(let name, let fileTypeIdentifier):
                settingsForRef = nil
                absolutePath = Path(name) // This path isn't actually absolute, but `LinkerSpec.LibrarySpecifier` supports that case.
                if let type = context.lookupFileType(identifier: fileTypeIdentifier) {
                    fileType = type
                } else {
                    context.error("Could not lookup file type '\(fileTypeIdentifier)'")
                    return nil
                }
            }

            // Link using search paths unless the reference is in a different project, in which case we use a full path (to support legacy build locations, primarily).
            let useSearchPaths: Bool
            switch buildFile.buildableItem {
            case .reference:
                useSearchPaths = true
            case .targetProduct(guid: let guid):
                if let referenceTarget = self.context.workspaceContext.workspace.target(for: guid) {
                    let referenceProject = self.context.workspaceContext.workspace.project(for: referenceTarget)
                    useSearchPaths = referenceProject === self.context.project
                } else {
                    useSearchPaths = true
                }
            case .namedReference:
                useSearchPaths = true
            }

            /// If this `BuildFile` is being produced by a target, capture the effective `Settings` for it.  `TaskProducerContext.settingsForProductReferenceTarget()` will resolve this to the actual settings for the `ConfiguredTarget` in the target dependency graph (as opposed to an older approach of applying the current configured target's parameters to the other target, which won't work if there are context-dependent overrides).
            var producingTargetSettings: Settings? = nil
            if let configuredTarget = self.context.configuredTarget, let producingTarget = context.globalProductPlan.planRequest.buildGraph.producingTarget(for: buildFile.buildableItem, in: configuredTarget)?.target.target {
                let parameters = configuredTarget.parameters
                let settings = self.context.settingsForProductReferenceTarget(producingTarget, parameters: parameters)
                producingTargetSettings = settings
            }

            // For each target product reference, find the corresponding target and if it uses Swift, determine the path to the
            // corresponding .swiftmodule file per arch, needed for debugging. Note that we can only determine these paths for
            // targets which we are building from source, other kinds of product references will not provide the necessary
            // information.
            var swiftModulePaths: [String: Path] = [:]
            var swiftModuleAdditionalLinkerArgResponseFilePaths: [String: Path] = [:]
            switch buildFile.buildableItem {
            case .reference:
                break
            case .targetProduct(guid: let guid):
                if let referenceTarget = self.context.workspaceContext.workspace.dynamicTarget(for: guid, dynamicallyBuildingTargets: context.globalProductPlan.dynamicallyBuildingTargets) {
                    let parameters = self.context.configuredTarget?.parameters ?? BuildParameters(configuration: nil)
                    let settings = self.context.settingsForProductReferenceTarget(referenceTarget, parameters: parameters)
                    if referenceTarget.usesSwift(context: self.context, settings: settings) {
                        var architectures = scope.evaluate(BuiltinMacros.ARCHS)
                        var processedArchitectures: Set<String> = []
                        while !architectures.isEmpty {
                            let originalArch = architectures.removeFirst()
                            guard !processedArchitectures.contains(originalArch) else {
                                continue
                            }
                            processedArchitectures.insert(originalArch)
                            let scope = settings.globalScope.subscope(binding: BuiltinMacros.archCondition, to: originalArch)
                            // Binding the architecture may change how we evaluate $(ARCHS). Ensure we process any new architectures.
                            for potentiallyNewArch in scope.evaluate(BuiltinMacros.ARCHS) {
                                if !processedArchitectures.contains(potentiallyNewArch) {
                                    architectures.append(potentiallyNewArch)
                                }
                            }
                            // Recompute arch as it will be interpolated in settings below, in case binding the architecture condition produced a value other than the original literal.
                            let arch = scope.evaluate(BuiltinMacros.CURRENT_ARCH)
                            if arch == "undefined_arch" {
                                // If we end up with an undefined architecture here, the settings we use to compute the
                                // AST path and additional linker args below will be incorrect. This state is undesirable,
                                // but recoverable, so do not record these incorrect paths.
                                // FIXME: The `settingsForProductReferenceTarget` call above should always find settings for a
                                // concrete configured target. However, there appears to be an issue currently when a root-level target
                                // with package dependencies uses non-standard architectures. We should remove the `settingsForProductReferenceTarget` once that issue is resolved, and then this check should no longer
                                // be needed.
                                if context.workspaceContext.userPreferences.enableDebugActivityLogs {
                                    context.warning("Could not determine settings for \(referenceTarget.name) when computing Swift AST paths for \(context.configuredTarget?.target.name ?? "<unknown>")")
                                }
                                continue
                            }
                            let moduleName = scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
                            let moduleFileDir = scope.evaluate(BuiltinMacros.PER_ARCH_MODULE_FILE_DIR)
                            swiftModulePaths[arch] = moduleFileDir.join(moduleName + ".swiftmodule")
                            if scope.evaluate(BuiltinMacros.SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS) {
                                swiftModuleAdditionalLinkerArgResponseFilePaths[arch] = moduleFileDir.join("\(moduleName)-linker-args.resp")
                            }
                        }

                        // Check if we can fill in information for missing architectures using a compatible architecture.
                        for (arch, moduleFileDir) in swiftModulePaths {
                            if let archSpec = context.workspaceContext.core.specRegistry.getSpec(arch, domain: scope.evaluate(BuiltinMacros.PLATFORM_NAME)) as? ArchitectureSpec {
                                for compatibilityArch in archSpec.compatibilityArchs {
                                    if swiftModulePaths[compatibilityArch] == nil {
                                        swiftModulePaths[compatibilityArch] = moduleFileDir
                                    }
                                }
                            }
                        }
                        for (arch, moduleFileDir) in swiftModuleAdditionalLinkerArgResponseFilePaths {
                            if let archSpec = context.workspaceContext.core.specRegistry.getSpec(arch, domain: scope.evaluate(BuiltinMacros.PLATFORM_NAME)) as? ArchitectureSpec {
                                for compatibilityArch in archSpec.compatibilityArchs {
                                    if swiftModuleAdditionalLinkerArgResponseFilePaths[compatibilityArch] == nil {
                                        swiftModuleAdditionalLinkerArgResponseFilePaths[compatibilityArch] = moduleFileDir
                                    }
                                }
                            }
                        }
                    }
                }
            case .namedReference:
                break
            }

            // If the target is set to aggregate tracked domains, then the path of the dependencies needs to be noted so that it can be scanned.
            let privacyFile: Path? = {
                if scope.evaluate(BuiltinMacros.AGGREGATE_TRACKED_DOMAINS) {
                    switch buildFile.buildableItem {
                    case .reference(_), .targetProduct(_):
                        do {
                            let (_, absolutePath, fileType) = try self.context.resolveBuildFileReference(buildFile)
                            // Currently only items that are embeddable are supported for scanning.
                            if fileType.isEmbeddableInProduct {
                                return absolutePath
                            }
                        }
                        catch {}
                    default:
                        return nil
                    }
                }

                return nil
            }()

            func linkageModeForDylib() -> LinkerSpec.LibrarySpecifier.Mode {
                if scope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES) {
                    // Right now, we only use reexport_merge and merge modes if the BuildFile was produced by a target and that target is a mergeable library.  This may change in the future as we add more scenarios.
                    if let settings = producingTargetSettings {
                        // Every mergeable framework or library which was built by a target which we're linking in this manner should be either reexported-merged or normally merged (because otherwise they wouldn't be a mergeable library).
                        if settings.globalScope.evaluate(BuiltinMacros.MERGEABLE_LIBRARY) {
                            return settings.globalScope.evaluate(BuiltinMacros.MAKE_MERGEABLE) ? .merge : .reexport_merge
                        }
                    }
                }
                // In all other cases then we treat it normally.
                return buildFile.shouldLinkWeakly ? .weak : .normal
            }

            if fileType.conformsTo(context.lookupFileType(identifier: "archive.ar")!) {
                return LinkerSpec.LibrarySpecifier(
                    kind: .static,
                    path: absolutePath,
                    mode: buildFile.shouldLinkWeakly ? .weak : .normal,
                    useSearchPaths: useSearchPaths,
                    swiftModulePaths: swiftModulePaths,
                    swiftModuleAdditionalLinkerArgResponseFilePaths: swiftModuleAdditionalLinkerArgResponseFilePaths,
                    privacyFile: privacyFile
                )
            } else if fileType.conformsTo(context.lookupFileType(identifier: "compiled.mach-o.dylib")!) {
                return LinkerSpec.LibrarySpecifier(
                    kind: .dynamic,
                    path: absolutePath,
                    mode: linkageModeForDylib(),
                    useSearchPaths: useSearchPaths,
                    swiftModulePaths: [:],
                    swiftModuleAdditionalLinkerArgResponseFilePaths: [:],
                    privacyFile: privacyFile
                )
            } else if fileType.conformsTo(context.lookupFileType(identifier: "sourcecode.text-based-dylib-definition")!) {
                return LinkerSpec.LibrarySpecifier(
                    kind: .textBased,
                    path: absolutePath,
                    mode: buildFile.shouldLinkWeakly ? .weak : .normal,
                    useSearchPaths: useSearchPaths,
                    swiftModulePaths: [:],
                    swiftModuleAdditionalLinkerArgResponseFilePaths: [:],
                    privacyFile: privacyFile
                )
            } else if fileType.conformsTo(context.lookupFileType(identifier: "wrapper.framework")!) {
                func kindFromSettings(_ settings: Settings) -> LinkerSpec.LibrarySpecifier.Kind? {
                    switch settings.globalScope.evaluate(BuiltinMacros.MACH_O_TYPE) {
                    case "staticlib":
                        return .static
                    case "mh_dylib":
                        return .dynamic
                    case "mh_object":
                        return .object
                    default:
                        return nil
                    }
                }

                let kind: LinkerSpec.LibrarySpecifier.Kind
                let path: Path
                let dsymPath: Path?
                let topLevelItemPath: Path?
                if let settingsForRef, let presumedKind = kindFromSettings(settingsForRef), !useSearchPaths {
                    // If we have a Settings from a cross-project reference, use the _actual_ library path. This prevents downstream code from reconstituting the framework path by joining the framework path with the basename of the framework, which won't be correct for deep frameworks which also need the Versions/A path component.
                    kind = presumedKind
                    path = settingsForRef.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(settingsForRef.globalScope.evaluate(BuiltinMacros.EXECUTABLE_PATH)).normalize()
                    topLevelItemPath = absolutePath
                    if shouldGenerateDSYM(settingsForRef.globalScope) {
                        dsymPath = scope.evaluate(BuiltinMacros.DWARF_DSYM_FOLDER_PATH).join(scope.evaluate(BuiltinMacros.DWARF_DSYM_FILE_NAME))
                    }
                    else {
                        dsymPath = nil
                    }
                } else {
                    kind = .framework
                    path = absolutePath
                    topLevelItemPath = nil
                    dsymPath = nil
                }

                return LinkerSpec.LibrarySpecifier(
                    kind: kind,
                    path: path,
                    mode: linkageModeForDylib(),
                    useSearchPaths: useSearchPaths,
                    swiftModulePaths: [:],
                    swiftModuleAdditionalLinkerArgResponseFilePaths: [:],
                    topLevelItemPath: topLevelItemPath,
                    dsymPath: dsymPath,
                    privacyFile: privacyFile
                )
            } else if fileType.conformsTo(context.lookupFileType(identifier: "compiled.mach-o.objfile")!) {
                return LinkerSpec.LibrarySpecifier(
                    kind: .object,
                    path: absolutePath,
                    mode: buildFile.shouldLinkWeakly ? .weak : .normal,
                    useSearchPaths: useSearchPaths,
                    swiftModulePaths: swiftModulePaths,
                    swiftModuleAdditionalLinkerArgResponseFilePaths: swiftModuleAdditionalLinkerArgResponseFilePaths,
                    privacyFile: privacyFile
                )
            } else if fileType.conformsTo(context.lookupFileType(identifier: "wrapper.xcframework")!) {
                // The XCFramework needs to be inspected here to determine what type of linkage is actually going to be done. This is more work than I'd like to do here, but there isn't really an alternative.

                guard let xcframeworkPath = (try? context.resolveBuildFileReference(buildFile))?.absolutePath else {
                    // Even if a suitable library cannot be found for the build flavor being asked for, the actual reference to the xcframework should always be found. This is an internal model error if this occurs.
                    assertionFailure("unable to get the xcframeworkPath")
                    return nil
                }

                guard let xcframework = try? context.globalProductPlan.planRequest.buildRequestContext.getCachedXCFramework(at: xcframeworkPath) else {
                    // Let the XCFrameworkTaskProducer log an errors here as this should only occur when an XCFramework is referenced on disk but is not actually present.
                    return nil
                }

                guard let library = xcframework.findLibrary(sdk: context.sdk, sdkVariant: context.sdkVariant) else {
                    // Let the XCFrameworkTaskProducer log an error here
                    return nil
                }

                guard let target = context.configuredTarget, let outputFilePaths = context.globalProductPlan.xcframeworkContext.outputFiles(xcframeworkPath: xcframeworkPath, target: target) else {
                    // Let the XCFrameworkTaskProducer log an error here
                    return nil
                }

                let outputPath = XCFramework.computeOutputDirectory(scope)
                let libraryTargetPath = outputPath.join(library.libraryPath)

                // Check if the architectures provided by the xcframework have at least all of the ones we're building for, but only emit a note if this isn't the case since it may still be link-compatible. In future this could be made an error if we can confidently replicate the linker's rules on what architectures are link-compatible (CompatibilityArchitectures is NOT necessarily 1:1 with those rules).
                let archs = scope.evaluate(BuiltinMacros.ARCHS)
                let missingArchs = Set(archs).subtracting(library.supportedArchitectures)
                if !missingArchs.isEmpty {
                    context.note("'\(xcframeworkPath.str)' is missing architecture(s) required by this target (\(missingArchs.joined(separator: ", "))), but may still be link-compatible.")
                }

                let libraryKind: LinkerSpec.LibrarySpecifier.Kind
                switch library.libraryType {
                case .framework: libraryKind = .framework; break
                case .dynamicLibrary: libraryKind = .dynamic; break
                case .staticLibrary: libraryKind = .static; break
                case let .unknown(fileExtension):
                    // An error of type this type should have already been manifested.
                    assertionFailure("unknown xcframework type: \(fileExtension)")
                    return nil
                }

                let mode: LinkerSpec.LibrarySpecifier.Mode = {
                    // If we're merging libraries, and this XCFramework library has been built as mergeable, then we merge or reexport it based on IS_UNOPTIMIZED_BUILD.
                    // This means there's to way to force a merge in debug builds, but it's not clear whether that is desirable behavior anyway.
                    if scope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES) {
                        if library.mergeableMetadata {
                            return scope.evaluate(BuiltinMacros.IS_UNOPTIMIZED_BUILD) ? .reexport_merge : .merge
                        }
                    }
                    // In all other cases then we treat it normally.
                    return buildFile.shouldLinkWeakly ? .weak : .normal
                }()

                // NOTE: XCFrameworks are not currently being searched for the `PrivacyInfo.xcprivacy` files, instead, they searched by the inclusion of the item within the "Copy Phase".
                return LinkerSpec.LibrarySpecifier(
                    kind: libraryKind,
                    path: libraryTargetPath,
                    mode: mode,
                    useSearchPaths: useSearchPaths,
                    swiftModulePaths: [:],
                    swiftModuleAdditionalLinkerArgResponseFilePaths: [:],
                    explicitDependencies: outputFilePaths,
                    xcframeworkSourcePath: xcframeworkPath,
                    privacyFile: nil
                )
            } else {
                // FIXME: Error handling.
                return nil
            }
        }
    }

    /// Record the inputs to 'prepare-for-index' target node, that were not already recorded so far.
    func addPrepareForIndexInputs(_ inputs: [any PlannedNode]) {
        guard hasEnabledIndexBuildArena else { return }

        let newInputs = inputs.filter { !prepareTargetForIndexInputsObjectSet.contains(ObjectIdentifier($0)) }
        prepareTargetForIndexInputs.append(contentsOf: newInputs)
        prepareTargetForIndexInputsObjectSet.formUnion(newInputs.map{ ObjectIdentifier($0) })
    }

    func prepare() {
        // CodeSigning in a monster... really, it is. Further, we don't actually have a model where we can perform proper pre-planning to determine what inputs will cause downstream outputs to end up in a particular location. Every source file has the potential to contribute some type of output that ends up in the wrapper.
        // For example, every metal file creates a library that is embedded into the product wrapper. However, the build system doesn't actually *know* that, as the outputs aren't really tracked in a way that the CodeSign task itself can depend on it.
        // What the build system does _know_, is that _all_ source files run tools that can potentially end up invalidating the code signature. Until we have a proper pre-planning (e.g. or dry-run) model (or a model that allows us to have dependencies on task producers), we need to be more conservative in our tracking of inputs, even if they can result in additional codesign work.
        // An additional note: if out output file, such as a metallib, is changed by something other than a source input, the codesign task will still not know about it, and that incremental build will fail to sign properly. That should be less likely to happen, but just goes to point out that we need to re-work how our codesign model works, in general.

        let scope = context.settings.globalScope

        // This is to provide a fallback to prevent any unexpected side-effects; this is for consistency with other codesign tracking...
        guard scope.evaluate(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING) else { return }

        // If we're not building a wrapper, then just bail.
        guard context.settings.productType?.isWrapper == true else { return }

        // Add all source files as they can contribute output into the wrapper: see comment above for further details.
        context.addAdditionalCodeSignInputs(buildPhase.buildFiles, context)
    }

    /// Compute a flattened list of build files to use
    func generateTasks() async -> [any PlannedTask] {
        // NOTE: The sources build phase uses its own generateTasks() to deal with the per-variant and per-arch nature.
        let scope = context.settings.globalScope

        // Sources are processed only when the "build", "api", or "headers" component is present.
        //
        // FIXME: Actually, we can limit the "API" part to just when Swift API is installed: <rdar://problem/33735618> [InstallAPI] Avoid headermap / sources task construction when Swift isn't present
        var isForAPI = false
        var isForHeaders = false
        var isForInstallLoc = false
        var isForExportLoc = false
        let components = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if !components.contains("build") {
            if components.contains("api"), context.settings.allowInstallAPIForTargetsSkippedInInstall(in: scope) {
                isForAPI = true
            }
            // <rdar://problem/59862065> Remove EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING after validation.
            if components.contains("headers"), context.settings.allowInstallAPIForTargetsSkippedInInstall(in: scope), (components.contains("api") || scope.evaluate(BuiltinMacros.EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING)) {
                isForHeaders = true
            }

            if components.contains("installLoc") {
                isForInstallLoc = true
            }

            // The exportLoc build action is only for extracting localizations from .swift files
            if components.contains("exportLoc") {
                isForExportLoc = true
            }

            guard isForAPI || isForHeaders || isForInstallLoc || isForExportLoc else {
                return []
            }
        }

        var tasks: [any PlannedTask] = []

        // Generate any auxiliary files whose content is not per-arch or per-variant.
        // For the index build arena it is important to avoid adding this because it forces creation of the Swift module due to the generated ObjC header being an input dependency. This is unnecessary work since we don't need to generate the Swift module of the target to be able to successfully create a compiler AST for the Swift files of the target.
        let generateVersionInfoFileTask = await (isForAPI || hasEnabledIndexBuildArena) ? nil : generateVersionInfoFile(scope)
        if let generateVersionInfoFileTask {
            tasks.append(generateVersionInfoFileTask)
        }

        let generateKernelExtensionModuleInfoFileTask = await (isForAPI || hasEnabledIndexBuildArena) ? nil : self.generateKernelExtensionModuleInfoFileTask(scope, buildPhase)
        if let generateKernelExtensionModuleInfoFileTask {
            tasks.append(generateKernelExtensionModuleInfoFileTask)
        }

        let packageTargetBundleAccessorResult = await generatePackageTargetBundleAccessorResult(scope)
        tasks += packageTargetBundleAccessorResult?.tasks ?? []

        let embedInCodeAccessorResult: GeneratedResourceAccessorResult?
        if scope.evaluate(BuiltinMacros.GENERATE_EMBED_IN_CODE_ACCESSORS), let configuredTarget = context.configuredTarget, buildPhase.containsSwiftSources(context.workspaceContext.workspace, context, scope, context.filePathResolver) {
            let ownTargetBuildFilesToEmbed = ((context.workspaceContext.workspace.target(for: configuredTarget.target.guid) as? StandardTarget)?.buildPhases.compactMap { $0 as? BuildPhaseWithBuildFiles }.flatMap { $0.buildFiles }.filter { $0.resourceRule == .embedInCode }) ?? []
            let bundleDependencies = configuredTarget.target.dependencies.map { $0.guid }.compactMap { context.workspaceContext.workspace.target(for: $0) as? StandardTarget }.filter {
                let settings = context.globalProductPlan.planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: $0)
                return settings.globalScope.evaluate(BuiltinMacros.PRODUCT_TYPE) == "com.apple.product-type.bundle"
            }
            let buildFilesToEmbed = ownTargetBuildFilesToEmbed + bundleDependencies.compactMap { $0.buildPhases.only as? BuildPhaseWithBuildFiles }.flatMap { $0.buildFiles }.filter { $0.resourceRule == .embedInCode }

            do {
                embedInCodeAccessorResult = try await generateEmbedInCodeAccessorResult(scope, resourceBuildFiles: buildFilesToEmbed)
                tasks += embedInCodeAccessorResult?.tasks ?? []
            } catch {
                embedInCodeAccessorResult = nil
                context.error("failed to generate embed-in-code accessor: \(error)")
            }
        } else {
            embedInCodeAccessorResult = nil
        }

        // Add the generated headers completion gate task.
        tasks.append(nonSwiftGeneratedHeadersCompletionTask)
        tasks.append(swiftGeneratedHeadersCompletionTask)
        tasks.append(copyHeadersCompletionTask)

        let archs: [String] = scope.evaluate(BuiltinMacros.ARCHS)
        let moduleOnlyArchs: [String] = scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS)
        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)

        // Generate tasks.
        let buildVariants = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        var dsymBundle: Path!
        var dsymutilOutputs = [Path]()
        var perVariantOutputPaths: [String:Set<Path>] = [:]
        var allLinkedLibraries = [LinkerSpec.LibrarySpecifier]()
        for variant in buildVariants {
            // Enter the per-variant scope.
            let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)

            // Create a virtual node to represent the final linked binary, needed to enforce ordering w.r.t. dsymutil.
            let binaryOutput = targetBuildDir.join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))
            let linkedBinaryNode = context.createVirtualNode("Linked Binary \(binaryOutput.str)")
            var dsymutilInputNodes: [any PlannedNode] = []

            let executablePreviewDylibPathString = scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH)
            let binaryPreviewDylibOutput = executablePreviewDylibPathString.isEmpty ? nil : targetBuildDir.join(executablePreviewDylibPathString)
            let linkedBinaryPreviewDylibNode = binaryPreviewDylibOutput.map { context.createVirtualNode("Linked Binary Debug Dylib \($0.str)") }

            let executablePreviewBlankInjectionDylibPathString = scope.evaluate(BuiltinMacros.EXECUTABLE_BLANK_INJECTION_DYLIB_PATH)
            let binaryPreviewBlankInjectionDylibOutput = executablePreviewBlankInjectionDylibPathString.isEmpty ? nil : targetBuildDir.join(executablePreviewBlankInjectionDylibPathString).normalize()
            let linkedBinaryPreviewBlankInjectionDylibNode = binaryPreviewBlankInjectionDylibOutput.map { context.createVirtualNode("Linked Binary Preview Injection Dylib \($0.str)") }

            assert(
                (linkedBinaryPreviewDylibNode == nil && linkedBinaryPreviewBlankInjectionDylibNode == nil)
                || (linkedBinaryPreviewDylibNode != nil && linkedBinaryPreviewBlankInjectionDylibNode != nil),
                "A debug dylib and blank injection dylib are either both present or absent."
            )

            // Process all the archs.

            let preferredArch = context.settings.preferredArch

            var singleArchBinaries: [Path] = []
            var singleArchPreviewDylibBinaries: [Path] = []
            var singleArchInjectionDylibBinaries: [Path] = []

            // Tracks whether a TBD used for eager linking must be processed by lipo or copied to the build products so downstream targets can link against it.
            var shouldPrepareEagerLinkingTBD = false

            for arch in archs {
                // Enter the per-arch scope.
                let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
                let currentArchSpec = context.getSpec(arch) as! ArchitectureSpec?

                // Reset the set of used tools.
                usedTools.removeAll(keepingCapacity: true)

                // Process all of the groups.
                //
                // FIXME: We should do this in parallel.
                let buildFilesContext = BuildFilesProcessingContext(scope, belongsToPreferredArch: preferredArch == nil || preferredArch == arch, currentArchSpec: currentArchSpec)
                var perArchTasks: [any PlannedTask] = []
                await groupAndAddTasksForFiles(self, buildFilesContext, scope, filterToAPIRules: isForAPI, filterToHeaderRules: isForHeaders, &perArchTasks, extraResolvedBuildFiles: {
                    var result: [(Path, FileTypeSpec, Bool)] = []

                    if let generateVersionInfoFileTask {
                        result.append((generateVersionInfoFileTask.outputs.first!.path, context.lookupFileType(languageDialect: .c)!, /* shouldUsePrefixHeader */ false))
                    }

                    if let generateKernelExtensionModuleInfoFileTask {
                        result.append((generateKernelExtensionModuleInfoFileTask.outputs.first!.path, context.lookupFileType(languageDialect: .c)!, /* shouldUsePrefixHeader */ false))
                    }

                    if let packageTargetBundleAccessorResult {
                        result.append((packageTargetBundleAccessorResult.fileToBuild, packageTargetBundleAccessorResult.fileToBuildFileType, /* shouldUsePrefixHeader */ false))
                    }

                    if let embedInCodeAccessorResult {
                        result.append((embedInCodeAccessorResult.fileToBuild, embedInCodeAccessorResult.fileToBuildFileType, /* shouldUsePrefixHeader */ false))
                    }

                    if scope.evaluate(BuiltinMacros.GENERATE_TEST_ENTRY_POINT) {
                        result.append((scope.evaluate(BuiltinMacros.GENERATED_TEST_ENTRY_POINT_PATH), context.lookupFileType(fileName: "sourcecode.swift")!,  /* shouldUsePrefixHeader */ false))
                    }

                    return result
                }())

                // Collect the list of object files.
                var linkerInputNodes: [any PlannedNode] = []
                let ltoSetting = scope.evaluate(BuiltinMacros.SWIFT_LTO)
                for task in perArchTasks {
                    for object in task.outputs {
                        // FIXME: We should be able to do this in terms of actual file types, once we get actual typed objects as the outputs from tasks.
                        switch object.path.fileExtension {
                        case "o":
                            linkerInputNodes.append(object)
                        case "bc" where ltoSetting == .yes || ltoSetting == .yesThin:
                            linkerInputNodes.append(object)
                        case "swiftmodule":
                            dsymutilInputNodes.append(object)
                            break
                        default:
                            break
                        }
                    }
                }

                // Handle linking master objects.  Presently we always do this if GENERATE_MASTER_OBJECT_FILE even if there are no other tasks, since PRELINK_LIBS or PRELINK_FLAGS might be set to values which will cause a master object file to be generated.
                // FIXME: The implicitly means that if GENERATE_MASTER_OBJECT_FILE is enabled then we will always try to link.  That's arguably not correct.
                if !isForAPI && scope.evaluate(BuiltinMacros.GENERATE_MASTER_OBJECT_FILE) {
                    let executableName = scope.evaluate(BuiltinMacros.EXECUTABLE_NAME) + "-" + arch + "-master.o"
                    // FIXME: It would be more consistent to put this in the per-arch directory.
                    let output = Path(scope.evaluate(BuiltinMacros.PER_VARIANT_OBJECT_FILE_DIR)).join(executableName)
                    await appendGeneratedTasks(&perArchTasks, options: [.linking, .linkingRequirement, .unsignedProductRequirement]) { delegate in
                        await context.masterObjectLinkSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: linkerInputNodes.map { FileToBuild(context: context, absolutePath: $0.path) }, output: output), delegate)
                    }
                    linkerInputNodes = [context.createNode(output)]
                }

                let previewsDylibInputs = previewsDylibForTestHost()

                // Compute the libraries that should be linked.
                let librariesToLink = computeLibraries(buildFilesContext, scope) + previewsDylibInputs
                allLinkedLibraries.append(contentsOf: librariesToLink)

                // Insert the object files present in the framework build phase to the linker inputs.
                let objectsInFrameworkPhase = librariesToLink.filter{ $0.kind == .object }
                linkerInputNodes.append(contentsOf: objectsInFrameworkPhase.map{ $0.path }.map(context.createNode))

                if !SWBFeatureFlag.enableLinkerInputsFromLibrarySpecifiers.value {
                    // If this flag isn't enabled we still want the dylib to be a dependency for this task.
                    // This is a fallback to add the dependency because if the feature flag is false we
                    // still want this to be a dependency. If the feature flag is turned on by default
                    // then this can be removed.
                    linkerInputNodes.append(contentsOf: previewsDylibInputs.map(\.path).map(context.createNode))
                }

                // If any of the items are from a generated source (such as an XCFramework), setup those as inputs as well.
                let additionalLinkerOrderingInputs = librariesToLink.flatMap { $0.explicitDependencies.map(context.createNode) }

                // If there is at least one object file that was built using Swift, ensure the Swift tool is present in the used tools to allow linker spec to add swift specific linker arguments.
                if objectsInFrameworkPhase.contains(where: { !$0.swiftModulePaths.isEmpty }), !usedTools.keys.contains(context.swiftCompilerSpec) {
                    usedTools[context.swiftCompilerSpec] = [context.lookupFileType(identifier: "compiled.mach-o.objfile")!]
                }

                // If this is an API build, or there are no tasks and object files, don't link, so we don't produce a binary if we're not compiling any code.
                // Except that we do want to run the linker when creating a merged library, because the binary needs to either reexport or merge its mergeable libraries.
                //
                // FIXME: This is a crude approximation of the actual logic, but works for now.
                if isForAPI || (perArchTasks.isEmpty && objectsInFrameworkPhase.isEmpty), !scope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES) {
                    tasks.append(contentsOf: perArchTasks)
                    continue
                }

                // Create the linker task.  If we have no input files but decide to create the task anyway, then this task will rely on gate tasks to be properly ordered (which is what happens for the master object file task above if there are no input files).
                if !linkerInputNodes.isEmpty || (components.contains("build") && scope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES)) {
                    // Compute the output path.
                    let output: Path
                    let commandOrderingOutputs: [any PlannedNode]

                    let outputPreviewDylib: Path?
                    let outputPreviewBlankInjectionDylib: Path?
                    let commandOrderingOutputsPreviewDylib: [any PlannedNode]
                    let commandOrderingOutputsBlankInjectionDylib: [any PlannedNode]

                    if archs.count == 1 {
                        output = binaryOutput
                        commandOrderingOutputs = [linkedBinaryNode]

                        outputPreviewDylib = binaryPreviewDylibOutput
                        outputPreviewBlankInjectionDylib = binaryPreviewBlankInjectionDylibOutput
                        commandOrderingOutputsPreviewDylib = [linkedBinaryPreviewDylibNode].compactMap { $0 }
                        commandOrderingOutputsBlankInjectionDylib = [linkedBinaryPreviewBlankInjectionDylibNode].compactMap { $0 }
                    } else {
                        output = scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR).join("Binary").join(scope.evaluate(BuiltinMacros.EXECUTABLE_NAME))
                        commandOrderingOutputs = []

                        outputPreviewDylib = binaryPreviewDylibOutput.map { scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR).join("Binary").join($0.basename) }
                        outputPreviewBlankInjectionDylib = binaryPreviewBlankInjectionDylibOutput.map { scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR).join("Binary").join($0.basename) }
                        commandOrderingOutputsPreviewDylib = []
                        commandOrderingOutputsBlankInjectionDylib = []
                    }

                    let canBeEagerlyLinkedAgainstUsingTBD = context.supportsEagerLinking(scope: scope)
                    shouldPrepareEagerLinkingTBD = shouldPrepareEagerLinkingTBD || canBeEagerlyLinkedAgainstUsingTBD

                    // Link the object files.
                    let linkerSpec = getLinkerToUse(scope)

                    var linkerOpts: TaskOrderingOptions = [.unsignedProductRequirement, .linking]
                    // The link task is a requirement for linking downstream tasks unless this target can be linked against using a TBD.
                    if !canBeEagerlyLinkedAgainstUsingTBD {
                        linkerOpts.insert(.linkingRequirement)
                    }
                    await appendGeneratedTasks(&perArchTasks, options: linkerOpts) { delegate in
                        let linkerInputs = linkerInputNodes.map { FileToBuild(context: context, absolutePath: $0.path) }
                        let actualOutput = outputPreviewDylib ?? output
                        let actualCommandOrderingOutputs = !commandOrderingOutputsPreviewDylib.isEmpty ? commandOrderingOutputsPreviewDylib : commandOrderingOutputs

                        await linkerSpec.constructLinkerTasks(CommandBuildContext(producer: context, scope: scope, inputs: linkerInputs, output: actualOutput, commandOrderingInputs: additionalLinkerOrderingInputs, commandOrderingOutputs: actualCommandOrderingOutputs), delegate, libraries: librariesToLink, usedTools: usedTools)
                    }

                    if let outputPreviewDylib, let outputPreviewBlankInjectionDylib {
                        singleArchPreviewDylibBinaries.append(outputPreviewDylib)
                        singleArchInjectionDylibBinaries.append(outputPreviewBlankInjectionDylib)
                    }
                    else {
                        singleArchBinaries.append(output)
                    }

                    // Link the preview shim.
                    if let outputPreviewDylib, let outputPreviewBlankInjectionDylib {
                        let ldSpec = linkerSpec as! LdLinkerSpec

                        await appendGeneratedTasks(&perArchTasks, options: [.linking, .linkingRequirement, .unsignedProductRequirement]) { delegate in
                            var linkerInputs = [FileToBuild(context: context, absolutePath: outputPreviewDylib)]
                            let outputPreviewDylibLibrary = LinkerSpec.LibrarySpecifier(
                                kind: LinkerSpec.LibrarySpecifier.Kind.dynamic,
                                path: outputPreviewDylib,
                                mode: .normal,
                                useSearchPaths: false,
                                swiftModulePaths: [:],
                                swiftModuleAdditionalLinkerArgResponseFilePaths: [:]
                            )
                            let libraries: [LinkerSpec.LibrarySpecifier]
                            let ldflags: [String]
                            if scope.previewStyle == .xojit {
                                guard let platform = context.platform as SWBCore.Platform? else {
                                    return
                                }

                                guard let previewsDylibRelativePath = outputPreviewDylibLibrary.path.relativeSubpath(from: output.dirname) else {
                                    return
                                }

                                let previewsDylibRelativePathFile: Path
                                do {
                                    let file = Path(scope.evaluate(scope.namespace.parseString("$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-DebugDylibPath-$(CURRENT_VARIANT)-$(CURRENT_ARCH).txt")))
                                    previewsDylibRelativePathFile = file
                                    linkerInputs.append(FileToBuild(context: context, absolutePath: file))

                                    context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: file), delegate, contents: ByteString(encodingAsUTF8: previewsDylibRelativePath), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                                }

                                // LD_ENTRY_POINT covers user-specified entry points as well as built-in entry points like _NSExtensionMain as defined in the app extension product type spec.
                                let entryPointFile: Path?
                                if let entryPoint = scope.evaluate(BuiltinMacros.LD_ENTRY_POINT).nilIfEmpty {
                                    let file = Path(scope.evaluate(scope.namespace.parseString("$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-DebugEntryPoint-$(CURRENT_VARIANT)-$(CURRENT_ARCH).txt")))
                                    entryPointFile = file
                                    linkerInputs.append(FileToBuild(context: context, absolutePath: file))

                                    context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: file), delegate, contents: ByteString(encodingAsUTF8: entryPoint), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                                } else {
                                    entryPointFile = nil
                                }

                                // We need to write out the install name into the stub executor so Previews has
                                // everything it needs to know without actually loading the debug dylib yet. In
                                // cases where Previews JIT's the main executable code it uses this name to
                                // construct the pseudodylib.
                                let installNameFile: Path?
                                if let installName = scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME).nilIfEmpty {
                                    let file = Path(scope.evaluate(scope.namespace.parseString("$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-DebugDylibInstallName-$(CURRENT_VARIANT)-$(CURRENT_ARCH).txt")))
                                    installNameFile = file
                                    linkerInputs.append(FileToBuild(context: context, absolutePath: file))

                                    context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: file), delegate, contents: ByteString(encodingAsUTF8: installName), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                                } else {
                                    installNameFile = nil
                                }

                                // libPreviewsJITStubExecutor.a is only ever linked by the stub executor, which is an executable, so zippering is not relevant.
                                let stubExecutorLibraryParentPath = platform.path.join("Developer").join(context.sdkVariant?.isMacCatalyst == true ? "iOSSupport" : nil).join("usr").join("lib")

                                // rdar://125894897 (🚨 fetchOperationServiceEndpoint seems completely broken for app extensions implemented in Swift (SwiftUI: Swift entry point data not found.))
                                // See comments on `ConstructStubExecutorInputFileListTaskAction` for why we need
                                // this extra task to pick between two stub executor library variants.
                                let stubExecutorLibraryPath = stubExecutorLibraryParentPath.join("libPreviewsJITStubExecutor_no_swift_entry_point.a")
                                let stubExecutorLibraryWithSwiftEntryPointPath = stubExecutorLibraryParentPath.join("libPreviewsJITStubExecutor.a")

                                let executorLinkFileListPath = Path(
                                    scope.evaluate(
                                        scope.namespace.parseString(
                                            "$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-ExecutorLinkFileList-$(CURRENT_VARIANT)-$(CURRENT_ARCH).txt"
                                        )
                                    )
                                )

                                // Update the list of linker inputs to include the link file list that contains the picked stub executor library.
                                linkerInputs.append(FileToBuild(context: context, absolutePath: executorLinkFileListPath))

                                let spec = context.specRegistry.getSpec(ConstructStubExecutorFileListToolSpec.identifier) as! ConstructStubExecutorFileListToolSpec

                                await spec.constructStubExecutorLinkFileListTask(
                                    CommandBuildContext(
                                        producer: context,
                                        scope: scope,
                                        inputs: [],
                                        output: executorLinkFileListPath
                                    ),
                                    delegate,
                                    debugDylibPath: outputPreviewDylib,
                                    stubExecutorLibraryPath: stubExecutorLibraryPath,
                                    stubExecutorLibraryWithSwiftEntryPointPath: stubExecutorLibraryWithSwiftEntryPointPath
                                )

                                // rdar://127248825 (Pre-link the debug dylib and emit a new empty dylib that Previews can load to get in front of dyld)
                                // If we are emitting the debug dylib then we should also construct the empty stub
                                // dylib with the same install name so Previews can leverage dyld behavior to block
                                // loading the original debug dylib until it is ready.
                                await ldSpec.constructPreviewsBlankInjectionDylibTask(
                                    CommandBuildContext(
                                        producer: context,
                                        scope: scope,
                                        inputs: [],
                                        output: outputPreviewBlankInjectionDylib,
                                        commandOrderingOutputs: commandOrderingOutputsBlankInjectionDylib
                                    ),
                                    delegate: delegate
                                )

                                // rdar://127248825 (Pre-link the debug dylib and emit a new empty dylib that Previews can load to get in front of dyld)
                                libraries = [outputPreviewDylibLibrary]

                                ldflags = [
                                    // Create a __TEXT section with the relative path to the preview dylib (we don't want to statically link it; instead the entry point provided by libPreviewsJITStubExecutor.a will load it on demand)
                                    "-Xlinker", "-sectcreate",
                                    "-Xlinker", "__TEXT",
                                    "-Xlinker", "__debug_dylib",
                                    "-Xlinker", previewsDylibRelativePathFile.str,
                                ] + (entryPointFile.map {
                                    [
                                        // Create a __TEXT section with the name of the original entry point
                                        "-Xlinker", "-sectcreate",
                                        "-Xlinker", "__TEXT",
                                        "-Xlinker", "__debug_entry",
                                        "-Xlinker", $0.str,
                                    ]
                                } ?? []) + (installNameFile.map {
                                    [
                                        // Create a __TEXT section with the client name of the original binary, which
                                        // becomes the install name of the debug/blank dylib
                                        "-Xlinker", "-sectcreate",
                                        "-Xlinker", "__TEXT",
                                        "-Xlinker", "__debug_instlnm",
                                        "-Xlinker", $0.str,
                                    ]
                                } ?? []) + [
                                    "-Xlinker", "-filelist", "-Xlinker", executorLinkFileListPath.str,
                                ]
                            } else {
                                libraries = [outputPreviewDylibLibrary]
                                ldflags = []
                            }

                            await ldSpec.constructPreviewShimLinkerTasks(
                                CommandBuildContext(
                                    producer: context,
                                    scope: scope,
                                    inputs: linkerInputs,
                                    output: output,
                                    commandOrderingInputs: additionalLinkerOrderingInputs,
                                    commandOrderingOutputs: commandOrderingOutputs
                                ),
                                delegate,
                                libraries: libraries,
                                usedTools: usedTools,
                                rpaths: ["@executable_path"],
                                ldflags: ldflags
                            )
                        }

                        singleArchBinaries.append(output)
                    }
                }

                // Add all the collected per-arch tasks.
                tasks.append(contentsOf: perArchTasks)

                // Add the output paths for all tasks of this variant to the map of output paths, in order to filter out
                // tasks of other variants which produce the same outputs.
                let thisVariantOutputPaths = perVariantOutputPaths[variant] ?? []
                perVariantOutputPaths[variant] = thisVariantOutputPaths.union(perArchTasks.flatMap { task in task.outputs.map({ $0.path }) })
            }

            // Generate tasks for the module-only architectures.
            for arch in moduleOnlyArchs {
                // Enter the per-arch scope.
                let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
                let currentArchSpec = context.getSpec(arch) as! ArchitectureSpec?

                // Reset the set of used tools.
                usedTools.removeAll(keepingCapacity: true)

                // Process all of the groups.
                //
                // FIXME: We should do this in parallel.
                let buildFilesContext = BuildFilesProcessingContext(scope, belongsToPreferredArch: preferredArch == nil || preferredArch == arch, currentArchSpec: currentArchSpec)
                var perArchTasks: [any PlannedTask] = []
                await groupAndAddTasksForFiles(self, buildFilesContext, scope, filterToAPIRules: isForAPI, filterToHeaderRules: isForHeaders, &perArchTasks, extraResolvedBuildFiles: {
                    if let packageTargetBundleAccessorResult {
                        return [(packageTargetBundleAccessorResult.fileToBuild, packageTargetBundleAccessorResult.fileToBuildFileType, /* shouldUsePrefixHeader */ false)]
                    } else {
                        return []
                    }
                }())

                // Add all the collected per-arch tasks.
                tasks.append(contentsOf: perArchTasks)
            }

            // If nothing was built, we are done with this variant.
            if singleArchBinaries.isEmpty {
                continue
            }

            if shouldPrepareEagerLinkingTBD {
                await self.context.settings.productType?.addInstallAPITasks(self, scope, context.tapiSpec.discoveredCommandLineToolSpecInfo(context, scope, context.globalProductPlan.delegate) as? DiscoveredTAPIToolSpecInfo, &tasks, destination: .eagerLinkingTBDDir)
            }

            // Lipo the linked binaries if there's more than one of them.
            if singleArchBinaries.count > 1 {
                await appendGeneratedTasks(&tasks, options: [.linking, .linkingRequirement, .unsignedProductRequirement]) { delegate in
                    await context.lipoSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: singleArchBinaries.map { FileToBuild(context: context, absolutePath: $0) }, output: binaryOutput, commandOrderingOutputs: [linkedBinaryNode]), delegate)
                }
            }
            else if singleArchBinaries.count == 1, archs.count > 1, let singleArchBinaryPath = singleArchBinaries.first {
                // If there's only one binary but multiple architectures defined for the target, then for some reason we didn't produce a binary for any of the others - probably due to a strange target configuration.  If so, then we should create a copy task to copy the single-arch binary to the final location.
                let productBinaryPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))
                if singleArchBinaryPath != productBinaryPath {
                    await appendGeneratedTasks(&tasks, options: [.linking, .linkingRequirement, .unsignedProductRequirement]) { delegate in
                        await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: singleArchBinaryPath)], output: productBinaryPath, commandOrderingOutputs: [linkedBinaryNode]), delegate, executionDescription: "Copy binary to product", stripUnsignedBinaries: false)
                    }
                }
            }

            if singleArchPreviewDylibBinaries.count > 1,
                let binaryPreviewDylibOutput,
                let linkedBinaryPreviewDylibNode {
                await appendGeneratedTasks(&tasks, options: [.linking, .linkingRequirement, .unsignedProductRequirement]) { delegate in
                    await context.lipoSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: singleArchPreviewDylibBinaries.map { FileToBuild(context: context, absolutePath: $0) }, output: binaryPreviewDylibOutput, commandOrderingOutputs: [linkedBinaryPreviewDylibNode]), delegate)
                }
            }

            if singleArchInjectionDylibBinaries.count > 1,
                binaryPreviewDylibOutput != nil,
                let linkedBinaryPreviewBlankInjectionDylibNode {
                await appendGeneratedTasks(&tasks, options: [.linking, .unsignedProductRequirement]) { delegate in
                    await context.lipoSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: singleArchInjectionDylibBinaries.map { FileToBuild(context: context, absolutePath: $0) }, output: binaryPreviewBlankInjectionDylibOutput, commandOrderingOutputs: [linkedBinaryPreviewBlankInjectionDylibNode]), delegate)
                }
            }

            // Register the produced binary. (Don't need this for preview shims, it's meant for installapi / tbd.)
            context.addProducedBinary(path: binaryOutput, forVariant: variant)

            // Create the dSYM, if desired.
            if shouldGenerateDSYM(scope) {

                // A single dSYM bundle can contain symbols for multiple build variants. The output for a variant is:
                // <bundle>/Contents/Resources/DWARF/$(EXECUTABLE_NAME)
                //
                // To keep the nodes unique for each build variant, we use the output path of the actual file that is generated (instead of the path to the dSYM bundle).
                dsymBundle = scope.evaluate(BuiltinMacros.DWARF_DSYM_FOLDER_PATH)
                    .join(scope.evaluate(BuiltinMacros.DWARF_DSYM_FILE_NAME))

                let binary = binaryPreviewDylibOutput ?? binaryOutput
                let binaryOrderingInput = linkedBinaryPreviewDylibNode ?? linkedBinaryNode

                let output = dsymBundle
                    .join("Contents").join("Resources").join("DWARF")
                    .join(binary.basename)

                // Compute the inputs.
                var inputs = [FileToBuild(context: context, absolutePath: binary)]

                // Add dependency to info.plist, if present.
                if !scope.effectiveInputInfoPlistPath().isEmpty && context.settings.productType?.hasInfoPlist == true {
                    let infoPlistPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.INFOPLIST_PATH))
                    inputs += [FileToBuild(context: context, absolutePath: infoPlistPath)]
                }

                // If we are merging any libraries, then pass the build variant and the search paths to the dSYMs for those libraries to dsymutil.
                // We don't want to add search paths more than once, but we don't have a strong reason to prefer an order for the search paths, so we order them approximately in the order of the libraries.
                var dsymSearchPaths = OrderedSet<String>()
                var mergedPaths = Set<Path>()
                for library in allLinkedLibraries {
                    if library.mode == .merge {
                        let libraryPath = library.path
                        // Only process any given srcPath once.  This is necessary because we're unioning the LibrarySpecifiers across all architectures and variants.
                        // Note that even if allLinkedLibraries were a set it's possible (though very unlikely) that a srcPath might still show up twice in it, with different linkage specifications.
                        guard !mergedPaths.contains(libraryPath) else {
                            continue
                        }
                        mergedPaths.insert(libraryPath)

                        // If the library has a known dSYM file, then pass the path to the directory of that dSYM.  If there isn'r one, then pass the path to the directory containing the library, since our best guess is that the dSYM will be alongside the library.
                        if let dsymPath = library.dsymPath {
                            dsymSearchPaths.append(dsymPath.dirname.str)
                        }
                        else {
                            dsymSearchPaths.append(libraryPath.dirname.str)
                        }
                    }
                }
                let buildVariant = (dsymSearchPaths.isEmpty || variant == "normal") ? "" : variant

                // We set usePhasedOrdering: false here because this task depends on the ProcessInfoPlist task which occurs downstream when phase ordering is used, which would lead to a cycle.
                await appendGeneratedTasks(&tasks, usePhasedOrdering: false) { delegate in
                    await context.dsymutilSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: inputs, output: output, commandOrderingInputs: [binaryOrderingInput] + dsymutilInputNodes), delegate, dsymBundle: dsymBundle, buildVariant: buildVariant, dsymSearchPaths: dsymSearchPaths.elements)
                }

                if binaryPreviewDylibOutput != nil {
                    let inputs = [FileToBuild(context: context, absolutePath: binaryOutput)]
                    let output = dsymBundle
                        .join("Contents").join("Resources").join("DWARF")
                        .join(binaryOutput.basename)
                    await appendGeneratedTasks(&tasks, usePhasedOrdering: false) { delegate in
                        await context.dsymutilSpec
                            .constructTasks(
                                CommandBuildContext(
                                    producer: context,
                                    scope: scope,
                                    inputs: inputs,
                                    output: output,
                                    commandOrderingInputs: [linkedBinaryNode] + dsymutilInputNodes
                                ),
                                delegate,
                                dsymBundle: dsymBundle,
                                buildVariant: buildVariant,
                                dsymSearchPaths: dsymSearchPaths.elements,
                                // The stub executor has no debug symbols but we need a dSYM due to:
                                // rdar://127835429 (Emit dSYM for stub executor to satisfy what lldb crashlog processing (behind user default))
                                // rdar://127433616 (Crashlogs not symbolicating)
                                // Since it has no symbols it will emit a warning so we need to silence it.
                                quietOperation: true
                            )
                    }
                }

                // Record the dSYM path for use by construction of downstream tasks.
                dsymutilOutputs.append(output)
                context.addProducedDSYM(path: output, forVariant: variant)
            }
        }

        if let preparedForIndexNode = targetContext.preparedForIndexPreCompilationNode, let configuredTarget = context.configuredTarget {
            // The pre-compilation marker should update if any of its dependencies updates the module content marker.
            let dependencies = context.globalProductPlan.planRequest.buildGraph.dependencies(of: configuredTarget)
            let moduleInputs = dependencies.compactMap { dependency -> (any PlannedNode)? in
                guard dependency !== configuredTarget else { return nil }
                let taskInfo = context.globalProductPlan.targetTaskInfos[dependency]!
                if context.globalProductPlan.targetsRequiredToBuildForIndexing.contains(dependency) {
                    return taskInfo.endNode
                } else {
                    return taskInfo.preparedForIndexModuleContentNode
                }
            }
            await appendGeneratedTasks(&tasks, usePhasedOrdering: false) { delegate in
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [], outputs: [preparedForIndexNode.path], commandOrderingInputs: prepareTargetForIndexInputs + moduleInputs)
                context.writeFileSpec.constructFileTasks(cbc, delegate, ruleName: ProductPlan.preparedForIndexPreCompilationRuleName, contents: [], permissions: nil, forceWrite: true, preparesForIndexing: true, additionalTaskOrderingOptions: [])
            }
        }

        let generatedDsymFiles = tasks.filter({ $0.type is DsymutilToolSpec }).flatMap { $0.outputs }
        if !generatedDsymFiles.isEmpty {
            let dsymBundleNode: any PlannedNode

            // Honor request to put dSYM adjacent to product.
            let accompanyingDsymFilePath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.DWARF_DSYM_FILE_NAME))

            // Only copy the dSYM if we'd actually copy it to a different location.
            // During a build action (not install), the input and output locations are generally the same.
            if scope.evaluate(BuiltinMacros.DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT) && dsymBundle != accompanyingDsymFilePath {
                let inputs = [FileToBuild(context: context, absolutePath: dsymBundle)]
                // Also add the declared outputs of the dsymutil tasks constructed above as inputs, or the copy task might not run when it should in incremental builds.
                let additionalInputs = dsymutilOutputs.map({ context.createNode($0) })

                var copyTasks = [any PlannedTask]()
                await appendGeneratedTasks(&copyTasks, usePhasedOrdering: false) { delegate in
                    await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: inputs, output: accompanyingDsymFilePath, commandOrderingInputs: additionalInputs), delegate, stripUnsignedBinaries: false, stripBitcode: false)
                }
                tasks.append(contentsOf: copyTasks)
                dsymBundleNode = copyTasks.first!.inputs.first!
            } else {
                dsymBundleNode = MakePlannedDirectoryTreeNode(dsymBundle)
            }

            // Add a gate task to allow users to depend on the whole dSYM bundle.
            let name = "\(dsymBundleNode.path.str)-\(context.configuredTarget?.guid.stringValue ?? "")"
            let gateTask = context.createGateTask(generatedDsymFiles, output: dsymBundleNode, name: name, mustPrecede: [targetContext.targetEndTask])
            tasks.append(gateTask)
        }

        let headers = context.generatedSwiftObjectiveCHeaderFiles()
        if !headers.isEmpty {
            var mergeHeaderTasks = [any PlannedTask]()
            await appendGeneratedTasks(&mergeHeaderTasks, usePhasedOrdering: false) { delegate in
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: headers.values.map { FileToBuild(context: context, absolutePath: $0) })
                context.swiftHeaderToolSpec.constructSwiftHeaderToolTask(cbc, delegate, inputs: headers, outputPath: SwiftCompilerSpec.generatedObjectiveCHeaderOutputPath(cbc.scope), mustPrecede: [self.swiftGeneratedHeadersCompletionTask])
            }
            tasks.append(contentsOf: mergeHeaderTasks)
        }

        // If we're merging libraries, we want to embed just the binaries of any mergeable libraries we're reexporting into ourselves.  This mainly occurs when performing a debug build.
        // This copy-and-resign algorithm is a simple one inspired by XCTestProductPostprocessingTaskProducer.copyAndReSignTestFramework() rather than the more complicated and general approach in CopyFilesTaskProducer.
        // We need to preserve the directory structure here because the LC_REEXPORT_DYLIB load command in the merged binary will contain the .framework directory and any intermediates which dyld will expect to find the library.
        if scope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES), !scope.evaluate(BuiltinMacros.DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES) {
            var copyLibraryTasks = [any PlannedTask]()
            // We don't want to use the defaultTaskOrderingOptions here because these tasks depend on the products of upstream targets and thus need to depend on the target's entry node, which the default options don't do.
            await appendGeneratedTasks(&copyLibraryTasks, options: .unsignedProductRequirement) { delegate in
                let dstDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.CONTENTS_FOLDER_PATH)).join(reexportedBinariesDirectoryName)
                var reexportedPaths = Set<Path>()
                for library in allLinkedLibraries {
                    // FIXME: There may be legitimate reasons why a library is being reexported but shouldn't be copied here.  In the LibrarySpecifier we should capture whether it's a mergeable library and take that into account.
                    if library.mode == .reexport_merge {
                        let libraryPath = library.topLevelItemPath ?? library.path
                        // Only process any given srcPath once.  This is necessary because we're unioning the LibrarySpecifiers across all architectures and variants.
                        // Note that even if allLinkedLibraries were a set it's possible (though very unlikely) that a srcPath might still show up twice in it, with different linkage specifications.
                        guard !reexportedPaths.contains(libraryPath) else {
                            continue
                        }
                        reexportedPaths.insert(libraryPath)
                        let fileToCopy = FileToBuild(absolutePath: libraryPath, inferringTypeUsing: context)
                        let dstPath = dstDir.join(libraryPath.basename)

                        var subpathsToInclude = OrderedSet<String>()
                        var additionalPresumedOutputs = [Path]()
                        var pathToSign = dstPath

                        var subpathsToStrip = OrderedSet<String>()

                        /// Utility method to add a subpath to `subpathsToInclude`. If the subpath's first path component is `removeFirstPart` then it will be removed before adding the rest of the subpath.
                        func addSubpath(_ string: String, removingFirstPartIfEqualTo firstPartToRemove: String) {
                            guard !string.isEmpty else {
                                return
                            }
                            let strParts = string.split(separator: Path.pathSeparator)
                            if let firstPart = strParts.first {
                                // (If there aren't any parts then we have nothing to add.)
                                if strParts.count > 1, firstPart == firstPartToRemove {
                                    let subpath = strParts[1...].joined(separator: Path.pathSeparatorString)
                                    subpathsToInclude.append(subpath)
                                }
                                else if firstPart != firstPartToRemove {
                                    // If string is *only* firstPartToRemove then we don't add it.
                                    subpathsToInclude.append(string)
                                }
                            }
                        }

                        // Compute the subpaths of the linked item we want to copy.  This means we need to get the scope for the producing target.
                        // FIXME: We should unify this as much as possible with the logic in CopyFilesTaskProducer.
                        if let producingTarget = context.globalProductPlan.productPathsToProducingTargets[libraryPath] {
                            let copiedFileSettings = context.globalProductPlan.planRequest.buildRequestContext.getCachedSettings(producingTarget.parameters, target: producingTarget.target)

                            if let productType = copiedFileSettings.productType {
                                // If this is a standalone binary product then we just copy it.  Otherwise PBXCp will include the subpaths we assemble here.
                                if productType.isWrapper {
                                    // Copy the binary, the Info.plist, and the code signature directory.  (The last two are needed to re-sign.)
                                    let copiedFullProductName = copiedFileSettings.globalScope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME)
                                    addSubpath(copiedFileSettings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_PATH).str, removingFirstPartIfEqualTo: copiedFullProductName.str)
                                    addSubpath(copiedFileSettings.globalScope.evaluate(BuiltinMacros.CONTENTS_FOLDER_PATH).join("_CodeSignature").str, removingFirstPartIfEqualTo: copiedFullProductName.str)
                                    addSubpath(copiedFileSettings.globalScope.evaluate(BuiltinMacros.INFOPLIST_PATH).str, removingFirstPartIfEqualTo: copiedFullProductName.str)
                                    if productType.conformsTo(identifier: "com.apple.product-type.framework"), !copiedFileSettings.globalScope.evaluate(BuiltinMacros.SHALLOW_BUNDLE) {
                                        // For deep frameworks (macOS), we also need to copy the symlinks for the binary and the Versions/Current directory, since those are how dyld accesses the binary.
                                        addSubpath(copiedFileSettings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_NAME), removingFirstPartIfEqualTo: copiedFullProductName.str)
                                        addSubpath(copiedFileSettings.globalScope.evaluate(BuiltinMacros.VERSIONS_FOLDER_PATH).join(copiedFileSettings.globalScope.evaluate(BuiltinMacros.CURRENT_VERSION)).str, removingFirstPartIfEqualTo: copiedFullProductName.str)
                                    }

                                    // If this is a framework, then we want to sign the CONTENTS_FOLDER_PATH which will be the Versions/A path for macOS frameworks.  We also need to declare additional outputs.
                                    if productType.conformsTo(identifier: "com.apple.product-type.framework") {
                                        pathToSign = dstDir.join(copiedFileSettings.globalScope.evaluate(BuiltinMacros.CONTENTS_FOLDER_PATH))

                                        if pathToSign != dstPath {
                                            additionalPresumedOutputs.append(pathToSign)
                                        }
                                        additionalPresumedOutputs.append(pathToSign.join(copiedFileSettings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_NAME)))
                                    }
                                }
                                else {
                                    // Don't add any paths - this will result in us just copying the unwrapped product.
                                }
                            }
                        }
                        else if let xcframeworkSourcePath = library.xcframeworkSourcePath {
                            // Copying an XCFramework component which is marked as mergeable.
                            var xcFramework: XCFramework? = nil
                            do {
                                // We need to get the XCFramework from the library being copied.  This logic is the current way to do this.
                                xcFramework = try XCFramework(path: xcframeworkSourcePath, fs: context.fs)
                            } catch {
                                context.error(error.localizedDescription)
                            }
                            if let xcFramework = xcFramework, let library = xcFramework.findLibrary(sdk: context.sdk, sdkVariant: context.sdkVariant) {
                                var shouldCopyBinary = false
                                if library.mergeableMetadata {
                                    // We know we're copying a library which was built mergeable. Now what we want to know if whether we're merging it, or one of our dependencies is.
                                    if let configuredTarget = context.configuredTarget {
                                        for cTarget in [configuredTarget] + context.globalProductPlan.dependencies(of: configuredTarget) {
                                            // FIXME: Perhaps knowing "does this target link this XCFramework" is something that the GlobalProductPlan or XCFrameworkContext should know.
                                            if let frameworksBuildPhase = (cTarget.target as? BuildPhaseTarget)?.frameworksBuildPhase {
                                                for linkedBuildFile in frameworksBuildPhase.buildFiles {
                                                    if let resolvedLinkedBuildFile = try? context.resolveBuildFileReference(linkedBuildFile), resolvedLinkedBuildFile.fileType.identifier == "wrapper.xcframework", xcframeworkSourcePath == resolvedLinkedBuildFile.absolutePath {
                                                        // Here we know that this target is merging linked libraries, that this is an XCFramework which is being linked, and that this XCFramework is marked as mergeable.
                                                        shouldCopyBinary = true
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // If we should skip copying it, then we set up the subpaths to exclude.
                                // We also direct PBXCp to strip the binary, to remove any mergeable metadata. This will also strip debug info <rdar://108221696> (and in addition PBXCp explicitly passes '-S'), so if this XCFramework is intended to be used for debugging then it needs to have an XCFramework.
                                if shouldCopyBinary {
                                    guard let binaryPath = library.binaryPath else {
                                        context.warning("XCFramework contains mergeable metadata but does not define a binary path: \(xcframeworkSourcePath.str)")
                                        continue
                                    }
                                    // If this is a standalone binary product then we skip copying it altogether.  Otherwise PBXCp will exclude the subpaths we add to the list here.
                                    switch library.libraryType {
                                    case .dynamicLibrary:
                                        // A standalone library simply gets copied and re-signed.
                                        subpathsToStrip.append(binaryPath.str)
                                    case .framework:
                                        // For a framework we need to configure what we need to copy, skipping everything else, and deal with the special nature of the macOS framework bundle layout.
                                        addSubpath(binaryPath.str, removingFirstPartIfEqualTo: library.libraryPath.str)
                                        let contentsPath = binaryPath.dirname
                                        addSubpath(contentsPath.join("_CodeSignature").str, removingFirstPartIfEqualTo: library.libraryPath.str)
                                        addSubpath(contentsPath.join("Info.plist").str, removingFirstPartIfEqualTo: library.libraryPath.str)
                                        if library.supportedPlatform == "macos" {
                                        // For deep frameworks (macOS), we also need to copy the symlinks for the binary and the Versions/Current directory, since those are how dyld accesses the binary.
                                            addSubpath(binaryPath.basename, removingFirstPartIfEqualTo: library.libraryPath.str)
                                            addSubpath(contentsPath.dirname.join("Current").str, removingFirstPartIfEqualTo: library.libraryPath.str)
                                        }
                                        // Finally, we want to strip the binary.
                                        subpathsToStrip.append(binaryPath.str)
                                    default:
                                        // These types do not support mergeable metadata.  This should have been caught at XCFramework creation time, but perhaps someone edited the XCFramework after creation.
                                        // In this case, we emit a warning and do not copy this item (because it's not clear what we should do with them in a debug build), by continuing in the loop.
                                        context.warning("XCFramework claims \(library.libraryType.libraryTypeName) contains mergeable metadata, which is not supported: \(xcframeworkSourcePath)")
                                        continue
                                    }
                                }
                            }
                        }

                        // Copy the linked item.
                        let copyOrderingNode = delegate.createVirtualNode("CopyReexportedBinary \(dstPath.str)")
                        do {
                            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [fileToCopy], output: dstPath, commandOrderingOutputs: [copyOrderingNode])
                            await context.copySpec.constructCopyTasks(cbc, delegate, includeOnlySubpaths: subpathsToInclude.elements, stripSubpaths: subpathsToStrip.elements, additionalPresumedOutputs: additionalPresumedOutputs.map({ context.createNode($0) }))
                        }

                        // Re-sign the linked item.
                        let signFrameworkOrderingNode = delegate.createVirtualNode("SignReexportedBinary \(dstPath.str)")
                        do {
                            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: pathToSign, inferringTypeUsing: context)], commandOrderingInputs: [copyOrderingNode], commandOrderingOutputs: [signFrameworkOrderingNode])
                            context.codesignSpec.constructCodesignTasks(cbc, delegate, productToSign: dstPath, isReSignTask: true, isAdditionalSignTask: true)
                        }
                    }
                }
            }
            tasks.append(contentsOf: copyLibraryTasks)
        }

        // Emit a warning for this target if $(ARCHS) was empty, but it looks like we otherwise should have produced a binary.  This probably indicates a project configuration problem.
        // See TaskProducerContext.willProducerBinary() for similar logic in this area; this code used to call that method, but once the $(ARCHS) check was rolled into that method, it was no longer applicable here.
        if archs.isEmpty {
            func willGenerateSources(for variant: String) -> Bool {
                // We don't bind a subscope to check arch conditions since we know archs is empty at this point, and so there are no values to enumerate
                let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
                let context = BuildFilesProcessingContext(scope)
                return scope.generatesAppleGenericVersioningFile(context) || scope.generatesKernelExtensionModuleInfoFile(context, self.context.settings, buildPhase)
            }

            if buildPhase.buildFiles.count > 0 || buildVariants.contains(where: willGenerateSources(for:)) {
                emitEmptyEffectiveArchitecturesDiagnostic(scope)
            }
        }

        if isForInstallLoc {
            // For installLoc, we really only care about valid localized content from the sources task producer
            tasks = tasks.filter { $0.inputs.contains(where: { $0.path.isValidLocalizedContent(scope) }) }
        }

        return tasks
    }

    private func emitEmptyEffectiveArchitecturesDiagnostic(_ scope: MacroEvaluationScope) {
        let arch = scope.evaluate(BuiltinMacros.arch)
        let rcArchs = scope.evaluate(BuiltinMacros.RC_ARCHS)
        let requestedArchsMacro = !rcArchs.isEmpty ? "RC_ARCHS" : "ARCHS"
        let validArchs = scope.evaluate(BuiltinMacros.VALID_ARCHS)
        let validArchsStr = validArchs.joined(separator: ", ")
        let excludedArchs = scope.evaluate(BuiltinMacros.EXCLUDED_ARCHS)
        let excludedArchsStr = excludedArchs.joined(separator: ", ")
        let originalArchs = scope.evaluate(BuiltinMacros.__ARCHS__)
        let requestedArchs = (!rcArchs.isEmpty ? rcArchs : originalArchs)

        if validArchsStr.isEmpty {
            context.warning("There are no architectures to compile for because the VALID_ARCHS build setting is an empty list.")
        } else if validArchs.filter({ !excludedArchs.contains($0) }).isEmpty {
            context.warning("There are no architectures to compile for because all architectures in VALID_ARCHS (\(validArchsStr)) are also in EXCLUDED_ARCHS (\(excludedArchsStr)).")
        } else if requestedArchs.isEmpty {
            context.warning("There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (\(validArchsStr))" + (!excludedArchsStr.isEmpty ? " which is not in EXCLUDED_ARCHS (\(excludedArchsStr))" : "") + ".")
        } else if scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH) && !arch.isEmpty && arch != "undefined_arch" {
            context.warning("The active architecture (\(arch)) is not valid - it is the only architecture considered because ONLY_ACTIVE_ARCH is enabled. Consider setting \(requestedArchsMacro) to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (\(validArchsStr))" + (!excludedArchsStr.isEmpty ? " which is not in EXCLUDED_ARCHS (\(excludedArchsStr))" : "") + ".")
        } else {
            context.warning("None of the architectures in \(requestedArchsMacro) (\(requestedArchs.joined(separator: ", "))) are valid. Consider setting \(requestedArchsMacro) to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (\(validArchsStr))" + (!excludedArchsStr.isEmpty ? " which is not in EXCLUDED_ARCHS (\(excludedArchsStr))" : "") + ".")
        }
    }

    /// Compute the linker to use in the given scope.
    private func getLinkerToUse(_ scope: MacroEvaluationScope) -> LinkerSpec {
        let isStaticLib = scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "staticlib"

        // Return the custom linker, if specified.
        var identifier = scope.evaluate(isStaticLib ? BuiltinMacros.LIBRARIAN : BuiltinMacros.LINKER)
        if !identifier.isEmpty {
            let spec = context.getSpec(identifier)
            if let linker = spec as? LinkerSpec {
                return linker
            }

            // FIXME: Emit a warning here.
        }

        // Return the default linker.
        identifier = isStaticLib ? LibtoolLinkerSpec.identifier : LdLinkerSpec.identifier
        return context.getSpec(identifier) as! LinkerSpec
    }

    /// Custom override to support supplying the resources directory when constructing tasks.
    override func constructTasksForRule(_ rule: any BuildRuleAction, _ group: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async {
        // Ignore asset catalog tasks during installLoc.
        // Asset catalogs are moved to the sources phase for generated asset symbols.
        if scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            let isAssetCatalog = group.files.contains(where: { $0.fileType.conformsTo(identifier: "folder.abstractassetcatalog") })
            guard !isAssetCatalog else { return }
        }

        // Compute the resources directory.
        let resourcesDir = buildFilesContext.resourcesDir.join(group.regionVariantPathComponent)

        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: group.files, isPreferredArch: buildFilesContext.belongsToPreferredArch, currentArchSpec: buildFilesContext.currentArchSpec, buildPhaseInfo: buildFilesContext.buildPhaseInfo(for: rule), resourcesDir: resourcesDir, tmpResourcesDir: buildFilesContext.tmpResourcesDir, unlocalizedResourcesDir: buildFilesContext.resourcesDir)
        await constructTasksForRule(rule, cbc, delegate)
    }

    func addTasksForUngroupedFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) {
        // We never compile ungrouped rules in the sources build phase.

        // Ignore files that don't want the warning (for example because it's a file that's already been handled by a package plugin).
        if let buildFile = ftb.buildFile, !buildFile.shouldWarnIfNoRuleToProcess {
            return
        }

        // Ignore header files, which are often produced by source code generators.
        // TODO: At some point this could probably be handled by the build file `shouldWarnIfNoRuleToProcess` property.
        if ftb.fileType.conformsToAny(context.workspaceContext.core.specRegistry.headerFileTypes) {
            return
        }

        // Emit a diagnostic about an unprocessed file in the sources build phase.
        //
        // FIXME: Don't warn about headers here, they are commonly generated by rules which produce generated source files.
        context.warning("no rule to process file '\(ftb.absolutePath.str)' of type '\(ftb.fileType.identifier)' for architecture '\(scope.evaluate(BuiltinMacros.CURRENT_ARCH))'")

        // FIXME: Xcode is willing to add certain types here to the things to link (object files, static libraries).
    }

    override func validateSpecForRule(_ spec: Spec, _ rule: any BuildRuleAction, _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> Bool {
        // <rdar://problem/34717923> Clean up handling of resource files in sources phase
        // TODO: Make this data-driven in the future...
        switch spec.identifier {
        case "com.apple.compilers.tiffutil", CopyToolSpec.identifier:
            for input in cbc.inputs {
                delegate.warning("The file \"\(input.absolutePath.str)\" cannot be processed by the \(buildPhase.name) build phase using the \"\(spec.name)\" rule.")
            }
            return false
        default:
            break
        }

        return super.validateSpecForRule(spec, rule, cbc, delegate)
    }

    override func shouldAddOutputFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ productDirectories: [Path], _ scope: MacroEvaluationScope) -> Bool {
        // We don't perform further processing of generated header files.
        guard !ftb.fileType.conformsToAny(context.workspaceContext.core.specRegistry.headerFileTypes) else { return false }

        return super.shouldAddOutputFile(ftb, buildFilesContext, productDirectories, scope)
    }

    /// The result containing the tasks required for generating resource accessors.
    struct GeneratedResourceAccessorResult {
        /// The generated tasks.
        var tasks: [any PlannedTask]

        /// The file to build. This can be either Swift or ObjC file.
        var fileToBuild: Path

        /// The type of file to build.
        var fileToBuildFileType: FileTypeSpec
    }

    private func generateEmbedInCodeAccessorResult(_ scope: MacroEvaluationScope, resourceBuildFiles: [BuildFile]) async throws -> GeneratedResourceAccessorResult? {
        if resourceBuildFiles.isEmpty {
            return nil
        }

        let filePath = scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("embedded_resources.swift")

        var content = "struct PackageResources {\n"

        for file in resourceBuildFiles {
            let (_, path, _) = try context.resolveBuildFileReference(file)

            let variableName = path.basename.mangledToC99ExtendedIdentifier()
            let fileContent = try Data(contentsOf: URL(fileURLWithPath: path.str)).map { String($0) }.joined(separator: ",")

            content += "static let \(variableName): [UInt8] = [\(fileContent)]\n"
        }

        content += "}"

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: filePath), delegate, contents: ByteString(encodingAsUTF8: content), permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }
        return GeneratedResourceAccessorResult(tasks: tasks, fileToBuild: filePath, fileToBuildFileType: context.lookupFileType(fileName: "sourcecode.swift")!)
    }

    /// Generates a task for creating the resource bundle accessor for package targets.
    private func generatePackageTargetBundleAccessorResult(_ scope: MacroEvaluationScope) async -> GeneratedResourceAccessorResult? {
        let bundleName = scope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_BUNDLE_NAME)
        let isRegularPackage = scope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_TARGET_KIND) == .regular
        let targetHasAssetCatalog = targetContext.configuredTarget?.target.hasAssetCatalog(scope: scope, context: context, includeGenerated: false) ?? false

        let needsPackageTargetBundleAccessor = !bundleName.isEmpty || (isRegularPackage && targetHasAssetCatalog)
        guard needsPackageTargetBundleAccessor else { return nil }

        if !scope.evaluate(BuiltinMacros.GENERATE_RESOURCE_ACCESSORS) {
            return nil
        }

        let workspace = self.context.workspaceContext.workspace

        // Swift package target can only contain either Swift or C-family languages so
        // we don't need to worry about targets with mixed languages.
        if buildPhase.containsSwiftSources(workspace, context, scope, context.filePathResolver) {
            return await generatePackageTargetBundleAccessorForSwift(scope, bundleName: bundleName)
        } else {
            return await generatePackageTargetBundleAccessorForObjC(scope, bundleName: bundleName)
        }
    }

    private func generatePackageTargetBundleAccessorForObjC(_ scope: MacroEvaluationScope, bundleName: String) async -> GeneratedResourceAccessorResult? {
        guard !bundleName.isEmpty else { return nil }

        let headerFile = scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("resource_bundle_accessor.h")
        let implFile = scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("resource_bundle_accessor.m")

        let escapedBundleName = bundleName.asLegalCIdentifier

        let headerFileContents = """
        #import <Foundation/Foundation.h>

        __BEGIN_DECLS

        NSBundle* \(escapedBundleName)_SWIFTPM_MODULE_BUNDLE(void);

        #define SWIFTPM_MODULE_BUNDLE \(escapedBundleName)_SWIFTPM_MODULE_BUNDLE()

        __END_DECLS
        """

        let implFileContents = """
        #import <Foundation/Foundation.h>

        NS_ASSUME_NONNULL_BEGIN

        @interface \(escapedBundleName)_SWIFTPM_MODULE_BUNDLER_FINDER : NSObject
        @end

        @implementation \(escapedBundleName)_SWIFTPM_MODULE_BUNDLER_FINDER
        @end

        NSBundle* \(escapedBundleName)_SWIFTPM_MODULE_BUNDLE() {
            NSString *bundleName = @"\(escapedBundleName)";

            NSArray<NSURL*> *candidates = @[
                NSBundle.mainBundle.resourceURL,
                [NSBundle bundleForClass:[\(escapedBundleName)_SWIFTPM_MODULE_BUNDLER_FINDER class]].resourceURL,
                NSBundle.mainBundle.bundleURL
            ];

            for (NSURL* candidate in candidates) {
                NSURL *bundlePath = [candidate URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.bundle", bundleName]];

                NSBundle *bundle = [NSBundle bundleWithURL:bundlePath];
                if (bundle != nil) {
                    return bundle;
                }
            }

            @throw [[NSException alloc] initWithName:@"SwiftPMResourcesAccessor" reason:[NSString stringWithFormat:@"unable to find bundle named %@", bundleName] userInfo:nil];
        }

        NS_ASSUME_NONNULL_END
        """

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            for (file, contents) in [(headerFile, headerFileContents), (implFile, implFileContents)] {
                context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: file), delegate, contents: ByteString(encodingAsUTF8: contents), permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
            }
        }

        return GeneratedResourceAccessorResult(tasks: tasks, fileToBuild: implFile, fileToBuildFileType: context.lookupFileType(languageDialect: .objectiveC)!)
    }

    private func generatePackageTargetBundleAccessorForSwift(_ scope: MacroEvaluationScope, bundleName: String) async -> GeneratedResourceAccessorResult {
        let filePath = scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("resource_bundle_accessor.swift")

        let contents = bundleName.isEmpty ? """
            import class Foundation.Bundle

            extension Foundation.Bundle {
                static let module = {
                    class BundleFinder {}
                    return Foundation.Bundle(for: BundleFinder.self)
                }()
            }
            """ : """
            import class Foundation.Bundle
            import class Foundation.ProcessInfo
            import struct Foundation.URL

            private class BundleFinder {}

            extension Foundation.Bundle {
                /// Returns the resource bundle associated with the current Swift module.
                static let module: Bundle = {
                    let bundleName = "\(bundleName.asSwiftStringLiteralContent)"

                    let overrides: [URL]
                    #if DEBUG
                    // The 'PACKAGE_RESOURCE_BUNDLE_PATH' name is preferred since the expected value is a path. The
                    // check for 'PACKAGE_RESOURCE_BUNDLE_URL' will be removed when all clients have switched over.
                    // This removal is tracked by rdar://107766372.
                    if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
                                   ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
                        overrides = [URL(fileURLWithPath: override)]
                    } else {
                        overrides = []
                    }
                    #else
                    overrides = []
                    #endif

                    let candidates = overrides + [
                        // Bundle should be present here when the package is linked into an App.
                        Bundle.main.resourceURL,

                        // Bundle should be present here when the package is linked into a framework.
                        Bundle(for: BundleFinder.self).resourceURL,

                        // For command-line tools.
                        Bundle.main.bundleURL,
                    ]

                    for candidate in candidates {
                        let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
                        if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
                            return bundle
                        }
                    }
                    fatalError("unable to find bundle named \(bundleName.asSwiftStringLiteralContent)")
                }()
            }
            """

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: filePath), delegate, contents: ByteString(encodingAsUTF8: contents), permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }
        return GeneratedResourceAccessorResult(tasks: tasks, fileToBuild: filePath, fileToBuildFileType: context.lookupFileType(fileName: "sourcecode.swift")!)
    }

    private func generateKernelExtensionModuleInfoFileTask(_ scope: MacroEvaluationScope, _ buildPhase: BuildPhaseWithBuildFiles) async -> (any PlannedTask)? {
        // Compile the kernel extension "module info" file, if necessary (note: this predates the compiler "modules" by a decade and has nothing to do with them).
        //
        // FIXME: Find a way to factor this along product type lines.
        guard scope.evaluate(BuiltinMacros.GENERATE_KERNEL_MODULE_INFO_FILE) && scope.evaluate(BuiltinMacros.MODULE_NAME) != "" && scope.evaluate(BuiltinMacros.MODULE_START) != "" && scope.evaluate(BuiltinMacros.MODULE_STOP) != "" else {
            return nil
        }

        let (path, contents) = generateKernelExtensionModuleInfoFile(scope)
        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: path), delegate, contents: contents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }
        return tasks.first
    }

    /// Generate the version info file.
    /// Presently only Apple Generic Versioning is supported.
    /// - returns: The path where the file will be generated.
    private func generateVersionInfoFile(_ scope: MacroEvaluationScope) async -> (any PlannedTask)? {

        let versioningSystem = scope.evaluate(BuiltinMacros.VERSIONING_SYSTEM)
        guard ["apple-generic", "apple-generic-hidden"].contains(versioningSystem) else { return nil }

        // Compute the path of the generated file.
        let versioningFilePath = scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(scope.evaluate(BuiltinMacros.VERSION_INFO_FILE))

        // Compute the contents of the generated file.
        let productNameAsIdentifier = scope.evaluate(BuiltinMacros.PRODUCT_NAME).asLegalCIdentifier
        let versionNumberComponents = scope.evaluate(BuiltinMacros.CURRENT_PROJECT_VERSION).split(separator: ".").map(String.init)

        var versionNumberString = ""
        if versionNumberComponents.count > 0 {
            versionNumberString.append(versionNumberComponents[0])
        }
        if versionNumberString.isEmpty {
            versionNumberString.append(Character("0"))
        }
        versionNumberString.append(Character("."))
        if versionNumberComponents.count >= 2 {
            // Append the integer value of the second component of the version number -- note that we ignore any components after that, per <rdar://problem/3107291>.
            // Surprisingly, if the value is not a number, then we don't default it to a number.
            if let number = Int(versionNumberComponents[1]) {
                versionNumberString.append(String(number))
            }
        }

        let versioningFilePathExpr = context.settings.userNamespace.parseLiteralString(versioningFilePath.str)
        let lookupClosure: ((MacroDeclaration) -> MacroExpression?) = { return $0 == BuiltinMacros.VERSIONING_STUB ? versioningFilePathExpr : nil }
        var versionInfoExportDecl = scope.evaluate(BuiltinMacros.VERSION_INFO_EXPORT_DECL, lookup: lookupClosure)
        if versioningSystem == "apple-generic-hidden" {
            versionInfoExportDecl = "__attribute__ ((__visibility__(\"hidden\"))) ".appending(versionInfoExportDecl)
        }
        let versionInfoPrefix = scope.evaluate(BuiltinMacros.VERSION_INFO_PREFIX, lookup: lookupClosure)
        let versionInfoSuffix = scope.evaluate(BuiltinMacros.VERSION_INFO_SUFFIX, lookup: lookupClosure)
        let versionInfoString = scope.evaluate(BuiltinMacros.VERSION_INFO_STRING, lookup: lookupClosure)

        var contents = ""
        if !versionInfoExportDecl.split(separator: " ").contains("static") {
            contents.append("\(versionInfoExportDecl) extern const unsigned char \(versionInfoPrefix)\(productNameAsIdentifier)VersionString\(versionInfoSuffix)[];\n")
            contents.append("\(versionInfoExportDecl) extern const double \(versionInfoPrefix)\(productNameAsIdentifier)VersionNumber\(versionInfoSuffix);\n")
            contents.append("\n")
        }
        contents.append("\(versionInfoExportDecl) const unsigned char \(versionInfoPrefix)\(productNameAsIdentifier)VersionString\(versionInfoSuffix)[] __attribute__ ((used)) = \(versionInfoString) \"\\n\";\n")
        contents.append("\(versionInfoExportDecl) const double \(versionInfoPrefix)\(productNameAsIdentifier)VersionNumber\(versionInfoSuffix) __attribute__ ((used)) = (double)\(versionNumberString);\n")

        // Add its contents via our task planning delegate.
        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: versioningFilePath), delegate, contents: ByteString(encodingAsUTF8: contents), permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }
        return tasks.first!
    }

    private func generateKernelExtensionModuleInfoFile(_ scope: MacroEvaluationScope) -> (Path, ByteString) {
        let module = (name:    scope.evaluate(BuiltinMacros.MODULE_NAME),
                      version: scope.evaluate(BuiltinMacros.MODULE_VERSION),
                      start:   scope.evaluate(BuiltinMacros.MODULE_START),
                      stop:    scope.evaluate(BuiltinMacros.MODULE_STOP))

        let path = scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(scope.evaluate(BuiltinMacros.PRODUCT_NAME) + "_info.c")

        var content = ""
        content.append("#include <mach/mach_types.h>\n")
        content.append(" \n")
        content.append("extern kern_return_t _start(kmod_info_t *ki, void *data);\n")
        content.append("extern kern_return_t _stop(kmod_info_t *ki, void *data);\n")

        if module.start != "0" {
            content.append("__private_extern__ kern_return_t \(module.start)(kmod_info_t *ki, void *data);\n")
        }

        if module.stop != "0" {
            content.append("__private_extern__ kern_return_t \(module.stop)(kmod_info_t *ki, void *data);\n")
        }

        content.append(" \n")
        content.append("__attribute__((visibility(\"default\"))) KMOD_EXPLICIT_DECL(\(module.name), \"\(module.version)\", _start, _stop)\n")
        content.append("__private_extern__ kmod_start_func_t *_realmain = \(module.start);\n")
        content.append("__private_extern__ kmod_stop_func_t *_antimain = \(module.stop);\n")
        content.append("__private_extern__ int _kext_apple_cc = __APPLE_CC__ ;\n")

        let contentBytes = ByteString(encodingAsUTF8: content)

        return (path, contentBytes)
    }

    /// In the case when `TEST_HOST` and `BUNDLE_LOADER` are set, and the
    /// `ENABLE_DEBUG_DYLIB` is set on the main target, we need to add the previews
    /// dylib to the list of libraries to link for the test target.
    ///
    /// `TEST_HOST` and `BUNDLE_LOADER` influence the `hostTargetForTargets` mapping.
    /// So if this target is present in there, we have a host we need to check.
    ///
    /// If the host has `EXECUTABLE_DEBUG_DYLIB_PATH`, then it had the preview dylib
    /// enabled and we should return that as a library to link!
    private func previewsDylibForTestHost() -> [LinkerSpec.LibrarySpecifier] {
        guard let target = self.context.configuredTarget,
              let testHost = self.context.globalProductPlan.hostTargetForTargets[target] else
        {
            return []
        }

        // Only consider linking the debug dylib if it is present in the test host.
        let hostSettings = self.context.globalProductPlan.getTargetSettings(testHost)
        guard let targetBuildDir = hostSettings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).nilIfEmpty,
              let previewsDylibPath = hostSettings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH).nilIfEmpty else
        {
            return []
        }

        // Only link the debug dylib if the bundle loader is present.
        let targetSettings = self.context.globalProductPlan.getTargetSettings(target)
        guard targetSettings.globalScope.evaluate(BuiltinMacros.BUNDLE_LOADER).nilIfEmpty != nil else {
            return []
        }

        let fullPath = targetBuildDir.join(Path(previewsDylibPath))

        return [.init(
            kind: .dynamic,
            path: fullPath,
            mode: .normal,
            useSearchPaths: false,
            swiftModulePaths: [:],
            swiftModuleAdditionalLinkerArgResponseFilePaths: [:]
        )]
    }

}

private func isAssetCatalog(scope: MacroEvaluationScope, buildFile: BuildFile, context: TaskProducerContext, includeGenerated: Bool) -> Bool {
    guard let (_, absolutePath, fileType) = try? context.resolveBuildFileReference(buildFile) else { return false }
    return isAssetCatalog(scope: scope, fileType: fileType, absolutePath: absolutePath, includeGenerated: includeGenerated)
}

package func isAssetCatalog(scope: MacroEvaluationScope, fileType: FileTypeSpec, absolutePath: Path, includeGenerated: Bool) -> Bool {
    let nativeGeneratedCatalogPath = { scope.evaluate(BuiltinMacros.APP_PLAYGROUND_GENERATED_ASSET_CATALOG_FILE) }
    let legacyGeneratedCatalogPath = { scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join("GeneratedAssetCatalog.xcassets") }

    return fileType.conformsTo(identifier: "folder.abstractassetcatalog")
        && (includeGenerated || (absolutePath != nativeGeneratedCatalogPath() && absolutePath != legacyGeneratedCatalogPath()))
}

// FIXME: There is similar code in `ProductPlan` and `SwiftStandardLibrariesTaskProducer`, this should eventually live in a central place.
private extension Target {
    /// Check whether at least one source code file is written in Swift.
    func usesSwift(context: TaskProducerContext, settings: Settings) -> Bool {
        return (self as? StandardTarget)?.sourcesBuildPhase?.buildFiles.compactMap { try? context.resolveBuildFileReference($0).fileType }.filter { $0.conformsTo(context.getSpec("sourcecode.swift") as! FileTypeSpec) }.count ?? 0 > 0
    }

    /// Check whether a target has at least one asset catalog.
    func hasAssetCatalog(scope: MacroEvaluationScope, context: TaskProducerContext, includeGenerated: Bool) -> Bool {
        guard let standardTarget = (self as? StandardTarget) else { return false }
        let buildPhases = [standardTarget.resourcesBuildPhase, standardTarget.sourcesBuildPhase].compactMap { $0 }
        let assetCatalogs = buildPhases.flatMap { buildPhase in
            buildPhase.buildFiles.filter { buildFile in
                isAssetCatalog(scope: scope, buildFile: buildFile, context: context, includeGenerated: includeGenerated)
            }
        }
        return !assetCatalogs.isEmpty
    }
}
