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

/// Producer for VerifyModule tasks
final class ModuleVerifierTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        var enable = shouldRunModuleVerifier()
        guard enable.builtin || enable.external else {
            return []
        }

        var tasks: [any PlannedTask] = []

        // The module verifier can't use header maps because it wants to test the built framework independent of
        // anything in SRCROOT. However, Xcode expects the diagnostics to refer to SRCROOT files, so the module
        // verifier requires a special mapping file to comply.
        let mappingFileBytes: ByteString
        do {
            mappingFileBytes = try await diagnosticFilenameMapContents()
        } catch {
            context.error("\(error)")
            return []
        }
        let scope = context.settings.globalScope
        let fileNameMapPath = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join(scope.evaluate(BuiltinMacros.PRODUCT_NAME) + "-diagnostic-filename-map.json")

        await appendGeneratedTasks(&tasks, usePhasedOrdering: false, options: .immediate) { delegate in
            let buildContext = CommandBuildContext(producer: context, scope: scope, inputs: [], output: fileNameMapPath)
            context.writeFileSpec.constructFileTasks(buildContext, delegate, contents: mappingFileBytes, permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        context.addDeferredProducer {
            // Don't run the module verifier unless the module has changed, that is the framework's headers or
            // module maps changed. That would be anything in Target.framework/{Headers,Modules,PrivateHeaders}.
            // The way to communicate that to the task system is by setting those as inputs, even though they
            // won't be passed directly to the module verifier tool. Directories don't work however, the task
            // system only supports files, so collect all of the files that will be output to Headers/Modules/
            // PrivateHeaders. The output files are needed rather than the source files so that the module
            // verifier task waits for the output files to be produced.
            var orderingInputs = self.collectModuleAffectingFiles()

            // The shell script virtual outputs represent Run Script build phases that don't have output files.
            // Those might affect the module, so the module verifier task needs to wait for them to run.
            let shellScriptVirtualOutputs = self.context.shellScriptVirtualOutputs()
            orderingInputs += shellScriptVirtualOutputs

            // The mapping file doesn't affect the module, but still needs to be an input so that the module
            // verifier task waits for it to be produced too.
            let inputs = [FileToBuild(context: self.context, absolutePath: fileNameMapPath)]

            var deferredTasks: [any PlannedTask] = []
            if enable.builtin {
                (deferredTasks, enable.external) = await self.generateBuiltinModuleVerifierTasks(inputs: inputs, commandOrderingInputs: orderingInputs, fileNameMapPath: fileNameMapPath, alwaysExecuteTask: !shellScriptVirtualOutputs.isEmpty)
            }
            if enable.external {
                let externalTasks = await self.generateExternalModuleVerifierTasks(inputs: inputs, commandOrderingInputs: orderingInputs, fileNameMapPath: fileNameMapPath, alwaysExecuteTask: !shellScriptVirtualOutputs.isEmpty)
                deferredTasks.append(contentsOf: externalTasks)
            }
            return deferredTasks
        }

        return tasks
    }

    private func generateExternalModuleVerifierTasks(inputs: [FileToBuild], commandOrderingInputs: [any PlannedNode], fileNameMapPath: Path, alwaysExecuteTask: Bool) async -> [any PlannedTask] {
        var deferredTasks: [any PlannedTask] = []
        await appendGeneratedTasks(&deferredTasks, usePhasedOrdering: false, options: .compilation) { delegate in
            let scope = context.settings.globalScope
            let orderingOutput = self.context.createVirtualNode("verify-module-" + (self.context.configuredTarget?.guid.stringValue ?? "global"))
            let buildContext = CommandBuildContext(producer: context, scope: scope, inputs: inputs, commandOrderingInputs: commandOrderingInputs, commandOrderingOutputs: [orderingOutput])
            // Run unconditionally if there are Run Script build phases that don't have output files. Those
            // could change the module even if none of the other inputs have changed.
            await context.modulesVerifierSpec.constructModuleVerifierTasks(buildContext, delegate, alwaysExecuteTask: alwaysExecuteTask, fileNameMapPath: fileNameMapPath)
        }
        return deferredTasks
    }

    private struct BuiltinModuleVerifierInputs {
        var main: Path
        var header: Path
        var moduleMap: Path
        var dir: Path
    }

    private func generateBuiltinModuleVerifierTasks(inputs: [FileToBuild], commandOrderingInputs: [any PlannedNode], fileNameMapPath: Path, alwaysExecuteTask: Bool) async -> ([any PlannedTask], fallbackToExternal: Bool) {
        let scope = context.settings.globalScope

        let languages = scope.evaluate(BuiltinMacros.MODULE_VERIFIER_SUPPORTED_LANGUAGES).compactMap { name in
            if let language = ModuleVerifierLanguage(rawValue: name) {
                return language
            }
            self.targetContext.warning("Unsupported module verifier language \"\(name)\"", location: .buildSettings(names: ["MODULE_VERIFIER_SUPPORTED_LANGUAGES"]))
            return nil
        }

        let targetArchs = scope.evaluate(BuiltinMacros.MODULE_VERIFIER_TARGET_TRIPLE_ARCHS)
        let targetVariants = scope.evaluate(BuiltinMacros.MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS)
        let targets = targetArchs.map { arch in scope.evaluate(scope.namespace.parseString("\(arch)-$(LLVM_TARGET_TRIPLE_VENDOR)-$(LLVM_TARGET_TRIPLE_OS_VERSION)$(LLVM_TARGET_TRIPLE_SUFFIX)")) }

        var languageStandardStrings = scope.evaluate(BuiltinMacros.MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS)
        if languageStandardStrings.isEmpty {
            // FIXME: we should just set a default in the xcspec, but the existing modules-verifier allows an empty set of standards to mean the default.
            languageStandardStrings = ["gnu17", "gnu++20"]
        }

        let languageStandards = languageStandardStrings.compactMap { name in
            if let standard = ModuleVerifierLanguage.Standard(rawValue: name) {
                return standard
            }
            self.targetContext.warning("Unsupported module verifier language standard \"\(name)\"", location: .buildSettings(names: ["MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS"]))
            return nil
        }

        let targetSets = ModuleVerifierTargetSet.combinations(languages: languages, targets: targets, targetVariants: targetVariants, standards: languageStandards)

        var fallbackToExternal = false
        var deferredTasks: [any PlannedTask] = []
        await self.appendGeneratedTasks(&deferredTasks, usePhasedOrdering: false, options: .compilation) { delegate in
            let targetDiagnostics = ModuleVerifierTargetSet.verifyTargets(targets: targets, targetVariants: targetVariants)
                                  + ModuleVerifierTargetSet.verifyLanguages(languages: languages, standards: languageStandards)
            var failed = false
            for diag in targetDiagnostics {
                delegate.diagnosticsEngine.emit(diag)
                if diag.behavior == .error {
                    failed = true
                }
            }
            if failed {
                return
            }

            do {
                let clangInfo = try await self.context.clangSpec.discoveredCommandLineToolSpecInfo(self.context, scope, delegate, forLanguageOfFileType: nil)
                if clangInfo?.toolFeatures.has(.wSystemHeadersInModule) != true {
                    delegate.warning("Builtin clang module verifier requires a compiler that supports -Wsystem-headers-in-module=; falling back to external module verifier")
                    fallbackToExternal = true
                    return
                }
            } catch {
                delegate.error(error)
                return
            }

            var inputsByLanguage: [ModuleVerifierLanguage: BuiltinModuleVerifierInputs] = [:]
            for language in languages {
                let fileExtension: String = language.preferredSourceFilenameExtension
                let outputPath = Path(scope.evaluate(scope.namespace.parseString("$(TARGET_TEMP_DIR)/VerifyModule/$(PRODUCT_NAME)/\(language.rawValue)")))
                let outputs = BuiltinModuleVerifierInputs(
                    main: outputPath.join("Test.\(fileExtension)"),
                    header: outputPath.join("Test.framework/Headers/Test.h"),
                    moduleMap: outputPath.join("Test.framework/Modules/module.modulemap"),
                    dir: outputPath)
                inputsByLanguage[language] = outputs
                let inputContext = CommandBuildContext(producer: self.context, scope: scope, inputs: inputs, commandOrderingInputs: commandOrderingInputs)
                await self.context.clangModuleVerifierInputGeneratorSpec.constructTasks(inputContext, delegate, alwaysExecuteTask: alwaysExecuteTask, language: language.rawValue, mainOutput: outputs.main, headerOutput: outputs.header, moduleMapOutput: outputs.moduleMap)
            }

            let productName = scope.evaluate(BuiltinMacros.PRODUCT_NAME)
            let enableLSVs = scope.evaluate(BuiltinMacros.MODULE_VERIFIER_LSV) ? [false, true] : [false]

            for targetSet in targetSets {
                for enableLSV in enableLSVs {
                    guard let inputs = inputsByLanguage[targetSet.language] else {
                        fatalError("mismatch between input languages; missing \(targetSet.language)")
                    }
                    await generateClangModuleVerifierTask(targetSet: targetSet, enableLSV: enableLSV, productName: productName, inputs: inputs, commandOrderingInputs: commandOrderingInputs, fileNameMapPath: fileNameMapPath, delegate: delegate)
                }
            }
        }
        return (deferredTasks, fallbackToExternal)
    }

    private func generateClangModuleVerifierTask(targetSet: ModuleVerifierTargetSet, enableLSV: Bool, productName: String, inputs: BuiltinModuleVerifierInputs, commandOrderingInputs: [any PlannedNode], fileNameMapPath: Path, delegate: any TaskGenerationDelegate) async {
        let scope = context.settings.globalScope
        let workspaceScope = self.context.globalProductPlan.getWorkspaceSettings().globalScope

        let outputPath = Path(scope.evaluate(scope.namespace.parseString("$(TARGET_TEMP_DIR)/VerifyModule/$(PRODUCT_NAME)/\(targetSet.pathComponent)\(enableLSV ? "-lsv" : "")")))

        var table = MacroValueAssignmentTable(namespace: workspaceScope.namespace)
        func passthrough(_ macro: StringMacroDeclaration) {
            table.push(macro, literal: scope.evaluate(macro))
        }
        func passthrough(_ macro: BooleanMacroDeclaration) {
            table.push(macro, literal: scope.evaluate(macro))
        }
        func passthrough<T>(_ macro: EnumMacroDeclaration<T>) {
            table.push(macro, literal: scope.evaluate(macro))
        }
        func passthrough(_ macro: PathMacroDeclaration) {
            table.push(macro, literal: scope.evaluate(macro).str)
        }

        table.pushContentsOf(workspaceScope.table)

        if let sdk = self.context.sdk {
            if let defaultSettingsTable = sdk.defaultSettingsTable {
                table.pushContentsOf(defaultSettingsTable)
            }
            if let overrideSettingsTable = sdk.overrideSettingsTable {
                table.pushContentsOf(overrideSettingsTable)
            }
            // Infer macabi target environment -> iosmac variant for Catalyst; otherwise use the default variant.
            let sdkVariant = targetSet.targetVariant?.environment == "macabi" ? sdk.variant(for: "iosmac") : sdk.variant(for: scope.evaluate(BuiltinMacros.SDK_VARIANT)) ?? sdk.defaultVariant
            if let sdkVariant = sdkVariant, let variantTable = sdkVariant.settingsTable {
                table.pushContentsOf(variantTable)
            }
        }

        let otherVerifierFlags = scope.evaluate(BuiltinMacros.OTHER_MODULE_VERIFIER_FLAGS)

        if !otherVerifierFlags.isEmpty && otherVerifierFlags.first != "--" {
            let toolFlags = otherVerifierFlags.prefix(while: { $0 != "--" })
            self.context.warning("ignoring OTHER_MODULE_VERIFIER_FLAGS that are not for the compiler '\(toolFlags.joined(separator: " "))'")
        }

        var otherCFlags = workspaceScope.evaluate(BuiltinMacros.OTHER_CFLAGS)
        otherCFlags += [
            "-Wsystem-headers-in-module=\(productName)",
            "-Wsystem-headers-in-module=\(productName)_Private",
            "-Werror=non-modular-include-in-module",
            "-Werror=non-modular-include-in-framework-module",
            "-Werror=incomplete-umbrella",
            "-Werror=quoted-include-in-framework-header",
            "-Werror=atimport-in-framework-header",
            "-Werror=framework-include-private-from-public",
            "-Werror=incomplete-framework-module-declaration",
            "-Wundef-prefix=TARGET_OS",
            "-Werror=undef-prefix",
            "-Werror=module-import-in-extern-c",
            "-ferror-limit=0",
        ]

        otherCFlags += otherVerifierFlags.drop(while: { $0 != "--" }).dropFirst()
        var otherCPlusPlusFlags = workspaceScope.evaluate(BuiltinMacros.OTHER_CPLUSPLUSFLAGS)
        otherCPlusPlusFlags += [
            "-fcxx-modules",
        ]
        otherCPlusPlusFlags += otherCFlags

        table.push(BuiltinMacros.CLANG_ENABLE_MODULES, literal: true)
        table.push(BuiltinMacros.CLANG_ENABLE_OBJC_ARC, literal: true)
        table.push(BuiltinMacros.USE_HEADERMAP, literal: false)
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS, literal: false)
        table.push(BuiltinMacros.GCC_C_LANGUAGE_STANDARD, literal: targetSet.standard.rawValue)
        table.push(BuiltinMacros.CLANG_CXX_LANGUAGE_STANDARD, literal: targetSet.standard.rawValue)
        table.push(BuiltinMacros.FRAMEWORK_SEARCH_PATHS, table.namespace.parseStringList("$(inherited) $(BUILT_PRODUCTS_DIR) '\(inputs.dir.str)'"))
        table.push(BuiltinMacros.OTHER_CFLAGS, literal: otherCFlags)
        table.push(BuiltinMacros.OTHER_CPLUSPLUSFLAGS, literal: otherCPlusPlusFlags)
        table.push(BuiltinMacros.CURRENT_ARCH, literal: targetSet.target.architecture!)
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, literal: outputPath.str)
        if let targetVariant = targetSet.targetVariant {
            table.push(BuiltinMacros.CLANG_TARGET_TRIPLE_VARIANTS, literal: [targetVariant.value])
        }
        passthrough(BuiltinMacros.CC)
        passthrough(BuiltinMacros.CLANG_EXPLICIT_MODULES_LIBCLANG_PATH)
        passthrough(BuiltinMacros.SDKROOT)
        passthrough(BuiltinMacros.BUILT_PRODUCTS_DIR)
        passthrough(BuiltinMacros.PRODUCT_NAME)
        passthrough(BuiltinMacros.FULL_PRODUCT_NAME)
        if let vendor = targetSet.target.vendor {
            table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_VENDOR, literal: vendor)
        } else {
            passthrough(BuiltinMacros.LLVM_TARGET_TRIPLE_VENDOR)
        }
        if let osAndVersion = targetSet.target.osAndVersion {
            table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_OS_VERSION, literal: osAndVersion)
        } else {
            passthrough(BuiltinMacros.LLVM_TARGET_TRIPLE_OS_VERSION)
        }
        if let environment = targetSet.target.environment {
            table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX, literal: "-\(environment)")
        } else {
            passthrough(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX)
        }
        passthrough(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES)
        passthrough(BuiltinMacros._EXPERIMENTAL_CLANG_EXPLICIT_MODULES)
        passthrough(BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE)
        passthrough(BuiltinMacros.COMPILATION_CACHE_CAS_PATH)
        passthrough(BuiltinMacros.SDK_STAT_CACHE_PATH)
        passthrough(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA) // Needed by clang explicit modules
        passthrough(BuiltinMacros.CLANG_EXPLICIT_MODULES_OUTPUT_PATH)
        passthrough(BuiltinMacros.CLANG_USE_RESPONSE_FILE)
        table.push(BuiltinMacros.CLANG_MODULE_LSV, literal: enableLSV)

        // Module cache: with explicit modules we have a strict context hash that ensures correctness. For implicit modules create a separate cache for each target to prevent cache-correctness issues from leaking into validation. This matches the external modules-verifier tool, which always creates a separate cache.
        if scope.evaluate(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES) || scope.evaluate(BuiltinMacros._EXPERIMENTAL_CLANG_EXPLICIT_MODULES) {
            passthrough(BuiltinMacros.MODULE_CACHE_DIR)
        } else {
            let cachePath = Path(scope.evaluate(scope.namespace.parseString("$(TARGET_TEMP_DIR)/VerifyModule/$(PRODUCT_NAME)/cache")))
            table.push(BuiltinMacros.MODULE_CACHE_DIR, literal: cachePath.str)
        }

        let buildScope = MacroEvaluationScope(table: table)

        let buildInputs = [
            FileToBuild(context: self.context, absolutePath: inputs.main),
        ]
        let buildOrderingInputs = commandOrderingInputs + [
            delegate.createNode(fileNameMapPath),
            delegate.createNode(inputs.header),
            delegate.createNode(inputs.moduleMap),
        ]
        let buildContext = CommandBuildContext(producer: self.context, scope: buildScope, inputs: buildInputs, commandOrderingInputs: buildOrderingInputs)

        await self.context.clangModuleVerifierSpec.constructTasks(buildContext, delegate)
    }

    private func shouldRunModuleVerifier() -> (builtin: Bool, external: Bool) {
        let scope = context.settings.globalScope
        guard SWBFeatureFlag.enableModuleVerifierTool.value ?? scope.evaluate(BuiltinMacros.ENABLE_MODULE_VERIFIER) else {
            return (false, false)
        }

        // The module verifier tool only supports frameworks.
        guard context.settings.productType is FrameworkProductTypeSpec else {
            return (false, false)
        }

        // Some compiler generated headers (e.g. Iig) are only produced for build, so the module
        // might not be complete until then. Also module verification is relatively expensive
        // compared to headers and even api, so wait for build.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else {
            return (false, false)
        }

        // Only support running the module verifier if we have some knowledge of the module maps.
        guard context.moduleInfo != nil else {
            return (false, false)
        }

        switch scope.evaluate(BuiltinMacros.MODULE_VERIFIER_KIND) {
        case .builtin:
            return (builtin: true, external: false)
        case .external:
            return (builtin: false, external: true)
        case .both:
            return (builtin: true, external: true)
        }
    }

    private func collectModuleAffectingFiles() -> [any PlannedNode] {
        // Most tasks output their module affecting files into $(PUBLIC_HEADERS_FOLDER_PATH)/
        // $(PRIVATE_HEADERS_FOLDER_PATH)/$(MODULES_FOLDER_PATH in $(TARGET_BUILD_DIR). However
        // it can get a little more complicated with Copy File and Run Script build phases.
        // The typical way Copy File build phases affect modules is when they copy headers into
        // subdirectories on Headers/PrivateHeaders. Xcode's UI doesn't have Headers/PrivateHeaders
        // in its Destination pop up, so people have to get creative. Ultimately they need
        // $(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/Subdirectory. The two most obvious
        // ways in Xcode are
        // 1. "Products Directory" + $(PUBLIC_HEADERS_FOLDER_PATH)/Subdirectory
        // 2. "Wrapper" + Versions/A/Headers/Subdirectory
        // The first one is technically wrong since "Products Directory" = BUILT_PRODUCTS_DIR, but
        // $(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME) is a symlink to $(TARGET_BUILD_DIR)/$(WRAPPER_NAME)
        // so it ends up working in practice. The second one is the only real way to do it, but
        // it's unfortunate that PUBLIC_HEADERS_FOLDER_PATH can't be used. As such, people end up
        // using the top level Headers or Versions/Current symlinks too. Run Script build phases have
        // complete flexibility and can use the above combinations and more. Try to put together the
        // most typical paths to Headers/PrivateHeaders, and also Modules, in an effort to catch the
        // output files that will affect the module.

        // Start by collecting TARGET_BUILD_DIR and BUILT_PRODUCTS_DIR.
        let settings = context.settings
        let scope = settings.globalScope
        var rootDirectories: [Path] = []
        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        rootDirectories.append(targetBuildDir)
        let builtProductsDir = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
        if builtProductsDir != targetBuildDir {
            rootDirectories.append(builtProductsDir)
        }

        // If we have a deep bundle then we need to add the top level symlink path and the
        // Versions/Current symlink path.
        let symlinkPaths: [Path]
        if scope.evaluate(BuiltinMacros.SHALLOW_BUNDLE) {
            symlinkPaths = []
        } else {
            let wrapperName = scope.evaluate(BuiltinMacros.WRAPPER_NAME)
            let versionsFolder = scope.evaluate(BuiltinMacros.VERSIONS_FOLDER_PATH)
            let currentVersion = versionsFolder.join(scope.evaluate(BuiltinMacros.CURRENT_VERSION), preserveRoot: true)
            symlinkPaths = [wrapperName, currentVersion]
        }

        // Now join the variations of the module affecting directories to the root paths.
        var fileTypesForDirectories: [Path: [FileTypeSpec]] = [:]
        func addPaths(for macro: PathMacroDeclaration, joinedTo rootPath: Path, fileTypes: [FileTypeSpec]) {
            let macroPath = scope.evaluate(macro)

            // Add the real path.
            fileTypesForDirectories[rootPath.join(macroPath, preserveRoot: true)] = fileTypes

            // And the symlink paths.
            if !symlinkPaths.isEmpty {
                let macroPathBasename = macroPath.basename
                for symlinkPath in symlinkPaths {
                    let directory = rootPath.join(symlinkPath, preserveRoot: true).join(macroPathBasename)
                    fileTypesForDirectories[directory] = fileTypes
                }
            }
        }

        let specRegistry = context.workspaceContext.core.specRegistry
        let headerFileTypes = specRegistry.headerFileTypes
        let moduleAffectingCombinations = [(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH, headerFileTypes),
                                           (BuiltinMacros.PRIVATE_HEADERS_FOLDER_PATH, headerFileTypes),
                                           (BuiltinMacros.MODULES_FOLDER_PATH, [specRegistry.modulemapFileType])]
        for (macro, fileTypes) in moduleAffectingCombinations {
            for rootDirectory in rootDirectories {
                addPaths(for: macro, joinedTo: rootDirectory, fileTypes: fileTypes)
            }
        }

        // Now we have the complete set of directory paths that can affect the module. Use it
        // to filter the module affecting files in the output context.
        var moduleAffectingFiles: [any PlannedNode] = []
        for outputNode in context.outputsOfMainTaskProducers {
            let path = outputNode.path
            for (directory, fileTypes) in fileTypesForDirectories {
                if directory.isAncestorOrEqual(of: path) {
                    if let fileType = context.lookupFileType(fileName: path.basename), fileType.conformsToAny(fileTypes) {
                        moduleAffectingFiles.append(outputNode)
                    }
                    continue
                }
            }
        }
        return moduleAffectingFiles
    }
}

extension ModuleVerifierTargetSet {
    var pathComponent: String {
        "\(self.language.rawValue)-\(self.standard.rawValue)-\(self.target.value)-\(self.targetVariant?.value ?? "none")"
    }
}
