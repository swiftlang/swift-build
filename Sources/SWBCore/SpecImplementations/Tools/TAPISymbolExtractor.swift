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

import Foundation
public import SWBUtil
public import SWBMacro
import SWBProtocol

final public class TAPISymbolExtractor: GenericCompilerSpec, GCCCompatibleCompilerCommandLineBuilder, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.documentation.objc-symbol-extract"

    /// Return whether or not this documentation build should include a task for symbol extraction.
    ///
    /// For projects that contain C++ headers, this checks whether the installed version of Clang supports C++ documentation.
    ///
    /// - Parameters:
    ///   - cbc: The command build context
    ///   - clangCompilerInfo: Optional information about the installed copy of clang. Pass nil if clang is not being used.
    ///
    static public func shouldConstructSymbolExtractionTask(_ cbc: CommandBuildContext, clangCompilerInfo: (any DiscoveredCommandLineToolSpecInfo)? ) async -> Bool {
        let (canGenerateCXXTasks, hasPlusPlusHeaders) = await (canGenerateCXXTasks(cbc), hasPlusPlusHeaders(cbc))
        return ((supportsPlusPlus(cbc: cbc, clangCompilerInfo: clangCompilerInfo) && canGenerateCXXTasks) || !hasPlusPlusHeaders) && DocumentationCompilerSpec.shouldConstructSymbolGenerationTask(cbc)
    }

    // This build supports C++ documentation if both are true:
    // - This build is using clang and not TAPI (check the IDEDocumentationEnableClangExtractAPI feature flag)
    // - The installed version of clang actually supports it
    static private func supportsPlusPlus(cbc: CommandBuildContext, clangCompilerInfo: (any DiscoveredCommandLineToolSpecInfo)?) -> Bool {
        guard SWBFeatureFlag.enableClangExtractAPI.value, let clangCompilerInfo else {
            return false
        }
        return clangCompilerInfo.hasFeature(DiscoveredClangToolSpecInfo.FeatureFlag.extractAPISupportsCPlusPlus.rawValue)
    }

    static private func canGenerateCXXTasks(_ cbc: CommandBuildContext) async -> Bool {
        if cbc.scope.evaluate(BuiltinMacros.DOCC_ENABLE_CXX_SUPPORT) {
            return true
        }
        return await hasNonPlusPlusHeader(cbc)
    }

    static private func shouldBuildInCXXMode(cbc: CommandBuildContext) async -> Bool {
        guard cbc.scope.evaluate(BuiltinMacros.DOCC_ENABLE_CXX_SUPPORT) else {
            return false
        }
        return await hasPlusPlusHeaders(cbc)
    }

    // Which -x option should this task pass along to clang for the extract-api command?
    static private func clangHeaderOption(cbc: CommandBuildContext) async -> String {
        return await shouldBuildInCXXMode(cbc: cbc) ? "objective-c++-header" : "objective-c-header"
    }

    // Does the current project contain C++ header files?
    static private func hasPlusPlusHeaders(_ cbc: CommandBuildContext) async -> Bool {
        await checkHeaderFiletypes(cbc: cbc) {
            return $0?.languageDialect?.isPlusPlus ?? false
        }
    }

    static private func hasNonPlusPlusHeader(_ cbc: CommandBuildContext) async -> Bool {
        await checkHeaderFiletypes(cbc: cbc) {
            !($0?.languageDialect?.isPlusPlus ?? false)
        }
    }

    static private func checkHeaderFiletypes(cbc: CommandBuildContext, _ predicate: (FileTypeSpec?) -> Bool) async -> Bool {
        let headers = await headerFilesToExtractDocumentationFor(cbc)
        guard !headers.isEmpty else {
            return false
        }

        return headers.headerBuildFiles
            .contains(where: {
                let foundFileType: FileTypeSpec
                switch $0.buildableItem {
                case .reference(guid: let guid):
                    guard let reference = cbc.producer.lookupReference(for: guid), let fileType = cbc.producer.lookupFileType(reference: reference) else {
                        return false
                    }
                    foundFileType = fileType
                case .namedReference(name: _, fileTypeIdentifier: let fileTypeIdentifier):
                    guard let fileType = cbc.producer.lookupFileType(identifier: fileTypeIdentifier) else {
                        return false
                    }
                    foundFileType = fileType
                case .targetProduct:
                    return false
                }
                return predicate(foundFileType)
            })
        || headers.publicHeaders.contains(where: { predicate(cbc.producer.lookupFileType(identifier: $0.fileTypeIdentifier)) })
        || headers.privateHeaders.contains(where: { predicate(cbc.producer.lookupFileType(identifier: $0.fileTypeIdentifier)) })
        || headers.projectHeaders.contains(where: { predicate(cbc.producer.lookupFileType(identifier: $0.fileTypeIdentifier)) })
    }

    /// A list of headers to consider for documentation
    public struct DocumentationHeaderInfo {
        public var publicHeaders: [FileReference]
        public var privateHeaders: [FileReference]
        public var projectHeaders: [FileReference]
        public var generatedSwiftHeader: Path?
        public var headerBuildFiles: [BuildFile]

        public var fileReferenceCount: Int {
            return publicHeaders.count + privateHeaders.count + projectHeaders.count + (generatedSwiftHeader == nil ? 0 : 1)
        }

        public var isEmpty: Bool {
            return fileReferenceCount == 0
        }
    }

    /// Returns the headers to consider for documentation when constructing tasks in a given command building context.
    ///
    /// - Note: The returned headers will be filtered by header visibility based on the type of target.
    ///
    /// - Parameter cbc: The command build context describing the target being built and its settings.
    /// - Returns: The headers to consider for documentation.
    static public func headerFilesToExtractDocumentationFor(_ cbc: CommandBuildContext) async -> DocumentationHeaderInfo {
        guard let target = cbc.producer.configuredTarget?.target as? BuildPhaseTarget, let projectInfo = await cbc.producer.projectHeaderInfo(for: target) else {
            return .init(publicHeaders: [], privateHeaders: [], projectHeaders: [], generatedSwiftHeader: nil, headerBuildFiles: [])
        }

        let headerVisibilityToProcess = DocumentationCompilerSpec.headerVisibilityToExtractDocumentationFor(cbc)

        struct FilteringContext: BuildFileFilteringContext {
            let excludedSourceFileNames: [String]
            let includedSourceFileNames: [String]
            let currentPlatformFilter: PlatformFilter?
        }
        let filteringContext = FilteringContext(
            excludedSourceFileNames: cbc.scope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES),
            includedSourceFileNames: cbc.scope.evaluate(BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES),
            currentPlatformFilter: PlatformFilter(cbc.scope)
        )

        var headerBuildFiles = [BuildFile]()
        var fileReferencePlatformFilters = [FileReference: Set<PlatformFilter>]()

        for buildFile in target.headersBuildPhase?.buildFiles ?? [] {
            guard headerVisibilityToProcess.contains(buildFile.headerVisibility),
                  case let .reference(guid) = buildFile.buildableItem,
                  let fileRef = cbc.producer.lookupReference(for: guid) as? FileReference,
                  let path = fileRef.path.asLiteralString
            else { continue }
            fileReferencePlatformFilters[fileRef] = buildFile.platformFilters

            guard !filteringContext.isExcluded(Path(path), filters: buildFile.platformFilters) else {
                continue
            }
            headerBuildFiles.append(buildFile)
        }

        func generatedSwiftHeaderPath(willProcessAnyHeaders: Bool) -> Path? {
            guard !cbc.scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME).isEmpty else {
                // No interface header can be returned
                return nil
            }
            guard cbc.scope.evaluate(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER) else {
                // The Swift interface header isn't installed so its content won't be available when importing this target.
                return nil
            }
            if cbc.scope.evaluate(BuiltinMacros.DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS) {
                // The developer has opted in to build multi-language documentation.
                return SwiftCompilerSpec.generatedObjectiveCHeaderOutputPath(cbc.scope)
            }
            guard willProcessAnyHeaders, // Only process the Swift interface header if some other headers are also processed ...
                    // ... and if the target has Swift code that can end up in the Swift interface header.
                    target.sourcesBuildPhase?.containsSwiftSources(cbc.producer, cbc.producer, cbc.scope, cbc.producer.filePathResolver) == true
            else {
                return nil
            }
            return SwiftCompilerSpec.generatedObjectiveCHeaderOutputPath(cbc.scope)
        }

        func filteredHeaders(_ headers: [FileReference]) -> [FileReference] {
            return headers.filter { fileRef in
                guard let path = fileRef.path.asLiteralString else { return false }
                return !filteringContext.isExcluded(Path(path), filters: fileReferencePlatformFilters[fileRef] ?? [])
            }
        }

        if let targetHeaderInfo = projectInfo.targetHeaderInfo[target] {
            // This target has associated header information.
            let publicHeaders = headerVisibilityToProcess.contains(.public) ? filteredHeaders(targetHeaderInfo.publicHeaders.map(\.fileReference)) : []
            let privateHeaders = headerVisibilityToProcess.contains(.private) ? filteredHeaders(targetHeaderInfo.privateHeaders.map(\.fileReference)) : []
            let projectHeaders = headerVisibilityToProcess.contains(nil /* project */) ? filteredHeaders(targetHeaderInfo.projectHeaders.map(\.fileReference)) : []

            return .init(
                publicHeaders: publicHeaders,
                privateHeaders: privateHeaders,
                projectHeaders: projectHeaders,
                generatedSwiftHeader: generatedSwiftHeaderPath(willProcessAnyHeaders: !publicHeaders.isEmpty || !privateHeaders.isEmpty || !projectHeaders.isEmpty),
                headerBuildFiles: headerBuildFiles
            )
        } else {
            // This target doesn't have any header information. This is expected for apps and other executable targets.
            //
            // If this target is an executable, continue with a heuristic for finding what headers to extract symbol information from for documentation.
            guard case .executable = DocumentationCompilerSpec.DocumentationType(from: cbc),
                  let cFamilySourceFileType = cbc.producer.lookupFileType(identifier: "sourcecode.c")
            else {
                // Otherwise, if it's not an executable, don't look for headers to process for documentation.
                return .init(publicHeaders: [], privateHeaders: [], projectHeaders: [], generatedSwiftHeader: generatedSwiftHeaderPath(willProcessAnyHeaders: false), headerBuildFiles: [])
            }

            // Previous heuristics that we attempted looked at:
            //  - All headers without target membership. This had errors when the project contained app targets of different platforms since files that import UIKit and files that import AppKit were processed together.
            //  - All headers with the same file name as the target's source files. Similar to the above, this had errors in real projects because multiple targets are likely to have files named AppDelegate, ViewController, etc.
            //  - Only headers where the path (minus the file extension) fully matches a source file's path. This mostly worked but missed some headers without source file counterparts, resulting in errors in those projects.
            //
            // Based on the learnings from those heuristics we now look for any header that's a sibling of one of the target's source files.
            // In the projects we've tested with, this manages to avoid the issue with multiple files with the same name and the issue with headers without source file counterparts.
            // This latest heuristic would have errors if the developer put all the source files for multiple targets (and multiple platforms( in the same location.
            var sourceFileDirnames = Set<String>()

            for file in target.sourcesBuildPhase?.buildFiles ?? [] {
                guard case let .reference(guid) = file.buildableItem,
                      let fileRef = cbc.producer.lookupReference(for: guid) as? FileReference,
                      let fileType = cbc.producer.lookupFileType(identifier: fileRef.fileTypeIdentifier),
                      fileType.conformsTo(cFamilySourceFileType)
                else { continue }

                let path = cbc.producer.filePathResolver.resolveAbsolutePath(fileRef)
                sourceFileDirnames.insert(path.dirname.str)
            }

            let headersMatchingSourceFilesInThisProject = projectInfo.knownHeaders.filter {
                let headerPath = cbc.producer.filePathResolver.resolveAbsolutePath($0)

                return sourceFileDirnames.contains(headerPath.dirname.str)
            }

            let projectHeaders = filteredHeaders(headersMatchingSourceFilesInThisProject)
            return .init(
                publicHeaders: [],
                privateHeaders: [],
                projectHeaders: projectHeaders,
                generatedSwiftHeader: generatedSwiftHeaderPath(willProcessAnyHeaders: !projectHeaders.isEmpty),
                headerBuildFiles: headerBuildFiles
            )
        }
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen. (same as other tools that need extra input to construct tasks)
        fatalError("Unexpected direct invocation. Use `constructTasks(_:_:dependencyModuleMaps:)` instead.")
    }

    public func constructTasksForClang(
        _ cbc: CommandBuildContext,
        _ delegate: any TaskGenerationDelegate,
        headerList: [TAPIFileList.HeaderInfo],
        dependenciesModuleMaps: [Path],
        swiftCompilerInfo: (any DiscoveredCommandLineToolSpecInfo)? = nil,
        clangCompilerInfo: (any DiscoveredCommandLineToolSpecInfo)? = nil
    ) async {
        guard await TAPISymbolExtractor.shouldConstructSymbolExtractionTask(cbc, clangCompilerInfo: clangCompilerInfo) else {
            return
        }

        let inputs = cbc.inputs.map({ delegate.createNode($0.absolutePath) }) as [any PlannedNode]
        let symbolGraphFile = Self.getMainSymbolGraphFile(cbc.scope)
        let output = [delegate.createNode(symbolGraphFile)]

        let clangPath = self.resolveExecutablePath(cbc.producer, Path(cbc.scope.clangExtractAPIExecutablePath()))

        var commandLine = [
            clangPath.str,
            "-extract-api"
        ]


        if let compatibilitySymbolsPath = swiftCompilerInfo?.toolPath.dirname.dirname.join("share").join("swift").join("compatibility-symbols"), let ignoresFlagAvailable = clangCompilerInfo?.hasFeature("extract-api-ignores"),
           localFS.exists(compatibilitySymbolsPath) && ignoresFlagAvailable {
            commandLine.append("--extract-api-ignores=\(compatibilitySymbolsPath.str)")
        }

        commandLine += await self.commandLineFromOptions(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)) { macro in
            // Let's replace the sdkdb output with the symbol graph output path since clang generates these directly
            switch macro {
            case BuiltinMacros.TAPI_EXTRACT_API_SDKDB_OUTPUT_PATH:
                return cbc.scope.namespace.parseLiteralString(symbolGraphFile.str)
            case BuiltinMacros.TAPI_EXTRACT_API_SEARCH_PATHS:
                let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(cbc.producer, cbc.scope, usesModules: cbc.scope.evaluate(BuiltinMacros.TAPI_ENABLE_MODULES))
                let frameworkSearchPaths = GCCCompatibleCompilerSpecSupport.frameworkSearchPathArguments(cbc.producer, cbc.scope)
                let sparseSDKSearchPaths = GCCCompatibleCompilerSpecSupport.sparseSDKSearchPathArguments(cbc.producer.sparseSDKs, headerSearchPaths.headerSearchPaths, frameworkSearchPaths.frameworkSearchPaths)

                let defaultHeaderSearchPaths = headerSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

                // Evaluate the original value and prefix each argument with "-I"
                let userHeaderSearchPaths = cbc.scope.evaluate(BuiltinMacros.TAPI_EXTRACT_API_SEARCH_PATHS).map {
                    return "-I" + $0
                }
                let defaultFrameworkSearchPaths = frameworkSearchPaths.searchPathArguments(for: self, scope:cbc.scope) + sparseSDKSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

                let moduleMapSearchPaths = dependenciesModuleMaps.map { "-fmodule-map-file=\($0.str)" }

                return cbc.scope.namespace.parseLiteralStringList(defaultHeaderSearchPaths + userHeaderSearchPaths + defaultFrameworkSearchPaths + moduleMapSearchPaths)
            default:
                return nil
            }
        }.map(\.asString)

        if await Self.shouldBuildInCXXMode(cbc: cbc) {
            let langStd = cbc.scope.evaluate(BuiltinMacros.CLANG_CXX_LANGUAGE_STANDARD)
            if !langStd.isEmpty {
                switch langStd {
                case "c++0x":
                    commandLine.append("-std=c++11")
                case "gnu++0x":
                    commandLine.append("-std=gnu++11")
                case "compiler-default":
                    break
                default:
                    commandLine.append("-std=\(langStd)")
                }
            }
            commandLine += cbc.scope.evaluate(BuiltinMacros.OTHER_CPLUSPLUSFLAGS)
        }

        // Add output options
        commandLine += [
            "--product-name=\(cbc.scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME))",
            "-fmodule-name=\(cbc.scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME))",
        ]

        await commandLine += ["-x", Self.clangHeaderOption(cbc: cbc)]

        if cbc.scope.evaluate(BuiltinMacros.DOCC_ENABLE_CXX_SUPPORT) {
            commandLine += headerList.map { $0.path.str }
        } else {
            commandLine += headerList.compactMap {
                if let language = $0.language,
                   GCCCompatibleLanguageDialect(dialectName: language).isPlusPlus {
                    return nil
                }
                return $0.path.str
            }
        }

        // Extract the symbol information
        delegate.createTask(
            type: self,
            ruleInfo: ["ExtractAPI", "\(symbolGraphFile.str)"],
            commandLine: commandLine,
            environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs,
            outputs: output,
            action: nil,
            execDescription: "Build symbol graph for \(cbc.scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME))",
            enableSandboxing: enableSandboxing
        )
    }

    public func constructTasksForTAPI(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, dependenciesModuleMaps: [Path]) async {
        // For TAPI don't pass in clang compiler info, disabling C++ support.
        guard await TAPISymbolExtractor.shouldConstructSymbolExtractionTask(cbc, clangCompilerInfo: nil) else {
            return
        }

        let inputs = cbc.inputs.map({ delegate.createNode($0.absolutePath) }) as [PlannedPathNode]
                   + cbc.commandOrderingInputs

        let symbolGraphFile = Self.getMainSymbolGraphFile(cbc.scope)

        let sdkdbFile = cbc.scope.evaluate(BuiltinMacros.TAPI_EXTRACT_API_SDKDB_OUTPUT_PATH)

        let intermediateFile = [delegate.createNode(sdkdbFile)]

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            // Override TAPI_EXTRACT_API_SEARCH_PATHS to construct all search paths (user headers, headers, system headers, frameworks, system frameworks, etc.)
            // We do this to also include header maps and VFS overlays.
            if macro == BuiltinMacros.TAPI_EXTRACT_API_SEARCH_PATHS {
                let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(cbc.producer, cbc.scope, usesModules: cbc.scope.evaluate(BuiltinMacros.TAPI_ENABLE_MODULES))
                let frameworkSearchPaths = GCCCompatibleCompilerSpecSupport.frameworkSearchPathArguments(cbc.producer, cbc.scope)
                let sparseSDKSearchPaths = GCCCompatibleCompilerSpecSupport.sparseSDKSearchPathArguments(cbc.producer.sparseSDKs, headerSearchPaths.headerSearchPaths, frameworkSearchPaths.frameworkSearchPaths)

                let defaultHeaderSearchPaths = headerSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

                // Evaluate the original value and prefix each argument with "-I"
                let userHeaderSearchPaths = cbc.scope.evaluate(BuiltinMacros.TAPI_EXTRACT_API_SEARCH_PATHS).map {
                    return "-I" + $0
                }
                let defaultFrameworkSearchPaths = frameworkSearchPaths.searchPathArguments(for: self, scope:cbc.scope) + sparseSDKSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

                let moduleMapSearchPaths = dependenciesModuleMaps.map { "-fmodule-map-file=\($0.str)" }

                return cbc.scope.namespace.parseLiteralStringList(defaultHeaderSearchPaths + userHeaderSearchPaths + defaultFrameworkSearchPaths + moduleMapSearchPaths)
            } else {
                return nil
            }
        }

        guard let toolSpecInfo = await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DiscoveredTAPIToolSpecInfo else {
            delegate.error("Value for TAPI_EXEC cannot be empty.")
            return
        }
        var extraCommandLineArguments = [String]()
        if toolSpecInfo.supportsModuleNameFlag {
            extraCommandLineArguments.append("-fmodule-name=\(cbc.scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME))")
        }
        if toolSpecInfo.supportsProductNameFlag {
            extraCommandLineArguments.append("--product-name=\(cbc.scope.evaluate(BuiltinMacros.PRODUCT_NAME))")
        }

        // Extract the symbol information
        await delegate.createTask(
            type: self,
            ruleInfo: defaultRuleInfo(cbc, delegate, lookup: lookup),
            commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString) + extraCommandLineArguments,
            environment: environmentFromSpec(cbc, delegate, lookup: lookup),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs,
            outputs: intermediateFile,
            action: nil,
            execDescription: resolveExecutionDescription(cbc, delegate, lookup: lookup),
            enableSandboxing: enableSandboxing
        )

        let converterPath = cbc.scope.evaluate(BuiltinMacros.SDKDB_TO_SYMGRAPH_EXEC)

        // Convert to a symbol graph file
        delegate.createTask(
            type: self,
            ruleInfo: ["ConvertSDKDBToSymbolGraph", sdkdbFile.str],
            commandLine: [converterPath.str, sdkdbFile.str, cbc.scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME), symbolGraphFile.str],
            environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: intermediateFile,
            outputs: [delegate.createNode(symbolGraphFile)],
            action: nil,
            execDescription: "Convert \(sdkdbFile.basename) to \(symbolGraphFile.basename)",
            enableSandboxing: enableSandboxing
        )
    }

    /// Gets the paths to the symbol graph files for the Swift module for all architectures and variants.
    static func mainSymbolGraphFiles(_ cbc: CommandBuildContext) -> [Path] {
        var paths: [Path] = []

        let archSpecificSubScopes = cbc.scope.evaluate(BuiltinMacros.ARCHS).map { arch in
            return cbc.scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
        }

        for subScope in archSpecificSubScopes {
            // Add the main symbol graph file for this architecture sub scope.
            paths.append(getMainSymbolGraphFile(subScope))
        }

        return paths
    }

    /// Gets the path to the symbol graph file for the Swift module in a given scope for a given compiler mode.
    ///
    /// - Important: Only use this as an argument to the command line tool that produces the symbol graph files.
    ///              Use `getMainSymbolGraphFile` when specifying the inputs and outputs of constructed tasks.
    static func getSymbolGraphDirectory(_ scope: MacroEvaluationScope) -> Path {
        // This method exists so that other tasks can compute the symbol graph file path to depend on it.
        return scope.evaluate(BuiltinMacros.TAPI_EXTRACT_API_OUTPUT_DIR)
    }

    /// Gets the path to the symbol graph file for the Swift module in a given scope for a given compiler mode.
    ///
    /// - Important: Use this value when specifying the inputs and outputs of constructed tasks.
    static func getMainSymbolGraphFile(_ scope: MacroEvaluationScope) -> Path {
        // Changes to a file in a directory doesn't mark the directory as "changed" when the directory is specified as a tasks output.
        //
        // Since one tasks outputs the directories of symbol graph files and another uses it as input, we need to specify
        // a file as input so that incremental builds work as expected.
        //
        // At the point where the tasks are constructed we don't know all the symbol graph files that it will output but it's
        // enough that we know the main symbol graph file (the one for the current module) since this is only control dependencies between tasks.
        return getSymbolGraphDirectory(scope).join("\(scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME)).symbols.json")
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = self.resolveExecutablePath(producer, Path(scope.tapiExecutablePath()))

        // Get the info from the global cache.
        do {
            return try await discoveredTAPIToolInfo(producer, delegate, at: toolPath)
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

private extension DiscoveredTAPIToolSpecInfo {
    /// A Boolean value that is true if TAPI supports specifying module name.
    ///
    /// The `-fmodule-name` flag was added in `tapi-1400.0.6`.
    var supportsModuleNameFlag: Bool {
        // We're explicitly checking the toolVersion here because tapi doesn't have a features.json file.
        guard let toolVersion else {
            return false
        }

        return toolVersion >= Version(1400, 0, 6)
    }

    /// A Boolean value that is true if TAPI supports specifying product name.
    ///
    /// The `--product-name` flag was added in `tapi-1400.0.9`.
    var supportsProductNameFlag: Bool {
        // We're explicitly checking the toolVersion here because tapi doesn't have a features.json file.
        guard let toolVersion else {
            return false
        }

        return toolVersion >= Version(1400, 0, 9)
    }
}

extension MacroEvaluationScope {
    func clangExtractAPIExecutablePath(lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        return evaluate(BuiltinMacros.CLANG_EXTRACT_API_EXEC, lookup: lookup, default: "clang")
    }
}
