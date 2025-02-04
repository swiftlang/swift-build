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

final class SwiftStandardLibrariesTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return [.immediate, .unsignedProductRequirement]
    }

    func generateTasks() async -> [any PlannedTask]
    {
        var tasks = [any PlannedTask]()
        let scope = context.settings.globalScope

        // Index build only generates module files, not native binaries.
        guard !scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA) else { return [] }

        // swift-stdlib-tool is run only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return [] }

        // If running this tool is disabled via build setting, then we can abort this task provider.
        guard !scope.evaluate(BuiltinMacros.DONT_RUN_SWIFT_STDLIB_TOOL) else { return [] }

        guard let productType = context.productType else { return [] }

        let currentPlatformFilter = PlatformFilter(scope)

        // Examine the sources build phase to see whether our target contains any Swift files.
        let buildingAnySwiftSourceFiles = (context.configuredTarget?.target as? BuildPhaseTarget)?.sourcesBuildPhase?.containsSwiftSources(context.workspaceContext.workspace, context, scope, context.filePathResolver) ?? false

        // Determine whether we want to embed swift libraries.
        var shouldEmbedSwiftLibraries = (buildingAnySwiftSourceFiles  &&  productType.supportsEmbeddingSwiftStandardLibraries)
        // If ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES then we will override our earlier reasoning if the product is a wrapper.
        if !shouldEmbedSwiftLibraries  &&  scope.evaluate(BuiltinMacros.ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES)
        {
            // If the product is not a wrapper, then we emit a warning that we won't run the tool, and return.
            guard productType.isWrapper else
            {
                context.warning("Not running swift-stdlib-tool: ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES is enabled, but the product type '\(productType.identifier)' is not a wrapper type.")
                return []
            }
            shouldEmbedSwiftLibraries = true
        }

        // Run the swift-stdlib-tool if we've determined that we should do so.
        if shouldEmbedSwiftLibraries
        {
            // Cache fo evaluated build settings we'll need multiple times.
            let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)

            // Construct a list of folders for the tool to scan.  We'll pass this to the SwiftStdlibToolSpec since it doesn't have access to the FrameworksBuildPhase like we do.
            var foldersToScan = [String]()

            // Always scan the product's embedded content directories which may contain other executables.
            // TODO: <rdar://89180738> Consider making this data-driven
            let embeddedContentDirectoryMacros = [
                BuiltinMacros.FRAMEWORKS_FOLDER_PATH,
                BuiltinMacros.PLUGINS_FOLDER_PATH,
                BuiltinMacros.SYSTEM_EXTENSIONS_FOLDER_PATH,
                BuiltinMacros.EXTENSIONS_FOLDER_PATH,
            ]
            foldersToScan.append(contentsOf: embeddedContentDirectoryMacros.compactMap { macro in
                guard let subpath = scope.evaluate(macro).nilIfEmpty else {
                    return nil
                }
                return targetBuildDir.join(subpath).str
            })

            // Add explicit paths to any linked frameworks, even if they are not copied in to the product.
            //
            // This allows EMBEDDED_CONTENT_CONTAINS_SWIFT to be used for things like Objective-C unit test bundles which are testing Swift frameworks.
            if let frameworksBuildPhase = (context.configuredTarget!.target as? BuildPhaseTarget)?.frameworksBuildPhase
            {
                for buildFile in frameworksBuildPhase.buildFiles where currentPlatformFilter.matches(buildFile.platformFilters) {
                    guard let (_, refPath, fileType) = try? context.resolveBuildFileReference(buildFile) else { continue }
                    if refPath.isAbsolute  &&  fileType.conformsTo(context.getSpec("wrapper.framework") as! FileTypeSpec)
                    {
                        foldersToScan.append(refPath.str)
                    }
                }
            }

            let inputPath: Path
            let previewDylib = scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH)
            let previewDylibPath = previewDylib.isEmpty ? nil : targetBuildDir.join(previewDylib)
            inputPath = previewDylibPath ?? targetBuildDir.join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))

            let input = FileToBuild(absolutePath: inputPath, inferringTypeUsing: context)
            let filterForSwiftOS = context.platform?.supportsSwiftInTheOS(scope) == true

            // For Xcode's that do not yet know about Swift Concurrency, this will return `nil`. In those cases, we also do not pass the flag.
            let supportsConcurrencyNatively = context.platform?.supportsSwiftConcurrencyNatively(scope)
            let backDeploySwiftConcurrency = supportsConcurrencyNatively != nil && supportsConcurrencyNatively != true

            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [ input ])
            let foldersToScanExpr: MacroStringListExpression? = foldersToScan.count > 0 ? scope.namespace.parseLiteralStringList(foldersToScan): nil
            await appendGeneratedTasks(&tasks) { delegate in
                await context.swiftStdlibToolSpec.constructSwiftStdLibraryToolTask(cbc, delegate, foldersToScan: foldersToScanExpr, filterForSwiftOS: filterForSwiftOS, backDeploySwiftConcurrency: backDeploySwiftConcurrency)
            }
        }

        return tasks
    }
}
