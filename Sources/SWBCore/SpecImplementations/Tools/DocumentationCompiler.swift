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
public import SWBProtocol
public import SWBMacro

final public class DocumentationCompilerSpec: GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.documentation"

    static public func shouldConstructSymbolGenerationTask(_ cbc: CommandBuildContext) -> Bool {
        /// Symbol graph generation is only relevant for one build variant
        guard cbc.isNeutralVariant else {
            return false
        }

        let buildComponents = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard buildComponents.contains("build") else {
            return false
        }

        return cbc.scope.evaluate(BuiltinMacros.RUN_SYMBOL_GRAPH_EXTRACT) || Self.shouldConstructDocumentationTask(cbc)
    }

    static public func shouldConstructDocumentationTask(_ cbc: CommandBuildContext) -> Bool {
        /// Documentation generation is only relevant for one build variant
        guard cbc.isNeutralVariant else {
            return false
        }

        let buildComponents = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)

        // Only construct a documentation task if this build has a "build" build component (rdar://87221580)
        // Otherwise, if RUN_DOCUMENTATION_COMPILER is set, the documentation task may expect symbol information that will never be produced.
        //
        // We could theoretically move this check into `constructTasks` instead and use it to control `shouldProcessSwiftSymbolGraphFiles` and
        // `shouldProcessObjectiveCSymbolGraphFiles` to allow documentation to be built from only the DocC catalog. However, in practice that
        // behavior would likely be more confusing than skipping the documentation task entirely.
        guard buildComponents.contains("build") else {
            return false
        }

        // Only construct a documentation task if this is a Build Documentation action or if the Build Documentation during 'Build' setting is set.
        guard buildComponents.contains("documentation") || cbc.scope.evaluate(BuiltinMacros.RUN_DOCUMENTATION_COMPILER) else {
            return false
        }

        // Some target types (such as Swift Macro implementations) _can_ build documentation but their documentation isn't intended for the
        // developer who uses the actual macro in their code. The PIF generation for these targets set SKIP_BUILDING_DOCUMENTATION=YES to
        // opt out of documentation. If, in the future, we want to support documentation for some Swift Macro implementations, that change
        // would be in the PIF generation code.
        guard !cbc.scope.evaluate(BuiltinMacros.SKIP_BUILDING_DOCUMENTATION) else {
            return false
        }

        // Only build documentation for the types of products where it makes sense.
        return DocumentationType(from: cbc) != nil
    }

    /// Returns additional flags, if any, that should be passed to the Swift compiler when building
    /// documentation for the given context.
    ///
    /// - Parameter cbc: The context for which documentation is being built.
    @_spi(Testing) public static func additionalSymbolGraphGenerationArgs(
        _ cbc: CommandBuildContext,
        swiftCompilerInfo: DiscoveredSwiftCompilerToolSpecInfo
    ) -> [String] {
        var additionalFlags = [String]()

        // Check if extension symbol documentation is requested
        if cbc.scope.evaluate(BuiltinMacros.DOCC_EXTRACT_EXTENSION_SYMBOLS) && swiftCompilerInfo.toolFeatures.has(.emitExtensionBlockSymbols) {
            additionalFlags.append("-emit-extension-block-symbols")
        }

        switch DocumentationType(from: cbc) {
        case .executable:
            guard swiftCompilerInfo.supportsSymbolGraphMinimumAccessLevelFlag else {
                // The swift compiler doesn't support specifying a minimum access level,
                // so just return an empty array.
                return additionalFlags
            }

            // When building executable types (like applications and command-line tools), include
            // internal symbols in the generated symbol graph.
            return additionalFlags.appending(contentsOf: ["-symbol-graph-minimum-access-level", "internal"])
        case .framework, .none:
            // For frameworks (and non-documentable types), just use the default behavior
            // of the symbol graph tool.
            return additionalFlags
        }
    }

    /// Returns the header visibility level to include when building documentation for C/Objective-C for the given context.
    ///
    /// - Parameter cbc: The context for which documentation is being built.
    static public func headerVisibilityToExtractDocumentationFor(_ cbc: CommandBuildContext) -> Set<HeaderVisibility?> {
        // Conceptually we think of the different header visibility levels like this:
        //  - Public headers are for "public API"
        //  - Private headers are for "SPI"
        //  - Project headers are not API at all but could be thought of as "private API" (only accessible within the project).
        if cbc.scope.evaluate(BuiltinMacros.DOCC_EXTRACT_SPI_DOCUMENTATION) {
            return [.public, .private]
        }

        // If the hidden build setting isn't YES, determine the header visibility based on the type of target.
        switch DocumentationType(from: cbc) {
        case .executable:
            // When building executable types (like applications and command-line tools), include all levels of headers in the generated symbol graph
            // since executable documentation is meant for the team developing that executable (compared to framework documentation for the consumers
            // of that framework).
            return [.public, .private, nil] // nil for project visibility
        case .framework, .none:
            // For frameworks (and non-documentable types), only include public API in the generated symbol graph.
            return [.public]
        }
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        guard Self.shouldConstructDocumentationTask(cbc) else {
            return
        }

        if cbc.inputs.count > 1 {
            delegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Each target may contain only a single documentation catalog."), childDiagnostics: cbc.inputs.map { input in
                Diagnostic(behavior: .note, location: .path(input.absolutePath), data: DiagnosticData("Documentation catalog named \(input.absolutePath.basename)"))
            }))
            return
        }

        // Documentation can only be built if there's either a Swift or Objective-C framework to process or if there is a documentation catalog to process.
        let buildPhaseTarget = cbc.producer.configuredTarget?.target as? BuildPhaseTarget
        let shouldProcessSwiftSymbolGraphFiles = buildPhaseTarget?.sourcesBuildPhase?.containsSwiftSources(cbc.producer, cbc.producer, cbc.scope, cbc.producer.filePathResolver) ?? false

        // A Swift target without any headers that generates a Swift interface Objective-C header should still process the Objective-C symbol graph files
        let hasAnyObjectiveCSourceHeaders = await !TAPISymbolExtractor.headerFilesToExtractDocumentationFor(cbc).isEmpty
        let clangInfo = await cbc.producer.clangSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
        let shouldConstructSymbolExtractionTask = await TAPISymbolExtractor.shouldConstructSymbolExtractionTask(cbc, clangCompilerInfo: clangInfo)
        let shouldProcessObjectiveCSymbolGraphFiles = hasAnyObjectiveCSourceHeaders && shouldConstructSymbolExtractionTask

        guard shouldProcessSwiftSymbolGraphFiles || shouldProcessObjectiveCSymbolGraphFiles || containsDocumentationCatalogInputs(among: cbc.inputs, cbc.producer) else {
            return
        }

        // Avoid depending on symbol graph extractor tasks that we know that they will never run (because there's no Swift / Objective-C code to extract symbol information from).
        var mainSymbolGraphFiles: [Path] = []
        if shouldProcessSwiftSymbolGraphFiles || (shouldProcessObjectiveCSymbolGraphFiles && SwiftSymbolExtractor.shouldConstructSymbolExtractionTask(cbc)) {
            mainSymbolGraphFiles += SwiftCompilerSpec.mainSymbolGraphFiles(cbc)
        }
        if shouldProcessObjectiveCSymbolGraphFiles {
            mainSymbolGraphFiles += TAPISymbolExtractor.mainSymbolGraphFiles(cbc)
        }

        let templatePath = Path(cbc.scope.evaluate(BuiltinMacros.DOCC_TEMPLATE_PATH)).normalize().nilIfEmpty
        let environmentBindings = templatePath.map { [("DOCC_HTML_DIR", $0.str)] } ?? []

        // The inputs (files that this task depend on) are the '.docs' bundles, specified in the '.xcspec' file, and the symbol graph task
        let inputs: [any PlannedNode] = cbc.inputs.map({ delegate.createDirectoryTreeNode($0.absolutePath) })
            + mainSymbolGraphFiles.map({ delegate.createNode($0) })

        // The outputs (files that other tasks can depend on) are specified in the '.xcspec' file.
        var outputs: [any PlannedNode] = cbc.outputs.map(delegate.createDirectoryTreeNode)

        // The docc executable only has one argument for a directory that it searches for symbol graph files.
        // The symbol graph extractor task(s) output an unknown number of symbol graphs per architecture in a given directory.
        // Also, both Swift and TAPI output symbol graph files, in separate directories next to each other.
        // We pass that parent directory to docc, so that it can find all symbol graphs (main and extensions) for all architectures
        // and for both Swift and TAPI (C/Objective-C).
        let symbolGraphArgs: [String]
        let symbolGraphParentDirectories = Set(mainSymbolGraphFiles.map { $0.dirname.dirname.dirname })
        if let symbolGraphParentDirectory = symbolGraphParentDirectories.only {
            symbolGraphArgs = ["--additional-symbol-graph-dir", symbolGraphParentDirectory.normalize().str]
        } else {
            if symbolGraphParentDirectories.count > 1 {
                delegate.error("Couldn't determine common parent directory for symbol graph files from paths:\n\(mainSymbolGraphFiles.sorted().map { $0.str }.joined(separator: "\n"))")
            }
            symbolGraphArgs = []
        }

        // For certain product types, we need to provide a display name for the kind of product being built
        // to DocC.
        let documentationKindArgs: [String]
        switch DocumentationType(from: cbc) {
        case .executable(displayName: let productTypeDisplayName):
            // When building documentation for executables, provide the name of the product type
            // to DocC so that generated documentation correctly renders the kind.
            //
            // For example, this could be 'Application' or 'Command-line Tool'.
            documentationKindArgs = ["--fallback-default-module-kind", productTypeDisplayName]
        case .framework, .none:
            // For frameworks (and non-documentable types), use DocC's default behavior.
            documentationKindArgs = []
        }

        guard let specInfo = await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DocumentationCompilerToolSpecInfo else {
            // An error will have already been emitted
            return
        }

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            // Override DOCC_INPUTS and return the inputs to the task.
            if macro == BuiltinMacros.DOCC_INPUTS {
                return cbc.scope.table.namespace.parseStringList(cbc.inputs.map { $0.absolutePath.normalize().str })
            }

            // Remove unsupported arguments gated by tool features
            if specInfo.toolFeatures.has(.diagnosticsFile) {
                if macro == BuiltinMacros.DOCC_EMIT_FIXITS {
                    return cbc.scope.namespace.parseLiteralString("NO")
                }
            } else {
                if macro == BuiltinMacros.DOCC_IDE_CONSOLE_OUTPUT {
                    return cbc.scope.namespace.parseLiteralString("NO")
                } else if macro == BuiltinMacros.DOCC_DIAGNOSTICS_FILE {
                    return cbc.scope.namespace.parseLiteralString("")
                }
            }

            return nil
        }

        let commandLine = commandLineFromTemplate(cbc, delegate, optionContext: specInfo, specialArgs: symbolGraphArgs + documentationKindArgs, lookup: lookup).map(\.asString)

        // Attach a payload with information about what built documentation this task will output.
        let outputDir = cbc.scope.evaluate(BuiltinMacros.DOCC_ARCHIVE_PATH)
        let diagnosticsFilePath = cbc.scope.evaluate(BuiltinMacros.DOCC_DIAGNOSTICS_FILE, lookup: lookup).nilIfEmpty
        let payload = outputDir.isEmpty ? nil : DocumentationTaskPayload(
            bundleIdentifier: cbc.scope.evaluate(BuiltinMacros.DOCC_CATALOG_IDENTIFIER),
            outputPath: Path(outputDir),
            targetIdentifier: cbc.producer.configuredTarget?.target.guid,
            documentationDiagnosticsPath: diagnosticsFilePath
        )
        if let diagnosticsFilePath {
            outputs.append(delegate.createNode(diagnosticsFilePath))
        }

        delegate.createTask(
            type: self,
            payload: payload,
            ruleInfo: defaultRuleInfo(cbc, delegate, lookup: lookup),
            commandLine: commandLine,
            environment: EnvironmentBindings(environmentBindings),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs,
            outputs: outputs,
            execDescription: resolveExecutionDescription(cbc, delegate),
            enableSandboxing: enableSandboxing
        )
    }

    /// Checks if any of the given input is a documentation catalog file type.
    /// - Parameters:
    ///   - inputs: The input to check.
    ///   - specLookupContext: The context used to look up specs and file types.
    /// - Returns: `true` if any other input is a documentation catalog file type; otherwise `false`.
    func containsDocumentationCatalogInputs(among inputs: [FileToBuild], _ specLookupContext: any SpecLookupContext) -> Bool {
        guard let documentationCatalogType = specLookupContext.lookupFileType(identifier: "folder.documentationcatalog") else { return false }
        return inputs.contains(where: { $0.fileType == documentationCatalogType })
    }

    // This spec uses a custom payload to attach additional information about the built documentation output to the constructed task.
    // The payload can then be retrieved by asking all tasks to `generateDocumentationInfo` to get a list of all the documentation that
    // the planned build will output.

    override public func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] {
        guard let payload = task.payload as? DocumentationTaskPayload else { return [] }
        return [.init(bundleIdentifier: payload.bundleIdentifier, outputPath: payload.outputPath, targetIdentifier: payload.targetIdentifier)]
    }

    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        // We expect every DocC task to have a payload of the right type.
        guard !documentationDiagnosticsPaths(for: task).isEmpty else {
            return super.customOutputParserType(for: task)
        }

        return DocumentationDiagnosticsOutputParser.self
    }

    override public var payloadType: (any TaskPayload.Type)? { return DocumentationTaskPayload.self }

    func documentationDiagnosticsPaths(for task: any ExecutableTask) -> [Path] {
        guard let payload = task.payload as? DocumentationTaskPayload, let path = payload.documentationDiagnosticsPath else { return [] }
        return [path]
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        // Get the path to the compiler.
        let path = scope.evaluate(BuiltinMacros.DOCC_EXEC).nilIfEmpty ?? Path(producer.hostOperatingSystem.imageFormat.executableName(basename: "docc"))
        let toolPath = self.resolveExecutablePath(producer, path)

        // Get the info from the global cache.
        do {
            return try await discoveredDocumentationCompilerInfo(producer, delegate, at: toolPath)
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

public func discoveredDocumentationCompilerInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, at toolPath: Path) async throws -> DocumentationCompilerToolSpecInfo {
    if !toolPath.isAbsolute {
        throw StubError.error("\(toolPath.str) is not absolute")
    }
    let featuresPath = toolPath.dirname.dirname.join("share").join("docc").join("features.json")
    // features.json is missing on Windows: https://github.com/swiftlang/swift-installer-scripts/issues/337
    if !producer.executableSearchPaths.fs.exists(featuresPath) && producer.hostOperatingSystem == .windows {
        return DocumentationCompilerToolSpecInfo(toolPath: toolPath, toolFeatures: .init([.diagnosticsFile]))
    }
    return try await producer.discoveredCommandLineToolSpecInfo(delegate, "docc", featuresPath, { contents in
        func getFeatures(at toolPath: Path) throws -> ToolFeatures<DocumentationCompilerToolSpecInfo.FeatureFlag> {
            do {
                let fs = PseudoFS()
                try fs.createDirectory(featuresPath.dirname, recursive: true)
                try fs.write(featuresPath, contents: ByteString(contents))
                return try .init(path: featuresPath, fs: fs)
            } catch {
                // If this is a custom tool path (via DOCC_EXEC) check the default features.
                if let defaultToolPath = producer.executableSearchPaths.findExecutable(operatingSystem: producer.hostOperatingSystem, basename: "docc"), defaultToolPath != toolPath {
                    let defaultFeaturesPath = defaultToolPath.dirname.dirname.join("share").join("docc").join("features.json")
                    if localFS.exists(defaultFeaturesPath) {
                        return try .init(path: defaultFeaturesPath, fs: localFS)
                    }
                }
                // Didn't find any default features.
                throw error
            }
        }
        return try DocumentationCompilerToolSpecInfo(toolPath: toolPath, toolFeatures: getFeatures(at: toolPath))
    })
}

public struct DocumentationCompilerToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public var toolPath: Path

    public var toolVersion: Version? {
        // The DocC tool doesn't have a version.
        return nil
    }

    public enum FeatureFlag: String, CaseIterable, Sendable {
        case diagnosticsFile = "diagnostics-file"
    }
    public var toolFeatures: ToolFeatures<FeatureFlag>
    public func hasFeature(_ flag: String) -> Bool {
        return toolFeatures.has(flag)
    }
}

extension DocumentationCompilerSpec {
    /// Represents the type of product being documented.
    ///
    /// Allows the documentation compiler to behave differently for different
    /// kinds of products, where appropriate.
    enum DocumentationType {

        case framework

        case executable(displayName: String)

        /// The Mach-O types considered by DocC to be frameworks.
        private static let frameworkMachOTypes: Set = [
            "mh_dylib", // dylibs and dynamic frameworks
            "staticlib", // static libraries and static frameworks
            "mh_object", // relocatable objects, used by SwiftPM
        ]

        /// The Mach-O type that DocC considers to be executable.
        private static let executableMachOType = "mh_execute"

        /// Create a documentation type from the given build context.
        ///
        /// Uses the Mach-O and product types to determine what kind of product this is from a
        /// documentation perspective.
        init?(from buildContext: CommandBuildContext) {
            let machOType = buildContext.scope.evaluate(BuiltinMacros.MACH_O_TYPE)

            guard !Self.frameworkMachOTypes.contains(machOType) else {
                // This is a framework, so we can return now without doing any additional work.
                self = .framework
                return
            }

            guard machOType == Self.executableMachOType else {
                // Since the Mach-O type is not a framework or executable type,
                // this is non-documentable build context and we just return nil.
                return nil
            }

            // Since the Mach-O type represents an executable, we now perform
            // some additional work to determine the correct display name to use
            // for the _kind_ of executable.

            guard let productType = buildContext.producer.productType else {
                // If we can't determine the product type for this build context,
                // we cannot accurately produce documentation for it.
                return nil
            }

            let documentationKindDisplayName: String
            if productType.conformsTo(identifier: "com.apple.product-type.tool") {
                documentationKindDisplayName = "Command-line Tool"
            } else if productType.conformsTo(identifier: "com.apple.product-type.application") {
                documentationKindDisplayName = "Application"
            } else if productType.conformsTo(identifier: "com.apple.product-type.driver-extension") {
                documentationKindDisplayName = "DriverKit Driver"
            } else if productType.conformsTo(identifier: "com.apple.product-type.system-extension") {
                documentationKindDisplayName = "System Extension"
            } else if productType.conformsTo(identifier: "com.apple.product-type.kernel-extension") {
                documentationKindDisplayName = "Kernel Extension"
            } else if productType.identifier == "com.apple.product-type.xpc-service" {
                // We're avoiding `conformsTo` here and being explicit
                // because _many_ things conform to XPC service, including
                // application extensions.
                documentationKindDisplayName = "XPC Service"
            } else if productType.conformsTo(identifier: "com.apple.product-type.app-extension") {
                documentationKindDisplayName = "Application Extension"
            } else {
                // This is an unsupported product type, return nil to indicate
                // that we should not produce documentation for it.
                return nil
            }

            self = .executable(displayName: documentationKindDisplayName)
        }
    }
}

/// Payload information for Documentation tasks.
@_spi(Testing) public struct DocumentationTaskPayload: TaskPayload {
    /// The bundle identifier of the documentation.
    @_spi(Testing) public let bundleIdentifier: String
    /// The output path where the built documentation will be written.
    @_spi(Testing) public let outputPath: Path
    /// The PIF GUID of the target that is associated with the documentation we're building.
    @_spi(Testing) public let targetIdentifier: String?
    /// The path where the documentation diagnostics file will be written.
    @_spi(Testing) public let documentationDiagnosticsPath: Path?

    @_spi(Testing) public init(
        bundleIdentifier: String,
        outputPath: Path,
        targetIdentifier: String?,
        documentationDiagnosticsPath: Path?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.outputPath = outputPath
        self.targetIdentifier = targetIdentifier
        self.documentationDiagnosticsPath = documentationDiagnosticsPath
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(bundleIdentifier)
            serializer.serialize(outputPath)
            serializer.serialize(targetIdentifier)
            serializer.serialize(documentationDiagnosticsPath)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.bundleIdentifier = try deserializer.deserialize()
        self.outputPath = try deserializer.deserialize()
        self.targetIdentifier = try deserializer.deserialize()
        self.documentationDiagnosticsPath = try deserializer.deserialize()
    }
}

private extension DiscoveredSwiftCompilerToolSpecInfo {
    /// A Boolean value that is true if the Swift compiler supports specifying a minimum
    /// access level for symbol graph generation.
    ///
    /// The `-symbol-graph-minimum-access-level` flag was added in `swiftlang-5.6.0.316.14`.
    var supportsSymbolGraphMinimumAccessLevelFlag: Bool {
        // We're explicitly checking the swiftlangVersion here instead of a value in the
        // the toolchain's `features.json` because a `features.json` flag wasn't originally
        // added when support for `-symbol-graph-minimum-access-level` was added.
        //
        // Instead of regressing the current documentation build experience while waiting for a
        // submission that includes the `features.json` flag, we're checking the raw version here.
        //
        // For future coordinated changes like this between the Swift-DocC infrastructure
        // in Swift Build and the Swift compiler, we'll rely on the `features.json` instead of
        // raw version numbers.
        return swiftlangVersion >= Version(5, 6, 0, 316, 14)
    }
}

// MARK: - Diagnostics

/// An output parser which forwards all output unchanged, then generates diagnostics from a serialized diagnostics file passed in the payload once it is closed.
public final class DocumentationDiagnosticsOutputParser: TaskOutputParser {
    private let task: any ExecutableTask

    public let workspaceContext: WorkspaceContext
    public let buildRequestContext: BuildRequestContext
    public let delegate: any TaskOutputParserDelegate

    required public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.task = task
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
    }

    public func write(bytes: ByteString) {
        // Forward the unparsed bytes immediately (without line buffering).
        delegate.emitOutput(bytes)

        // Disable diagnostic scraping, since we use serialized diagnostics.
    }

    public func close(result: TaskResult?) {
        defer {
            delegate.close()
        }
        // Don't try to read diagnostics if the process crashed or got cancelled as they were almost certainly not written in this case.
        if result.shouldSkipParsingDiagnostics { return }

        guard let documentationDiagnosticsPath = (task.payload as? DocumentationTaskPayload)?.documentationDiagnosticsPath else {
            return
        }

        let fs = workspaceContext.fs
        if !fs.exists(documentationDiagnosticsPath) {
            // DocC tries to write a diagnostics file even if it encounters an error that prevents the documentation build from continuing but if
            // there's a crash or if the error happens before the command line arguments have been parsed then it can't write a diagnostics file.
            //
            // This should rare in practice but we've had a couple of people getting confused by the "Could not read diagnostics file" warning
            // when they've reported bugs and avoiding that confusion is enough of a reason for me to want to silence the warning.
            return
        }

        let diagnostics: [DiagnosticFile.Diagnostic]
        do {
            diagnostics = try JSONDecoder().decode(DiagnosticFile.self, from: documentationDiagnosticsPath, fs: fs).diagnostics
        } catch {
            // Any other error with the diagnostic file we'd want to know about, by presenting a warning about it, even if it's not actionable to
            // the developer.
            delegate.diagnosticsEngine.emit(Diagnostic(behavior: .warning, location: .path(documentationDiagnosticsPath), data: DiagnosticData("Could not read diagnostics file: \(error)")))
            return
        }

        for documentationDiagnostic in diagnostics {
            let diagnostic = Diagnostic(documentationDiagnostic)
            delegate.diagnosticsEngine.emit(diagnostic)
        }
    }
}

// MARK: DocC Diagnostic File

private struct DiagnosticFile: Codable {
    var version: VersionTriplet
    var diagnostics: [Diagnostic]

    // This file format follows semantic versioning.
    // Breaking changes should increment the major version component.
    // Non breaking additions should increment the minor version.
    // Bug fixes should increment the patch version.
    static let currentVersion = VersionTriplet(major: 1, minor: 0, patch: 0)

    enum Error: Swift.Error {
        case unknownMajorVersion(found: VersionTriplet, latestKnown: VersionTriplet)
    }

    static func verifyIsSupported(_ version: VersionTriplet, current: VersionTriplet = Self.currentVersion) throws {
        guard version.major == current.major else {
            throw Error.unknownMajorVersion(found: version, latestKnown: current)
        }
    }

    struct Diagnostic: Codable {
        struct Range: Codable {
            var start: Location
            var end: Location
            struct Location: Codable {
                var line: Int
                var column: Int
            }
        }
        var source: URL?
        var range: Range?
        var severity: Severity
        var summary: String
        var explanation: String?
        var solutions: [Solution]
        struct Solution: Codable {
            var summary: String
            var replacements: [Replacement]
            struct Replacement: Codable {
                var range: Range
                var text: String
            }
        }
        var notes: [Note]
        struct Note: Codable {
            var source: URL?
            var range: Range?
            var message: String
        }
        enum Severity: String, Codable {
            case error, warning, note, remark
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, diagnostics
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(VersionTriplet.self, forKey: .version)
        try Self.verifyIsSupported(version)

        diagnostics = try container.decode([Diagnostic].self, forKey: .diagnostics)
    }

    struct VersionTriplet: Codable {
        var major: Int
        var minor: Int
        var patch: Int
    }
}

// MARK: Diagnostic Initialization

private extension Diagnostic {
    init(_ diagnostic: DiagnosticFile.Diagnostic) {
        let path = diagnostic.source.map { Path($0.path) }

        func sourceRanges(path: Path?, range: DiagnosticFile.Diagnostic.Range?) -> [SourceRange] {
            guard let path, let range else {
                return []
            }
            return [SourceRange(path: path, range: range)]
        }

        let mainLocation = Location(path: path, range: diagnostic.range)
        let mainSourceRanges = sourceRanges(path: path, range: diagnostic.range)

        var childDiagnostics = [Diagnostic]()

        if let path {
            // The path is needed to create fixits

            for fixit in diagnostic.solutions {
                childDiagnostics.append(
                    Diagnostic(
                        behavior: .note,
                        location: mainLocation,
                        sourceRanges: mainSourceRanges,
                        data: DiagnosticData(fixit.summary),
                        fixIts: fixit.replacements.map {
                            Diagnostic.FixIt(
                                sourceRange: SourceRange(path: path, range: $0.range),
                                newText: $0.text
                            )
                        },
                        childDiagnostics: []
                    )
                )
            }
        }

        for note in diagnostic.notes {
            let notePath = note.source.map { Path($0.path) }
            childDiagnostics.append(
                Diagnostic(
                    behavior: .note,
                    location: Location(path: notePath, range: note.range),
                    sourceRanges: sourceRanges(path: notePath, range: note.range),
                    data: DiagnosticData(note.message),
                    fixIts: [],
                    childDiagnostics: []
                )
            )
        }

        if let explanation = diagnostic.explanation, mainLocation != .unknown {
            childDiagnostics.append(
                Diagnostic(
                    behavior: .note,
                    location: mainLocation,
                    sourceRanges: mainSourceRanges,
                    data: DiagnosticData(explanation),
                    fixIts: [],
                    childDiagnostics: []
                )
            )
        }

        self.init(
            behavior: Behavior(diagnostic.severity),
            location: mainLocation,
            sourceRanges: mainSourceRanges,
            data: DiagnosticData(diagnostic.summary),
            fixIts: [], // DocC Solutions are created as child diagnostics to customize the fix-it messages
            childDiagnostics: childDiagnostics
        )
    }
}

private extension Diagnostic.Behavior {
    init(_ severity: DiagnosticFile.Diagnostic.Severity) {
        switch severity {
        case .error:
            self = .error
        case .warning:
            self = .warning
        case .note:
            self = .note
        case .remark:
            self = .remark
        }
    }
}

private extension Diagnostic.Location {
    init(path: Path?, range: DiagnosticFile.Diagnostic.Range?) {
        if let path {
            self = .path(path, line: range?.start.line, column: range?.start.column)
        } else {
            self = .unknown
        }
    }
}

private extension Diagnostic.SourceRange {
    init(path: Path, range: DiagnosticFile.Diagnostic.Range) {
        self.init(
            path: path,
            startLine: range.start.line, startColumn: range.start.column,
            endLine: range.end.line, endColumn: range.end.column
        )
    }
}

