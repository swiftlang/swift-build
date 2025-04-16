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

public import SWBCore
import SWBLibc
public import SWBUtil
package import SWBMacro
import SWBProtocol
import Foundation

/// Convenience initializers for FileToBuild.
extension FileToBuild {
    /// Initialize a file to build from a path.
    //
    // FIXME: Figure out how this should look, maybe clients have to produce the fully formed output, instead of inferring information?
    init(context: TaskProducerContext, absolutePath: Path, shouldUsePrefixHeader: Bool = true) {
        self.init(absolutePath: absolutePath, inferringTypeUsing: context, shouldUsePrefixHeader: shouldUsePrefixHeader)
    }
}


extension TaskProducerContext: InputFileGroupingStrategyContext {
    public var fs: any FSProxy {
        return workspaceContext.fs
    }
}


// MARK:


/// Context for grouping files in the build phase, and processing the groups.
package final class BuildFilesProcessingContext: BuildFileFilteringContext {
    package let excludedSourceFileNames: [String]
    package let includedSourceFileNames: [String]
    package let currentPlatformFilter: SWBCore.PlatformFilter?

    // FIXME: It would be better to have simple heuristics for ordering these groups, but this logic was how the old build system worked.
    //
    /// File groups which contain only a single file.  These are processed before those which contain multiple files.
    private(set) var singletonGroups = Queue<FileToBuildGroup>()
    /// File groups which contain multiple files.  These are processed after groups which contain a single file each, so the output of those groups can be potentially collected into these.
    private(set) var collectionGroups = Queue<FileToBuildGroup>()
    /// The file groups indexed by identifier.
    private(set) var groupsByIdent = [String: FileToBuildGroup]()

    /// The identifiers of file groups which have already been processed, so we can act accordingly if we try to add a file to a group which has already been processed.
    private var processedGroupIdents = Set<String>()

    /// Task construction context data for each tool spec resolved in this context.
    private var buildPhaseInfos = [Ref<CommandLineToolSpec>: any BuildPhaseInfoForToolSpec]()
    /// Look up and return the build phase info for a tool spec.
    package func buildPhaseInfo(for toolSpec: CommandLineToolSpec) -> (any BuildPhaseInfoForToolSpec)? {
        return buildPhaseInfos[Ref(toolSpec)]
    }
    /// Look up and return the build phase info for a tool spec given a build rule action.  This is a convenience API so clients don't need to check if the build rule action they have has a tool spec.
    package func buildPhaseInfo(for ruleAction: any BuildRuleAction) -> (any BuildPhaseInfoForToolSpec)? {
        guard let taskAction = ruleAction as? BuildRuleTaskAction else {
            return nil
        }
        return buildPhaseInfo(for: taskAction.toolSpec)
    }

    /// `true` if this build phase wants to use build rules to process build files.
    fileprivate let resolveBuildRules: Bool

    /// The resources directory for the product, if relevant.
    public let resourcesDir: Path
    /// The resources intermediates directory, if appropriate.
    let tmpResourcesDir: Path

    /// True if the build files belongs to the preferred arch among the archs we're processing.
    ///
    /// For e.g., if we're processing a file for arm64 as well as arm7, this will be true for arm64.
    let belongsToPreferredArch: Bool
    let currentArchSpec: ArchitectureSpec?

    package init(_ scope: MacroEvaluationScope, belongsToPreferredArch: Bool = true, currentArchSpec: ArchitectureSpec? = nil, resolveBuildRules: Bool = true, resourcesDir: Path? = nil, tmpResourcesDir: Path? = nil) {
        // Define the predicates for filtering source files.
        //
        // FIXME: Factor this out, and make this machinery efficient.
        self.excludedSourceFileNames = scope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES)
        self.includedSourceFileNames = scope.evaluate(BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES)

        self.resolveBuildRules = resolveBuildRules
        self.resourcesDir = resourcesDir ?? scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH))
        self.tmpResourcesDir = tmpResourcesDir ?? scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR)
        self.belongsToPreferredArch = belongsToPreferredArch
        self.currentArchSpec = currentArchSpec
        self.currentPlatformFilter = PlatformFilter(scope)
    }

    /// Adds the file to build to the appropriate group for the task producer being processed, including resolving a build rule action for that group if appropriate.
    /// - parameter generatedByBuildRuleAction: If the file-to-build was generated by some task, then this should be the build rule action which was used to generate it.
    /// - parameter addIfNoBuildRuleFound: If `true`, then the file-to-build will be added as an ungrouped file if no build rule to process it could be found. If `false`, then the file-to-build is added only if a build rule to process it can be found.
    fileprivate func addFile(_ ftb: FileToBuild, _ taskProducerContext: TaskProducerContext, _ scope: MacroEvaluationScope, _ generatedByBuildRuleAction: (any BuildRuleAction)? = nil, addIfNoBuildRuleFound: Bool = false) {
        // If not honoring build rules, assign each file to an individual group.
        guard resolveBuildRules else {
            addFileGroup(FileToBuildGroup(files: [ftb], action: nil), false)
            return
        }

        // Find the best-matching build rule action for the file-to-build.
        let buildRuleMatchResult = taskProducerContext.buildRuleSet.match(ftb, scope)
        let provisionalRuleAction = buildRuleMatchResult.action

        for diagnostic in buildRuleMatchResult.diagnostics {
            taskProducerContext.emit(diagnostic.behavior, diagnostic.message)
        }

        // If this file is the output of some task, then we perform some checks to see whether we should process it.
        let ruleAction: (any BuildRuleAction)?
        if let generatedByBuildRuleAction {
            var addAsUngrouped = false
            // If our computed rule action is the same as the one which generated this file:
            if generatedByBuildRuleAction === provisionalRuleAction {
                // If we should not add if we didn't find an appropriate build rule, then emit a warning and return.
                guard addIfNoBuildRuleFound else {
                    let currentArch = scope.evaluate(BuiltinMacros.CURRENT_ARCH)
                    taskProducerContext.warning("no rule to process file '\(ftb.absolutePath.str)' of type '\(ftb.fileType.identifier)'" + (currentArch != "undefined_arch" ? " for architecture '\(scope.evaluate(BuiltinMacros.CURRENT_ARCH))'" : ""))
                    return
                }
                // If we should always add, then do so as an ungrouped file.
                addAsUngrouped = true
            }

            // If we didn't find a rule action:
            if provisionalRuleAction == nil {
                // If we should not add if we didn't find an appropriate build rule, then return.
                guard addIfNoBuildRuleFound else { return }
                // If
                addAsUngrouped = true
            }

            // If we get here, then either we validated a rule action, or we decided to add the file-to-build as an ungrouped file.
            ruleAction = addAsUngrouped ? nil : provisionalRuleAction
        }
        else {
            // If it isn't the output of some task, then we always use the matching rule action (or lack thereof) which we found.
            ruleAction = provisionalRuleAction
        }

        // If the rule action has a tool spec which wants to collect information about this build phase, then have it do so.
        if let taskAction = ruleAction as? BuildRuleTaskAction {
            // Get the task construction context for this rule action, creating a new one if necessary.
            var taskConstrContext = buildPhaseInfo(for: taskAction)
            if taskConstrContext == nil {
                let spec = taskAction.toolSpec
                taskConstrContext = spec.newBuildPhaseInfo()
                buildPhaseInfos[Ref(spec)] = taskConstrContext
            }

            // If we have a context, then let it collect the information it wants.
            if let taskConstrContext = taskConstrContext {
                taskConstrContext.addToContext(ftb)
            }
        }

        // Get a hold of the effective file path from the file-to-build.
        let path = ftb.absolutePath

        // Ask the rule action to determine the file group identifier, falling back on just the path if there isn't one.
        let groupIdent: String
        let isCollectionGroup: Bool

        if let identFromRuleAction = ruleAction?.inputFileGroupingStrategies.lazy.compactMap({ $0.determineGroupIdentifier(groupable: ftb) }).first {
            groupIdent = identFromRuleAction
            isCollectionGroup = true
        }
        else {
            groupIdent = path.str
            isCollectionGroup = false
        }

        // If we've already processed a group with this identifier, then emit an error to the user as this is likely a project configuration error. For example, if a project is generating code (e.g. from a build rule) and multiple versions of the same file are being generated, and thus being processed, this is potentially very bad, especially if those files don't contain the same output!
        guard !processedGroupIdents.contains(groupIdent) else {
            return taskProducerContext.error("the file group with identifier '\(groupIdent)' has already been processed.")
        }

        // Find or create the group for the identifier we got back.
        let group = groupsByIdent[groupIdent] ?? {
            // We didn’t already have a group for this identifier, so create one now.
            let group = FileToBuildGroup(groupIdent, action: ruleAction)
            addFileGroup(group, isCollectionGroup)
            return group
        }()

        // Append the file to the group.
        group.files.append(ftb)
    }

    private func addFileGroup(_ group: FileToBuildGroup, _ isCollectionGroup: Bool) {
        // Add it to the appropriate list.
        if isCollectionGroup {
            collectionGroups.append(group)
        }
        else {
            singletonGroups.append(group)
        }
        // We skip adding the group to the index if instructed - typically because the build phase isn't resolving build rules.
        if let ident = group.identifier {
            groupsByIdent[ident] = group
        }
    }

    /// Allow `collectionGroups` to subsume `singletonGroups`. The initial pass in groupAndAddTasksForFiles looks at one file at a time to assign rules and groups. Certain grouping strategies need to inspect multiple files to group them (e.g. sticker packs need to group an asset catalog and loose strings files matching the sticker pack - without grouping every other strings file as well). This function allows each collectionGroup to inspect
    fileprivate func mergeGroups(_ context: TaskProducerContext) {
        // This assumes that groupAdditionalFiles() rarely chooses to group anything.

        var allGroupedSingletonGroups = Set<FileToBuildGroup>()
        for collectionGroup in collectionGroups {
            if let rule = collectionGroup.assignedBuildRuleAction {
                for grouper in rule.inputFileGroupingStrategies {
                    let groupedSingletonGroups = grouper.groupAdditionalFiles(to: collectionGroup, from: self.singletonGroups, context: context)

                    for group in groupedSingletonGroups {
                        collectionGroup.files.append(contentsOf: group.files)

                        if allGroupedSingletonGroups.contains(group) {
                            context.error("Multiple rules merged: \(group.files[0].absolutePath)")
                        }
                    }

                    allGroupedSingletonGroups.formUnion(groupedSingletonGroups)
                }
            }
        }

        if !allGroupedSingletonGroups.isEmpty {
            self.singletonGroups = Queue(self.singletonGroups.filter { !allGroupedSingletonGroups.contains($0) })
        }
    }

    // Returns the next file group to process, or nil if all groups have been processed.
    fileprivate func nextFileGroup() -> FileToBuildGroup? {
        if let group = singletonGroups.popFirst() ?? collectionGroups.popFirst() {
            // Remember that this group has now been processed, if it has an identifier.
            if let ident = group.identifier {
                processedGroupIdents.insert(ident)
            }
            return group
        }
        return nil
    }
}

final class BuildPhaseFileWarningContext {
    static let buildPhaseFileWarningsData: [(setting: PathMacroDeclaration, kind: String)] = [
        (BuiltinMacros.CODE_SIGN_ENTITLEMENTS, "entitlements"),
        (BuiltinMacros.INFOPLIST_FILE, "Info.plist"),
        (BuiltinMacros.EXPORTED_SYMBOLS_FILE, "exported symbols"),
        (BuiltinMacros.UNEXPORTED_SYMBOLS_FILE, "unexported symbols"),
        (BuiltinMacros.ORDER_FILE, "order"),
    ]

    let context: TaskProducerContext

    private let paths: [(Path, String)]

    init(_ context: TaskProducerContext, _ scope: MacroEvaluationScope) {
        self.context = context
        let basePath = scope.evaluate(BuiltinMacros.PROJECT_DIR)
        self.paths = Self.buildPhaseFileWarningsData.map { (setting, kind) in
            (basePath.join(scope.evaluate(setting)), kind)
        }
    }

    // Warn the user if this build phase contains a file reference with a path which is being handled by a build setting.
    func emitBuildPhaseFileWarningDiagnostics(buildPhase: SWBCore.BuildPhase, buildFile: SWBCore.BuildFile?, path: Path) {
        for (settingFilePath, kind) in paths where path == settingFilePath {
            context.emitBuildPhaseFileWarning(buildPhase: buildPhase, buildFile: buildFile, message: "The \(buildPhase.name) build phase contains this target's \(kind) file '\(settingFilePath.str)'.")
        }
    }
}

extension TaskProducerContext {
    func emitBuildPhaseFileWarning(buildPhase: SWBCore.BuildPhase, buildFile: SWBCore.BuildFile?, message: String) {
        let diagnosticLocation: Diagnostic.Location
        if let buildFile, let target = configuredTarget?.target {
            diagnosticLocation = .buildFile(buildFileGUID: buildFile.guid, buildPhaseGUID: buildPhase.guid, targetGUID: target.guid)
        } else {
            diagnosticLocation = .unknown
        }

        warning(message, location: diagnosticLocation)
    }
}

// MARK:


/// Protocol for build phase tasks producers which are based around processing file references.
protocol FilesBasedBuildPhaseTaskProducer: AnyObject, TaskProducer {
    /// The type of build phase managed by this producer.
    associatedtype ManagedBuildPhase: SWBCore.BuildPhaseWithBuildFiles

    /// The build phase managed by the producer.
    var buildPhase: SWBCore.BuildPhaseWithBuildFiles { get }

    /// The managed build phase instance (equivalent to the buildPhase but with the appropriate type).
    var managedBuildPhase: ManagedBuildPhase { get }

    /// Add the appropriate tasks for the given individual, ungrouped, file.
    ///
    /// This method is only called when no rule can be found to process a file.  None of the produced tasks will be subject to further processing.
    func addTasksForUngroupedFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async
}

extension FilesBasedBuildPhaseTaskProducer {
    var managedBuildPhase: ManagedBuildPhase {
        return buildPhase as! ManagedBuildPhase
    }
}

/// Base class for build phase tasks producers which are based around processing file references.
class FilesBasedBuildPhaseTaskProducerBase: PhasedTaskProducer {
    /// Captures the state used when expanding groups, to prevent recursion.
    struct GroupContext {
        /// The set of rules which have been used during this evaluation. Each individual rule is used at most once.
        var usedRules: OrderedSet<Ref<any BuildRuleAction>>

        init() {
            usedRules = OrderedSet()
        }
    }

    /// The build phase managed by this producer.
    unowned let buildPhase: SWBCore.BuildPhaseWithBuildFiles

    /// The map of compilers used during file processing, and the file types they processed.
    var usedTools = [CommandLineToolSpec: Set<FileTypeSpec>]()

    /// For each FileToBuildGroup processed by an architecture-neutral tool spec, we remember the output paths produced by the tool to process them for other architectures & variants.
    var outputsProducedByArchNeutralToolSpec = [FileToBuildGroup: [FileToBuild]]()

    /// Create a phase-based task producer for the given phase.
    ///
    /// - phaseStartNode: A virtual node which should be used as an input for all tasks produced by the phase.
    /// - phaseEndNode: A virtual node which should be have as inputs all tasks produced by the phase.
    init(_ context: TargetTaskProducerContext, buildPhase: SWBCore.BuildPhaseWithBuildFiles, phaseStartNodes: [any PlannedNode], phaseEndNode: any PlannedNode, phaseEndTask: any PlannedTask) {
        self.buildPhase = buildPhase
        super.init(context, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
    }

    /// Allows subclasses to contribute additional build files.
    func additionalBuildFiles(_ scope: MacroEvaluationScope) -> [SWBCore.BuildFile] {
        return []
    }

    /// Allows subclasses to contribute additional files to build.
    func additionalFilesToBuild(_ scope: MacroEvaluationScope) -> [FileToBuild] {
        return []
    }

    /// Group all the files in this phase, then add tasks for each group.
    func groupAndAddTasksForFiles<T: FilesBasedBuildPhaseTaskProducer>(_ producer: T, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, filterToAPIRules: Bool, filterToHeaderRules: Bool, _ tasks: inout [any PlannedTask], extraResolvedBuildFiles: [(Path, FileTypeSpec, Bool)] = []) async {

        // Create the list of files to build, then group and process them.
        //
        // We do this in two passes, once to build up the file paths and the set of non-unique input basenames, and the last time to actually create and process the files.
        //
        // FIXME: We should cache this, for phases which iterate over the build files multiple times.
        var seenBases = Set<String>()
        var nonUniqueBases = Set<String>()
        typealias ResolvedBuildFile = (buildFile: SWBCore.BuildFile?, buildableReference: SWBCore.Reference?, path: Path, basename: String, fileTypeSpec: FileTypeSpec, shouldUsePrefixHeader: Bool)
        var resolvedBuildFiles: [ResolvedBuildFile] = []

        let buildPhaseFileWarningContext = BuildPhaseFileWarningContext(context, scope)

        // Helper function for adding a resolved item.  The build file can be nil here if the client wants to add a file divorced from any build file (e.g., because the build file contains context which shouldn't be applied to this file).
        func addResolvedItem(buildFile: SWBCore.BuildFile?, path: Path, reference: SWBCore.Reference?, fileType: FileTypeSpec, shouldUsePrefixHeader: Bool = true) {
            let base = path.basenameWithoutSuffix.lowercased()
            if seenBases.contains(base) {
                nonUniqueBases.insert(base)
            } else {
                seenBases.insert(base)
            }
            resolvedBuildFiles.append((buildFile, reference, path, base, fileType, shouldUsePrefixHeader))

            buildPhaseFileWarningContext.emitBuildPhaseFileWarningDiagnostics(buildPhase: buildPhase, buildFile: buildFile, path: path)

            do {
                // If we're copying a WatchKit settings bundle into an iOS app deploying to iOS 13 or later, issue a deprecation warning.
                if context.platform?.familyName == "iOS" && ((try? Version(scope.evaluate(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET))) ?? Version()) >= Version(13) && path.basename == "Settings-Watch.bundle" && fileType.isWrapper {
                    context.emitBuildPhaseFileWarning(buildPhase: buildPhase, buildFile: buildFile, message: "WatchKit Settings bundles in iOS apps are deprecated.")
                }
            }
        }

        for (path, fileType, shouldUsePrefixHeader) in extraResolvedBuildFiles {
            addResolvedItem(buildFile: nil, path: path, reference: nil, fileType: fileType, shouldUsePrefixHeader: shouldUsePrefixHeader)
        }

        for buildFile in buildPhase.buildFiles + additionalBuildFiles(scope) {
            // Resolve the reference.
            do {
                let (reference, path, fileType) = try context.resolveBuildFileReference(buildFile)

                let sourceFiles = (self.targetContext.configuredTarget?.target as? SWBCore.StandardTarget)?.sourcesBuildPhase?.buildFiles.count ?? 0
                if scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS) && (sourceFiles > 0) {
                    // Ignore xcassets in Resource Copy Phase since they're now added to the Compile Sources phase for codegen.
                    if producer.buildPhase is SWBCore.ResourcesBuildPhase && fileType.conformsTo(identifier: "folder.abstractassetcatalog") {
                        continue
                    }
                }

                // Compilation of .rkassets depends on additional auxiliary inputs that are not
                // accessible from a spec class. Instead, they are handled entirely by their own
                // task producer (RealityAssetsTaskProducer), so skip processing them as part of
                // the normal build phase task producers.
                guard !fileType.conformsTo(identifier: "folder.rkassets") else { continue }

                // Utility function to unwrap a variant group and add each child as a separate item.
                func unwrapResolveAndAdd(variantGroup: SWBCore.VariantGroup, for buildFile: SWBCore.BuildFile) throws {
                    for childReference in variantGroup.children {
                        let (reference, path, fileType) = try context.resolveBuildFileReference(buildFile, reference: childReference)
                        addResolvedItem(buildFile: buildFile, path: path, reference: reference, fileType: fileType)
                    }
                }

                // For localization projects, we want to produce a root that only contains localized .strings files associated with xibs or storyboards for the language(s) defined in $(INSTALLLOC_LANGUAGE).
                let installlocSpecificLanguages = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") && !scope.evaluate(BuiltinMacros.INSTALLLOC_LANGUAGE).isEmpty

                // If this is a variant group and the file type doesn't expect to be grouped, expand it.
                //
                // FIXME: This is a very invasive way of handling the problem that variant groups can be built both as a single item (XIB + resources) or as an exploded list. We should push this higher into the model, or lower down into the actual rule. Or we might be able to just always unwrap if ibtool doesn't need combined compilation anymore.
                if let asVariantGroup = reference as? SWBCore.VariantGroup {
                    // If we're processing a single language for installLoc, then unwrap the variant group into a separate item for each of its child references.
                    if installlocSpecificLanguages {
                        try unwrapResolveAndAdd(variantGroup: asVariantGroup, for: buildFile)
                    }
                    else {
                        // If the first item in the variant group is an IB document with Base localization, then we need to handle it specially, since it may contain a mix of IB documents and strings files.
                        // An exception to this is when String Catalogs are in play.
                        if let baseReference = asVariantGroup.children.first as? SWBCore.FileReference, SpecRegistry.interfaceBuilderDocumentFileTypeIdentifiers.contains(baseReference.fileTypeIdentifier), baseReference.regionVariantName == "Base" {
                            var ibDocRefs = [SWBCore.FileReference]() // These are specifically override nibs, not including Base.
                            var hasStringCatalog = false

                            // Iterate over the children of the group - skipping the first reference - to put them into buckets.
                            for (idx, ref) in asVariantGroup.children.enumerated() {
                                guard idx > 0 else {
                                    continue
                                }
                                // FIXME: It's only valid to have a single item in the variant group for any given localization, and we should emit an issue (an error?) about that.  (It seems hard to get into that situation other than an SCM merge conflict.)  Also maybe emit an issue if there's an item in the group with no localization.
                                if let fileRef = ref as? SWBCore.FileReference {
                                    if SpecRegistry.interfaceBuilderDocumentFileTypeIdentifiers.contains(fileRef.fileTypeIdentifier) {
                                        // If it's an IB document, then remember it.
                                        ibDocRefs.append(fileRef)
                                    }
                                    else if fileRef.fileTypeIdentifier == "text.plist.strings" {
                                        // If it's a .strings file, then we'll just include it in the variant group.
                                    }
                                    else if fileRef.fileTypeIdentifier == "text.json.xcstrings" {
                                        // If it has a String Catalog, remember that.
                                        hasStringCatalog = true
                                    }
                                    else {
                                        // FIXME: If there's something in the variant group that isn't an IB document or a .strings file, then what should we do about it?
                                    }
                                }
                                else {
                                    // FIXME: If this isn't a file reference, what should we do about it?
                                }
                            }

                            if hasStringCatalog && ibDocRefs.isEmpty {
                                // Need to unwrap if it's a String Catalog, and override nibs wouldn't be supported in that case.
                                // This is so ibtool can compile the XIB and xcstringstool can compile the String Catalog.
                                // NOTE: (mseaman) As far as I can tell, the reasons why ibtool wants to process .strings files alongside the IB file seem to be for historical reasons.
                                // For example, in iOS 8 and earlier, .strings files sometimes needed to be written to idiom paths, e.g. XIBName~ipad.strings.
                                // But in modern times that sort of thing doesn't seem to happen anymore.
                                // If we can verify that ibtool definitely doesn't need to do this anymore for any still-supported platforms or edge cases,
                                // we could unwrap the variant group always, not just when String Catalogs are in use.
                                // That would greatly cleanup this entire code tree dealing with Variant Groups.
                                try unwrapResolveAndAdd(variantGroup: asVariantGroup, for: buildFile)

                                // If there also happened to be .strings files as well, XCStringsCompiler should notice that (via its grouping rule) and yell.

                            } else if hasStringCatalog && !ibDocRefs.isEmpty {
                                // There is a String Catalog in the variant group, but there are override nibs as well.
                                // That's not a supported configuration.
                                context.error("An IB file cannot provide its localizations via both a String Catalog and other overriding IB files.", location: .path(path), component: .targetIntegrity)
                            } else {
                                // Add the variant group as a single item, so the Base localized IB document will be processed with the .strings files.
                                // FIXME: This is really nasty - we're relying on the fact that any localized .xibs in here will be skipped.  But there's no good way to create a new VariantGroup.  It would be nice if we could just extract this out into a FileToBuild and not have to pass the reference around.
                                addResolvedItem(buildFile: buildFile, path: path, reference: reference, fileType: fileType)

                                // Add all the localized IB document refs as single items.  Adding them here ensures they are consistently ordered after the Base localization (which is useful for checking the order of arguments to the storyboard linker).
                                for ibDocRef in ibDocRefs {
                                    let (reference, path, fileType) = try context.resolveBuildFileReference(buildFile, reference: ibDocRef)
                                    // We don't pass the build file here since we want to detach the FileToBuild from other content in the variant group.
                                    addResolvedItem(buildFile: nil, path: path, reference: reference, fileType: fileType)
                                }
                            }
                        }
                        else {
                            // If the first reference is not an IB document, or does not have base localization, then we unwrap the variant group into a separate item for each of its child references.
                            try unwrapResolveAndAdd(variantGroup: asVariantGroup, for: buildFile)
                        }
                    }
                }
                else {
                    func isXCFrameworkWrapper(_ path: Path, fileType: FileTypeSpec) -> Bool {
                        guard let xcframeworkFileSpec = context.lookupFileType(identifier: "wrapper.xcframework") else {
                            return false
                        }

                        return fileType.conformsTo(xcframeworkFileSpec)
                    }

                    // Utility to map XCFramework.Library.LibraryType -> FileTypeSpec.
                    func fileTypeSpec(for library: XCFramework.Library) -> FileTypeSpec? {
                        switch library.libraryType {
                        case .framework: return context.workspaceContext.core.specRegistry.getSpec("wrapper.framework") as? FileTypeSpec
                        case .staticLibrary: return context.workspaceContext.core.specRegistry.getSpec("archive.ar") as? FileTypeSpec
                        case .dynamicLibrary: return context.workspaceContext.core.specRegistry.getSpec("compiled.mach-o.dylib") as? FileTypeSpec
                        case .unknown(fileExtension: _): return nil
                        }
                    }

                    if isXCFrameworkWrapper(path, fileType: fileType) {
                        // Note that we are looking up the version of the library that was copied into the build output from the xcframework processing task.

                        // Let the XCFrameworkTaskProducer log an errors here as this should only occur when an XCFramework is referenced on disk but is not actually present.
                        if let xcframework = try? context.globalProductPlan.planRequest.buildRequestContext.getCachedXCFramework(at: path) {
                            // Find a library in the XCFramework which is compatible with the current platform.
                            // Note that we don't validate supported architectures here because this code path only executes for non-frameworks build phases (like copy files), and it might actually be desirable in this case for an embedded framework to have a subset of the architectures of the current target.
                            if let library = xcframework.findLibrary(sdk: context.sdk, sdkVariant: context.sdkVariant) {
                                // FIXME: This should really be pulling the framework out of the debug location. However, due to the complexities of dealing with multiple actions that can produce these across various targets in the workspace, and attempting to order those correctly, this pulls the data from the xcframework itself. This is will only be a problem when/if we move to having incomplete xcframeworks that we can build up.
                                // rdar://59753495 - Copy step for XCFrameworks should pull from the target directory, not the actual framework
                                let libraryTargetPath = path.join(library.libraryIdentifier).join(library.libraryPath)

                                if let fileType = fileTypeSpec(for: library) {
                                    addResolvedItem(buildFile: buildFile, path: libraryTargetPath, reference: reference, fileType: fileType)
                                }
                                else {
                                    // This error should actually never be reached as we should have provided this error earlier.
                                    context.error("Unsupported library type: '\(libraryTargetPath.fileSuffix)'")
                                }
                            }
                        }
                    }
                    else {
                        // The reference is not a variant group, so add it as a single item.
                        addResolvedItem(buildFile: buildFile, path: path, reference: reference, fileType: fileType)
                    }
                }
            } catch let validationError as XCFrameworkValidationError {
                switch validationError {
                case .missingXCFramework(_):
                    break  // this is safe to ignore as it's already been reported by the `XCFrameworkTaskProducer`.
                default:
                    context.error(validationError.localizedDescription)
                }
            } catch WorkspaceErrors.missingPackageProduct(let packageName) {
                context.missingPackageProduct(packageName, buildFile, buildPhase)
            } catch WorkspaceErrors.namedReferencesCannotBeResolved(let name) {
                context.missingNamedReference(name, buildFile, buildPhase)
            } catch {
                context.error("Unable to resolve build file: \(buildFile) (\(error))")
            }
        }

        var compileToSwiftFileTypes : [String] = []
        for groupingStragegyExtensions in await context.workspaceContext.core.pluginManager.extensions(of: InputFileGroupingStrategyExtensionPoint.self) {
            compileToSwiftFileTypes.append(contentsOf: groupingStragegyExtensions.fileTypesCompilingToSwiftSources())
        }

        // Reorder resolvedBuildFiles so that file types which compile to Swift appear first in the list and so are processed first.
        // This is needed because generated sources aren't added to the the main source code list.
        // rdar://102834701 (File grouping for 'collection groups' is sensitive to ordering of build phase members)
        var compileToSwiftFiles = [ResolvedBuildFile]()
        var otherBuildFiles = [ResolvedBuildFile]()
        for resolvedBuildFile in resolvedBuildFiles {
            if compileToSwiftFileTypes.contains (where: { identifier in resolvedBuildFile.fileTypeSpec.conformsTo(identifier: identifier)}) {
                compileToSwiftFiles.append(resolvedBuildFile)
            } else {
                otherBuildFiles.append(resolvedBuildFile)
            }
            resolvedBuildFiles = compileToSwiftFiles + otherBuildFiles
        }

        // Allow subclasses to provide additional content
        // We have to process this _before_ the resolvedBuildFiles to workaround an issue where generated sources aren't added to main source code group.
        // rdar://102834701 (File grouping for 'collection groups' is sensitive to ordering of build phase members)
        for ftb in additionalFilesToBuild(scope) {
            buildFilesContext.addFile(ftb, context, scope)
        }

        var seenPaths = Set<Path>()
        for (buildFile, _, path, base, fileType, shouldUsePrefixHeader) in resolvedBuildFiles {
            guard !seenPaths.contains(path) else {
                // If this path has already been seen, then we emit a warning and don't include it again.
                context.warning("Skipping duplicate build file in \(buildPhase.name) build phase: \(path.str)")
                continue
            }
            seenPaths.insert(path)

            // Compute the uniquingSuffix, if necessary.
            //
            // FIXME: We only need to do this for some phases, we could avoid doing this universally. Investigate if there is any performance win in that.
            let uniquingSuffix: String
            if nonUniqueBases.contains(base) {
                uniquingSuffix = "-" + BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: path)
            } else {
                uniquingSuffix = ""
            }

            // Construct the file-to-build with the full reference information.
            let fileToBuild = FileToBuild(absolutePath: path, fileType: fileType, buildFile: buildFile, uniquingSuffix: uniquingSuffix, shouldUsePrefixHeader: shouldUsePrefixHeader)

            // Ignore filtered files.
            if case let .excluded(exclusionReason) = buildFilesContext.filterState(of: fileToBuild.absolutePath, filters: buildFile?.platformFilters ?? []) {
                let location: Diagnostic.Location?
                if let buildFile = buildFile, let configuredTarget = context.configuredTarget {
                    location = .buildFile(buildFileGUID: buildFile.guid, buildPhaseGUID: buildPhase.guid, targetGUID: configuredTarget.target.guid)
                } else {
                    location = nil
                }
                context.emitFileExclusionDiagnostic(exclusionReason, buildFilesContext, fileToBuild.absolutePath, buildFile?.platformFilters ?? [], location)
                continue
            }

            // Have the build files context add the file to the appropriate file group.
            buildFilesContext.addFile(fileToBuild, context, scope)
        }

        // Allow collection groups to consume any ungrouped files
        buildFilesContext.mergeGroups(context)

        // Generate and add the tasks for all of the groups.
        var generatedRequiresAPIError = false
        while let group = buildFilesContext.nextFileGroup() {
            // When in InstallAPI mode, only process this group if supported.
            if filterToAPIRules {
                // InstallAPI is a superset of InstallHeaders, so we check if the build rule action supports either
                assert(filterToHeaderRules)
                if !(group.assignedBuildRuleAction?.supportsInstallAPI ?? false) && !(group.assignedBuildRuleAction?.supportsInstallHeaders ?? false) {
                    continue
                }

                // If this target itself hasn't adopted Install API, then it is an error (since presumably it is required).
                if !scope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API) {
                    // If TAPI support errors are disabled, ignore the error.
                    if !scope.evaluate(BuiltinMacros.ALLOW_UNSUPPORTED_TEXT_BASED_API) {
                        // Don't enforce `SUPPORTS_TEXT_BASED_API` setting if the group only contains
                        // asset catalogs since generated symbols code doesn't export API. Related: rdar://108210630, rdar://108379090.

                        // xcassets get grouped together.
                        let isAllCatalogs = group.files.allSatisfy({ $0.fileType.conformsTo(identifier: "folder.abstractassetcatalog") })
                        let productType: ProductTypeSpec? = try? context.getSpec(scope.evaluate(BuiltinMacros.PRODUCT_TYPE))
                        if let productType = productType, productType.supportsInstallAPI && !generatedRequiresAPIError && !isAllCatalogs {
                            producer.context.error("\(productType.name) requested to generate API, but has not adopted SUPPORTS_TEXT_BASED_API", location: .buildSetting(BuiltinMacros.SUPPORTS_TEXT_BASED_API))
                            generatedRequiresAPIError = true
                        }
                    }
                    continue
                }
            } else if filterToHeaderRules && !(group.assignedBuildRuleAction?.supportsInstallHeaders ?? false) {
                // When in InstallHeaders mode, only process this group if supported.
                continue
            }

            await addTasksForGroup(producer, group, buildFilesContext, scope, &tasks)
        }
    }

    /// `generateTasks()` is the main entry point to task producers.
    func generateTasks<T: FilesBasedBuildPhaseTaskProducer>(_ producer: T, _ scope: MacroEvaluationScope, _ buildFilesContext: BuildFilesProcessingContext) async -> [any PlannedTask] {
        precondition(producer === self)
        precondition(buildPhase is T.ManagedBuildPhase)

        // Group all the files, then add tasks for each of the groups.
        //
        // FIXME: Do this in parallel? Must document contract to clients if so.
        var tasks: [any PlannedTask] = []
        await groupAndAddTasksForFiles(producer, buildFilesContext, scope, filterToAPIRules: false, filterToHeaderRules: false, &tasks)
        return tasks
    }

    /// Add the appropriate tasks for the given group.
    /// - parameter buildFilesContext: This must be non-nil for outputs of tasks generated for the group to be themselves processed.
    func addTasksForGroup<T: FilesBasedBuildPhaseTaskProducer>(_ producer: T, _ group: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Construct the group context used to prevent unbounded recursion, and delegate to the main implementation.
        var groupContext = GroupContext()
        await addTasksForGroup(&groupContext, producer, group, buildFilesContext, scope, &tasks)
    }

    /// Add the tasks for the given group.
    private func addTasksForGroup<T: FilesBasedBuildPhaseTaskProducer>(_ groupContext: inout GroupContext, _ producer: T, _ group: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // If there is a rule, and it hasn't already been used, delegate to it.
        //
        // FIXME: It would be nice to make this consistent and just have everything go through the rule based path.
        if let rule = group.assignedBuildRuleAction, groupContext.usedRules.append(Ref(rule)).inserted {
            await addTasksForRule(groupContext: &groupContext, producer, rule, group, buildFilesContext, scope, &tasks)

            // Pop the used rule entry and return.
            _ = groupContext.usedRules.removeLast()
            return
        }

        // Otherwise, process each grouped file individually.
        for file in group.files {
            await producer.addTasksForUngroupedFile(file, buildFilesContext, scope, &tasks)
        }
    }

    /// Add the tasks for the given rule.
    private func addTasksForRule<T: FilesBasedBuildPhaseTaskProducer>( groupContext: inout GroupContext, _ producer: T, _ rule: any BuildRuleAction, _ group: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Do the necessary work, ending up with an array of output paths.
        let outputs: [FileToBuild]
        if let priorOutputs = outputsProducedByArchNeutralToolSpec[group] {
            // If we already have the output paths because the input group has previously been processed by an architecture-neutral tool spec (for a different arch or variant), then we re-use those paths.
            outputs = priorOutputs
        }
        else {
            // Otherwise we construct tasks for the input group.
            let result = await appendGeneratedTasks(&tasks) { delegate in
                let scope = !rule.isArchitectureNeutral ? scope : (
                    scope
                        .subscope(binding: BuiltinMacros.variantCondition, to: "normal")
                        .subscope(binding: BuiltinMacros.archCondition, to: "undefined_arch")
                )
                await constructTasksForRule(rule, group, buildFilesContext, scope, delegate)
            }
            outputs = result.outputs

            // If we used an architecture-neutral rule, then we remember the output paths for use by other archs and variants.  Notice that we don't determine the rule to use for these paths here, since it's conceivable that different archs or variants might want to use different rules.
            // Also determine here whether the tool spec used does not want us to process its output files.
            if rule.isArchitectureNeutral {
                outputsProducedByArchNeutralToolSpec[group] = outputs
            }
        }

        // Process all of the output files, if the tool spec which produced them wants us to.
        //
        // FIXME: Eventually, we want a model where these feed cleanly back into the group processing logic.
        let shouldProcessOutputs = !rule.dontProcessOutputs
        if shouldProcessOutputs {
            for ftb in outputs {
                addOutputFile(ftb, group, buildFilesContext, [], scope, rule, addIfNoBuildRuleFound: false)
            }
        }
    }

    /// This method is used by the `installLoc` build action to return the paths to localized content within a bundle.
    /// For example a bundle which is part of the project sources, where only the localized content in the bundle should be copied in the `installLoc` action.
    /// - returns: A list of path strings relative to the absolute path of `ftb`.
    func localizedFilesToBuildForEmbeddedBundle(_ path: Path, _ scope: MacroEvaluationScope) -> [Path] {
        // The installloc action is never used to do incremental builds, so we don't need to add these paths to the list of paths which invalidate the build description if they change, and we prefer not to do so to avoid the performance impact of checking it.
        var localizedContent: [Path] = []

        do {
            try context.workspaceContext.fs.traverse(path) { subPath in
                if let relativePath = subPath.relativeSubpath(from: path),
                   context.workspaceContext.fs.isDirectory(subPath) &&
                   subPath.join(".").isValidLocalizedContent(scope) {
                    localizedContent.append(Path(relativePath))
                }
            }
        } catch {
            context.warning("Unable to find localized content for bundle at '\(path.str)' because the directory contents could not be traversed: '\(error)'")
            return []
        }

        return localizedContent
    }

    /// Returns `true` if the file to build - an output from another tool - should be further processed if a tool can be found to do so.
    /// - parameter ftb: The `FileToBuild` for the output file being considered to be added.
    /// - parameter productDirectories: The file will _not_ be added if it is inside one of these directories.  This is because files which are in directories considered part of the product should not be reprocessed (but we don't just look at the `SYMROOT` or `DSTROOT` because some projects put content there to share across targets).
    func shouldAddOutputFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ productDirectories: [Path], _ scope: MacroEvaluationScope) -> Bool {
        // If we're not resolving build rules, then outputs will not be further processed.
        guard buildFilesContext.resolveBuildRules else { return false }

        // Don't process output files which are already in the resources folder of a wrapped product, or a product directory we were passed.  (If further processing is desired, then the tool should place it somewhere else, such as in the derived files folder.)
        // FIXME: This applies to all task producers because the Metal linker expects it (in the Sources producer).  Consider a more general approach, e.g. any file in the product should not be reprocessed.
        if !scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH).isEmpty {
            guard !buildFilesContext.resourcesDir.isAncestor(of: ftb.absolutePath) else {
                return false
            }
        }

        let buildDir = scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) ? BuiltinMacros.DSTROOT : BuiltinMacros.TARGET_BUILD_DIR
        let intermediatesDir = scope.evaluate(BuiltinMacros.OBJROOT)
        if scope.evaluate(buildDir).isAncestor(of: ftb.absolutePath) && !intermediatesDir.isAncestor(of: ftb.absolutePath) {
            return false
        }

        for path in productDirectories {
            guard !path.isAncestor(of: ftb.absolutePath) else {
                return false
            }
        }

        // Don't process output files which are already in a product headers folder.
        let publicDestDirPath = TargetHeaderInfo.destDirPath(for: HeaderVisibility.public, scope: scope)
            guard !publicDestDirPath.isAncestor(of: ftb.absolutePath) else {
                return false
            }

        let privateDestDirPath = TargetHeaderInfo.destDirPath(for: HeaderVisibility.private, scope: scope)
            guard !privateDestDirPath.isAncestor(of: ftb.absolutePath) else {
                return false
            }

        return true
    }

    /// Determine whether an output file should be added to the list of files to process, and if so, add it.
    /// - parameter ftb: The `FileToBuild` for the output file being considered to be added.
    /// - parameter producedFromGroup: The group from which the `ftb` being considered was produced..
    /// - parameter productDirectories: The file will _not_ be added if it is inside one of these directories.  This is because files which are in directories considered part of the product should not be reprocessed (but we don't just look at the `SYMROOT` or `DSTROOT` because some projects put content there to share across targets).
    /// - parameter generatedByBuildRuleAction: The build rule action which was used to generate this output file.
    /// - parameter addIfNoBuildRuleFound: If true, then `ftb` will always be added to the build files context - possibly as an ungrouped file - even if the context can't find a valid build rule action for it.
    func addOutputFile(_ ftb: FileToBuild, _ producedFromGroup: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ productDirectories: [Path], _ scope: MacroEvaluationScope, _ generatedByBuildRuleAction: any BuildRuleAction, addIfNoBuildRuleFound: Bool) {
        // If the task producer doesn't think this output file should be added, then we don't do so.
        guard shouldAddOutputFile(ftb, buildFilesContext, productDirectories, scope) else { return }

        // Have the build files context group the file appropriately.  It will be processed when it comes around in the build phase's main loop.
        buildFilesContext.addFile(ftb, context, scope, generatedByBuildRuleAction, addIfNoBuildRuleFound: addIfNoBuildRuleFound)
    }

    /// Construct the tasks for the given rule and group.
    ///
    /// This is an extension point provided to allow the ResourcesBuildPhase to provide custom context data.
    func constructTasksForRule(_ rule: any BuildRuleAction, _ group: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async {
        // Create the build context.
        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: group.files, isPreferredArch: buildFilesContext.belongsToPreferredArch, buildPhaseInfo: buildFilesContext.buildPhaseInfo(for: rule))

        await constructTasksForRule(rule, cbc, delegate)
    }

    /// Construct the tasks for the given rule against the supplied context.
    func constructTasksForRule(_ rule: any BuildRuleAction, _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Evaluate the rule.
        if let action = rule as? BuildRuleTaskAction {
            let spec = action.toolSpec.resolveConcreteSpec(cbc)

            // If we're building a module-only architecture, but not using the SwiftCompilerSpec we should do nothing.
            if !(spec is SwiftCompilerSpec) {
                let moduleOnlyArchs = cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS)
                if !moduleOnlyArchs.isEmpty, moduleOnlyArchs.contains(cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)) {
                    return
                }
            }

            if validateSpecForRule(spec, rule, cbc, delegate) {
                // Our command build context should not contain any outputs, since the spec determines the output paths.
                precondition(cbc.outputs.isEmpty, "Unexpected output paths \(cbc.outputs.map { "'\($0.str)'" }) passed to \(type(of: self)).")

                // Create a new command build context adding the spec's outputs, and construct tasks.
                let context = cbc.appendingOutputs(defaultOutputsForSpec(spec, cbc, delegate))
                await spec.constructTasks(context, delegate)

                // Update the used tools map.
                usedTools[spec, default: []].insert(spec.resolvedSourceFileType(file: context.inputs[0], inBuildContext: context, delegate: delegate))
            }
        } else {
            // If we're building a module-only architecture we should do nothing.
            let moduleOnlyArchs = cbc.scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS)
            if !moduleOnlyArchs.isEmpty, moduleOnlyArchs.contains(cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)) {
                return
            }

            let _ = await BuildRuleTaskProducer(context, action: rule as! BuildRuleScriptAction, cbc: cbc, delegate: delegate, buildPhase: buildPhase).generateTasks()
        }
    }

    /// Validates whether the spec is actually valid for this build rule action.
    /// Returning `true` will allow to continue to task construction, returning `false` will prevent it.
    func validateSpecForRule(_ spec: Spec, _ rule: any BuildRuleAction, _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> Bool {
        return true
    }

    func defaultOutputsForSpec(_ spec: CommandLineToolSpec, _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> [Path] {
        return spec.evaluatedOutputs(cbc, delegate)?.map { $0.path } ?? []
    }
}
