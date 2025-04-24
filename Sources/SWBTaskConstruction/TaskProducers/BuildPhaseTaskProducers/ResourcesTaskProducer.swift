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

import SWBCore
import SWBUtil
import SWBMacro
import Foundation

/// Produces tasks for files in a Copy Resources build phase in an Xcode target.
final class ResourcesTaskProducer: FilesBasedBuildPhaseTaskProducerBase, FilesBasedBuildPhaseTaskProducer {
    typealias ManagedBuildPhase = ResourcesBuildPhase

    func shouldProcessResources(_ scope: MacroEvaluationScope) -> Bool {
        // Resources are processed only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") ||
            scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") else { return false }

        // Resources are processed only if $(UNLOCALIZED_RESOURCES_FOLDER_PATH) is defined.
        guard !scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH).isEmpty else { return false }

        return true
    }

    func prepare() {
        let scope = context.settings.globalScope

        // This is to provide a fallback to prevent any unexpected side-effects this close to shipping...
        guard scope.evaluate(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING) else { return }

        // If we're not building a wrapper, then just bail.
        let wrapperName = scope.evaluate(BuiltinMacros.WRAPPER_NAME)
        guard !wrapperName.isEmpty else { return }

        // If no resources are going to be processed, then we're done here!
        guard shouldProcessResources(scope) else { return }

        // Add all of the resources as inputs as any change to a resource will result in an output that goes into a product that will be signed. This is a slightly naive approach to this, but calculating everything can be expensive and this should suffice without over-signing the product.
        context.addAdditionalCodeSignInputs(buildPhase.buildFiles, context)
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        guard shouldProcessResources(scope) else { return [] }

        // Delegate to base implementation.
        let buildFilesContext = BuildFilesProcessingContext(scope, resolveBuildRules: true)

        let resourcesTasks = await generateTasks(self, scope, buildFilesContext)

        // Setup On-Demand Resources tasks
        if context.onDemandResourcesEnabled {
            context.addDeferredProducer {
                // This task construction needs to run after any actool or resources task construction which may update context.onDemandResourcesAssetPackSubPaths or context.onDemandResourcesAssetPacks. TODO Should adopt Michael's new task producer inputs/outputs mechanism for this.

                let assetPacks = self.context.allOnDemandResourcesAssetPacks
                guard !assetPacks.isEmpty else { return [] }

                var tasks = [any PlannedTask]()
                await self.appendGeneratedTasks(&tasks) { delegate in
                    // Emit asset pack Info.plists
                    for assetPack in assetPacks {
                        self.createOnDemandResourcesAssetPackInfoPlistTask(assetPack, delegate)
                    }

                    // Emit OnDemandResources.plist
                    self.createOnDemandResourcesPlistTask(assetPacks, delegate)

                    // Emit AssetPackManifest[Template].plist (check for <rdar://problem/19679943>)
                    let hasCustomAssetPackManifest = resourcesTasks.contains{ $0.outputs.contains { ["AssetPackManifest.plist", "AssetPackManifestTemplate.plist"].contains($0.path.basename) } }
                    if !hasCustomAssetPackManifest {
                        let orderingInputs: [any PlannedNode] = resourcesTasks.flatMap { $0.outputs }
                        self.context.createAssetPackManifestSpec.constructAssetPackManifestTask(self.context, assetPacks, orderingInputs: orderingInputs, scope, delegate)
                    }
                }

                return tasks
            }
        }

        return resourcesTasks
    }

    /// Custom override to support supplying the resources directory when constructing tasks.
    override func constructTasksForRule(_ rule: any BuildRuleAction, _ group: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async {
        // For installloc, let's ignore any Resources that are not in an .lproj.
        // An exception is xcstrings files.
        let isXCStrings = group.files.contains(where: { $0.fileType.conformsTo(identifier: "text.json.xcstrings") })
        if scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            guard isXCStrings || group.isValidLocalizedContent(scope) else { return }
        }

        // Compute the path to the effective localized directories (.lproj) in the resources and temp resources directories to define the output file for the tool.

        let assetPackInfo = context.onDemandResourcesAssetPack(for: group)
        let unlocalizedResourcesDir = assetPackInfo?.path ?? buildFilesContext.resourcesDir
        let resourcesDir = unlocalizedResourcesDir.join(group.regionVariantPathComponent.dropLast())
        // xcstrings can be in mul.lproj when paired with resource files in Base, but we still don't really want TempResourcesDir to be affected by that.
        let tmpResourcesDir = buildFilesContext.tmpResourcesDir.join(isXCStrings ? "" : group.regionVariantPathComponent.dropLast())

        // FIXME: Get the constructed tasks out of the call to `constructTasksForRule` and use their output paths directly. The asset pack just needs a relative path from the output to itself; the file _name_ doesn't matter, and for now we can just use ".".
        if let assetPackInfo, let subPath = resourcesDir.join(".").relativeSubpath(from: assetPackInfo.path) {
            context.didProduceAssetPackSubPath(assetPackInfo, subPath)
        }

        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: group.files, isPreferredArch: buildFilesContext.belongsToPreferredArch, buildPhaseInfo: buildFilesContext.buildPhaseInfo(for: rule), resourcesDir: resourcesDir, tmpResourcesDir: tmpResourcesDir, unlocalizedResourcesDir: unlocalizedResourcesDir)
        await constructTasksForRule(rule, cbc, delegate)
    }

    override func validateSpecForRule(_ spec: Spec, _ rule: any BuildRuleAction, _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> Bool {
        // <rdar://problem/37311583> Ignore Swift sources in Copy Bundle Resources build phase
        // TODO: Make this data-driven in the future...
        if spec.identifier == SwiftCompilerSpec.identifier {
            for input in cbc.inputs {
                delegate.warning("The Swift file \"\(input.absolutePath.str)\" cannot be processed by a Copy Bundle Resources build phase")
            }
            return false
        }

        return super.validateSpecForRule(spec, rule, cbc, delegate)
    }

    override func defaultOutputsForSpec(_ spec: CommandLineToolSpec, _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> [Path] {
        let outputs = super.defaultOutputsForSpec(spec, cbc, delegate)

        // If the spec doesn't declare any outputs, use a build-phase appropriate default.
        return outputs.nilIfEmpty ?? cbc.resourcesDir.map { resourcesDir in
            cbc.inputs.map { resourcesDir.join($0.absolutePath.basename) }
        } ?? []
    }

    override func addOutputFile(_ ftb: FileToBuild, _ producedFromGroup: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ productDirectories: [Path], _ scope: MacroEvaluationScope, _ generatedByBuildRuleAction: any BuildRuleAction, addIfNoBuildRuleFound: Bool) {
        // If we have an asset pack, then add it to the list of product directories.
        var productDirectories = productDirectories
        if let assetPackPath = context.onDemandResourcesAssetPack(for: producedFromGroup)?.path {
            productDirectories.append(assetPackPath)
        }

        // Have the build files context group the file appropriately.  If the context doesn't think it should be added, we instruct it to add it anyway, as an ungrouped file.
        super.addOutputFile(ftb, producedFromGroup, buildFilesContext, productDirectories, scope, generatedByBuildRuleAction, addIfNoBuildRuleFound: true)
    }

    func addTasksForUngroupedFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        if scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            // For installLoc, skip any paths that aren't copied into an lproj.
            // For bundles that are the product of a target, we copy the product generated by the installLoc action for that target.
            // For other bundles (e.g., that are part of the project sources), we selectively copy the localized content in that bundle.
            var targetBundleProduct = false
            if ftb.fileType.isBundle, let buildableItem = ftb.buildFile?.buildableItem {
                switch buildableItem {
                case .targetProduct:
                    targetBundleProduct = true
                default:
                    await addTasksForEmbeddedLocalizedBundle(ftb, buildFilesContext, scope, &tasks)
                    return
                }
            }
            guard ftb.isValidLocalizedContent(scope) || targetBundleProduct else { return }
        }

        await appendGeneratedTasks(&tasks) { delegate in
            // Compute the output path, taking the region into account.
            let assetPackInfo = context.onDemandResourcesAssetPack(for: FileToBuildGroup(nil, files: [ftb], action: nil))
            let outputDir = assetPackInfo?.path ?? buildFilesContext.resourcesDir
            let subPath = Path(ftb.regionVariantPathComponent).join(ftb.absolutePath.basename)
            let output = outputDir.join(subPath)

            if let assetPackInfo {
                context.didProduceAssetPackSubPath(assetPackInfo, subPath.str)
            }

            let ignoreMissingInputs = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") && ftb.fileType.isBundle
            await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [ftb], output: output), delegate, ruleName: "CpResource", ignoreMissingInputs: ignoreMissingInputs)
        }
    }

    private func addTasksForEmbeddedLocalizedBundle(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        await appendGeneratedTasks(&tasks) { delegate in
            let outputDir = buildFilesContext.resourcesDir
            for file in localizedFilesToBuildForEmbeddedBundle(ftb.absolutePath, scope) {
                let localizableFtb = FileToBuild(context: context, absolutePath: ftb.absolutePath.join(file))
                let subPath = Path(ftb.absolutePath.basename).join(file)
                let output = outputDir.join(subPath)
                await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [localizableFtb], output: output), delegate, ruleName: "CpResource")
            }
        }
    }

    override func additionalFilesToBuild(_ scope: MacroEvaluationScope) -> [FileToBuild] {
        var additionalFilesToBuild: [FileToBuild] = []

        // Add the generated xcassets when we're not generating asset symbols since we'll be handling the other xcassets here as well.
        let sourceFiles = (self.targetContext.configuredTarget?.target as? StandardTarget)?.sourcesBuildPhase?.buildFiles.count ?? 0
        if (!scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS) || sourceFiles == 0) && scope.evaluate(BuiltinMacros.APP_PLAYGROUND_GENERATE_ASSET_CATALOG) {
            let assetCatalogToBeGenerated = scope.evaluate(BuiltinMacros.APP_PLAYGROUND_GENERATED_ASSET_CATALOG_FILE)
            additionalFilesToBuild.append(
                FileToBuild(absolutePath: assetCatalogToBeGenerated, inferringTypeUsing: context)
            )
        }

        // Return any files provided by the product type
        if let productType = context.productType {
            additionalFilesToBuild += productType.buildPhaseFileRefAdditions["com.apple.buildphase.resources"]?.compactMap { file in
                let path = Path(scope.evaluate(file.path))
                guard path.isAbsolute else { context.error("unexpected non-absolute path from \(productType.identifier) buildPhaseFileRefAdditions \(file.path.stringRep): \(path.str)"); return nil }

                return FileToBuild(absolutePath: path, inferringTypeUsing: context, regionVariantName: scope.evaluate(file.regionVariantName).nilIfEmpty)
            } ?? []
        }

        return additionalFilesToBuild
    }

    // On-Demand Resources

    func createOnDemandResourcesAssetPackInfoPlistTask(_ assetPack: ODRAssetPackInfo, _ delegate: any TaskGenerationDelegate) {
        let scope = self.context.settings.globalScope
        let infoPlistPath = assetPack.path.join("Info.plist")
        let data = try! assetPack.infoPlistContent.asBytes(.binary)

        context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: infoPlistPath), delegate, contents: ByteString(data), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
    }

    func createOnDemandResourcesPlistTask(_ assetPacks: [ODRAssetPackInfo], _ delegate: any TaskGenerationDelegate) {
        let scope = self.context.settings.globalScope

        let unlocalizedProductResourcesDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).normalize()

        let onDemandResourcesPlist = OnDemandResourcesPlist(assetPacks, subPaths: self.context.allOnDemandResourcesAssetPackSubPaths)
        let onDemandResourcesPlistData = try! onDemandResourcesPlist.propertyListItem.asBytes(.binary)
        let onDemandResourcesPlistPath = unlocalizedProductResourcesDir.join("OnDemandResources.plist")
        self.context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: self.context, scope: scope, inputs: [], output: onDemandResourcesPlistPath), delegate, contents: ByteString(onDemandResourcesPlistData), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
    }
}
