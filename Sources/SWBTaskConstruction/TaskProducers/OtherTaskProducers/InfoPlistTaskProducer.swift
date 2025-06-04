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

/// This task producer is responsible for creating tasks which result in the Info.plist file being produced in its final form and location.
///
///   * Generating the Info.plist file if necessary.
///   * Running the C preprocessor over the Info.plist file if so configured.
///   * Running the Info.plist process if so configured.
///
/// If the Info.plist is to be embedded into a binary, then the final version produced by these tasks will be consumed elsewhere (probably by the linker).
final class InfoPlistTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks = [any PlannedTask]()

        // Ask the product type to generate the relevant Info.plist tasks.
        await context.settings.productType?.addInfoPlistTasks(self, scope, &tasks)

        return tasks
    }
}


// MARK: Product Type Extensions


private extension ProductTypeSpec
{
    /// Add the Info.plist tasks required by the product.
    func addInfoPlistTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async
    {
        // FIXME: We cannot yet use inheritance based mechanisms to implement this.
        switch self
        {
        case let asBundle as BundleProductTypeSpec:
            await asBundle.addBundleInfoPlistTasks(producer, scope, &tasks)
        case let asTool as ToolProductTypeSpec:
            await asTool.addToolInfoPlistTasks(producer, scope, &tasks)
        case let asStandalone as StandaloneExecutableProductTypeSpec:
            let _ = asStandalone
        default:
            if case .some(false) = self.hasInfoPlist {
                break
            }

            fatalError("unknown product type")
        }
    }

    func addCreateEmptyInfoPlistTaskIfNeeded(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        let emptyPlist = scope.infoPlistEmptyPath()
        if emptyPlist == scope.effectiveInputInfoPlistPath() {
            await producer.appendGeneratedTasks(&tasks) { delegate in
                // Unfortunate to have a `try!` here, but this realistically cannot ever fail.
                let emptyPlistBytes = try! ByteString(PropertyListItem.plDict([:]).asBytes(.xml))
                producer.context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: producer.context, scope: scope, inputs: [], output: emptyPlist), delegate, contents: emptyPlistBytes, permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
            }
        }
    }

    func addInfoPlistPreprocessTaskIfNeeded(_ path: Path, basename: String, _ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async -> Path? {
        guard scope.evaluate(BuiltinMacros.INFOPLIST_PREPROCESS) else { return nil }
        let context = producer.context

        let effectiveBasename = basename.isEmpty ? "Info.plist" : basename

        let outputPath = scope.evaluate(BuiltinMacros.TEMP_DIR)
            .join(scope.evaluate(BuiltinMacros.CURRENT_VARIANT))
            .join(scope.evaluate(BuiltinMacros.CURRENT_ARCH))
            .join("Preprocessed-\(effectiveBasename)")

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.CPP_OTHER_PREPROCESSOR_FLAGS:
                return BuiltinMacros.namespace.parseStringList("$(INFOPLIST_OTHER_PREPROCESSOR_FLAGS)")

            case BuiltinMacros.CPP_PREPROCESSOR_DEFINITIONS:
                return BuiltinMacros.namespace.parseStringList("$(INFOPLIST_PREPROCESSOR_DEFINITIONS)")

            case BuiltinMacros.CPP_PREFIX_HEADER:
                return BuiltinMacros.namespace.parseStringList("$(INFOPLIST_PREFIX_HEADER)")

            default:
                return nil
            }
        }

        await producer.appendGeneratedTasks(&tasks) { delegate in
            await context.cppSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: path)], output: outputPath), delegate, specialArgs: [], toolLookup: lookup)
        }
        return outputPath
    }
}

private extension BundleProductTypeSpec
{
    func archForUIRequiredDeviceCapabilities(_ scope: MacroEvaluationScope) -> String?
    {
        // <rdar://problem/20364499> BUILD: Set appropriate build/Info.plist flags for apps building arm64 only
        // <rdar://problem/22810408> Xcode does not include UIRequiredDeviceCapabilities key in an extension of tvOS app

        // Ordered from oldest to newest. The requirement on UIRequiredDeviceCapabilities is that if an app supports multiple archs, only the oldest is marked required, with the assumption that devices with newer archs can execute older ones. This isn't fully generalized or formalized, and is only used for specific circumstances (see conditions below)
        let orderedSupportedArchs = ["arm64", "arm64e"]

        let archs = scope.evaluate(BuiltinMacros.ARCHS)

        // If the app supports any archs outside of our special set, don't require any arch
        guard (archs.allSatisfy { orderedSupportedArchs.contains($0) }) else { return nil }

        // The required arch is the oldest of the bundle's support archs
        let requiredArch = orderedSupportedArchs.first { archs.contains($0) }

        let platform = scope.evaluate(BuiltinMacros.PLATFORM_NAME)
        switch platform {
        case "iphoneos":
            do {
                let iOSVersion = try Version(scope.evaluate(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET))
                return iOSVersion >= Version(8, 0, 0) ? requiredArch : nil
            } catch {
                return requiredArch
            }
        case "appletvos":
            let validIdentifiers = Set([
                "com.apple.product-type.application",
                "com.apple.product-type.tv-app-extension"
            ])

            return validIdentifiers.contains(identifier) ? requiredArch : nil
        default:
            return nil
        }
    }

    func addBundleInfoPlistTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async
    {
        let context = producer.context

        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)

        // Only add Info.plist tasks when building. For the installLoc case, we don't want to generate InfoPlist Tasks
        // when we are installing for a specific language(s) (i.e. INSTALLLOC_LANGUAGE has a value) in order to match the output
        // of Localization projects. When not installing for a specific language(s), generating InfoPlist Tasks is useful
        // for informational and debugging purposes (and it's also in line with historical behavior).
        guard Self.validateBuildComponents(buildComponents, scope: scope) else { return }

        // Process the Info.plist file, if used.
        let infoplistFile = scope.effectiveInputInfoPlistPath()
        let infoplistPath = scope.evaluate(BuiltinMacros.INFOPLIST_PATH)
        // FIXME: Warn about one of these being empty and not the other?
        if !infoplistFile.isEmpty && !infoplistPath.isEmpty {
            let rawPlistPath = context.makeAbsolute(infoplistFile)

            // Create the "empty.plist" file, if needed.
            await addCreateEmptyInfoPlistTaskIfNeeded(producer, scope, &tasks)

            // Determine if we need to create a PkgInfo file.
            let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
            let pkginfoPath = scope.evaluate(BuiltinMacros.PKGINFO_PATH)
            let targetBuildDirPkginfoPath: Path?
            if scope.evaluate(BuiltinMacros.GENERATE_PKGINFO_FILE) && !pkginfoPath.isEmpty && !scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
                targetBuildDirPkginfoPath = targetBuildDir.join(pkginfoPath)
            }  else {
                targetBuildDirPkginfoPath = nil
            }

            let output = targetBuildDir.join(infoplistPath)
            let requiredArch = archForUIRequiredDeviceCapabilities(scope)

            context.addDeferredProducer {
                var tasks = [any PlannedTask]()

                // We're deferring to get generatedInfoPlistContents after it's been populated by other tasks
                let additionalContentFilePaths = producer.context.generatedInfoPlistContents

                // We're deferring to get generatedPrivacyContentFilePaths after it's been populated by other tasks
                let privacyContentFilePaths = producer.context.generatedPrivacyContentFilePaths

                var intermediatePlistPaths = Set<Path>()

                // Create the processed output.  This is done per-variant-per-arch since there may be content in the source which varies based on those factors.  The outputs will be consumed in a merge step which ensures the contents are identical across variations.
                for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
                    let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
                    for arch in scope.evaluate(BuiltinMacros.ARCHS) {
                        let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)

                        // Preprocess the file, if requested.
                        if let preprocessedPlistPath = await self.addInfoPlistPreprocessTaskIfNeeded(rawPlistPath, basename: infoplistPath.basename, producer, scope, &tasks) {
                            intermediatePlistPaths.insert(preprocessedPlistPath)
                        }
                    }
                }

                await producer.appendGeneratedTasks(&tasks) { delegate in
                    let inputPlistPath: Path
                    if !scope.evaluate(BuiltinMacros.INFOPLIST_PREPROCESS) {
                        // If we're not preprocessing the Info.plist, take the original input directly.
                        inputPlistPath = rawPlistPath
                    } else {
                        // If we are preprocessing the Info.plist, "merge" all the inputs, which validates that all are identical. Note that `intermediatePlistPaths` might still be empty at this point (for example if the effective `ARCHS` ended up being an empty set), at which point we'll produce an error message from the merge task.
                        let basename = infoplistPath.basename
                        let effectiveBasename = basename.isEmpty ? "Info.plist" : basename
                        inputPlistPath = scope.evaluate(BuiltinMacros.TEMP_DIR).join("Preprocessed-\(effectiveBasename)")
                        await context.mergeInfoPlistSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: intermediatePlistPaths.sorted().map { FileToBuild(context: context, absolutePath: $0) }, output: inputPlistPath), delegate)
                    }

                    await context.infoPlistSpec.constructInfoPlistTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: inputPlistPath)], output: output), delegate, generatedPkgInfoFile: targetBuildDirPkginfoPath, additionalContentFilePaths: additionalContentFilePaths, requiredArch: requiredArch, appPrivacyContentFiles: privacyContentFilePaths, clientLibrariesForCodelessBundle: producer.context.clientLibrariesForCodelessBundle.map { $0.basename })
                }

                return tasks
            }
        }
    }
}


private extension ToolProductTypeSpec
{
    func addToolInfoPlistTasks(_ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async
    {
        let context = producer.context

        // Only add Info.plist tasks when building.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

        // Check if we are creating an Info.plist section for a tool.
        if scope.evaluate(BuiltinMacros.CREATE_INFOPLIST_SECTION_IN_BINARY)
        {
            // Process the Info.plist file, if used.
            let infoplistFile = scope.effectiveInputInfoPlistPath()
            let infoplistPath = scope.evaluate(BuiltinMacros.INFOPLIST_PATH)
            if !infoplistFile.isEmpty
            {
                let rawPlistPath = context.makeAbsolute(infoplistFile)

                // Create the "empty.plist" file, if needed.
                await addCreateEmptyInfoPlistTaskIfNeeded(producer, scope, &tasks)

                // Create the processed output.  This is done per-variant-per-arch since there may be content in the source which varies based on those factors.  And each such slice of the final tool ends up with a separate final Info.plist embedded in it.
                for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
                {
                    let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
                    for arch in scope.evaluate(BuiltinMacros.ARCHS)
                    {
                        let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)

                        // Preprocess the file, if requested.
                        let preprocessedPlistPath = await addInfoPlistPreprocessTaskIfNeeded(rawPlistPath, basename: infoplistPath.basename, producer, scope, &tasks) ?? rawPlistPath

                        await producer.appendGeneratedTasks(&tasks)
                        { delegate in
                            await context.infoPlistSpec.constructInfoPlistTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: preprocessedPlistPath)], output: scope.evaluate(BuiltinMacros.PROCESSED_INFOPLIST_PATH)), delegate)
                        }
                    }
                }
            }
        }
    }
}

extension TaskProducerContext {
    /// Compute a list of client libraries for a particular codeless bundle.
    fileprivate var clientLibrariesForCodelessBundle: [Path] {
        guard let configuredTarget = configuredTarget else {
            return []
        }

        let scope = self.settings.globalScope
        // If we're skipping App Store deployment work, we also want to skip this.
        if scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT) {
            return []
        }

        // Determine whether this target is actually codeless.
        var willEverProduceBinary = false
        for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
            let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
            willEverProduceBinary = willEverProduceBinary || self.willProduceBinary(scope)
        }
        guard !willEverProduceBinary, let clients = self.globalProductPlan.clientsOfBundlesByTarget[configuredTarget] else {
            return []
        }

        return clients.compactMap {
            let scope = self.globalProductPlan.planRequest.buildRequestContext.getCachedSettings($0.parameters, target: $0.target).globalScope
            // Filter non-library clients.
            let machOType = scope.evaluate(BuiltinMacros.MACH_O_TYPE)
            guard ["mh_bundle", "mh_dylib", "mh_object", "staticlib"].contains(machOType) else {
                return nil
            }
            // Seems a bit odd to manually piece this together here, but I don't know of a better option.
            return Path(scope.evaluate(BuiltinMacros.namespace.parseString("$(EXECUTABLE_FOLDER_PATH)/$(EXECUTABLE_PREFIX)$(PRODUCT_NAME)$(EXECUTABLE_SUFFIX)")))
        }
    }
}
