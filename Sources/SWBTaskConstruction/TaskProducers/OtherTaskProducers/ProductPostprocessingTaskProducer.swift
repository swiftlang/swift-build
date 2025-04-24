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

/// Returns an array of build variant-macro evaluation scope pairs for the given scope for a list of build variants.
/// - parameter scope: The base scope for which to return the varianted subscopes.
/// - parameter variants: If non-nil, then the subscopes for the given variants will be returned.  If nil, then subscopes for the values of `$(BUILD_VARIANTS)` evaluated in the given scope will be returned.
private func perVariantSubscopes(_ scope: MacroEvaluationScope, variants: [String]? = nil) -> [(variant: String, scope: MacroEvaluationScope)] {
    let effectiveVariants = variants ?? scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
    return effectiveVariants.map { variant in
        (variant, scope.subscope(binding: BuiltinMacros.variantCondition, to: variant))
    }
}

enum InstallAPIDestination {
    case eagerLinkingTBDDir
    case builtProduct

    var correspondingTaskOrderingOptions: TaskOrderingOptions {
        switch self {
        case .eagerLinkingTBDDir:
            return [.linkingRequirement]
        case .builtProduct:
            return []
        }
    }
}

final class ProductPostprocessingTaskProducer: PhasedTaskProducer, TaskProducer {

    /// Set of auxiliary files we've created tasks for which only need to be created once per variant.
    fileprivate var uniqueAuxiliaryFilePaths = Set<Path>()

    /// Set of paths of the products of targets this target is hosting, for setting up dependencies on those target.
    var hostedProductPaths: [Path] { return hostedProductPathsCache.getValue(self) }
    private var hostedProductPathsCache = LazyCache { (producer: ProductPostprocessingTaskProducer) -> [Path] in
        guard let configuredTarget = producer.context.configuredTarget, let hostedTargets = producer.context.globalProductPlan.hostedTargetsForTargets[configuredTarget] else {
            return []
        }
        let paths: [Path] = hostedTargets.compactMap({ hostedTarget in
            let settings = producer.context.globalProductPlan.getTargetSettings(hostedTarget)
            let scope = settings.globalScope
            let path = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME))
            return path.isAbsolute ? path : nil
        })
        return paths
    }


    // MARK: Provisional task setup


    class func provisionalTasks(_ settings: Settings) -> [String: ProvisionalTask] {
        var provisionalTasks = [String: ProvisionalTask]()

        let scope = settings.globalScope

        // Use per-variant copy aside only if this is not a wrapped product.
        //
        // In Xcode, the copy aside has a custom check to see if the destination has a producer. In practice, this means it is generally only done for the first copy if the paths are the same.
        //
        // FIXME: We should find a clean way to model this that doesn't rely on state like the Xcode approach.
        // TODO: Figure out how to compute this value in the context of provisional task creation.
//        let usePerVariantCopyAside = !(context.settings.productType is BundleProductTypeSpec)

        // Create the provisional tasks for each type of postprocessing step.
        let variants = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        let postprocessingItems = [
            (addChangePermissionProvisionalTasks, false),
            (addChangeAlternatePermissionProvisionalTasks, false),

            // CodeSign is actually per-variant, but it enumerates variants itself because it might need to coalesce tasks (see `testPerVariantSigning()`)
            (addCodeSignProvisionalTasks, false),
        ]

        for (fn, perVariant) in postprocessingItems {
            if perVariant {
                let variantSubscopes = perVariantSubscopes(scope, variants: variants)
                for variantSubscope in variantSubscopes {
                    fn(variantSubscope.scope, settings, &provisionalTasks)
                }
            } else {
                // We still need to set the 'normal' variant condition here, for bug compatibility, or the first variant if that one is not present. This behavior is depended upon by 'libplatform', for example, although we should consider migrating away from it.
                // FIXME: in the comment above, what does 'This' in "This behavior" refer to?  The setting of the 'normal' variant, or picking the first variant if there is no 'normal'?
                // FIXME: is using the first of variants the right thing?  BUILD_VARIANTS has a stable order since it is user-defined but is that order is supposed to matter?
                let variant = variants.contains("normal") ? "normal" : (variants.first ?? "normal")

                // Enter the per-variant scope.
                let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)

                fn(scope, settings, &provisionalTasks)
            }
        }

        return provisionalTasks
    }


    // MARK: Task generation


    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []

        // FIXME: This should really be phrased in terms of a concrete check against the produced executable (a provisional task), not a phase check.
        let isProducingProduct = context.willProduceProduct(scope)

        // Use per-variant copy aside only if this is not a wrapped product.
        //
        // In Xcode, the copy aside has a custom check to see if the destination has a producer. In practice, this means it is generally only done for the first copy if the paths are the same.
        //
        // FIXME: We should find a clean way to model this that doesn't rely on state like the Xcode approach.
        let usePerVariantForUnbundled = !(context.settings.productType is BundleProductTypeSpec)

        typealias PostprocessingTaskProducer = (name: String, fn: (MacroEvaluationScope, inout [any PlannedTask]) async -> Void, perVariant: Bool, mustFollow: [any PlannedNode], mustPrecede: [any PlannedTask])
        enum PostprocessingTaskProducerType {
            // This producer's tasks generate content which is part of the unsigned product, i.e. it needs to be present when code signing occurs.
            case unsignedProductContributor
            // This producer creates tasks which process the final product, e.g. code signing, copy-aside, etc.
            case productPostprocessor
        }
        var postprocessingItems = [PostprocessingTaskProducer]()
        func addPostprocessingFunction(_ name: String, _ fn: @escaping (MacroEvaluationScope, inout [any PlannedTask]) async -> Void, perVariant: Bool, _ type: PostprocessingTaskProducerType) {
            let (startNodes, mustPrecedeTasks): ([any PlannedNode], [any PlannedTask]) = {
                switch type {
                case .unsignedProductContributor:
                    return ([], [targetContext.unsignedProductReadyTask])
                case .productPostprocessor:
                    return ([targetContext.willSignNode], [])
                }
            }()
            postprocessingItems.append((name, fn, perVariant, startNodes, mustPrecedeTasks))
        }

        // Perform various post-processing tasks.  This list is in the specific order these tasks need to be set up, because below we will set up phase barriers which cause these tasks to run in the order they were set up.
        //
        // FIXME: This variant processing isn't quite right. Codesigning, for example, tries to always process the 'normal' variant last, so we should just define that as the behavior and always do it. And it seems like all of these have moved to being per-variant.
        if ProductPostprocessingTaskProducer.shouldUseInstallAPI(scope, context.settings) {
            addPostprocessingFunction("GenerateInstallAPI", addInstallAPITasks, perVariant: true, .unsignedProductContributor)
        }
        addPostprocessingFunction("GenerateStubAPI", addStubAPITasks, perVariant: false, .unsignedProductContributor)

        // At this point the unsigned product is complete.  Everything after here is postprocessing the product.

        if isProducingProduct {
            // CopyAside need to run after generating API since those tasks may put content inside wrapper products, but before stripping symbols, since the copied-aside product is supposed to be symbol-rich.
            addPostprocessingFunction("CopyAside", addCopyAsideTasks, perVariant: usePerVariantForUnbundled, .productPostprocessor)
        }
        addPostprocessingFunction("StripSymbols", addStripSymbolsTasks, perVariant: true, .productPostprocessor)
        if isProducingProduct {
            addPostprocessingFunction("ChangePermissions", addChangePermissionTasks, perVariant: usePerVariantForUnbundled, .productPostprocessor)
        }
        addPostprocessingFunction("ChangeAlternatePermissions", addChangeAlternatePermissionTasks, perVariant: false, .productPostprocessor)
        // CodeSign is actually per-variant, but it enumerates variants itself because it might need to coalesce tasks (see `testPerVariantSigning()`)
        addPostprocessingFunction("CodeSign", addCodeSignTasks, perVariant: false, .productPostprocessor)
        if isProducingProduct {
            addPostprocessingFunction("RegisterExecutionPolicyException", addExecutionPolicyExceptionTasks, perVariant: usePerVariantForUnbundled, .productPostprocessor)
            addPostprocessingFunction("Validate", addProductValidationTasks, perVariant: false, .productPostprocessor)
        }
        addPostprocessingFunction("RegisterProduct", addProductRegistrationTasks, perVariant: false, .productPostprocessor)

        let variants = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        for (name, fn, perVariant, mustFollow, mustPrecede) in postprocessingItems {
            // Force a new phase between each post-processing step.
            self.addTaskBarrier(name: "\(context.configuredTarget!.guid)-Barrier-\(name)", additionalStartNodes: mustFollow, additionalMustPrecedeTasks: mustPrecede)

            if perVariant {
                let variantSubscopes = perVariantSubscopes(scope, variants: variants)
                for variantSubscope in variantSubscopes {
                    await fn(variantSubscope.scope, &tasks)
                }
            } else {
                // We still need to set the 'normal' variant condition here, for bug compatibility, or the first variant if that one is not present. This behavior is depended upon by 'libplatform', for example, although we should consider migrating away from it.
                // FIXME: in the comment above, what does 'This' in "This behavior" refer to?  The setting of the 'normal' variant, or picking the first variant if there is no 'normal'?
                // FIXME: is using the first of variants the right thing?  BUILD_VARIANTS has a stable order since it is user-defined but is that order is supposed to matter?
                let variant = variants.contains("normal") ? "normal" : (variants.first ?? "normal")

                // Enter the per-variant scope.
                let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)

                await fn(scope, &tasks)
            }
        }

        // Add the touch task, if appropriate for this product type.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if buildComponents.contains("build") || buildComponents.contains("headers") {
            await context.settings.productType?.addTouchTask(self, scope, &tasks)
        }

        if buildComponents.contains("build") {
            // Add any product specific registration tasks.
            await context.settings.productType?.addCopyProductDefinitionPlistTasks(self, scope, &tasks)
        }

        // Add any additional gates we used for task barriers.
        tasks += self.additionalGateTasks

        return tasks
    }


    // MARK: Copy aside


    private class func addCopyAsideProvisionalTasks(_ scope: MacroEvaluationScope, _ provisionalTasks: inout [String: ProvisionalTask]) {

        // TODO: Implement copy aside provisional tasks
    }

    /// Creates a task to copy aside the symboled product to the SYMROOT during an install build.
    private func addCopyAsideTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // This feature is used to retain the raw (unstripped) binaries.

        // Only perform the copy aside when building for deployment, and enabled.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") && scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING) && scope.evaluate(BuiltinMacros.RETAIN_RAW_BINARIES) else {
            return
        }

        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        let buildDir = scope.evaluate(BuiltinMacros.BUILD_DIR)
        let fullProductName = scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME)
        if targetBuildDir != buildDir {
            // Get the input, which is the path we're copying the symboled product from.
            let input = FileToBuild(context: context, absolutePath: targetBuildDir.join(fullProductName))

            // Compute additional inputs.
            let additionalInputs = hostedProductPaths.map({ context.createDirectoryTreeNode($0, excluding: []) })

            // <rdar://problem/45465505> Enable hierarchical layout in SYMROOT of copied-aside products by default
            let output: Path
            if SWBFeatureFlag.useHierarchicalBuiltProductsDir.value || SWBFeatureFlag.useHierarchicalLayoutForCopiedAsideProducts.value || scope.evaluate(BuiltinMacros.USE_HIERARCHICAL_LAYOUT_FOR_COPIED_ASIDE_PRODUCTS) {
                // Since a build might have multiple targets which generate the same product name, we want to avoid collisions when computing the destination here.  So for installed products we place them at their INSTALL_PATH relative to the SYMROOT, and for uninstalled products we place them at $(SYMROOT)/UninstalledProducts/$(PROJECT_NAME)/$(TARGET_NAME).
                if scope.evaluate(BuiltinMacros.SKIP_INSTALL) || scope.evaluate(BuiltinMacros.INSTALL_PATH).isEmpty {
                    output = buildDir.join("UninstalledProducts").join(context.settings.project?.name).join(context.settings.target?.name).join(fullProductName)
                }
                else {
                    let installPath = scope.evaluate(Static { BuiltinMacros.namespace.parseString("$(INSTALL_PATH)$(TARGET_BUILD_SUBPATH)") })
                    output = buildDir.join(installPath, preserveRoot:true).join(fullProductName)
                }
            }
            else {
                // Right now we use the old, flat layout until we can enable the hierarchical layout by default.
                output = buildDir.join(fullProductName)
            }
            await appendGeneratedTasks(&tasks) { delegate in
                await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [input], output: output, commandOrderingInputs: additionalInputs), delegate, stripUnsignedBinaries: false, stripBitcode: false, repairViaOwnershipAnalysis: true)
            }
        }
    }


    // MARK: Stripping

    private func addStripSymbolsTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) {
        // Only perform stripping when building for deployment, and enabled.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") && scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING) && scope.evaluate(BuiltinMacros.STRIP_INSTALLED_PRODUCT) else {
            return
        }

        // If this target is going to be copying a stub as its binary (presently, because $(PRODUCT_BINARY_SOURCE_PATH) is defined and therefore the stub is for a WatchKit product), then we don't strip it.
        guard scope.evaluate(BuiltinMacros.PRODUCT_BINARY_SOURCE_PATH).isEmpty else {
            return
        }

        // NOTE: These must be captured here; they are mutable and used to define the task order gating.
        let phaseStartNodes = self.phaseStartNodes
        let phaseEndTask = self.phaseEndTask

        context.addDeferredProducer {
            guard let inputPath = self.context.producedBinary(forVariant: scope.evaluate(BuiltinMacros.CURRENT_VARIANT)) else { return [] }

            let input = FileToBuild(context: self.context, absolutePath: inputPath)
            let delegate = PhasedProducerBasedTaskGenerationDelegate(producer: self, context: self.context, phaseStartNodes: phaseStartNodes, phaseEndTask: phaseEndTask)
            var orderingInputs = [any PlannedNode]()
            // The strip task needs to be ordered after the dsymutil task, since dsymutil needs the symbols which strip will remove.
            if let dsymPath = self.context.producedDSYM(forVariant: scope.evaluate(BuiltinMacros.CURRENT_VARIANT)) {
                orderingInputs.append(delegate.createVirtualNode("GenerateDSYMFile \(dsymPath.str)"))
            }
            await self.context.stripSpec.constructTasks(CommandBuildContext(producer: self.context, scope: scope, inputs: [input], commandOrderingInputs: orderingInputs), delegate)
            return delegate.tasks
        }
    }

    // MARK: Install API

    private static func machOTypeSupportsTAPI(_ scope: MacroEvaluationScope) -> Bool {
        // Only Mach-O dynamic libraries are supported. We don't error out if the MachO type is different,
        // because a target's product type doesn't necessarily match the MachO type.
        // For example the target was originally generated as a dynamic library, but then later on the MachO
        // type was changed to static library.
        return scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_dylib"
    }

    static func shouldUseInstallAPI(_ scope: MacroEvaluationScope, _ settings: Settings) -> Bool {
        if !machOTypeSupportsTAPI(scope) {
            return false
        }

        // Targets are only expected to produce API, if (1) the target is being installed, and API generation is required (because no build is being done), and (2) the target has opted into API generation.
        //
        // The intent is that we will always attempt to generate API for installed targets with "installapi", or for any target that has opted in to the feature.
        return (scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING) && settings.allowInstallAPIForTargetsSkippedInInstall(in: scope) && scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("api")) || scope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API)
    }

    private static func stubAPIDestination(_ scope: MacroEvaluationScope, _ settings: Settings) -> InstallAPIDestination? {
        // Don't use stub API if using "installapi".
        if shouldUseInstallAPI(scope, settings) {
            return nil
        }

        if !machOTypeSupportsTAPI(scope) {
            return nil
        }

        if scope.evaluate(BuiltinMacros.GENERATE_TEXT_BASED_STUBS) {
            return .builtProduct
        } else if scope.evaluate(BuiltinMacros.GENERATE_INTERMEDIATE_TEXT_BASED_STUBS) {
            // We don't want to generate the intermediate stub if creating a mergeable library, because the linker will end up trying to merge the .tbd (which it finds in the eager linking directory before it finds the binary in the product directory) and fail.
            // In the scenarios we're currently supporting for mergeable libraries this is a reasonable compromise, but if we want to support this feature for mergeable libraries (e.g., because some targets are treating them as regular dylibs) then we may need support in the linker and/or tapi for that.  (For example, we could direct tapi to add something to the .tbd indicating that it's for a mergeable library, which would cause the linker to skip it when searching for libraries with -merge_framework/library options.)
            guard !scope.evaluate(BuiltinMacros.MAKE_MERGEABLE) else {
                return nil
            }
            // If `INLINE_PRIVATE_FRAMEWORKS` is set, stubify is not guaranteed to succeed without project modifications. It's rare for this setting to be `YES` when installAPI and installed stubs are both disabled, so just disable the optimization if it happens.
            guard !scope.evaluate(BuiltinMacros.INLINE_PRIVATE_FRAMEWORKS) else {
                return nil
            }
            // Disable this optimization if the binary reexports any frameworks or libraries, as it is not safe in all cases when what's being reexported was not built in the same xcodebuild invocation.
            guard scope.evaluate(BuiltinMacros.REEXPORTED_LIBRARY_NAMES).isEmpty && scope.evaluate(BuiltinMacros.REEXPORTED_LIBRARY_PATHS).isEmpty && scope.evaluate(BuiltinMacros.REEXPORTED_FRAMEWORK_NAMES).isEmpty else {
                return nil
            }
            for flag in scope.evaluate(BuiltinMacros.OTHER_LDFLAGS) {
                guard !flag.contains("-reexport-l") && !flag.contains("-reexport_framework") else {
                    return nil
                }
            }
            // Generate an intermediate tbd file using `stubify` which won't be included in the built product. Downstream targets will use this as the linker input instead of the binary, allowing for more granular incremental builds.
            return .eagerLinkingTBDDir
        } else {
            return nil
        }
    }

    private func addInstallAPITasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        await context.settings.productType?.addInstallAPITasks(self, scope, context.tapiSpec.discoveredCommandLineToolSpecInfo(context, scope, context.globalProductPlan.delegate) as? DiscoveredTAPIToolSpecInfo, &tasks, destination: .builtProduct)
    }

    private func addStubAPITasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) {
        if let destination = ProductPostprocessingTaskProducer.stubAPIDestination(scope, context.settings) {
            if destination == .eagerLinkingTBDDir {
                guard !context.supportsEagerLinking(scope: scope) else {
                    // If we're generating a tbd through eager linking, we don't need to run `tapi stubify`. We can't check this in `stubAPIDestination` because it needs to be static so it can be used to determine paths to codesign. tbd files in EagerLinkingTBDs don't need to be codesigned, so it's safe to narrow the eligibility criteria here.
                    return
                }
                guard !context.globalProductPlan.duplicatedProductNames.contains(scope.evaluate(BuiltinMacros.PRODUCT_NAME)) else {
                    // If multiple targets in the build share a product name, they may compute clashing tbd paths in EagerLinkingTBDs. This is rare, so for now we just skip the optimization if it happens.
                    return
                }
            }
            context.settings.productType?.addStubAPITasks(self, scope, destination: destination, &tasks)
        }
    }

    // MARK: Changing ownership and permissions


    private class func addChangePermissionProvisionalTasks(_ scope: MacroEvaluationScope, _ settings: Settings, _ provisionalTasks: inout [String: ProvisionalTask]) {

        // TODO: Implement change permission provisional tasks
    }

    private class func addChangeAlternatePermissionProvisionalTasks(_ scope: MacroEvaluationScope, _ settings: Settings, _ provisionalTasks: inout [String: ProvisionalTask]) {

        // TODO: Implement change alternate permission provisional tasks
    }

    private func addChangePermissionTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Change permissions tasks are performed only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

        // Evaluate the permission properties.
        let owner = scope.evaluate(BuiltinMacros.INSTALL_OWNER)
        let group = scope.evaluate(BuiltinMacros.INSTALL_GROUP)
        let mode = scope.evaluate(BuiltinMacros.INSTALL_MODE_FLAG)
        let path = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME))
        await addSpecificChangePermissionTasks(scope, &tasks, owner, group, mode, path)
    }

    private func addChangeAlternatePermissionTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Don't change alternate permissions when performing these actions.
        guard context.configuredTarget?.parameters.action != .installHeaders && context.configuredTarget?.parameters.action != .installAPI else { return }

        // Evaluate the permission properties.
        for pathStr in scope.evaluate(BuiltinMacros.ALTERNATE_PERMISSIONS_FILES) {
            var path = Path(pathStr)

            // If the path is not absolute, resolve it relative to the install path.
            //
            // FIXME: Presumably, we should enforce that INSTALL_PATH is absolute at some point?
            if !path.isAbsolute {
                path = scope.evaluate(BuiltinMacros.INSTALL_DIR).join(path)
            }

            let owner = scope.evaluate(BuiltinMacros.ALTERNATE_OWNER)
            let group = scope.evaluate(BuiltinMacros.ALTERNATE_GROUP)
            let mode = scope.evaluate(BuiltinMacros.ALTERNATE_MODE)
            await addSpecificChangePermissionTasks(scope, &tasks, owner, group, mode, path)
        }
    }

    private func addSpecificChangePermissionTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask], _ owner: String, _ group: String, _ mode: String, _ path: Path) async {
        // chmod tasks aren't relevant for Windows
        guard context.sdkVariant?.llvmTargetTripleSys != "windows" else {
            return
        }

        // Only perform change permission tasks when building and deploying.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") && scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) && scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING) else {
            return
        }

        // Construct the appropriate tasks.
        await appendGeneratedTasks(&tasks) { delegate in
            context.setAttributesSpec.constructSetAttributesTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: path)]), delegate, owner: (owner != "") ? .some(owner) : nil, group: (group != "") ? .some(group) : nil, mode: (mode != "") ? .some(mode) : nil)
        }
    }


    // MARK: Code signing

    private class func codeSignProvisionalTaskIdentifier(pathToSign: Path) -> String {
        return "CodeSign \(pathToSign.str)"
    }

    /// Returns a list of files to sign for the current product.
    /// - returns: An array of tuples consisting of:
    ///     - *pathToSign*: The path to the file to sign.
    ///     - *variantSubscope*: The variant subscope for this file, which can be used by the caller to compute additional information about this file.
    ///     - *isNormalProductPath*: `true` if this is the path to the normal build variant for the product.  For unwrapped products this will be `true` for the normal build variant binary.  For wrapped products, this will be `true` for the directory being signed.  Only one path in the returned array will have this set to `true`.
    ///     - *mayBeWrapper*: `true` if the path might be a wrapper, `false` if we are certain that it is not a wrapper.  This should be passed to `CodeSignToolSpec.constructCodesignTasks()` to indicate whether it should employ its heuristics to compute the output paths when signing a wrapper.
    class func pathsToSign(_ scope: MacroEvaluationScope, _ settings: Settings) -> [(path: Path, variantSubscope: MacroEvaluationScope, isNormalProductPath: Bool, mayBeWrapper: Bool, ignoreEntitlements: Bool)] {
        var seenPaths = Set<Path>()
        let paths = perVariantSubscopes(scope).flatMap { (variant: String, subscope: MacroEvaluationScope) -> [(path: Path, variantSubscope: MacroEvaluationScope, isNormalProductPath: Bool, mayBeWrapper: Bool, ignoreEntitlements: Bool)] in

            // For wrapped products, $(CODESIGNING_FOLDER_PATH) will evaluate to the wrapper for the normal variant, and the binary to be built for other variants.
            // FIXME: If not all variants will have their binaries produced, then this probably won't work at present.
            let path = subscope.evaluate(BuiltinMacros.CODESIGNING_FOLDER_PATH)

            // FIXME: If two different variants result in the same signed path, we discard the second variant scope. The problem is, it could have other variant-conditionalized settings that would affect signing (e.g. separate entitlements). This would be a user error and it would be nice if we diagnosed it.
            guard !seenPaths.contains(path) else { return [] }
            seenPaths.insert(path)

            // We remember if this is the path to the normal product path because we want to make its signing task depend on all of the other signing tasks.
            let isNormalProductPath = (variant == "normal")
            var paths = [(path, subscope, isNormalProductPath, isNormalProductPath, false)]

            // If we have a shim, we need to sign the preview dylib
            let previewDylibPath = subscope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH)
            if !previewDylibPath.isEmpty {
                paths.append((subscope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(Path(previewDylibPath)), subscope, false, false, true))
            }
            let previewBlankInjectionDylibPath = subscope.evaluate(BuiltinMacros.EXECUTABLE_BLANK_INJECTION_DYLIB_PATH)
            if !previewBlankInjectionDylibPath.isEmpty {
                paths.append((subscope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(Path(previewBlankInjectionDylibPath)).normalize(), subscope, false, false, true))
            }

            // If we are creating a TBD for this product, then also sign the .tbd file.
            //
            // FIXME: This is not strictly correct, because there are situations where these methods return true but we don't actually enable InstallAPI. We should resolve this eventually.
            //
            // FIXME: This is very gross, we currently only have access to the scope here, so we can't use the actual product type object. However, we will hopefully replace all of this logic by eliminating the
            let productType = ProductTypeIdentifier(subscope.evaluate(BuiltinMacros.PRODUCT_TYPE))

            // TAPI will only be run when the output is a dylib. Swift static library may schedule installAPI phase to generate a swiftmodule.
            if productType.supportsInstallAPI && (shouldUseInstallAPI(subscope, settings) || stubAPIDestination(subscope, settings) == .builtProduct) {
                let tapiOutputPath = Path(subscope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH))
                paths.append((tapiOutputPath, subscope, false, false, false))
            }

            return paths
        }

        // Make sure there is at most one path for the normal-variant product, and if there is one, sort it to the end so it gets signed last.
        assert(paths.filter({ $0.isNormalProductPath }).count <= 1, "found multiple paths to sign for the normal-variant product")
        return paths.sorted(by: { $1.isNormalProductPath })
    }

    private class func addCodeSignProvisionalTasks(_ scope: MacroEvaluationScope, _ settings: Settings, _ provisionalTasks: inout [String: ProvisionalTask]) {
        for pathToSign in pathsToSign(scope, settings) {
            let provisionalTaskIdentifier = ProductPostprocessingTaskProducer.codeSignProvisionalTaskIdentifier(pathToSign: pathToSign.path)
            provisionalTasks[provisionalTaskIdentifier] = ProductPostprocessingProvisionalTask(identifier: provisionalTaskIdentifier, mustBeDependedOn: false)
        }
    }

    /// The entry point for signing the main product of the configured target.
    ///
    /// Other than constructing the context for signing the main product, this method is mainly concerned with emitting errors and warnings about signing for the target, and any other functionality which should only occur once per target (and not once per signing, since a target may sign other things besides its main product).
    private func addCodeSignTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        let isProducingProduct = context.willProduceProduct()

        // Remember all of the ordering output nodes for tasks which are signing nested content so that the task to sign the normal variant - the product wrapper - can be made to depend on those tasks for wrapped products.
        var nestedSigningTaskOrderingNodes = [PlannedVirtualNode]()
        let pathsToSign = ProductPostprocessingTaskProducer.pathsToSign(scope, context.settings)
        for pathToSign in pathsToSign {
            let scope = pathToSign.variantSubscope
            let provisionalTaskIdentifier = ProductPostprocessingTaskProducer.codeSignProvisionalTaskIdentifier(pathToSign: pathToSign.path)
            guard let provisionalTask = context.provisionalTasks[provisionalTaskIdentifier] else { preconditionFailure("Expected to find provisional task for: \(provisionalTaskIdentifier)") }

            // Create the task to sign the main product.
            // For frameworks on macOS, the output is the Versions/A folder inside the framework and the productToSign is the .framework itself.
            // For UI tests, the output is the XCTRunner.app and the productToSign is the .xctest product which gets built inside the runner - so that both of them can use the .xcent file emitted for the target.
            let codeSignTask: (any PlannedTask)? = await {
                guard context.signingSettings != nil else { return nil }

                // When signing for a variant, we will only be signing a single binary, even though we would expect a bundle based on the product type
                let isSigningBinary = !pathToSign.isNormalProductPath && (context.productType?.isWrapper ?? false)

                // We aren't going to be producing a binary if we have no ARCHS...
                let archs = scope.evaluate(BuiltinMacros.ARCHS)
                guard !archs.isEmpty else { return nil }

                let isProducingBinary = context.willProduceBinary(scope)

                // If we're not going to be producing a product, we stop right now.  This is important because even though the CodeSign task itself is provisional, the ProcessProductPackaging task and others on which the CodeSign task relies are not currently provisional, which will cause CodeSign to run anyway.
                guard isSigningBinary ? isProducingBinary : isProducingProduct else { return nil }

                // If we don't have an Info.plist (but the product type expects one), we can't ever code sign.
                if scope.effectiveInputInfoPlistPath().isEmpty && context.settings.productType?.hasInfoPlist == true {
                    let message = "Cannot code sign because the target does not have an Info.plist file and one is not being generated automatically. Apply an Info.plist file to the target using the \(BuiltinMacros.INFOPLIST_FILE.name) build setting or generate one automatically by setting the \(BuiltinMacros.GENERATE_INFOPLIST_FILE.name) build setting to YES (recommended)."
                    if scope.evaluate(BuiltinMacros.DOWNGRADE_CODESIGN_MISSING_INFO_PLIST_ERROR) {
                        context.warning(message)
                    } else {
                        context.error(message)
                    }
                    return nil
                }

                // Create the task to sign the main product.
                let fileToSign = FileToBuild(context: context, absolutePath: pathToSign.path)
                let productToSign = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME))
                var orderingOutputs = [any PlannedNode]()
                let signingOrderingNode = context.createVirtualNode("CodeSign \(fileToSign.absolutePath.str)")
                orderingOutputs.append(signingOrderingNode)

                // Add a dependency to Info.plist if present.
                //
                // This should be fine for now but we ultimately want to add dependency to the directory structure of the product. LLBuild supports that but it doesn't support excluding paths inside the structure. This is required because we don't want to depend on like the binary itself and contents of _CodeSignature/.
                var extraInputs: [Path] = []
                if context.productType?.hasInfoPlist == true {
                    let infoplistFile = scope.effectiveInputInfoPlistPath()
                    let infoplistPath = scope.evaluate(BuiltinMacros.INFOPLIST_PATH)
                    if !infoplistFile.isEmpty && !infoplistPath.isEmpty {
                        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
                        extraInputs.append(targetBuildDir.join(infoplistPath).normalize())
                    }
                }

                // Also depend on any hosted products which are being built directly into our product.
                extraInputs.append(contentsOf: hostedProductPaths)

                // Now we can set up the signing task.
                let (codeSignTasks, _) = await self.appendGeneratedTasks(&tasks) { delegate in
                    let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [fileToSign], commandOrderingInputs: nestedSigningTaskOrderingNodes, commandOrderingOutputs: orderingOutputs)
                    context.codesignSpec.constructCodesignTasks(cbc, delegate, productToSign: productToSign, isProducingBinary: isProducingBinary, fileToSignMayBeWrapper: pathToSign.mayBeWrapper, ignoreEntitlements: pathToSign.ignoreEntitlements, extraInputs: extraInputs)
                }
                precondition(codeSignTasks.count <= 1, "Expected 0 or 1 tasks from constructCodesignTasks")

                // If this is not the path for the normal product, and the product we're signing is a wrapper, then add this task's ordering node to the list so the normal product signing task (which will sign the wrapper) can depend on it.
                if isSigningBinary {
                    nestedSigningTaskOrderingNodes.append(signingOrderingNode)
                }

                return codeSignTasks.first
            }()

            if let task = codeSignTask {
                provisionalTask.fulfill(task)
            }
            else {
                provisionalTask.fulfillWithNoTask()
            }
        }
    }

    private func addExecutionPolicyExceptionTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else {
            return
        }

        // Pointless for static libraries/frameworks
        if context.productType is StaticLibraryProductTypeSpec || context.productType is StaticFrameworkProductTypeSpec {
            return
        }

        await appendGeneratedTasks(&tasks) { delegate in
            let path = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME))
            let input = FileToBuild(context: context, absolutePath: path.normalize())
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [input])
            await context.registerExecutionPolicyExceptionSpec?.constructRegisterExecutionPolicyExceptionTask(cbc, delegate)
        }
    }

    /// The entry point for creating a validation task for the product if necessary.
    private func addProductValidationTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Change permissions tasks are performed only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else {
            return
        }

        // If the product type specifies a validation tool to run, then we create a task to do so.
        // Presently we only create this task for iOS/tvOS/watchOS/macOS device application products.
        // FIXME: The fact that the product type spec defines the identifier of the tool to use is wacky, since nothing is taking advantage of it, so we take advantage of that by just doing the simple thing to get the one tool spec we know about.
        if let identifier = context.productType?.productValidationToolSpecIdentifier, identifier == context.validateProductSpec.identifier {
            await appendGeneratedTasks(&tasks) { delegate in
                let input = FileToBuild(context: context, absolutePath: scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME)).normalize())
                let additionalInputs = hostedProductPaths.map({ context.createDirectoryTreeNode($0, excluding: []) })
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [input], commandOrderingInputs: additionalInputs, commandOrderingOutputs: [delegate.createVirtualNode("Validate \(input.absolutePath.str)")])
                await context.validateProductSpec.constructTasks(cbc, delegate)
            }
        }
    }

    // The entry point for adding in the product registration tasks for 'build' commands.
    private func addProductRegistrationTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else {
            return
        }
        await context.productType?.addRegistrationTasks(self, scope, &tasks)
    }
}


// MARK: Product Type Extensions

extension ProductTypeSpec {
    /// Add the Install API tasks, if appropriate for the product.
    ///
    /// These are the tasks which run during the "installapi" build command, and are required to produce the "API" for a product without needing to execute the full build.
    func addInstallAPITasks(_ producer: PhasedTaskProducer, _ scope: MacroEvaluationScope, _ tapiInfo: DiscoveredTAPIToolSpecInfo?, _ tasks: inout [any PlannedTask], destination: InstallAPIDestination) async {
        // FIXME: We cannot yet use inheritance based mechanisms to implement this.
        switch self {
        case let subtype as FrameworkProductTypeSpec:
            await subtype.addFrameworkInstallAPITasks(producer, scope, tapiInfo, &tasks, destination: destination)
        case let subtype as LibraryProductTypeSpec:
            await subtype.addDynamicLibraryInstallAPITasks(producer, scope, tapiInfo, &tasks, destination: destination)
        default:
            break
        }
    }
}

private extension ProductTypeSpec {
    /// Add the product registration tasks, if appropriate.
    func addRegistrationTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // FIXME: We cannot yet use inheritance based mechanisms to implement this.
        switch self {
        case let asApp as ApplicationProductTypeSpec:
            await asApp.addAppProductRegistrationTasks(producer, scope, &tasks)
        default:
            break
        }
    }

    /// Add a task to copy the product definition plist, if appropriate.
    ///
    /// Product definition plists are a mechanism used to inform the App Store about specialized hardware and software capabilities required for an app to run (such as specific OpenCL and OpenGL functionality). See https://developer.apple.com/library/archive/qa/qa1748/_index.html for more information.
    func addCopyProductDefinitionPlistTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        guard let project = producer.context.project, let productDefinitionPlistPath = Path(scope.evaluate(BuiltinMacros.PRODUCT_DEFINITION_PLIST)).nilIfEmpty?.makeAbsolute(relativeTo: project.sourceRoot), scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build"), self is BundleProductTypeSpec else {
            return
        }

        let context = producer.context
        await producer.appendGeneratedTasks(&tasks) { delegate in
            await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: productDefinitionPlistPath)], output: scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join("ProductDefinition.plist")), delegate)
        }
    }

    /// Add the touch task, if appropriate for the product.
    ///
    /// This task is used to ensure that the product is always as-up-to-date as the things inside it. This is then relied upon by other targets (which check its timestamp), but may also be a nice invariant to expose to scripts, etc. However, we should probably make sure that the integrity of the build as understood by the build system itself does not depend on this task.
    func addTouchTask(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Product touch occurs only when the "build" or "headers" component is present.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard buildComponents.contains("build") || buildComponents.contains("headers") else { return }

        let context = producer.context
        // FIXME: We cannot yet use inheritance based mechanisms to implement this.
        if self is BundleProductTypeSpec {
            let path = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))
            await producer.appendGeneratedTasks(&tasks) { delegate in
                await context.touchSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: path)]), delegate)
            }
        }
    }

    /// Add the Stub API tasks, if appropriate for the product.
    ///
    /// These are tasks which are run _in addition to_ the regular build tasks, typically to validate that the "installapi" command has parity with the actual build products.
    func addStubAPITasks(_ producer: PhasedTaskProducer, _ scope: MacroEvaluationScope, destination: InstallAPIDestination, _ tasks: inout [any PlannedTask]) {
        // FIXME: We cannot yet use inheritance based mechanisms to implement this.
        switch self {
        case let subtype as FrameworkProductTypeSpec:
            subtype.addFrameworkStubAPITasks(producer, scope, destination, &tasks)
        case let subtype as LibraryProductTypeSpec:
            subtype.addDynamicLibraryStubAPITasks(producer, scope, destination, &tasks)
        default:
            break
        }
    }
}

private extension ApplicationProductTypeSpec {
    func addAppProductRegistrationTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Signing occurs only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

        // If we're building for the macOS platform, then register the application with LaunchServices.  c.f. <rdar://problem/18464352> Handoff doesn't work with app launched from Xcode
        let context = producer.context
        guard context.settings.platform?.name == "macosx" else { return }

        let path = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))
        await producer.appendGeneratedTasks(&tasks) { delegate in
            // Mutating tasks *require* the input node, otherwise this task will not properly run for incremental builds.
            let vnode = delegate.createVirtualNode("LSRegisterURL \(path.str)")

            await context.launchServicesRegisterSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: path)], output: path, commandOrderingOutputs: [vnode]), delegate)
        }
    }
}

// MARK: Text-based API generation

private extension ProductTypeSpec {
    func addFileListInstallAPITasks(_ targetHeaderInfo: TargetHeaderInfo?, _ isFramework: Bool, _ producer: PhasedTaskProducer, tapiInfo: DiscoveredTAPIToolSpecInfo?, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask], _ tapiInputNodes: inout [any PlannedNode]) async -> Path? {
        let jsonPath: Path
        if let postProcessingProducer = producer as? ProductPostprocessingTaskProducer {
            // Create a JSON file with a list of the headers.  We only need to do this once for the target - each build variant will share the same JSON file.
            jsonPath = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join(scope.evaluate(BuiltinMacros.PRODUCT_NAME) + ".json")
            guard !postProcessingProducer.uniqueAuxiliaryFilePaths.contains(jsonPath) else {
                return jsonPath
            }
        } else {
            // If this task is not being generated as part of a ProductPostprocessingTaskProducer, don't attempt to deduplicate it across variants. For now, this is ok, because when eagerly linking there are no headers and the computation below is cheap, but we still need at least one input file to pass to tapi.
            jsonPath = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("\(scope.evaluate(BuiltinMacros.PRODUCT_NAME))-\(scope.evaluate(BuiltinMacros.CURRENT_VARIANT)).json")
        }

        guard let tapiVersion = tapiInfo?.toolVersion else {
            producer.context.error("Couldn't determine tapi version")
            return nil
        }

        let headerListVersion = TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: tapiVersion)
        let headerDestPaths = TargetHeaderInfo.builtProductDestDirs(scope: scope, workingDirectory: producer.targetContext.defaultWorkingDirectory)

        let requiresSRCROOTSupport = scope.evaluate(BuiltinMacros.TAPI_ENABLE_PROJECT_HEADERS) || scope.evaluate(BuiltinMacros.TAPI_USE_SRCROOT)

        struct FilteringContext: PathResolvingBuildFileFilteringContext {
            let excludedSourceFileNames: [String]
            let includedSourceFileNames: [String]
            let currentPlatformFilter: SWBCore.PlatformFilter?
            let filePathResolver: FilePathResolver
        }
        let filteringContext = FilteringContext(
            excludedSourceFileNames: scope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES),
            includedSourceFileNames: scope.evaluate(BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES),
            currentPlatformFilter: PlatformFilter(scope),
            filePathResolver: producer.context.filePathResolver
        )

        // Add all headers to the header list for the JSON file and to the input nodes for dependency tracking.
        let headerList: [(TAPIFileList.HeaderVisibility, String)] = {
            guard let info = targetHeaderInfo else {
                return []
            }
            return ([(.public, info.publicHeaders), (.private, info.privateHeaders), (nil, info.projectHeaders)] as [(HeaderVisibility?, [TargetHeaderInfo.Entry])]).compactMap { (visibility, headerEntries) in
                // Ignore public/private headers for frameworks, unless it's been opted in.
                if (isFramework && (visibility == .public || visibility == .private)) && !requiresSRCROOTSupport {
                    return nil
                }

                // Skip project headers unless we've opted in
                if visibility == nil && !scope.evaluate(BuiltinMacros.TAPI_ENABLE_PROJECT_HEADERS) {
                    return nil
                }

                return headerEntries.compactMap { entry -> (TAPIFileList.HeaderVisibility, String)? in
                    // The JSON file should have the product headers, not the source headers, so we need to compute the output path.
                    // FIXME: We should be able to get this info from - or at least share it with - the HeadersTaskProducer.
                    guard let path = filteringContext.path(header: entry) else {
                        return nil
                    }

                    // FIXME: headerDestPaths should only be used for framework targets when determining outputPath
                    // until rdar://81762676 (Dylib targets inconsistently writes headers to BUILD_PRODUCTS_DIR
                    // based install vs normal build) has been resolved.
                    let outputPath : Path
                    let tapiVisibility: TAPIFileList.HeaderVisibility
                    switch visibility {
                    case .public?:
                        tapiVisibility = .public
                        outputPath = isFramework ? headerDestPaths.publicPath.join(path.basename) : TargetHeaderInfo.outputPath(for: path, visibility: .public, scope: scope)
                        tapiInputNodes.append(producer.context.createNode(TargetHeaderInfo.outputPath(for: path, visibility: .public, scope: scope).normalize()))
                    case .private?:
                        tapiVisibility = .private
                        outputPath = isFramework ? headerDestPaths.privatePath.join(path.basename) : TargetHeaderInfo.outputPath(for: path, visibility: .private, scope: scope)
                        tapiInputNodes.append(producer.context.createNode(TargetHeaderInfo.outputPath(for: path, visibility: .private, scope: scope).normalize()))
                    case nil:
                        tapiVisibility = .project
                        outputPath = path
                        tapiInputNodes.append(producer.context.createNode(outputPath.normalize()))
                    }

                    return (tapiVisibility, outputPath.str)
                }
            }.reduce([], +)
        }()

        if isFramework && !requiresSRCROOTSupport {
            if !(targetHeaderInfo?.publicHeaders.filter({ !filteringContext.isExcluded(header: $0) }) ?? []).isEmpty {
                tapiInputNodes.append(producer.context.createDirectoryTreeNode(TargetHeaderInfo.destDirPath(for: .public, scope: scope), excluding: []))
            }
            if !(targetHeaderInfo?.privateHeaders.filter({ !filteringContext.isExcluded(header: $0) }) ?? []).isEmpty {
                tapiInputNodes.append(producer.context.createDirectoryTreeNode(TargetHeaderInfo.destDirPath(for: .private, scope: scope), excluding: []))
            }
        }

        let fileList: TAPIFileList
        let fileListBytes: ByteString
        do {
            fileList = try TAPIFileList(version: headerListVersion, headers: headerList)
            fileListBytes = ByteString(try fileList.asBytes())
        } catch {
            producer.context.error(error.localizedDescription)
            return nil
        }

        await producer.appendGeneratedTasks(&tasks) { delegate in
            producer.context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: producer.context, scope: producer.context.settings.globalScope, inputs: [], output: jsonPath), delegate, contents: fileListBytes, permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        if let postProcessingProducer = producer as? ProductPostprocessingTaskProducer {
            // Have the producer remember that we've set up a task to generate this file.
            postProcessingProducer.uniqueAuxiliaryFilePaths.insert(jsonPath)
        }


        return jsonPath
    }
}

/// Adds the InstallAPI tasks that are common between framework and dylib targets.
/// This function will determine if Swift and TAPI-based InstallAPI actions took place during the build.
func addCommonInstallAPITasks(_ producer: PhasedTaskProducer, _ scope: MacroEvaluationScope, inputs: [FileToBuild],
                              headerDependencyInputs: [any PlannedNode],
                              tapiOutputNode: PlannedPathNode, tapiOrderingNode: PlannedVirtualNode, phaseStartNodes: [any PlannedNode],
                              phaseEndTask: any PlannedTask, jsonPath: Path?, destination: InstallAPIDestination) async -> [any PlannedTask] {
    let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
    var dependencyInputs = headerDependencyInputs
    // Only add dSYM dependency iff this the task is installAPI verification.
    let tapiReadDSYM = scope.evaluate(BuiltinMacros.TAPI_READ_DSYM) && scope.evaluate(BuiltinMacros.DEBUG_INFORMATION_FORMAT) == "dwarf-with-dsym"
    if buildComponents.contains("build") && !(destination == .eagerLinkingTBDDir) && tapiReadDSYM {
        let dsymBundle = scope.evaluate(BuiltinMacros.DWARF_DSYM_FOLDER_PATH)
            .join(scope.evaluate(BuiltinMacros.DWARF_DSYM_FILE_NAME))
        dependencyInputs.append(producer.context.createDirectoryTreeNode(dsymBundle, excluding:[""]))
    }

    let variant = scope.evaluate(BuiltinMacros.CURRENT_VARIANT)
    // Add support for passing the built binary path, when building.
    let builtBinaryPath: Path?
    let dsymPath: Path?
    switch destination {
    case .eagerLinkingTBDDir:
        builtBinaryPath = nil
        dsymPath = nil
    case .builtProduct:
        builtBinaryPath = producer.context.producedBinary(forVariant: variant)
        // Only capture dSYM when reading binary.
        dsymPath = producer.context.producedDSYM(forVariant: variant)

    }
    let delegate = PhasedProducerBasedTaskGenerationDelegate(producer: producer, context: producer.context, taskOptions: destination.correspondingTaskOrderingOptions, phaseStartNodes: phaseStartNodes, phaseEndTask: phaseEndTask)
    let swiftTBDFiles = producer.context.generatedTBDFiles(forVariant: variant)
    await producer.context.tapiSpec.constructTAPITasks(CommandBuildContext(producer: producer.context, scope: scope, inputs: inputs, output: tapiOutputNode.path, commandOrderingInputs: dependencyInputs, commandOrderingOutputs: [tapiOrderingNode]), delegate, generatedTBDFiles: swiftTBDFiles, builtBinaryPath: builtBinaryPath, fileListPath: jsonPath, dsymPath: dsymPath)

    return delegate.tasks
}

extension FrameworkProductTypeSpec {
    func addTBDSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ fileName: String, _ tasks: inout [any PlannedTask], destination: InstallAPIDestination) async {
        // If not using a shallow bundle, also create the symlink from the top-level wrapper.
        if !scope.evaluate(BuiltinMacros.SHALLOW_BUNDLE) {
            let target: Path
            let output: PlannedPathNode
            switch destination {
            case .builtProduct:
                target = Path(scope.evaluate(BuiltinMacros.VERSIONS_FOLDER_PATH).basename).join(scope.evaluate(BuiltinMacros.CURRENT_VERSION)).join(fileName)
                output = producer.context.createNode(scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME)).join(fileName))
            case .eagerLinkingTBDDir:
                target = Path(scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH))
                output = producer.context.createNode(scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME)).join(fileName))
            }

            await producer.appendGeneratedTasks(&tasks, options: destination.correspondingTaskOrderingOptions) { delegate in
                producer.context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: producer.context, scope: scope, inputs: [], output: output.path), delegate, toPath: target, repairViaOwnershipAnalysis: true)
            }
        }
    }
}

private extension FrameworkProductTypeSpec {
    func addFrameworkInstallAPITasks(_ producer: PhasedTaskProducer, _ scope: MacroEvaluationScope, _ tapiInfo: DiscoveredTAPIToolSpecInfo?, _ tasks: inout [any PlannedTask], destination: InstallAPIDestination) async {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let target = producer.context.configuredTarget!.target

        // If not building the "api" component, then only generate API if actually building and verification mode is enabled, or if eagerly linking.
        guard buildComponents.contains("api") || (buildComponents.contains("build") && (scope.evaluate(BuiltinMacros.TAPI_ENABLE_VERIFICATION_MODE) || (producer.targetContext.supportsEagerLinking(scope: scope) && destination == .eagerLinkingTBDDir))) else { return }

        // We only generate API (a .tbd file) if the target is producing a binary, since this file is only used in linking.
        guard producer.context.willProduceBinary(scope) else { return }

        // Get the target header info, if present.
        let targetHeaderInfo: TargetHeaderInfo?
        if let target = target as? SWBCore.BuildPhaseTarget, let projectInfo = await producer.context.workspaceContext.headerIndex.projectHeaderInfo[producer.context.workspaceContext.workspace.project(for: target)] {
            targetHeaderInfo = projectInfo.targetHeaderInfo[target]
        } else {
            targetHeaderInfo = nil
        }

        // The target is required to opt-in to text-based API generation, it is an error to get here for a target that has not. The intent here is to force any project using "installapi" to adopt SUPPORTS_TEXT_BASED_API for the appropriate targets, so that they will also have API generation done during regular builds of the target.
        if !scope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API) && !producer.targetContext.supportsEagerLinking(scope: scope) {
            // If the target has no installed headers, it is not an error for it not to support InstallAPI.
            guard let targetInfo = targetHeaderInfo,
                  !targetInfo.publicHeaders.isEmpty || !targetInfo.privateHeaders.isEmpty else {
                return
            }

            // If TAPI support errors are disabled, ignore the error.
            if scope.evaluate(BuiltinMacros.ALLOW_UNSUPPORTED_TEXT_BASED_API) {
                return
            }

            // Otherwise, diagnose that this project has installed content which does not have it's API reflected.
            producer.context.error("Framework requested to generate API, but has not adopted SUPPORTS_TEXT_BASED_API", location: .buildSetting(BuiltinMacros.SUPPORTS_TEXT_BASED_API))
            return
        }

        let tapiOutputNode: PlannedPathNode
        let tapiOrderingNode: PlannedVirtualNode
        switch destination {
        case .eagerLinkingTBDDir:
            // Compute the TAPI output path.
            tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH)))
            // Create a virtual node to represent the final .tbd, needed to enforce ordering.
            tapiOrderingNode = producer.context.createVirtualNode("Eager Linking TBD Production \(tapiOutputNode.path.str)")
        case .builtProduct:
            // Compute the TAPI output path.
            tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH)))
            // Create a virtual node to represent the final .tbd, needed to enforce ordering.
            tapiOrderingNode = producer.context.createVirtualNode("TBD Production \(tapiOutputNode.path.str)")
        }

        await addTBDSymlinkTasks(producer, scope, tapiOutputNode.path.basename, &tasks, destination: destination)

        var tapiInputNodes = [any PlannedNode]()

        // Compute the text-based API, providing the input binary if we are also in a mode that is building it.
        let tapiInputNode = producer.context.createNode(scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME)))

        guard let jsonPath = await addFileListInstallAPITasks(targetHeaderInfo, true, producer, tapiInfo: tapiInfo, scope, &tasks, &tapiInputNodes) else {
            return // we've already emitted an error
        }

        // NOTE: These must be captured here; they are mutable and used to define the task order gating.
        let phaseStartNodes = producer.phaseStartNodes
        let phaseEndTask = producer.phaseEndTask

        producer.context.addDeferredProducer {
            let inputs = [FileToBuild(context: producer.context, absolutePath: tapiInputNode.path)]

            return await addCommonInstallAPITasks(producer, scope, inputs: inputs, headerDependencyInputs: tapiInputNodes, tapiOutputNode: tapiOutputNode, tapiOrderingNode: tapiOrderingNode,
                                            phaseStartNodes: phaseStartNodes, phaseEndTask: phaseEndTask, jsonPath: jsonPath, destination: destination)
        }
    }

    func addFrameworkStubAPITasks(_ producer: PhasedTaskProducer, _ scope: MacroEvaluationScope, _ destination: InstallAPIDestination, _ tasks: inout [any PlannedTask]) {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if !(buildComponents.contains("build") || buildComponents.contains("exportLoc")) { return }

        // We only generate API (a .tbd file) if the target is producing a binary, since this file is only used in linking.
        guard producer.context.willProduceBinary(scope) else { return }

        // NOTE: These must be captured here; they are mutable and used to define the task order gating.
        let phaseStartNodes = producer.phaseStartNodes
        let phaseEndTask = producer.phaseEndTask

        producer.context.addDeferredProducer {
            // Early exit when the target doesn't generate any binaries at all.
            guard let builtBinaryPath = producer.context.producedBinary(forVariant: scope.evaluate(BuiltinMacros.CURRENT_VARIANT)) else {
                return []
            }

            let tapiOutputNode: PlannedPathNode
            let tapiOrderingNode: PlannedVirtualNode
            switch destination {
            case .eagerLinkingTBDDir:
                // Compute the TAPI output path.
                tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH)))
                // Create a virtual node to represent the final .tbd, needed to enforce ordering.
                tapiOrderingNode = producer.context.createVirtualNode("Eager Linking TBD Production \(tapiOutputNode.path.str)")
            case .builtProduct:
                // Compute the TAPI output path.
                tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH)))
                // Create a virtual node to represent the final .tbd, needed to enforce ordering.
                tapiOrderingNode = producer.context.createVirtualNode("TBD Production \(tapiOutputNode.path.str)")
            }

            var tasks: [any PlannedTask] = []
            await self.addTBDSymlinkTasks(producer, scope, tapiOutputNode.path.basename, &tasks, destination: destination)

            let cbc = CommandBuildContext(producer: producer.context, scope: scope, inputs: [FileToBuild(context: producer.context, absolutePath: builtBinaryPath)], output: tapiOutputNode.path, commandOrderingOutputs: [tapiOrderingNode])

            let delegate = PhasedProducerBasedTaskGenerationDelegate(producer: producer, context: producer.context, phaseStartNodes: phaseStartNodes, phaseEndTask: phaseEndTask)
            await producer.context.tapiStubifySpec.constructTasks(cbc, delegate)
            tasks += delegate.tasks

            return tasks
        }
    }
}

private extension LibraryProductTypeSpec {
    func addDynamicLibraryInstallAPITasks(_ producer: PhasedTaskProducer, _ scope: MacroEvaluationScope, _ tapiInfo: DiscoveredTAPIToolSpecInfo?, _ tasks: inout [any PlannedTask], destination: InstallAPIDestination) async {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let target = producer.context.configuredTarget!.target

        // If not building the "api" component, then only generate API if actually building and verification mode is enabled, or if eagerly linking.
        guard buildComponents.contains("api") || (buildComponents.contains("build") && (scope.evaluate(BuiltinMacros.TAPI_ENABLE_VERIFICATION_MODE) || (producer.targetContext.supportsEagerLinking(scope: scope) && destination == .eagerLinkingTBDDir))) else { return }

        // We only generate API (a .tbd file) if the target is producing a binary, since this file is only used in linking.
        guard producer.context.willProduceBinary(scope) else { return }

        // Get the target header info, if present.
        let targetHeaderInfo: TargetHeaderInfo?
        if let target = target as? SWBCore.BuildPhaseTarget, let projectInfo = await producer.context.workspaceContext.headerIndex.projectHeaderInfo[producer.context.workspaceContext.workspace.project(for: target)] {
            targetHeaderInfo = projectInfo.targetHeaderInfo[target]
        } else {
            targetHeaderInfo = nil
        }

        // The target is required to opt-in to text-based API generation, it is an error to get here for a target that has not. The intent here is to force any project using "installapi" to adopt SUPPORTS_TEXT_BASED_API for the appropriate targets, so that they will also have API generation done during regular builds of the target.
        if !scope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API) && !producer.targetContext.supportsEagerLinking(scope: scope) {
            // If the target has no installed headers, it is not an error for it not to support InstallAPI.
            guard let targetHeaderInfo = targetHeaderInfo,
                  !targetHeaderInfo.publicHeaders.isEmpty || !targetHeaderInfo.privateHeaders.isEmpty else {
                return
            }

            // If TAPI support errors are disabled, ignore the error.
            if scope.evaluate(BuiltinMacros.ALLOW_UNSUPPORTED_TEXT_BASED_API) {
                return
            }

            // Otherwise, diagnose that this project has installed content which does not have it's API reflected.
            producer.context.error("Dynamic Library requested to generate API, but has not adopted SUPPORTS_TEXT_BASED_API", location: .buildSetting(BuiltinMacros.SUPPORTS_TEXT_BASED_API))
            return
        }

        let tapiOutputNode: PlannedPathNode
        let tapiOrderingNode: PlannedVirtualNode
        switch destination {
        case .eagerLinkingTBDDir:
            // Compute the TAPI output path.
            tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH)))
            // Create a virtual node to represent the final .tbd, needed to enforce ordering.
            tapiOrderingNode = producer.context.createVirtualNode("Eager Linking TBD Production \(tapiOutputNode.path.str)")
        case .builtProduct:
            // Compute the TAPI output path.
            tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH)))
            // Create a virtual node to represent the final .tbd, needed to enforce ordering.
            tapiOrderingNode = producer.context.createVirtualNode("TBD Production \(tapiOutputNode.path.str)")
        }

        // Generate the .tbd file.
        var tapiInputNodes = [any PlannedNode]()

        guard let jsonPath = await addFileListInstallAPITasks(targetHeaderInfo, false, producer, tapiInfo: tapiInfo, scope, &tasks, &tapiInputNodes) else {
            return // we've already emitted an error
        }

        // NOTE: These must be captured here; they are mutable and used to define the task order gating.
        let phaseStartNodes = producer.phaseStartNodes
        let phaseEndTask = producer.phaseEndTask

        producer.context.addDeferredProducer {
            return await addCommonInstallAPITasks(producer, scope, inputs: [], headerDependencyInputs: tapiInputNodes, tapiOutputNode: tapiOutputNode, tapiOrderingNode: tapiOrderingNode,
                                            phaseStartNodes: phaseStartNodes, phaseEndTask: phaseEndTask, jsonPath: jsonPath, destination: destination)
        }
    }

    func addDynamicLibraryStubAPITasks(_ producer: PhasedTaskProducer, _ scope: MacroEvaluationScope, _ destination: InstallAPIDestination, _ tasks: inout [any PlannedTask]) {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard buildComponents.contains("build") || buildComponents.contains("exportLoc") else { return }

        // We only generate API (a .tbd file) if the target is producing a binary, since this file is only used in linking.
        guard producer.context.willProduceBinary(scope) else { return }

        // NOTE: These must be captured here; they are mutable and used to define the task order gating.
        let phaseStartNodes = producer.phaseStartNodes
        let phaseEndTask = producer.phaseEndTask

        producer.context.addDeferredProducer {
            // Early exit when the target doesn't generate any binaries at all.
            guard let builtBinaryPath = producer.context.producedBinary(forVariant: scope.evaluate(BuiltinMacros.CURRENT_VARIANT)) else {
                return []
            }

            let tapiOutputNode: PlannedPathNode
            let tapiOrderingNode: PlannedVirtualNode
            switch destination {
            case .eagerLinkingTBDDir:
                // Compute the TAPI output path.
                tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH)))
                // Create a virtual node to represent the final .tbd, needed to enforce ordering.
                tapiOrderingNode = producer.context.createVirtualNode("Eager Linking TBD Production \(tapiOutputNode.path.str)")
            case .builtProduct:
                // Compute the TAPI output path.
                tapiOutputNode = producer.context.createNode(Path(scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH)))
                // Create a virtual node to represent the final .tbd, needed to enforce ordering.
                tapiOrderingNode = producer.context.createVirtualNode("TBD Production \(tapiOutputNode.path.str)")
            }

            let cbc = CommandBuildContext(producer: producer.context, scope: scope, inputs: [FileToBuild(context: producer.context, absolutePath: builtBinaryPath)], output: tapiOutputNode.path, commandOrderingOutputs: [tapiOrderingNode])

            // Generate the text-based stub from the input binary.
            let delegate = PhasedProducerBasedTaskGenerationDelegate(producer: producer, context: producer.context, phaseStartNodes: phaseStartNodes, phaseEndTask: phaseEndTask)
            await producer.context.tapiStubifySpec.constructTasks(cbc, delegate)
            return delegate.tasks
        }
    }
}
