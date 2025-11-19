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

final class ProductStructureTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .immediate
    }

    func generateTasks() async -> [any PlannedTask] {
        var tasks = [any PlannedTask]()
        let settings = context.settings
        let scope = settings.globalScope

        // Ignore targets with no product type.
        guard let productType = context.settings.productType else { return [] }

        // Generate tasks to create directories defining the product structure.
        let targetBuildDir = self.context.settings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        var outputPaths = Set<Path>()
        for directory in PackageTypeSpec.productStructureDirectories {
            let buildSetting = directory.buildSetting
            let subDir = context.settings.globalScope.evaluate(buildSetting)

            guard !subDir.isEmpty else { continue }

            let outputDir = (subDir.isAbsolute ? subDir : targetBuildDir.join(subDir)).normalize()

            // Don't create duplicate directory tasks
            guard outputPaths.insert(outputDir).inserted else { continue }

            let criteria = DirectoryCreationValidityCriteria(
                directoryPath: outputDir,
                nullifyIfProducedByAnotherTask: directory.dontCreateIfProducedByAnotherTask
            )

            await appendGeneratedTasks(&tasks) { delegate in
                await context.mkdirSpec.constructTasks(
                    CommandBuildContext(
                        producer: context,
                        scope: scope,
                        inputs: [],
                        output: outputDir,
                        preparesForIndexing: true,
                        validityCriteria: criteria
                    ),
                    delegate
                )
            }
        }

        // See 51529407. When building localizations, we don't want the builds to create any symlinks that would overlap with the base project builds.
        if !scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {

            // Generate tasks to create symbolic links in the product structure.
            for descriptor in productType.productStructureSymlinkDescriptors(scope) {
                let destinationPath =
                    descriptor.toPath.isAbsolute
                    ? descriptor.toPath
                    : descriptor.location.dirname.join(descriptor.effectiveToPath ?? descriptor.toPath).normalize()

                let criteria = SymlinkCreationValidityCriteria(
                    symlinkPath: descriptor.location,
                    destinationPath: destinationPath
                )

                await appendGeneratedTasks(&tasks) { delegate in
                    context.symlinkSpec.constructSymlinkTask(
                        CommandBuildContext(
                            producer: context,
                            scope: scope,
                            inputs: [],
                            output: descriptor.location,
                            preparesForIndexing: true,
                            validityCriteria: criteria
                        ),
                        delegate,
                        toPath: descriptor.toPath,
                        repairViaOwnershipAnalysis: false
                    )
                }
            }
        }

        // Generate the tasks to create the symlinks at $(BUILT_PRODUCTS_DIR)/<product> pointing to $(TARGET_BUILD_DIR)/<product>, if appropriate (typically only if $(DEPLOYMENT_LOCATION) is enabled).
        // While not technically "product structure", we want these to be ordered early because tasks which operate on other targets' products typically go through this symlink to do their work.
        await productType.addBuiltProductsDirSymlinkTasks(self, settings, &tasks)

        return tasks
    }

}

// MARK: Product Type Extensions

private extension ProductTypeSpec {
    /// Create the tasks to make the symlinks to the products in the `BUILT_PRODUCTS_DIR`, if appropriate.
    func addBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ settings: Settings, _ tasks: inout [any PlannedTask]) async {
        let scope = settings.globalScope

        // Only create symlink tasks when using deployment locations.
        guard scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) else {
            return
        }
        // If DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS is true then we don't create symlinks for this target.
        guard !scope.evaluate(BuiltinMacros.DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS) else {
            return
        }

        // FIXME: We cannot yet use inheritance based mechanisms to implement this.
        if let asBundle = self as? BundleProductTypeSpec {
            await asBundle.addBundleBuiltProductsDirSymlinkTasks(producer, scope, &tasks)
            if let asXCTestBundle = self as? XCTestBundleProductTypeSpec {
                await asXCTestBundle.addXCTestBundleBuiltProductsDirSymlinkTasks(producer, scope, &tasks)
            }
        } else if let asDynamicLibrary = self as? DynamicLibraryProductTypeSpec {
            await asDynamicLibrary.addDynamicLibraryBuiltProductsDirSymlinkTasks(producer, settings, &tasks)
        } else if let asStandalone = self as? StandaloneExecutableProductTypeSpec {
            await asStandalone.addStandaloneExecutableBuiltProductsDirSymlinkTasks(producer, scope, &tasks)
        } else {
            fatalError("unknown product type: \(self)")
        }
    }
}

private extension BundleProductTypeSpec {
    /// Create the task to make the symlink to the product in the `BUILT_PRODUCTS_DIR`, if appropriate.
    func addBundleBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        let context = producer.context
        // FIXME: This is in essence the same logic as for standalone products except for using WRAPPER_NAME, just diverged because the variants are top-level for them. We should reconcile, maybe by introducing a generic notion for "why" this is different.
        let targetWrapper = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))
        let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))

        await producer.appendGeneratedTasks(&tasks) { delegate in
            context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: true)
        }
    }
}

private extension DynamicLibraryProductTypeSpec {
    /// Create the tasks to make the symlink(s) to the dynamic library(s) in the `BUILT_PRODUCTS_DIR`, if appropriate.  There will be one such symlink per build variant.
    func addDynamicLibraryBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ settings: Settings, _ tasks: inout [any PlannedTask]) async {
        let scope = settings.globalScope

        // Only add symlink tasks when building API or just building.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let addDynamicLibrarySymlinks = buildComponents.contains("build")

        let shouldUseInstallAPI = ProductPostprocessingTaskProducer.shouldUseInstallAPI(scope, settings)
        // Condensed from LibraryProductTypeSpec.addDynamicLibraryInstallAPITasks(:::::).
        let willProduceTBD =
            (buildComponents.contains("api") || (addDynamicLibrarySymlinks && scope.evaluate(BuiltinMacros.TAPI_ENABLE_VERIFICATION_MODE)))
            && (scope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API) || (((producer as? PhasedTaskProducer)?.targetContext.supportsEagerLinking(scope: scope)) ?? false))
        // Only make a symlink for targets that use the default extension/suffix. Some projects have multiple dynamic libraries
        // with the same product name but different executable extensions. They all end up with the same TAPI_OUTPUT_PATH, and
        // there's no good way to resolve that, so only make symlinks for tbds that go with dylibs.
        let usesDefaultExtension = scope.evaluate(BuiltinMacros.EXECUTABLE_SUFFIX) == ".\(scope.evaluate(BuiltinMacros.DYNAMIC_LIBRARY_EXTENSION))"
        let addTBDSymlinks = shouldUseInstallAPI && willProduceTBD && usesDefaultExtension

        guard addTBDSymlinks || addDynamicLibrarySymlinks else { return }

        // Only create the symlink if the target will produce a product.
        guard producer.context.willProduceProduct(scope) else {
            return
        }

        // Add a symlink per-variant.
        for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
            if addTBDSymlinks {
                await addDynamicLibraryTBDBuiltProductsDirSymlinkTasks(producer, scope, variant, &tasks)
            }
            if addDynamicLibrarySymlinks {
                await addStandaloneExecutableBuiltProductsDirSymlinkTasks(producer, scope, variant, &tasks)
            }
        }
    }

    /// Create the task to make the symlink to the TBD in the `BUILT_PRODUCTS_DIR` for a single build variant, if appropriate.
    func addDynamicLibraryTBDBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ variant: String, _ tasks: inout [any PlannedTask]) async {
        // Enter the per-variant scope.
        let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)

        let context = producer.context
        // From LibraryProductTypeSpec.addDynamicLibraryInstallAPITasks(:::::).
        guard producer.context.willProduceBinary(scope) else { return }
        let targetWrapper = Path(scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH))
        let relativeTargetWrapper = targetWrapper.relativeSubpath(from: scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR))
        let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(relativeTargetWrapper)

        await producer.appendGeneratedTasks(&tasks) { delegate in
            context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: false)
        }
    }
}

private extension StandaloneExecutableProductTypeSpec {
    /// Create the tasks to make the symlink(s) to the product(s) in the `BUILT_PRODUCTS_DIR`, if appropriate.  There will be one such symlink per build variant.
    func addStandaloneExecutableBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        // Only add symlink tasks when building.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

        // Only create the symlink if the target will produce a product.
        guard producer.context.willProduceProduct(scope) else {
            return
        }

        // Add a symlink per-variant.
        for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
            await addStandaloneExecutableBuiltProductsDirSymlinkTasks(producer, scope, variant, &tasks)
        }
    }

    /// Create the task to make the symlink to the product in the `BUILT_PRODUCTS_DIR` for a single build variant, if appropriate.
    func addStandaloneExecutableBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ variant: String, _ tasks: inout [any PlannedTask]) async {
        // Enter the per-variant scope.
        let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)

        let context = producer.context
        // FIXME: This is in essence the same logic as for wrapped products except for using EXECUTABLE_PATH, just diverged to handle each variant.  We should reconcile, maybe by introducing a generic notion for "why" this is different.
        let targetWrapper = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))
        let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))

        await producer.appendGeneratedTasks(&tasks) { delegate in
            context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: false)
        }
    }
}

private extension XCTestBundleProductTypeSpec {
    func addXCTestBundleBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)

        guard BundleProductTypeSpec.validateBuildComponents(buildComponents, scope: scope) else { return }

        let context = producer.context

        // If we are creating a runner app, then we want to create a symlink to the runner in the built products dir.
        if type(of: self).usesXCTRunner(scope) {
            let targetWrapper = scope.unmodifiedTargetBuildDir.join(scope.evaluate(BuiltinMacros.XCTRUNNER_PRODUCT_NAME))
            let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(scope.evaluate(BuiltinMacros.XCTRUNNER_PRODUCT_NAME))

            await producer.appendGeneratedTasks(&tasks) { delegate in
                context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: true)
            }
        }
    }
}
