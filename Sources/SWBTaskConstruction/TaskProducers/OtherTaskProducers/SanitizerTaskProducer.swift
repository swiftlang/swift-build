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

/// The `SanitizerTaskProducer` generates tasks to support the compiler sanitizer features, in particular copying the libraries for the sanitizers into the product for appropriate product types.
final class SanitizerTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return [.immediate, .unsignedProductRequirement]
    }

    private struct Sanitizer {
        let name: String
        let macro: BooleanMacroDeclaration
        let libraryNameInfix: String

        init(name: String, macro: BooleanMacroDeclaration, libraryNameInfix: String) {
            self.name = name
            self.macro = macro
            self.libraryNameInfix = libraryNameInfix
        }

        func libraryName(for sdkVariant: SDKVariant) -> String? {
            guard let clangRuntimeLibraryPlatformName = sdkVariant.clangRuntimeLibraryPlatformName else {
                return nil
            }
            return "libclang_rt.\(libraryNameInfix)_\(clangRuntimeLibraryPlatformName)_dynamic.dylib"
        }

        func errorForMissingLibrary(on platform: Platform?) -> Bool {
            // TSan is not presently available for device platforms.
            return libraryNameInfix != "tsan" || platform?.isSimulator == true || platform?.name == "macosx"
        }

        static let all = [
            Sanitizer(name: "Address", macro: BuiltinMacros.ENABLE_ADDRESS_SANITIZER, libraryNameInfix: "asan"),
            Sanitizer(name: "Thread", macro: BuiltinMacros.ENABLE_THREAD_SANITIZER, libraryNameInfix: "tsan"),
            Sanitizer(name: "Undefined Behavior", macro: BuiltinMacros.ENABLE_UNDEFINED_BEHAVIOR_SANITIZER, libraryNameInfix: "ubsan"),
        ]
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        // Sanitizer tasks are generated only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return [] }

        // Sanitizer tasks are generated only if this product type supports embedding the libraries.
        guard context.settings.productType?.canEmbedCompilerSanitizerLibraries ?? false else { return [] }

        // Determine the macro evaluation scopes to consider when determining whether to embed each sanitizer.
        // For most build actions, consider the subscopes for all build variants, but skip this for the "install"
        // action and only consider the non-variant conditionalized scope. This is because
        // these sanitizer dylibs are much less useful in "install" scenarios since Xcode does not facilitate using them.
        let scopesToConsider: [MacroEvaluationScope]
        if scope.evaluate(BuiltinMacros.ACTION) == "install" {
            scopesToConsider = [scope]
        } else {
            scopesToConsider = scope.evaluate(BuiltinMacros.BUILD_VARIANTS).map { variant -> MacroEvaluationScope in
                return scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
            }
        }

        let sanitizersToEmbed = Sanitizer.all.filter { sanitizer in
            return scopesToConsider.contains(where: { variantSubscope -> Bool in
                return variantSubscope.evaluate(sanitizer.macro)
            })
        }

        var tasks: [any PlannedTask] = []
        await appendGeneratedTasks(&tasks) { delegate in
            // Set up commands for the libraries for each sanitizer in turn.
            for sanitizerToEmbed in sanitizersToEmbed {
                await embedCompilerSanitizerLibrary(sanitizer: sanitizerToEmbed, delegate: delegate, scope: scope)
            }
        }

        return tasks
    }

    private func embedCompilerSanitizerLibrary(sanitizer: Sanitizer, delegate: any TaskGenerationDelegate, scope: MacroEvaluationScope) async {
        let sanitizerName = sanitizer.name

        // Sanitizers 2.0 do not require dylibs to be embedded in the the target path.
        if sanitizerName == "Address" && scope.evaluate(BuiltinMacros.ENABLE_SYSTEM_SANITIZERS) {
            return
        }
        guard let sdkVariant = context.settings.sdkVariant, let libraryName = sanitizer.libraryName(for: sdkVariant) else {
            return
        }

        // The sanitizer libraries are bundled with the clang in the toolchain we're using.  Moreover, there is a separate library for each platform, and it lives in a directory based on the version of the clang in that platform.
        // So, we have to do some path calculations to compute the location of the library.  Fortunately, we can ask the clang specification to be used for the its version.
        guard let clangInfo = try? await context.clangSpec.discoveredCommandLineToolSpecInfo(context, scope, delegate, forLanguageOfFileType: nil), !clangInfo.toolPath.isEmpty else {
            context.error("Could not find path to clang binary to locate \(sanitizerName) Sanitizer library")
            return
        }
        // The build description depends on the clang compiler due to the discovered info.
        access(path: clangInfo.toolPath)
        guard let clangLibDarwinPath = clangInfo.getLibDarwinPath() else {
            context.error("Could not get lib darwin path")
            return
        }

        let libraryPath = clangLibDarwinPath.join(libraryName)
        guard clangLibDarwinPath.isAbsolute else {
            context.error("Unable to copy clang \(sanitizerName) Sanitizer library: Path to it is not an absolute path but is \(libraryPath.str)'")
            return
        }

        guard context.fs.exists(libraryPath) else {
            if sanitizer.errorForMissingLibrary(on: context.settings.platform) {
                context.error("Unable to copy \(sanitizerName) Sanitizer library: Could not determine where it lives." )
            }
            return
        }

        // The path to copy the library to.
        let libraryDstPath = Path(scope.evaluate(scope.namespace.parseString("$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/\(libraryName)")))

        // Create a virtual node to order the copy and code signing tasks.
        let copySanitizerLibraryOrderingNode = delegate.createVirtualNode("Copy \(sanitizerName) Sanitizer library \(libraryDstPath.str)")

        // Copy the library.
        do {
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: libraryPath, inferringTypeUsing: context)], output: libraryDstPath, commandOrderingOutputs: [copySanitizerLibraryOrderingNode])
            await context.copySpec.constructCopyTasks(cbc, delegate, executionDescription: "Copy \(sanitizerName) Sanitizer library", stripUnsignedBinaries: false, stripBitcode: false)
        }

        // Code sign the copied library if appropriate.
        do {
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: libraryDstPath, inferringTypeUsing: context)], commandOrderingInputs: [copySanitizerLibraryOrderingNode])
            context.codesignSpec.constructCodesignTasks(cbc, delegate, productToSign: libraryDstPath, isReSignTask: true)
        }
    }
}
