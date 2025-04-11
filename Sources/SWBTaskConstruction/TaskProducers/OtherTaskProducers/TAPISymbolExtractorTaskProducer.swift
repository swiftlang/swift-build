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
import class SWBCore.DocumentationCompilerSpec
import SWBMacro
import SWBProtocol
import Foundation

/// A task producer that constructs TAPI Symbol Extraction tasks.
///
/// This task producer exists to support building documentation for C and Objective-C code where we need information about a target's headers, which isn't available when a spec constructs its tasks.
final class TAPISymbolExtractorTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        // The target needs to finish copying headers.
        return .blockedByTargetHeaders
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        let cbcWithoutInputs = CommandBuildContext(producer: context, scope: scope, inputs: [], outputs: [])
        guard DocumentationCompilerSpec.shouldConstructSymbolGenerationTask(cbcWithoutInputs) else {
            // Only generate symbol extraction tasks if documentation compilation tasks will also run.
            return []
        }

        if scope.evaluate(BuiltinMacros.DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS) && !scope.evaluate(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER) {
            // These settings are contradictory. We raise the warning here — instead of where they are checked — to avoid duplicate warnings.
            context.warning("Multi-language documentation for Swift code (DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS=YES) has no effect when the Objective-C compatibility header isn't installed (SWIFT_INSTALL_OBJC_HEADER=NO)")
        }

        // The TAPI symbol extraction consist of 3 steps, that each result in one task or one task per architecture:
        //
        // First, find all the header files, grouped by visibility, and write that to a file.
        // Second, pass the file with the header info to `tapi extractapi` to extract symbol information as a SDKSB file.
        // Third, convert the SDKDB file to a Symbol Graph file.
        //
        // The first is planned in `TAPISymbolExtractorTaskProducer`. The other two are planned in `TAPISymbolExtractor`
        var tasks: [any PlannedTask] = []

        let documentationHeaderInfo = await TAPISymbolExtractor.headerFilesToExtractDocumentationFor(cbcWithoutInputs)

        var commandOrderingInputs: [any PlannedNode] = []
        // No task is planned if the `targetHeaderInfo` is empty or `nil`.
        let isFramework = context.productType?.conformsTo(identifier: "com.apple.product-type.framework") ?? false

        guard let (headerList, inputNodes) = computeHeadersInputList(documentationHeaderInfo, isFramework: isFramework, producer: self, scope: scope) else {
            // Abort if we could not figure out the input files for the ExtractAPI operation.
            return tasks
        }

        let archSpecificSubScopes = scope.evaluate(BuiltinMacros.ARCHS).map { arch in
            return scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
        }

        // For Objective-C targets that `@import` their dependencies we need to know the locations of the module maps for those targets.
        // This search needs to be done recursively since, for example with SwiftPM the target will depend on the PACKAGE:PRODUCT target
        // which in turn depends on the PACKAGE:TARGET target that generates the module map.
        var dependenciesModuleMaps = OrderedSet<Path>()
        if let configuredTarget = context.configuredTarget {
            let currentPlatformFilter = PlatformFilter(scope)
            var remainingDependenciesToProcess = configuredTarget.target.dependencies[...]
            var encounteredDependencies = Set(remainingDependenciesToProcess.map { $0.guid })
            while let dependency = remainingDependenciesToProcess.popFirst() {
                if currentPlatformFilter.matches(dependency.platformFilters),
                   let dependencyTarget = context.workspaceContext.workspace.dynamicTarget(for: dependency.guid, dynamicallyBuildingTargets: context.globalProductPlan.dynamicallyBuildingTargets)
                {
                    // Find the right build parameters for each dependency
                    let dependencyParameters: BuildParameters
                    if let otherConfiguredTarget = context.globalProductPlan.planRequest.buildGraph.dependencies(of: configuredTarget).first(where: { $0.target.guid == dependencyTarget.guid }) {
                        dependencyParameters = otherConfiguredTarget.parameters
                    } else {
                        dependencyParameters = context.globalProductPlan.planRequest.buildGraph.buildRequest.buildTargets.first(where: { $0.target.guid == dependencyTarget.guid })?.parameters ?? configuredTarget.parameters
                    }

                    let settings = context.settingsForProductReferenceTarget(dependencyTarget, parameters: dependencyParameters)
                    let dependencyConfiguredTarget = ConfiguredTarget(parameters: dependencyParameters, target: dependencyTarget)

                    if let moduleInfo = context.globalProductPlan.getModuleInfo(dependencyConfiguredTarget) {
                        dependenciesModuleMaps.append(moduleInfo.moduleMapPaths.builtPath)
                    } else if let moduleMapPath = settings.globalScope.evaluate(BuiltinMacros.MODULEMAP_PATH).nilIfEmpty {
                        dependenciesModuleMaps.append(Path(moduleMapPath))
                    }

                    let newDependencies = dependencyConfiguredTarget.target.dependencies.filter { !encounteredDependencies.contains($0.guid) }
                    encounteredDependencies.formUnion(newDependencies.map { $0.guid} )
                    remainingDependenciesToProcess.append(contentsOf: newDependencies)
                }
            }
        }

        commandOrderingInputs += inputNodes

        if SWBFeatureFlag.enableClangExtractAPI.value {
            await appendGeneratedTasks(&tasks) { delegate in
                for scope in archSpecificSubScopes {
                    // The spec will compute the task's outputs, even if they're not listed in the context.
                    let cbc = CommandBuildContext(
                        producer: context,
                        scope: scope,
                        inputs: inputNodes.map { FileToBuild(context: context, absolutePath: $0.path) },
                        outputs: []
                    )
                    let swiftCompilerInfo = await context.swiftCompilerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
                    let clangCompilerInfo = await context.clangSpec.discoveredCommandLineToolSpecInfo(cbc.producer, context.settings.globalScope, delegate)
                    await context.tapiSymbolExtractor?.constructTasksForClang(
                        cbc,
                        delegate,
                        headerList: headerList,
                        dependenciesModuleMaps: dependenciesModuleMaps.elements,
                        swiftCompilerInfo: swiftCompilerInfo,
                        clangCompilerInfo: clangCompilerInfo
                    )
                }

                // Generate Swift symbol extraction tasks (for Objective-C only code) for all architectures.
                // The spec won't construct any tasks if this target already builds Swift code.
                for scope in archSpecificSubScopes {
                    // The spec will compute the task's inputs and outputs, even if they're not listed in the context.
                    let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [], outputs: [], commandOrderingInputs: commandOrderingInputs)
                    await context.swiftSymbolExtractor?.constructTasks(cbc, delegate)
                }
            }
        } else {
            let tapiInfo = await context.tapiSymbolExtractor?.discoveredCommandLineToolSpecInfo(context, scope, context.globalProductPlan.delegate)

            guard let jsonPath = await addFileListExtractAPITasks(headers: headerList, producer: self, tapiInfo: tapiInfo as? DiscoveredTAPIToolSpecInfo, scope: scope, tasks: &tasks) else {
                // No point continuing if we can not figure out the paths for TAPI's input file list.
                return tasks
            }

            let inputs = [FileToBuild(context: context, absolutePath: jsonPath)]

            await appendGeneratedTasks(&tasks) { delegate in
                // Generate Objective-C symbol extraction tasks for all architectures
                for scope in archSpecificSubScopes {
                    // The spec will compute the task's outputs, even if they're not listed in the context.
                    let cbc = CommandBuildContext(producer: context, scope: scope, inputs: inputs, outputs: [], commandOrderingInputs: commandOrderingInputs)
                    await context.tapiSymbolExtractor?.constructTasksForTAPI(cbc, delegate, dependenciesModuleMaps: dependenciesModuleMaps.elements)
                }

                // Generate Swift symbol extraction tasks (for Objective-C only code) for all architectures.
                // The spec won't construct any tasks if this target already builds Swift code.
                for scope in archSpecificSubScopes {
                    // The spec will compute the task's inputs and outputs, even if they're not listed in the context.
                    let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [], outputs: [], commandOrderingInputs: commandOrderingInputs)
                    await context.swiftSymbolExtractor?.constructTasks(cbc, delegate)
                }
            }
        }

        return tasks
    }

    func computeHeadersInputList(
        _ documentationHeaderInfo: TAPISymbolExtractor.DocumentationHeaderInfo,
        isFramework: Bool,
        producer: PhasedTaskProducer,
        scope: MacroEvaluationScope
    ) -> ([TAPIFileList.HeaderInfo], [any PlannedNode])? {
        // This code is taken from the 'TAPITools.swift' but there are some differences, mainly:
        //
        //  - Since this isn't a post processing task producer, it doesn't have access to the `uniqueAuxiliaryFilePaths`.
        //  - It doesn't ignore public/private headers for frameworks.
        //  - It doesn't plan any tasks if there are no headers.
        //  - It moves the umbrella header first in the header list.
        //  - It skips headers that are excluded or platform filtered out.

        let headerDestPaths = TargetHeaderInfo.builtProductDestDirs(scope: scope, workingDirectory: producer.targetContext.defaultWorkingDirectory)
        // Keep track of the input nodes for dependency tracking
        var inputNodes = [any PlannedNode]()
        var headerList: [TAPIFileList.HeaderInfo] = { [headerBuildFiles = documentationHeaderInfo.headerBuildFiles] in
            let buildFilesContext = BuildFilesProcessingContext(scope)

            func computeProductHeader(for fileRef: SWBCore.FileReference, isFramework: Bool, visibility: TAPIFileList.HeaderVisibility, inputNodes: inout [any PlannedNode]) -> TAPIFileList.HeaderInfo? {
                // The JSON file should have the product headers, not the source headers, so we need to compute the output path.
                // FIXME: We should be able to get this info from - or at least share it with - the HeadersTaskProducer.
                let path = producer.context.settings.filePathResolver.resolveAbsolutePath(fileRef)

                let language: String?
                if let languageDialect = producer.context.lookupFileType(reference: fileRef)?.languageDialect, GCCCompatibleLanguageDialect.allCLanguages.contains(languageDialect) {
                    language = languageDialect.dialectNameForCompilerCommandLineArgument
                } else {
                    language = nil
                }

                // If this header is among the target's header build files we check if it has any platform filters.
                // If this header is generated then it won't have any platform filters.
                let platformFilters = headerBuildFiles.filter({
                    if let resolvedFile = try? producer.context.resolveBuildFileReference($0) {
                        return resolvedFile.absolutePath == path
                    }
                    return false
                }).only?.platformFilters ?? []

                // Skip the header if it is excluded or filtered out.
                guard !buildFilesContext.isExcluded(path, filters: platformFilters) else {
                    return nil
                }

                // FIXME: headerDestPaths should only be used for framework targets when determining outputPath
                // until rdar://81762676 (Dylib targets inconsistently writes headers to BUILD_PRODUCTS_DIR
                // based install vs normal build) has been resolved.
                let outputPath : Path
                switch visibility {
                case .public:
                    outputPath = isFramework ? headerDestPaths.publicPath.join(path.basename) : TargetHeaderInfo.outputPath(for: path, visibility: .public, scope: scope)
                case .private:
                    outputPath = isFramework ? headerDestPaths.privatePath.join(path.basename) : TargetHeaderInfo.outputPath(for: path, visibility: .private, scope: scope)
                case .project:
                    outputPath = path
                }

                // The framework specific code path incorrectly truncates the header directory paths which results in test failures because of a mismatch of expected inputs.
                // rdar://84523763 (TAPI file list & VFS overlay unnecessarily truncate paths)
                //
                // That code path exist to workaround a different issue where the header directory paths are different in install builds (compared to regular builds).
                //
                // Since the "file list" file and the VFS overlay needs to use the same file paths, we use the truncated paths in the "file list" but recompute the paths
                // without the truncation for the command ordering input nodes.
                let inputNodePath: Path
                if isFramework {
                    let outputPathVisibility: HeaderVisibility = visibility == .public ? .public : .private // convert between two different visibility enums
                    inputNodePath = TargetHeaderInfo.outputPath(for: path, visibility: outputPathVisibility, scope: scope)
                } else {
                    inputNodePath = outputPath
                }
                inputNodes.append(producer.context.createNode(inputNodePath))

                return TAPIFileList.HeaderInfo(visibility: visibility, path: outputPath, language: language, isSwiftCompatibilityHeader: false)
            }

            var headers = [TAPIFileList.HeaderInfo]()
            let headerVisibilityToProcess = DocumentationCompilerSpec.headerVisibilityToExtractDocumentationFor(CommandBuildContext(producer: context, scope: scope, inputs: []))
            headers.reserveCapacity(documentationHeaderInfo.fileReferenceCount)

            if headerVisibilityToProcess.contains(.public) {
                for fileRef in documentationHeaderInfo.publicHeaders {
                    if let header = computeProductHeader(for: fileRef, isFramework: isFramework, visibility: .public, inputNodes: &inputNodes) {
                        headers.append(header)
                    }
                }
            }
            if headerVisibilityToProcess.contains(.private) {
                for fileRef in documentationHeaderInfo.privateHeaders {
                    if let header = computeProductHeader(for: fileRef, isFramework: isFramework, visibility: .private, inputNodes: &inputNodes) {
                        headers.append(header)
                    }
                }
            }
            if headerVisibilityToProcess.contains(nil) { // project visible headers
                for fileRef in documentationHeaderInfo.projectHeaders {
                    if let header = computeProductHeader(for: fileRef, isFramework: isFramework, visibility: .project, inputNodes: &inputNodes) {
                        headers.append(header)
                    }
                }
            }
            if let generatedSwiftHeaderPath = documentationHeaderInfo.generatedSwiftHeader {
                let visibility: TAPIFileList.HeaderVisibility = scope.evaluate(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER) ? .public : .project
                headers.append(TAPIFileList.HeaderInfo(visibility: visibility, path: generatedSwiftHeaderPath, language: GCCCompatibleLanguageDialect.c.dialectNameForCompilerCommandLineArgument, isSwiftCompatibilityHeader: true))
                inputNodes.append(producer.context.createNode(generatedSwiftHeaderPath))
            }

            return headers
        }()

        guard !headerList.isEmpty else {
            return nil
        }

        // As a heuristic to improve the odds for successfully building a project where its headers have include-what-you-use violations
        // we move the umbrella header first in the header list so that it's processed first.
        if let moduleInfo = producer.context.moduleInfo {
            // If the build system generates a module map, the umbrella header can be accessed via the module info. If there's an existing
            // module map file we need to parse the potential umbrella header information from that file instead.
            if let umbrellaHeaderName = findUmbrellaHeaderFromGeneratedModuleMap(moduleInfo) ?? findUmbrellaHeaderFromExistingModuleMap(moduleInfo),
               let umbrellaHeaderIndex = headerList.firstIndex(where: { $0.visibility == .public && $0.path.basename == umbrellaHeaderName })
            {
                let umbrellaHeader = headerList.remove(at: umbrellaHeaderIndex)
                headerList.insert(umbrellaHeader, at: 0)
            }
        }

        return (headerList, inputNodes)
    }

    private func addFileListExtractAPITasks(headers headerList: [TAPIFileList.HeaderInfo], producer: PhasedTaskProducer, tapiInfo: DiscoveredTAPIToolSpecInfo?, scope: MacroEvaluationScope, tasks: inout [any PlannedTask]) async -> Path? {

        // Create a JSON file with a list of the headers.  We only need to do this once for the target - each build variant will share the same JSON file.
        let jsonPath = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join(scope.evaluate(BuiltinMacros.PRODUCT_NAME) + "-extractapi-headers.json")

        guard let tapiVersion = tapiInfo?.toolVersion else {
            producer.context.error("Couldn't determine tapi version")
            return nil
        }

        let headerListVersion = TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: tapiVersion)

        let fileList: TAPIFileList
        let fileListBytes: ByteString
        do {
            if headerListVersion < TAPIFileList.FormatVersion.v3 {
                fileList = try TAPIFileList(version: headerListVersion, headers: headerList.map { ($0.visibility, $0.path.str) })
            } else {
                fileList = try TAPIFileList(version: headerListVersion, headerInfos: headerList)
            }
            fileListBytes = ByteString(try fileList.asBytes())
        } catch {
            producer.context.error(error.localizedDescription)
            return nil
        }

        await producer.appendGeneratedTasks(&tasks) { delegate in
            let cbc = CommandBuildContext(producer: producer.context, scope: producer.context.settings.globalScope, inputs: [], output: jsonPath)
            producer.context.writeFileSpec.constructFileTasks(cbc, delegate, contents: fileListBytes, permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        return jsonPath
    }

    private func findUmbrellaHeaderFromGeneratedModuleMap(_ moduleInfo: ModuleInfo) -> String? {
        // If the build system generates a module map, the umbrella header can be accessed via the module info
        return moduleInfo.umbrellaHeader.nilIfEmpty
    }

    private func findUmbrellaHeaderFromExistingModuleMap(_ moduleInfo: ModuleInfo) -> String? {
        // If the module map source path is the same as the temp path, then the module map is synthesized.
        guard moduleInfo.moduleMapPaths.sourcePath != moduleInfo.moduleMapPaths.tmpPath else {
            return nil
        }

        // There's no API to parse the module map file. Instead we use a regex to find only the umbrella header information.
        // rdar://88357965 (Add tool or API to introspect the module for information such as “what’s the umbrella header”)
        guard let contents = try? readFileContents(moduleInfo.moduleMapPaths.sourcePath) else {
            return nil
        }
        return parseUmbrellaHeaderName(contents.asString)
    }
}
