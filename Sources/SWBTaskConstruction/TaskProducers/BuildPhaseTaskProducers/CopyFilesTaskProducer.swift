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
import SWBProtocol
import Foundation

/// Produces tasks for files in a Copy Files build phase in an Xcode target.
///
/// Also subclassed by ``SwiftPackageCopyFilesTaskProducer``.
class CopyFilesTaskProducer: FilesBasedBuildPhaseTaskProducerBase, FilesBasedBuildPhaseTaskProducer {
    typealias ManagedBuildPhase = SWBCore.CopyFilesBuildPhase

    func prepare() {
        let scope = context.settings.globalScope

        // This is to provide a fallback to prevent any unexpected side-effects this close to shipping...
        guard scope.evaluate(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING) else { return }

        let dstFolder = computeOutputDirectory(scope)

        let wrapperName = scope.evaluate(BuiltinMacros.WRAPPER_NAME)
        if !wrapperName.isEmpty {
            let wrapperPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(wrapperName, preserveRoot: true)
            if wrapperPath.isAncestorOrEqual(of: dstFolder) {
                // Each of the files in the build phase need to be added as codesign inputs to ensure that the product is re-signed if any of these change and there is no matching code change that would otherwise trigger a re-sign. Ideally this could be replaced by watching the directory tree signature of the app bundle, but there are a host of issues that prevent that from happening.
                context.addAdditionalCodeSignInputs(buildPhase.buildFiles, context)
            }
        }
    }

    // We want to scan any app with a copy files phase for relevant privacy content.
    func declarePrivacyContentForApplicationIfNeeded(_ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate, _ ftb: FileToBuild) {
        guard ftb.absolutePath.basename == "PrivacyInfo.xcprivacy" else {
            return
        }

        func lookupProductType(_ ident: String) -> ProductTypeSpec? {
            do {
                return try context.getSpec(ident)
            } catch {
                context.error("Couldn't look up product type '\(ident)' in domain '\(context.domain)': \(error)")
                return nil
            }
        }

        let productTypeIdentifier = scope.evaluate(BuiltinMacros.PRODUCT_TYPE)
        guard let contextProductType = lookupProductType(productTypeIdentifier) else {
            return
        }

        guard let appProductType = lookupProductType("com.apple.product-type.application") else {
            return
        }
        guard contextProductType.conformsTo(appProductType) else {
            return
        }

        let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))
        delegate.declareGeneratedPrivacyPlistContent(builtWrapper)
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        // If this phase is only for deployment processing, don't run when we are not installing.
        guard !managedBuildPhase.runOnlyForDeploymentPostprocessing || scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING) else {
            return []
        }

        // Files are copied for the "build" component, or the "api" or "headers" components if $(INSTALLAPI_COPY_PHASE) or $(INSTALLHDRS_COPY_PHASE) are enabled, respectively.
        //
        // FIXME: The latter feature here is rarely used, and not very flexible as any target which needs other copy phases won't be able to disable them selectively.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard buildComponents.contains("build")
                || buildComponents.contains("installLoc")
                || (buildComponents.contains("api") && scope.evaluate(BuiltinMacros.INSTALLAPI_COPY_PHASE))
                || (buildComponents.contains("headers") && scope.evaluate(BuiltinMacros.INSTALLHDRS_COPY_PHASE)) else {
            return []
        }

        // Determine if we are honoring build rules (APPLY_RULES_IN_COPY_FILES) then lookup and apply them.
        var resolveBuildRules = scope.evaluate(BuiltinMacros.APPLY_RULES_IN_COPY_FILES)

        // Delegate to base implementation.
        // When generating a localization root, we do not want to apply APPLY_RULES_IN_COPY_FILES
        if buildComponents.contains("installLoc") {
            resolveBuildRules = false
        }
        let buildFilesContext = BuildFilesProcessingContext(scope, resolveBuildRules: resolveBuildRules)
        return await generateTasks(self, scope, buildFilesContext)
    }

    /// Compute the destination path for the copy.
    private func computeOutputDirectory(_ scope: MacroEvaluationScope) -> Path {
        // FIXME: Clean up the typing of these properties. <rdar://problem/23702533> Copy files phase properties should be stronger typed
        let subfolder: Path
        if self.managedBuildPhase.destinationSubfolder.stringRep == "<absolute>" || self.managedBuildPhase.destinationSubfolder.stringRep == "" {
            if scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
                subfolder = scope.evaluate(BuiltinMacros.INSTALL_ROOT)
            } else {
                subfolder = Path("/")
            }
        } else if self.managedBuildPhase.destinationSubfolder.stringRep == "<builtProductsDir>" {
            subfolder = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
        } else {
            let destinationSubfolder = scope.evaluate(self.managedBuildPhase.destinationSubfolder)
            if destinationSubfolder.isEmpty {
                subfolder = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME), preserveRoot: true)
            } else {
                subfolder = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(destinationSubfolder, preserveRoot: true)
            }
        }
        let subpath = Path(scope.evaluate(self.managedBuildPhase.destinationSubpath))
        let result = subfolder.join(subpath, preserveRoot: true).normalize()

        // Trim any trailing slashes, as the result is directly combined in spec files.
        return result.withoutTrailingSlash()
    }

    private func bundleFormat(_ ftb: FileToBuild) -> BundleFormat? {
        // Compute the format of the file being copied, if it's a bundle (shallow vs deep), and the version, if it's a framework.
        if case .targetProduct(let guid) = ftb.buildFile?.buildableItem, let referenceTarget = self.context.workspaceContext.workspace.dynamicTarget(for: guid, dynamicallyBuildingTargets: context.globalProductPlan.dynamicallyBuildingTargets) {
            // If the source file being copied is the product of a target, get the values from the project model.
            let parameters = self.context.configuredTarget?.parameters ?? BuildParameters(configuration: nil)
            let settings = self.context.settingsForProductReferenceTarget(referenceTarget, parameters: parameters)
            let isShallow = settings.globalScope.evaluate(BuiltinMacros.SHALLOW_BUNDLE)
            if ftb.fileType.isFramework {
                return .framework(version: isShallow ? nil : settings.globalScope.evaluate(BuiltinMacros.FRAMEWORK_VERSION))
            } else if ftb.fileType.isBundle {
                return .bundle(shallow: isShallow)
            } else {
                return nil
            }
        } else if ftb.fileType.isFramework {
            let current = ftb.absolutePath.join("Versions/Current")
            access(path: current)
            if context.fs.exists(current) {
                do {
                    return try .framework(version: context.fs.readlink(current).str)
                } catch {
                    context.warning("Couldn't resolve framework symlink for '\(current.str)': \(error)")
                    return .framework(version: "A")
                }
            } else {
                return .framework(version: nil)
            }
        } else if ftb.fileType.isBundle {
            let contents = ftb.absolutePath.join("Contents")
            access(path: contents)
            return .bundle(shallow: !context.fs.exists(contents))
        } else {
            return nil
        }
    }

    /// Custom override to support supplying the resources directory when constructing tasks.
    override func constructTasksForRule(_ rule: any BuildRuleAction, _ group: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async {
        let dstFolder = computeOutputDirectory(scope)

        // FIXME: Merge the region variant.

        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: group.files, isPreferredArch: buildFilesContext.belongsToPreferredArch, buildPhaseInfo: buildFilesContext.buildPhaseInfo(for: rule), resourcesDir: dstFolder, unlocalizedResourcesDir: dstFolder)
        await constructTasksForRule(rule, cbc, delegate)
    }

    override func addOutputFile(_ ftb: FileToBuild, _ producedFromGroup: FileToBuildGroup, _ buildFilesContext: BuildFilesProcessingContext, _ productDirectories: [Path], _ scope: MacroEvaluationScope, _ generatedByBuildRuleAction: any BuildRuleAction, addIfNoBuildRuleFound: Bool) {
        // Have the build files context group the file appropriately.  If the context doesn't think it should be added, we instruct it to add it anyway, as an ungrouped file.  This will cause it to be copied to the phase's destination folder if it is not already there (and to not emit any warnings if it is already there).
        super.addOutputFile(ftb, producedFromGroup, buildFilesContext, productDirectories, scope, generatedByBuildRuleAction, addIfNoBuildRuleFound: true)
    }

    func addTasksForUngroupedFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        let dstFolder = computeOutputDirectory(scope)

        // If the file is already in the destination path (e.g., a build rule placed it there), we are done and should not continue processing.
        if dstFolder.isAncestorOrEqual(of: ftb.absolutePath.dirname) {
            return
        }

        // Files with the `.embedInCode` rule should be skipped here.
        if ftb.buildFile?.resourceRule == .embedInCode {
            return
        }

        // Skip DriverKit drivers when building for the simulator, as we aren't able to to sign drivers differently for device versus simulator builds.
        if context.platform?.isSimulator == true && ftb.fileType.conformsTo(identifier: "wrapper.driver-extension") {
            // Similar diagnostics for platform filters and {EX,IN}CLUDED_SOURCE_FILE_NAMES are behind EnableDebugActivityLogs, but those are skipped due to explicit user action. In contrast, skipping drivers on the simulator is not likely to be expected and so users should see the diagnostic regardless of whether that dwrite is enabled.
            let platformFamilyName = context.platform?.familyDisplayName ?? "No Platform"
            context.note("Skipping '\(ftb.absolutePath.str)' because DriverKit drivers are not supported in the \(platformFamilyName) Simulator.", location: ftb.buildFile.map { buildFile in .buildFile(buildFileGUID: buildFile.guid, buildPhaseGUID: buildPhase.guid, targetGUID: targetContext.configuredTarget?.guid.stringValue ?? "") } ?? .unknown)
            return
        }

        // Compute the region path component.
        let regionPathComponent = Path(ftb.regionVariantPathComponent).normalize()

        let dst = dstFolder.join(regionPathComponent).join(ftb.absolutePath.basename)

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
                    let builtProductsDirectory = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
                    // Another way we can tell if this is the product of another target (even in another project)
                    // is if it's path is in the built products directory
                    if ftb.absolutePath.relativeSubpath(from: builtProductsDirectory) != nil {
                        targetBundleProduct = true
                    } else {
                        await addTasksForEmbeddedLocalizedBundle(ftb, buildFilesContext, scope, &tasks)
                        return
                    }
                }
            }
            guard ftb.isValidLocalizedContent(scope) || targetBundleProduct else { return }
        }

        // Determine whether we should remove header directories on copy.
        let removeHeaderDirectories = ftb.removeHeadersOnCopy && scope.evaluate(BuiltinMacros.REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES)

        // Determine whether we should remove static executables on copy, for example static frameworks whose executable is a static library.
        let removeStaticExecutables = scope.evaluate(BuiltinMacros.REMOVE_STATIC_EXECUTABLES_FROM_EMBEDDED_BUNDLES)

        // Determine whether we should re-sign on copy.  This is only done if the file-to-build wants it, *and* the file type supports it.
        let codeSignAfterCopying = ftb.codeSignOnCopy && ftb.fileType.codeSignOnCopy

        // Determine whether we should strip bitcode during copying.
        // STRIP_BITCODE_FROM_COPIED_FILES is set to YES for non-simulator embedded platforms, so we don't need to spend time stripping it for other platforms.
        let stripBitcode = scope.evaluate(BuiltinMacros.STRIP_BITCODE_FROM_COPIED_FILES) && codeSignAfterCopying

        // SUPPORT FOR MERGEABLE LIBRARIES
        // If this file was built as mergeable, and either we are a merged binary which is merging or re-exporting that file (and embedding it, which is the step that we're setting up here), or we are embedding that merged/reexported binary product as well as this product, then we need to skip copying the product's binary.
        // Note that we remove the binary even for the debug workflow, because the SourcesTaskProducer will copy only the binary part of the product into the merged product to mimic the actual merge workflow.
        // FIXME: At present only products of other targets in this build, and XCFrameworks, are supported here.
        var subpathsToExclude = [String]()
        var subpathsToStrip = [String]()

        /// Utility method to add a subpath to `subpathsToExclude`. If the subpath's first path component is `removeFirstPart` then it will be removed before adding the rest of the subpath.
        func addSubpath(_ string: String, removingFirstPartIfEqualTo firstPartToRemove: String) {
            guard !string.isEmpty else {
                return
            }
            let strParts = string.split(separator: Path.pathSeparator)
            if let firstPart = strParts.first {
                // (If there aren't any parts then we have nothing to add.)
                if strParts.count > 1, firstPart == firstPartToRemove {
                    let subpath = strParts[1...].joined(separator: Path.pathSeparatorString)
                    subpathsToExclude.append(subpath)
                }
                else if firstPart != firstPartToRemove {
                    // If string is *only* firstPartToRemove then we don't add it.
                    subpathsToExclude.append(string)
                }
            }
        }

        // The case where this file is being produced by another target.
        if let producingTarget = context.globalProductPlan.productPathsToProducingTargets[ftb.absolutePath], let mergingTargets = context.globalProductPlan.mergeableTargetsToMergingTargets[producingTarget], let configuredTarget = context.configuredTarget {
            // If either we are in the list of mergingTargets, or one of our dependencies is, then we want to skip.
            // FIXME: We should probably refine this to check that we're also embedding the dependency which is merging the item we're copying, though it's likely that we are.
            // FIXME: We should probably check whether the mergeable target is actually being linked, though it's unclear what edge case would cause that not to happen.
            var shouldSkipCopyingBinary = false
            if mergingTargets.contains(configuredTarget) {
                shouldSkipCopyingBinary = true
            }
            else {
                for dependency in context.globalProductPlan.dependencies(of: configuredTarget) {
                    if mergingTargets.contains(dependency) {
                        shouldSkipCopyingBinary = true
                        break
                    }
                }
            }
            let settings = context.globalProductPlan.planRequest.buildRequestContext.getCachedSettings(producingTarget.parameters, target: producingTarget.target)
            // We want to not exclude the binary if DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES is enabled in debug builds.  If we get here then we know this is a mergeable library, but if MAKE_MERGEABLE is enabled on the producing target then we expect this to be a debug build.  (We want to check MAKE_MERGEABLE because it's possible that setting was enabled manually, and in that case DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES doesn't apply.)
            if !settings.globalScope.evaluate(BuiltinMacros.MAKE_MERGEABLE) && scope.evaluate(BuiltinMacros.DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES) {
                shouldSkipCopyingBinary = false
            }

            if shouldSkipCopyingBinary, let productType = settings.productType {
                // If this is a standalone binary product then we skip copying it altogether.  Otherwise PBXCp will exclude the subpaths we add to the list here.
                if productType.isWrapper {
                    addSubpath(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_PATH).str, removingFirstPartIfEqualTo: settings.globalScope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME).str)
                }
                else {
                    // Skip standalone binary altogether by returning out of this method.
                    return
                }
            }
        }
        // Other kinds of build files (right now, XCFrameworks).
        else if let buildFile = ftb.buildFile {
            // We're copying an XCFramework.  We need to resolve the build file to work with it further.
            // FIXME: It's unfortunate that we have to resolve the build file here to see if it's an XCFramework, but the FileToBuild's file type is that of the library inside the XCFramework.
            if let resolvedBuildFile = try? context.resolveBuildFileReference(buildFile), resolvedBuildFile.fileType.identifier == "wrapper.xcframework" {
                var xcFramework: XCFramework? = nil
                do {
                    // We need to get the XCFramework from the library being copied.  This logic is the current way to do this.
                    xcFramework = try XCFramework(path: resolvedBuildFile.absolutePath, fs: context.fs)
                } catch {
                    context.error(error.localizedDescription)
                }
                if let xcFramework = xcFramework, let library = xcFramework.findLibrary(sdk: context.sdk, sdkVariant: context.sdkVariant) {
                    // At this point we know this is an XCFramework which we're copying, and we've successfully resolved information about the relevant library in it that we're using.
                    // Now, if this library contains mergeable metadata then we *either* want to skip copying its binary (if we're merging it), *or* we want to strip mergeable metadata from it (if we're not merging it).
                    var shouldSkipCopyingBinary = false
                    var shouldStripBinary = false
                    if library.mergeableMetadata {
                        // We know we're copying a library which was built mergeable. Now what we want to know whether we're merging it, or one of our dependencies is.
                        if let configuredTarget = context.configuredTarget {
                            for cTarget in [configuredTarget] + context.globalProductPlan.dependencies(of: configuredTarget) {
                                // FIXME: Perhaps knowing "does this target link this XCFramework" is something that the GlobalProductPlan or XCFrameworkContext should know.
                                var didFindBuildFile = false
                                if let frameworksBuildPhase = (cTarget.target as? SWBCore.BuildPhaseTarget)?.frameworksBuildPhase {
                                    for linkedBuildFile in frameworksBuildPhase.buildFiles {
                                        // FIXME: This is sketchy: It's using the current context to evaluate a build file in potentially a different target. This might rarely matter since this code only applies to XCFrameworks, but it feels wrong.
                                        if let resolvedLinkedBuildFile = try? context.resolveBuildFileReference(linkedBuildFile), resolvedLinkedBuildFile.fileType.identifier == "wrapper.xcframework", resolvedBuildFile.absolutePath == resolvedLinkedBuildFile.absolutePath {
                                            // Here we know that this is an XCFramework which is being linked by us or one of our dependencies, and that this XCFramework is marked as mergeable.  So we decide what we want to do with it.
                                            didFindBuildFile = true
                                            let cTargetSettings = context.globalProductPlan.planRequest.buildRequestContext.getCachedSettings(cTarget.parameters, target: cTarget.target)
                                            let mergeLinkedLibraries = cTargetSettings.globalScope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES)
                                            if mergeLinkedLibraries {
                                                shouldSkipCopyingBinary = true
                                            } else {
                                                shouldStripBinary = true
                                            }
                                            break
                                        }
                                    }
                                }
                                if didFindBuildFile {
                                    break
                                }
                            }
                        }
                    }


                    // If we should skip copying it, then we set up the subpaths to exclude.
                    if shouldSkipCopyingBinary {
                        // If this is a standalone binary product then we skip copying it altogether.  Otherwise PBXCp will exclude the subpaths we add to the list here.
                        switch library.libraryType {
                        case .dynamicLibrary:
                            // Skip standalone binary altogether by returning out of this method.
                            return
                        case .framework:
                            if let binaryPath = library.binaryPath {
                                addSubpath(binaryPath.str, removingFirstPartIfEqualTo: library.libraryPath.str)
                            } else {
                                context.warning("XCFramework contains mergeable metadata but does not define a binary path: \(resolvedBuildFile.absolutePath)")
                            }
                        default:
                            // These types do not support mergeable metadata.  This should have been caught at XCFramework creation time, but perhaps someone edited the XCFramework after creation.
                            // In this case, we emit a warning and copy these items normally.
                            context.warning("XCFramework claims \(library.libraryType.libraryTypeName) contains mergeable metadata, which is not supported: \(resolvedBuildFile.absolutePath)")
                        }
                    }
                    // If we should strip the binary, then add the path to its binary to the subpaths to strip.
                    if shouldStripBinary {
                        switch library.libraryType {
                        case .dynamicLibrary, .framework:
                            if let binaryPath = library.binaryPath {
                                subpathsToStrip.append(binaryPath.str)
                            } else {
                                context.warning("XCFramework contains mergeable metadata but does not define a binary path: \(resolvedBuildFile.absolutePath)")
                            }
                        default:
                            // These types do not support mergeable metadata.  This should have been caught at XCFramework creation time, but perhaps someone edited the XCFramework after creation.
                            // In this case, we emit a warning and copy these items normally, without stripping any mergeable metadata they may have.  We may refine this in the future.
                            context.warning("XCFramework claims \(library.libraryType.libraryTypeName) contains mergeable metadata, which is not supported: \(resolvedBuildFile.absolutePath)")
                        }
                    }
                }
            }
        }

        // Block downstream compilation if copy files phases contain any header files or modulemaps.
        // Note that header visibility is not relevant here since the files are always copied.
        let registry = context.workspaceContext.core.specRegistry
        let fileTypes = registry.headerFileTypes + [registry.modulemapFileType]
        let (taskOrderingOptions, preparesForIndexing) = ftb.fileType.conformsToAny(fileTypes) ? (TaskOrderingOptions.compilationRequirement, true) : (nil, false)

        // Generate the tasks.
        let (_, _, (copyFileOrderingNode, resignFileOrderingNode)) = await appendGeneratedTasks(&tasks, usePhasedOrdering: true, options: taskOrderingOptions) { delegate -> (PlannedVirtualNode, (PlannedVirtualNode)?) in
            // Virtual output nodes for individual tasks for mutation tasks to depend on.
            // I'm not sure whether it's worth the logic to only create virtual nodes when we need them.  For logical simplicity, we create the nodes up-front whether or not we need them, unless they need information we compute later.
            let copyFileOrderingNode: PlannedVirtualNode = delegate.createVirtualNode("Copy \(dst.str)")
            let resignFileOrderingNode: (PlannedVirtualNode)?

            let ftbBundleFormat = bundleFormat(ftb)

            // If the target is aggregating tracked domains, then all copied binaries need to be scanned.
            if scope.evaluate(BuiltinMacros.AGGREGATE_TRACKED_DOMAINS) {
                declarePrivacyContentForApplicationIfNeeded(scope, delegate, ftb)

                switch ftbBundleFormat {
                case .bundle(_), .framework(_):
                    delegate.declareGeneratedPrivacyPlistContent(dst)
                default:
                    break
                }
            }

            // Add additional declared outputs if re-signing.
            //
            // These declarations are needed because the re-signing task we set up below defines dependencies on more than just the top-level wrapper, so if we don't declare those items then we'll get errors when creating the build description.  Note that this assumes the bundle we're copying *has* a binary.
            var additionalPresumedOutputs = [any PlannedNode]()
            if codeSignAfterCopying {
                var fileToSign = dst

                switch ftbBundleFormat {
                case let .framework(frameworkVersion):
                    let frameworkName = dst.basenameWithoutSuffix
                    if let frameworkVersion = frameworkVersion {
                        let versionRelativePath = "Versions/\(frameworkVersion)"

                        // If this is not a shallow-bundle framework, then we sign the "Versions/A" folder inside it.
                        fileToSign = fileToSign.join(versionRelativePath)

                        // With deep bundles, we also report the Versions/A folder as an output, because that's what codesign signs.
                        additionalPresumedOutputs.append(delegate.createNode(dst.join(versionRelativePath)))
                        additionalPresumedOutputs.append(delegate.createNode(dst.join(versionRelativePath).join(frameworkName)))
                    }
                    else {
                        additionalPresumedOutputs.append(delegate.createNode(dst.join(frameworkName)))
                    }
                case let .bundle(shallow):
                    let bundleName = dst.basenameWithoutSuffix
                    if !shallow {
                        additionalPresumedOutputs.append(delegate.createNode(dst.join("Contents/MacOS").join(bundleName)))
                    }
                    else {
                        additionalPresumedOutputs.append(delegate.createNode(dst.join(bundleName)))
                    }
                case nil:
                    break
                }

                // Construct the signing task.
                let resignNode = delegate.createVirtualNode("CodeSign \(fileToSign.str)")
                resignFileOrderingNode = resignNode
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: fileToSign, fileType: ftb.fileType)], commandOrderingInputs: [copyFileOrderingNode], commandOrderingOutputs: [resignNode])
                context.codesignSpec.constructCodesignTasks(cbc, delegate, productToSign: dst, bundleFormat: ftbBundleFormat, isReSignTask: true)
            } else {
                resignFileOrderingNode = nil
            }

            // Construct the copy task.
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [ftb], output: dst, commandOrderingOutputs: [copyFileOrderingNode], resourcesDir: dstFolder, unlocalizedResourcesDir: dstFolder, preparesForIndexing: preparesForIndexing)

            let ignoreMissingInputs = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") && ftb.fileType.isBundle
            await context.copySpec.constructCopyTasks(cbc, delegate, removeHeaderDirectories: removeHeaderDirectories, removeStaticExecutables: removeStaticExecutables, excludeSubpaths: subpathsToExclude, stripSubpaths: subpathsToStrip, stripBitcode: stripBitcode, additionalPresumedOutputs: additionalPresumedOutputs, ignoreMissingInputs: ignoreMissingInputs, repairViaOwnershipAnalysis: true)

            return (copyFileOrderingNode, resignFileOrderingNode)
        }

        // Disable phase ordering for the ValidateEmbeddedBinary task so that the dependency on CodeSign (see below) does not cause a cycle due to an indirect dependency in the opposite direction because of phase ordering.
        await appendGeneratedTasks(&tasks, usePhasedOrdering: false, options: taskOrderingOptions) { delegate in
            // Validate the binary after copying and signing it, if appropriate.
            if ftb.fileType.validateOnCopy && ftb.fileType.isEmbeddableInProduct && (context.productType?.validateEmbeddedBinaries ?? false) {
                let signingIdentity = scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY)
                let infoPlistPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.INFOPLIST_PATH))

                // Ensure that ValidateEmbeddedBinary runs *after* CodeSign (of this product, not the product being copied).
                // This is important because the validation of the embedded product might depend on the parent product's signature.
                let codeSignOrderingNodes = ProductPostprocessingTaskProducer.pathsToSign(scope, context.settings).map { context.createVirtualNode("CodeSign \($0.path.str)") }
                let commandOrderingInputs: [any PlannedNode] = [delegate.createNode(infoPlistPath), copyFileOrderingNode] + (resignFileOrderingNode.map { [$0] } ?? []) + codeSignOrderingNodes
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: dst, fileType: ftb.fileType)], commandOrderingInputs: commandOrderingInputs)

                func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
                    switch macro {
                    case BuiltinMacros.InfoPlistPath:
                        return cbc.scope.namespace.parseLiteralString(infoPlistPath.str)
                    case BuiltinMacros.SigningCert:
                        return cbc.scope.namespace.parseLiteralString(signingIdentity)
                    default:
                        return nil
                    }
                }

                if !scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
                    await context.validateEmbeddedBinarySpec.constructValidateEmbeddedBinaryTask(cbc, delegate, lookup: lookup)
                }
            }
        }
    }

    private func addTasksForEmbeddedLocalizedBundle(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        await appendGeneratedTasks(&tasks) { delegate in
            let dstFolder = computeOutputDirectory(scope)
            let regionPathComponent = Path(ftb.regionVariantPathComponent).normalize()
            for file in localizedFilesToBuildForEmbeddedBundle(ftb.absolutePath, scope) {
                let localizableFtb = FileToBuild(context: context, absolutePath: ftb.absolutePath.join(file))
                let output = dstFolder.join(regionPathComponent).join(ftb.absolutePath.basename).join(file)

                await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [localizableFtb], output: output, resourcesDir: dstFolder, unlocalizedResourcesDir: dstFolder), delegate)
            }
        }
    }
}
