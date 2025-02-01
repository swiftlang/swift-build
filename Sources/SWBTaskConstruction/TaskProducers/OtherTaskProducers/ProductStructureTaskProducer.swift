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
    private class func mkdirProvisionalTaskName(_ buildSetting: PathMacroDeclaration) -> String
    {
        return "MkDir $(\(buildSetting.name))"
    }

    private class func symlinkProvisionalTaskName(_ location: Path) -> String
    {
        return "SymLink \(location.str)"
    }

    class func provisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]
    {
        // Ignore targets with no product type.
        guard let productType = settings.productType else { return [:] }

        var result = [String: ProvisionalTask]()

        // Set up the provisional tasks for creating directories.
        for directory in PackageTypeSpec.productStructureDirectories
        {
            let name = self.mkdirProvisionalTaskName(directory.buildSetting)
            let provisionalTask = CreateDirectoryProvisionalTask(identifier: name, nullifyIfProducedByAnotherTask: directory.dontCreateIfProducedByAnotherTask)
            result[name] = provisionalTask
        }

        // See 51529407. When building localizations, we don't want the builds to create any symlinks that would overlap with the base project builds.
        let scope = settings.globalScope
        if !scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            // Set up the provisional tasks for creating symlinks.
            for descriptor in productType.productStructureSymlinkDescriptors(settings.globalScope)
            {
                let name = self.symlinkProvisionalTaskName(descriptor.location)
                let provisionalTask = CreateSymlinkProvisionalTask(identifier: name, descriptor: descriptor)
                result[name] = provisionalTask
            }
        }

        return result
    }

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .immediate
    }

    func generateTasks() async -> [any PlannedTask]
    {
        var tasks = [any PlannedTask]()
        let settings = context.settings
        let scope = settings.globalScope

        // Ignore targets with no product type.
        guard let productType = context.settings.productType else { return [] }

        // Generate tasks to create directories defining the product structure.
        // This is done by going through the list of product structure directory build settings defined by the `PackageTypeSpec` class.  For each one, if the build setting expands to a non-empty value, then create a task for it and use it to fulfill a provisional task.  If it expands to an empty value, then set the corresponding provisional task to not have a concrete task.
        let targetBuildDir = self.context.settings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        var outputPaths = Set<Path>()
        for directory in PackageTypeSpec.productStructureDirectories
        {
            let buildSetting = directory.buildSetting
            let provisionalTaskName = ProductStructureTaskProducer.mkdirProvisionalTaskName(buildSetting)
            let provisionalTask = context.provisionalTasks[provisionalTaskName]
            let subDir = context.settings.globalScope.evaluate(buildSetting)
            if !subDir.isEmpty
            {
                let outputDir = (subDir.isAbsolute ? subDir : targetBuildDir.join(subDir)).normalize()
                // If we've already created a task for this directory, then don't create another one.
                if !outputPaths.contains(outputDir)
                {
                    // Create the task.
                    let (tasks, _) = await appendGeneratedTasks(&tasks) { delegate in
                        await context.mkdirSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: outputDir, preparesForIndexing: true), delegate)
                    }

                    // Fulfill the provisional task.
                    assert(tasks.count == 1)
                    let plannedTask = tasks[0]
                    let outputNode = plannedTask.outputs.first!         // The first node is the concrete output node of the mkdir task.
                    provisionalTask?.fulfill(plannedTask, outputNode)

                    // Remember that we've already created a task for this outputDir.
                    outputPaths.insert(outputDir)
                }
                else
                {
                    provisionalTask?.fulfillWithNoTask()
                }
            }
            else
            {
                provisionalTask?.fulfillWithNoTask()
            }
        }

        // See 51529407. When building localizations, we don't want the builds to create any symlinks that would overlap with the base project builds.
        if !scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {

            // Generate tasks to create symbolic links in the product structure.
            // This is done by going through the list of product structure symlink descriptors defined by the target's `ProductTypeSpec` instance.  For each one we create a task to create the symlink and use it to fulfill a provisional task.
            // At present, we expect that every symlink descriptor will have a provisional task which is fulfilled by an actual task.
            for descriptor in productType.productStructureSymlinkDescriptors(scope)
            {
                // Create the task.
                let (tasks, _) = await appendGeneratedTasks(&tasks) { delegate in
                    context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: descriptor.location, preparesForIndexing: true), delegate, toPath: descriptor.toPath, repairViaOwnershipAnalysis: false)
                }

                // Fulfill provisional tasks.
                precondition(tasks.count == 1, "Created wrong number of tasks (\(tasks.count)) for symlink at \(descriptor.location.str)")
                let task = tasks.first!
                let provisionalTaskName = ProductStructureTaskProducer.self.symlinkProvisionalTaskName(descriptor.location)
                let provisionalTask = context.provisionalTasks[provisionalTaskName]
                let outputNode = context.createNode(descriptor.location)
                provisionalTask?.fulfill(task, outputNode)
            }
        }

        // Generate the tasks to create the symlinks at $(BUILT_PRODUCTS_DIR)/<product> pointing to $(TARGET_BUILD_DIR)/<product>, if appropriate (typically only if $(DEPLOYMENT_LOCATION) is enabled).
        // While not technically "product structure", we want these to be ordered early because tasks which operate on other targets' products typically go through this symlink to do their work.
        await productType.addBuiltProductsDirSymlinkTasks(self, settings, &tasks)

        return tasks
    }

}


// MARK: Product Type Extensions


private extension ProductTypeSpec
{
    /// Create the tasks to make the symlinks to the products in the `BUILT_PRODUCTS_DIR`, if appropriate.
    func addBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ settings: Settings, _ tasks: inout [any PlannedTask]) async
    {
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
        }
        else if let asDynamicLibrary = self as? DynamicLibraryProductTypeSpec {
            await asDynamicLibrary.addDynamicLibraryBuiltProductsDirSymlinkTasks(producer, settings, &tasks)
        }
        else if let asStandalone = self as? StandaloneExecutableProductTypeSpec {
            await asStandalone.addStandaloneExecutableBuiltProductsDirSymlinkTasks(producer, scope, &tasks)
        }
        else {
            fatalError("unknown product type: \(self)")
        }
    }
}

private extension BundleProductTypeSpec
{
    /// Create the task to make the symlink to the product in the `BUILT_PRODUCTS_DIR`, if appropriate.
    func addBundleBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async
    {
        let context = producer.context
        // FIXME: This is in essence the same logic as for standalone products except for using WRAPPER_NAME, just diverged because the variants are top-level for them. We should reconcile, maybe by introducing a generic notion for "why" this is different.
        let targetWrapper = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))
        let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))

        await producer.appendGeneratedTasks(&tasks)
        { delegate in
            context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: true)
        }
    }
}


private extension DynamicLibraryProductTypeSpec
{
    /// Create the tasks to make the symlink(s) to the dynamic library(s) in the `BUILT_PRODUCTS_DIR`, if appropriate.  There will be one such symlink per build variant.
    func addDynamicLibraryBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ settings: Settings, _ tasks: inout [any PlannedTask]) async
    {
        let scope = settings.globalScope

        // Only add symlink tasks when building API or just building.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let addDynamicLibrarySymlinks = buildComponents.contains("build")

        let shouldUseInstallAPI = ProductPostprocessingTaskProducer.shouldUseInstallAPI(scope, settings)
        // Condensed from LibraryProductTypeSpec.addDynamicLibraryInstallAPITasks(:::::).
        let willProduceTBD = (buildComponents.contains("api") || (addDynamicLibrarySymlinks && scope.evaluate(BuiltinMacros.TAPI_ENABLE_VERIFICATION_MODE)))
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
        for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        {
            if addTBDSymlinks
            {
                await addDynamicLibraryTBDBuiltProductsDirSymlinkTasks(producer, scope, variant, &tasks)
            }
            if addDynamicLibrarySymlinks
            {
                await addStandaloneExecutableBuiltProductsDirSymlinkTasks(producer, scope, variant, &tasks)
            }
        }
    }

    /// Create the task to make the symlink to the TBD in the `BUILT_PRODUCTS_DIR` for a single build variant, if appropriate.
    func addDynamicLibraryTBDBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ variant: String, _ tasks: inout [any PlannedTask]) async
    {
        // Enter the per-variant scope.
        let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)

        let context = producer.context
        // From LibraryProductTypeSpec.addDynamicLibraryInstallAPITasks(:::::).
        guard producer.context.willProduceBinary(scope) else { return }
        let targetWrapper = Path(scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH))
        let relativeTargetWrapper = targetWrapper.relativeSubpath(from: scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR))
        let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(relativeTargetWrapper)

        await producer.appendGeneratedTasks(&tasks)
        { delegate in
            context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: false)
        }
    }
}

private extension StandaloneExecutableProductTypeSpec
{
    /// Create the tasks to make the symlink(s) to the product(s) in the `BUILT_PRODUCTS_DIR`, if appropriate.  There will be one such symlink per build variant.
    func addStandaloneExecutableBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async
    {
        // Only add symlink tasks when building.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

        // Only create the symlink if the target will produce a product.
        guard producer.context.willProduceProduct(scope) else {
            return
        }

        // Add a symlink per-variant.
        for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        {
            await addStandaloneExecutableBuiltProductsDirSymlinkTasks(producer, scope, variant, &tasks)
        }
    }

    /// Create the task to make the symlink to the product in the `BUILT_PRODUCTS_DIR` for a single build variant, if appropriate.
    func addStandaloneExecutableBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ variant: String, _ tasks: inout [any PlannedTask]) async
    {
        // Enter the per-variant scope.
        let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)

        let context = producer.context
        // FIXME: This is in essence the same logic as for wrapped products except for using EXECUTABLE_PATH, just diverged to handle each variant.  We should reconcile, maybe by introducing a generic notion for "why" this is different.
        let targetWrapper = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))
        let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))

        await producer.appendGeneratedTasks(&tasks)
        { delegate in
            context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: false)
        }
    }
}

private extension XCTestBundleProductTypeSpec
{
    func addXCTestBundleBuiltProductsDirSymlinkTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)

        guard BundleProductTypeSpec.validateBuildComponents(buildComponents, scope: scope) else { return }

        let context = producer.context

        // If we are creating a runner app, then we want to create a symlink to the runner in the built products dir.
        if type(of: self).usesXCTRunner(scope) {
            let targetWrapper = scope.unmodifiedTargetBuildDir.join(scope.evaluate(BuiltinMacros.XCTRUNNER_PRODUCT_NAME))
            let builtWrapper = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(scope.evaluate(BuiltinMacros.XCTRUNNER_PRODUCT_NAME))

            await producer.appendGeneratedTasks(&tasks)
            { delegate in
                context.symlinkSpec.constructSymlinkTask(CommandBuildContext(producer: context, scope: scope, inputs: [], output: builtWrapper, preparesForIndexing: true), delegate, toPath: targetWrapper, makeRelative: true, repairViaOwnershipAnalysis: true)
            }
        }
    }
}
