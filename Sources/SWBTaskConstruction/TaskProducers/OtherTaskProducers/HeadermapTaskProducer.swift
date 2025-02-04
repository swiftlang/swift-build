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
import SWBUtil
import SWBMacro

final class HeadermapTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .immediate
    }

    func generateTasks() async -> [any PlannedTask]     {
        let scope = context.settings.globalScope

        // Headermaps are generated only when the "build" or when "api" component is present.

        let components = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard components.contains("build") || components.contains("exportLoc") || (components.contains("api")) else {
            return []
        }

        // If headermaps are disabled for this target, do nothing.
        if !scope.evaluate(BuiltinMacros.USE_HEADERMAP) {
            return []
        }

        // Only generate headermaps for standard targets.
        guard case let target as StandardTarget = context.configuredTarget?.target else {
            return []
        }

        // Swift Build does not support "traditional" (single-file) headermaps.  Use of separate headermaps has been the default for new projects for years, and use of the VFS (when clang modules are enabled) requires separate headermaps.
        // If the target is configured to use a traditional headermap, then we emit a warning and use separate headermaps anyway.
        // FIXME: Figure out how to get the equivalent of depGraphContext.buildOperationContext.needsVFS here
        let usesVFS = (true /* depGraphContext.buildOperationContext.needsVFS */ || scope.evaluate(BuiltinMacros.HEADERMAP_USES_VFS)) && scope.evaluate(BuiltinMacros.CLANG_ENABLE_MODULES)
        if scope.evaluate(BuiltinMacros.ALWAYS_SEARCH_USER_PATHS) && !scope.evaluate(BuiltinMacros.ALWAYS_USE_SEPARATE_HEADERMAPS) && !usesVFS {
            context.warning("Traditional headermap style is no longer supported; please migrate to using separate headermaps and set 'ALWAYS_SEARCH_USER_PATHS' to NO.")
        }

        // Generate the headermaps using auxiliary file tasks.
        //
        // FIXME: Evaluate whether or not it is worth deferring some of the work here until build time.

        // We always generate every file that can be used.
        //
        // FIXME: This is somewhat inefficient. We should be able to use the provisional task mechanism to avoid this.
        var tasks = [any PlannedTask]()
        // We do not support the traditional header map, but currently always generate an empty one for backwards compatibility.
        await defineHeadermap(target, scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE), &tasks) { _, _ in (.init(), []) }
        await defineHeadermap(target, scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_PROJECT_FILES), &tasks, construct: constructAllProjectHeadersMap)
        await defineHeadermap(target, scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_OWN_TARGET_HEADERS), &tasks, construct: constructOwnTargetHeadersMap)
        await defineHeadermap(target, scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_ALL_TARGET_HEADERS), &tasks, construct: constructAllTargetHeadersMap)
        await defineHeadermap(target, scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_ALL_NON_FRAMEWORK_TARGET_HEADERS), &tasks, construct: constructAllNonFrameworkTargetHeadersMap)

        // The generated files headermap must be computed after all other producers have run, so we defer production of this task until the main task production is done.
        context.addDeferredProducer {
            let productName = self.context.settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)
            var tasks = [any PlannedTask]()
            await self.defineHeadermap(target, scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_GENERATED_FILES), &tasks) { (scope, target) in
                var hmap = Headermap()
                for path in self.context.generatedSourceFiles.sorted() {
                    let basename = path.basename
                    hmap.insert(Path(basename), value: path, replace: true)
                    hmap.insert(Path(productName).join(basename), value: path, replace: true)
                }
                return (hmap, [])
            }
            return tasks
        }

        return tasks
    }

    /// Helper function for defining a headermap from a constructor function.
    func defineHeadermap(_ target: StandardTarget, _ path: Path, _ tasks: inout [any PlannedTask], construct: (MacroEvaluationScope, StandardTarget) async -> (hmap: Headermap, diagnostics: [AuxiliaryFileTaskActionContext.Diagnostic])) async {
        // Ignore empty paths.
        if path.isEmpty {
            return
        }

        // Make absolute.
        let path = context.makeAbsolute(path)

        // Construct the headermap.
        let (hmap, diagnostics) = await construct(context.settings.globalScope, target)

        // Create the auxiliary file task.
        await appendGeneratedTasks(&tasks) { delegate in
            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: path), delegate, contents: hmap.toBytes(), permissions: nil, diagnostics: diagnostics, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }
    }

    /// Construct the headermap for the "all project headers" separate headermap.
    ///
    /// This headermap is used to provide access from any target to all of the headers which are explicitly included in the project's structure.
    ///
    /// It is passed with "-iquote" to the compiler, so it is effectively one of the highest priority headermaps (only behind the generated files headermap).
    ///
    /// In order to work well with user defined modules, this headermap does not directly map to headers which are installed by some target (i.e., headers which might be part of a module). Instead, the headermap contains a relative entry to the framework-style include of that header file. When using the VFS, this will map to the file on disk using the normal header search mechanism. When not using the VFS, this is mapped to the actual file using the other target-based header maps.
    func constructAllProjectHeadersMap(_ scope: MacroEvaluationScope, _ target: StandardTarget) async -> (hmap: Headermap, diagnostics: [AuxiliaryFileTaskActionContext.Diagnostic]) {
        let project = context.workspaceContext.workspace.project(for: target)
        let index = await context.workspaceContext.headerIndex

        // Get the project header info.
        guard let projectInfo = index.projectHeaderInfo[project] else {
            return (.init(), [])
        }

        // Compute the mapping of project header path to installed info.
        //
        // To match Xcode, we currently always resolve ties by order of appearance in the project. However, we most likely should be doing something more principled.
        //
        // FIXME: This is very inefficient, we are resolving target names multiple times. However, we do have this information available efficiently.
        var installedHeaderProductNames = [Path: String]()
        for case let target as BuildPhaseTarget in project.targets {
            guard let targetInfo = projectInfo.targetHeaderInfo[target] else { continue }

            // Compute the target's product name.
            let settings = context.globalProductPlan.getUnconfiguredTargetSettings(target, viewedFrom: context.configuredTarget!)
            let targetProductName = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)

            func addEntry(_ fileRef: FileReference) {
                // FIXME: This is not the right context to evaluate the path in, but what is?
                let path = context.settings.filePathResolver.resolveAbsolutePath(fileRef)

                // In order to match Xcode exactly, we guarantee that we always use the name from the first target.
                if !installedHeaderProductNames.contains(path) {
                    installedHeaderProductNames[path] = targetProductName
                }
            }
            targetInfo.publicHeaders.map(\.fileReference).forEach(addEntry)
            targetInfo.privateHeaders.map(\.fileReference).forEach(addEntry)
        }

        var hmap = Headermap()
        let diagnostics = [AuxiliaryFileTaskActionContext.Diagnostic]()

        // Add all of the project header entries.
        for fileRef in projectInfo.knownHeaders {
            // FIXME: This is not the right context to evaluate the path in, but what is?
            let path = context.settings.filePathResolver.resolveAbsolutePath(fileRef)
            let basename = path.basename

            // If this is an installed header, then map it recursively. This will resolve to a later entry in the "all targets" headermap, or it will be resolved via the VFS (we hope).
            if let productName = installedHeaderProductNames[path] {
                hmap.insert(Path(basename), value: Path(productName).join(basename), replace: false)
            } else {
                // Otherwise, map to the absolute path.
                //
                // The first entry in the project always wins here, unless later overridden by an installed definition.
                hmap.insert(Path(basename), value: path, replace: false)
            }
        }

        return (hmap, diagnostics)
    }


    /// Construct the headermap for the "own target headers" separate headermap.
    ///
    /// This headermap is used to ensure that a targets own headers are always found first, and that they can be found via any angle bracket style ('<Header.h>' or '<Target/Header.h>'). It is also used to make available the target's "project headers" via bracket style includes. The *intent* (judgement aside) was that this allowed projects to change headers from internal (Swift sense) to public without needing to update source code.
    ///
    /// It is passed with "-I" to compiler ahead of the "all targets" headermap.
    func constructOwnTargetHeadersMap(_ scope: MacroEvaluationScope, _ target: StandardTarget) async -> (hmap: Headermap, diagnostics: [AuxiliaryFileTaskActionContext.Diagnostic]) {
        let index = await context.workspaceContext.headerIndex

        // Get the project header info.
        let project = context.workspaceContext.workspace.project(for: target)
        guard let projectInfo = index.projectHeaderInfo[project] else {
            return (.init(), [])
        }

        // Get the target header info.
        guard let targetInfo = projectInfo.targetHeaderInfo[target] else {
            return (.init(), [])
        }

        var hmap = Headermap()
        let diagnostics = [AuxiliaryFileTaskActionContext.Diagnostic]()

        // Compute the target's product name.
        let settings = context.globalProductPlan.getUnconfiguredTargetSettings(target, viewedFrom: context.configuredTarget!)
        let targetProductName = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)

        // Add the entries, in priority order so that private/public headers take precedence over project headers with the same name.  If we try to add an entry for a header which has previously been added at a higher priority, then we skip it.
        var alreadyAddedBasenames = Set<String>()
        func addProductRelativeEntry(_ fileRef: FileReference) {
            // Add an entry for a public/private header:
            //   Header.h -> <PRODUCT_NAME>/Header.h
            let path = context.settings.filePathResolver.resolveAbsolutePath(fileRef)
            let basename = path.basename
            guard !alreadyAddedBasenames.contains(basename) else { return }
            hmap.insert(Path(basename), value: Path(targetProductName).join(basename))
            alreadyAddedBasenames.insert(basename)
        }
        func addAbsoluteEntry(_ fileRef: FileReference) {
            // Add two entries for a project header:
            //   Header.h -> source path
            //   <PRODUCT_NAME>/Header.h -> source path
            let path = context.settings.filePathResolver.resolveAbsolutePath(fileRef)
            let basename = path.basename
            guard !alreadyAddedBasenames.contains(basename) else { return }
            hmap.insert(Path(basename), value: path)
            hmap.insert(Path(targetProductName).join(path.basename), value: path)
            alreadyAddedBasenames.insert(basename)
        }
        targetInfo.publicHeaders.map(\.fileReference).forEach(addProductRelativeEntry)
        targetInfo.privateHeaders.map(\.fileReference).forEach(addProductRelativeEntry)
        targetInfo.projectHeaders.map(\.fileReference).forEach(addAbsoluteEntry)

        return (hmap, diagnostics)
    }

    /// Construct the headermap for the "all non-framework target headers" separate headermap.
    ///
    /// This headermap is used to provide access to any installed target header using the canonical "client" include style of `#include <Target/Target.h>`, for headers which do not match the "framework style", and thus will not be able to be remapped via the VFS. Thus, this headermap plus the VFS is intended to match the semantics of using the "all target headers" headermap.
    ///
    /// Note that, by definition, using a headermap to accomplish this means that user defined modules will not work with these headers.
    func constructAllNonFrameworkTargetHeadersMap(_ scope: MacroEvaluationScope, _ target: StandardTarget) async -> (hmap: Headermap, diagnostics: [AuxiliaryFileTaskActionContext.Diagnostic]) {
        // FIXME: Xcode traditionally reorders this list based on the target dependencies as seen from this target. In practice the main thing that fixes is seeing the right platform specific target, when a project has duplicate install paths for a particular header.

        let index = await context.workspaceContext.headerIndex

        // Get the project header info.
        let project = context.workspaceContext.workspace.project(for: target)
        guard let projectInfo = index.projectHeaderInfo[project] else {
            return (.init(), [])
        }

        let hasEnabledIndexBuildArena = scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        let includeFrameworkEntriesForTargetsNotBeingBuilt = scope.evaluate(BuiltinMacros.HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT)

        // Compute the set of targets being built.
        let targetsBeingBuilt = Set<Target>(context.globalProductPlan.allTargets.map { $0.target })

        // Build up the installed framework and non-framework style key mappings, for every target.
        var seenInstalledFrameworkMappings = Set<Path>()
        var nonFrameworkMappings = OrderedDictionary<Path, Path>()

        for (target, targetInfo) in projectInfo.targetHeaderInfo.sorted(byKey: { ($0.name + $0.guid) < ($1.name + $1.guid) }) {
            // Compute the target's product name.
            let settings = context.globalProductPlan.getUnconfiguredTargetSettings(target, viewedFrom: context.configuredTarget!)
            let scope = settings.globalScope
            let targetProductName = scope.evaluate(BuiltinMacros.PRODUCT_NAME)

            // Determine if the installed headers should be rewritten to framework style references.
            //
            // There is not a reliable way to determine this, because (a) non-framework targets may install headers into a framework style location, and (b) framework targets may override their install paths to put headers in a non-standard location.
            //
            // Therefore, we determine this by just sniffing the actual computed install paths and see if they look like a framework location.
            var publicHeadersAreFramework = false
            var privateHeadersAreFramework = false

            // If this target is not part of the active build operation, assume that it's headers are not framework style, which will mean they get exposed via headermaps (as opposed to via VFS).
            // This behavior can be opted out of by overriding HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT to NO, in which case they
            // won't be exposed via headermap or VFS, and will need to be found in the build directory or SDK.
            //
            // This behavior is just present to match Xcode, which wasn't able to easily come up with results for targets not being built.
            // Index build needs the headermaps to have consistent contents independent of the list of targets that are built.
            if hasEnabledIndexBuildArena || targetsBeingBuilt.contains(target) || !includeFrameworkEntriesForTargetsNotBeingBuilt {
                // If the wrapper ends in .framework, then treat public/private headers as framework headers if their install path matches the standard location.
                let wrapperName = scope.evaluate(BuiltinMacros.WRAPPER_NAME)
                if wrapperName.fileExtension == "framework" {
                    let publicHeadersFolderPath = scope.evaluate(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH)
                    let privateHeadersFolderPath = scope.evaluate(BuiltinMacros.PRIVATE_HEADERS_FOLDER_PATH)
                    let contentsFolderPath = scope.evaluate(BuiltinMacros.CONTENTS_FOLDER_PATH)
                    if contentsFolderPath.join("Headers") == publicHeadersFolderPath {
                        publicHeadersAreFramework = true
                    }
                    if contentsFolderPath.join("PrivateHeaders") == privateHeadersFolderPath {
                        privateHeadersAreFramework = true
                    }
                }
            }

            func addEntry(_ fileRef: FileReference, isFrameworkStyle: Bool) {
                // Add an entry: <PRODUCT_NAME>/Header.h -> source path
                //
                // FIXME: This isn't the correct file resolver to use.
                let path = context.settings.filePathResolver.resolveAbsolutePath(fileRef)
                let basename = path.basename
                let key = Path(targetProductName).join(basename)

                // If this is a framework style path, add it to the seen installed framework mappings.
                if isFrameworkStyle {
                    seenInstalledFrameworkMappings.insert(key)
                } else {
                    // Otherwise, add it to the non-framework mappings.
                    //
                    // The first entry in the project always wins here, unless later overridden by an installed definition.
                    if !nonFrameworkMappings.contains(key) {
                        nonFrameworkMappings[key] = path
                    }
                }
            }
            for entry in targetInfo.publicHeaders {
                addEntry(entry.fileReference, isFrameworkStyle: publicHeadersAreFramework)
            }
            for entry in targetInfo.privateHeaders {
                addEntry(entry.fileReference, isFrameworkStyle: privateHeadersAreFramework)
            }
        }

        // Build the headermap contents from all of the non-framework mappings which wouldn't shadow an installed value.
        var hmap = Headermap()
        for (key, value) in nonFrameworkMappings {
            if !seenInstalledFrameworkMappings.contains(key) {
                hmap.insert(key, value: value)
            }
        }
        return (hmap, [])
    }

    /// Construct the headermap for the "all target headers" separate headermap.
    ///
    /// This headermap is used to provide access to any installed target header using the canonical "client" include style of `#include <Target/Target.h>`. Note that the framework style include is supported even for non-framework targets.
    ///
    /// This headermap is passed with "-I" to the compiler, so it is lower in precedence than the "all project headers" headermap, and it will never be used to satisfy quote-style includes.
    ///
    /// When building with user modules support is enabled, this headermap cannot be used. If used, it would cause the compiler to see headers not laid out according to their framework structure, which is how the compiler determines the module map and thus the module. Instead, the compiler is passed a VFS which presents it with a view of the headers as if they had been installed into their final locations. This is intended to work in conjunction with the automatic search path arguments to the built products directory to let the compiler find these headers while preserving modules behavior.
    func constructAllTargetHeadersMap(_ scope: MacroEvaluationScope, _ target: StandardTarget) async -> (hmap: Headermap, diagnostics: [AuxiliaryFileTaskActionContext.Diagnostic]) {
        let index = await context.workspaceContext.headerIndex

        // Get the project header info.
        let project = context.workspaceContext.workspace.project(for: target)
        guard let projectInfo = index.projectHeaderInfo[project] else {
            return (.init(), [])
        }

        // Sort target header information such that other targets precede target dependencies.
        let targetDependencies = context.globalProductPlan.dependencies(of: context.configuredTarget!).map { $0.target }
        var targetHeaderInfo = projectInfo.targetHeaderInfo.map({ ($0, $1) }).filter({ $0.0 != target })
        let p = targetHeaderInfo.partition(by: { headerInfo in targetDependencies.contains(headerInfo.0) })

        var sortedTargetHeaderInfo: [(BuildPhaseTarget, TargetHeaderInfo)] = []
        sortedTargetHeaderInfo.append(contentsOf: targetHeaderInfo[..<p].sorted(by: { ($0.0.name + $0.0.guid) < ($1.0.name + $1.0.guid) }))
        sortedTargetHeaderInfo.append(contentsOf: targetHeaderInfo[p...].sorted(by: { ($0.0.name + $0.0.guid) < ($1.0.name + $1.0.guid) }))

        // Append the target header information so that the current target always takes precedence.
        if let currentTargetHeaderInfo = projectInfo.targetHeaderInfo[target] {
            sortedTargetHeaderInfo.append((target, currentTargetHeaderInfo))
        }

        // Add entries for each all of the project header entries.
        var hmap = Headermap()
        for (target, targetInfo) in sortedTargetHeaderInfo {
            // Compute the target's product name.
            let settings = context.globalProductPlan.getUnconfiguredTargetSettings(target, viewedFrom: context.configuredTarget!)
            let targetProductName = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)

            func addEntry(_ fileRef: FileReference) {
                // Add an entry: <PRODUCT_NAME>/Header.h -> source path
                //
                // FIXME: This isn't the correct file resolver to use.
                let path = context.settings.filePathResolver.resolveAbsolutePath(fileRef)
                hmap.insert(Path(targetProductName).join(path.basename), value: path)
            }
            targetInfo.publicHeaders.map(\.fileReference).forEach(addEntry)
            targetInfo.privateHeaders.map(\.fileReference).forEach(addEntry)
        }
        return (hmap, [])
    }

}


/// Performance testing entry point to headermap construction.
package func perfTestHeadermapProducer(planRequest: BuildPlanRequest, delegate: any TaskPlanningDelegate) async -> [String: [any PlannedTask]] {
    let targetTaskInfo = TargetTaskInfo(startNode: MakePlannedPathNode(Path("a")), endNode: MakePlannedPathNode(Path("b")), unsignedProductReadyNode: MakePlannedPathNode(Path("c")), willSignNode: MakePlannedPathNode(Path("d")))
    let globalProductPlan = await GlobalProductPlan(planRequest: planRequest, delegate: delegate, nodeCreationDelegate: delegate)
    var result = [String: [any PlannedTask]]()
    for configuredTarget in planRequest.buildGraph.allTargets {
        let context = TargetTaskProducerContext(configuredTarget: configuredTarget, workspaceContext: planRequest.workspaceContext, targetTaskInfo: targetTaskInfo, globalProductPlan: globalProductPlan, delegate: delegate)
        let headermapProducer = HeadermapTaskProducer(context, phaseStartNodes: [context.createVirtualNode("headermap-start")], phaseEndNode: context.createVirtualNode("headermap-end"))
        let tasks = await headermapProducer.generateTasks().map { $0 } + context.takeDeferredProducers().flatMap{ await $0() }
        result[configuredTarget.target.name] = tasks
    }
    return result
}

extension Sequence {
    fileprivate func flatMap<SegmentOfResult>(_ transform: (Self.Element) async throws -> SegmentOfResult) async rethrows -> [SegmentOfResult.Element] where SegmentOfResult : Sequence {
        var result: [SegmentOfResult.Element] = []
        for element in self {
            try await result.append(contentsOf: transform(element))
        }
        return result
    }
}
