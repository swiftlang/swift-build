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

public import SWBUtil
public import SWBMacro
import Foundation


/// Abstract C Compiler.  This is not a concrete implementation, but rather it uses various information in the command build context to choose a specific compiler and to call `constructTasks()` on that compiler.  This provides a level of indirection for projects that just want their source files compiled using the default C compiler.  Depending on the context, the default C compiler for any particular combination of platform, architecture, and other factors may be Clang, ICC, GCC, or some other compiler.
class AbstractCCompilerSpec : CompilerSpec, SpecIdentifierType, GCCCompatibleCompilerCommandLineBuilder, @unchecked Sendable {
    static let identifier = "com.apple.compilers.gcc"

    override func resolveConcreteSpec(_ cbc: CommandBuildContext) -> CommandLineToolSpec {
        // Look up the “effective” compiler specification based on GCC_VERSION and other factors.
        // FIXME: Xcode implements various checks here, and we should do the same.  In particular we should look at GCC_VERSION.
        let compilerIdentifier = ClangCompilerSpec.identifier
        let spec = cbc.producer.getSpec(compilerIdentifier)

        // FIXME: We should report an error if we didn’t end up finding a valid spec.
        guard let compilerSpec = spec as? CompilerSpec else { return self }

        return compilerSpec
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: Report an error if we are ever asked to produce tasks directly.
    }
}

public struct ClangPrefixInfo: Serializable, Hashable, Encodable, Sendable {
    let input: Path
    let pch: PCHInfo?

    struct PCHInfo: Serializable, Hashable, Encodable {
        let output: Path
        let hashCriteria: Path? // Should be non-optional, but blocked on: <rdar://problem/24469921> [Swift Build] Complete handling of PCH precompiling
        let commandLine: [ByteString]

        private enum CodingKeys: CodingKey {
            case output
            case hashCriteria
            case commandLine
        }

        init(output: Path, hashCriteria: Path?, commandLine: [ByteString]) {
            self.output = output
            self.hashCriteria = hashCriteria
            self.commandLine = commandLine
        }

        func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(3) {
                serializer.serialize(self.output)
                serializer.serialize(self.hashCriteria)
                serializer.serialize(self.commandLine)
            }
        }

        init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(3)
            self.output = try deserializer.deserialize()
            self.hashCriteria = try deserializer.deserialize()
            self.commandLine = try deserializer.deserialize()
        }
    }

    init(input: Path, pch: PCHInfo?) {
        self.input = input
        self.pch = pch
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(self.input)
            serializer.serialize(self.pch)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.input = try deserializer.deserialize()
        self.pch = try deserializer.deserialize()
    }
}

/// The minimal data we need to serialize to reconstruct `ClangSourceFileIndexingInfo` from `generateIndexingInfo`
fileprivate struct ClangIndexingPayload: Serializable, Encodable, Sendable {
    let sourceFileIndex: Int
    let outputFileIndex: Int
    let sourceLanguageIndex: Int
    let builtProductsDir: Path
    let assetSymbolIndexPath: Path
    let workingDir: Path
    let prefixInfo: ClangPrefixInfo?
    let toolchains: [String]
    let responseFileAttachmentPaths: [Path: Path]

    init(sourceFileIndex: Int,
         outputFileIndex: Int,
         sourceLanguageIndex: Int,
         builtProductsDir: Path,
         assetSymbolIndexPath: Path,
         workingDir: Path,
         prefixInfo: ClangPrefixInfo?,
         toolchains: [String],
         responseFileAttachmentPaths: [Path: Path]) {
        self.sourceFileIndex = sourceFileIndex
        self.outputFileIndex = outputFileIndex
        self.sourceLanguageIndex = sourceLanguageIndex
        self.builtProductsDir = builtProductsDir
        self.assetSymbolIndexPath = assetSymbolIndexPath
        self.workingDir = workingDir
        self.prefixInfo = prefixInfo
        self.toolchains = toolchains
        self.responseFileAttachmentPaths = responseFileAttachmentPaths
    }

    func sourceFile(for task: any ExecutableTask) -> Path {
        return Path(task.commandLine[self.sourceFileIndex].asString)
    }

    func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(9) {
            serializer.serialize(sourceFileIndex)
            serializer.serialize(outputFileIndex)
            serializer.serialize(sourceLanguageIndex)
            serializer.serialize(builtProductsDir)
            serializer.serialize(assetSymbolIndexPath)
            serializer.serialize(workingDir)
            serializer.serializeUniquely(prefixInfo)
            serializer.serialize(toolchains)
            serializer.serialize(responseFileAttachmentPaths)
        }
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(9)
        self.sourceFileIndex = try deserializer.deserialize()
        self.outputFileIndex = try deserializer.deserialize()
        self.sourceLanguageIndex = try deserializer.deserialize()
        self.builtProductsDir = try deserializer.deserialize()
        self.assetSymbolIndexPath = try deserializer.deserialize()
        self.workingDir = try deserializer.deserialize()
        self.prefixInfo = try deserializer.deserializeUniquely()
        self.toolchains = try deserializer.deserialize()
        self.responseFileAttachmentPaths = try deserializer.deserialize()
    }
}

/// The indexing info for a file being compiled by clang.  This will be sent to the client in a property list format described below.
public struct ClangSourceFileIndexingInfo: SourceFileIndexingInfo {
    let outputFile: Path
    let sourceLanguage: ByteString
    let commandLine: [ByteString]
    let builtProductsDir: Path
    let assetSymbolIndexPath: Path
    let prefixInfo: ClangPrefixInfo?
    let toolchains: [String]

    init(outputFile: Path, sourceLanguage: ByteString, commandLine: [ByteString], builtProductsDir: Path, assetSymbolIndexPath: Path, prefixInfo: ClangPrefixInfo?, toolchains: [String]) {
        self.outputFile = outputFile
        self.sourceLanguage = sourceLanguage
        self.commandLine = commandLine
        self.builtProductsDir = builtProductsDir
        self.assetSymbolIndexPath = assetSymbolIndexPath
        self.prefixInfo = prefixInfo
        self.toolchains = toolchains
    }

    fileprivate init(task: any ExecutableTask, payload: ClangIndexingPayload, enableIndexBuildArena: Bool) {
        self.outputFile = Path(task.commandLine[payload.outputFileIndex].asString)
        self.sourceLanguage = task.commandLine[payload.sourceLanguageIndex].asByteString
        self.commandLine = Self.indexingCommandLine(from: task.commandLine.map(\.asByteString), workingDir: payload.workingDir, prefixInfo: payload.prefixInfo, addSupplementary: !enableIndexBuildArena, responseFileMapping: payload.responseFileAttachmentPaths)
        self.builtProductsDir = payload.builtProductsDir
        self.assetSymbolIndexPath = payload.assetSymbolIndexPath
        self.prefixInfo = payload.prefixInfo
        self.toolchains = payload.toolchains
    }

    static let skippedArgsWithoutValues = Set<ByteString>(["-M", "-MD", "-MMD", "-MG", "-MJ", "-MM", "-MP", "-MV", "-fmodules-validate-once-per-build-session"])
    static let skippedArgsWithValues = Set<ByteString>(["-MT", "-MF", "-MQ", "--serialize-diagnostics"])

    public static func indexingCommandLine(from commandLine: [ByteString], workingDir: Path, prefixInfo: ClangPrefixInfo? = nil, addSupplementary: Bool = true, replaceCompile: Bool = true, responseFileMapping: [Path: Path]) -> [ByteString] {
        var result = [ByteString]()
        var iterator = commandLine.makeIterator()
        let _ = iterator.next() // Skip compiler path

        while let arg = iterator.next() {
            if skippedArgsWithValues.contains(arg) {
                // Skip arg and value
                _ = iterator.next() // Ignore failure...
            } else if skippedArgsWithoutValues.contains(arg) {
                // Skip
            } else if arg == "-c" && replaceCompile {
                result.append("-fsyntax-only")
            } else if let prefixInfo = prefixInfo, let pchInfo = prefixInfo.pch, arg == "-include" {
                // Replace the PCH with the underlying header. Indexing will replace
                // this with its own PCH if necessary.

                result.append(arg)

                guard let includePathBytes = iterator.next() else {
                    break
                }

                if let includePath = includePathBytes.stringValue,
                   pchInfo.output.str.hasPrefix(includePath) {
                    result.append(ByteString(encodingAsUTF8: prefixInfo.input.str))
                } else {
                    result.append(includePathBytes)
                }
            } else if arg.bytes.starts(with: ByteString(stringLiteral: "-fbuild-session-file=").bytes) {
                // Skip
            } else if arg.starts(with: ByteString(unicodeScalarLiteral: "@")),
                      let attachmentPath = responseFileMapping[Path(arg.asString.dropFirst())],
                      let responseFileArgs = try? ResponseFiles.expandResponseFiles(["@\(attachmentPath.str)"], fileSystem: localFS, relativeTo: workingDir) {
                result.append(contentsOf: responseFileArgs.map { ByteString(encodingAsUTF8: $0) })
            } else {
                result.append(arg)
            }
        }

        // For <rdar://problem/8397100> Xcode4 can't see headers within relative paths
        result.append(ByteString(encodingAsUTF8: "-working-directory=\(workingDir.str)"))

        // Supplementary indexing parameters have already been added when the
        // arena is enabled, just remove any unneeded options in that case.
        if addSupplementary {
            result += ClangCompilerSpec.supplementalIndexingArgs(allowCompilerErrors: false).map { ByteString(encodingAsUTF8: $0) }
        }

        return result
    }

    /// The indexing info is packaged and sent to the client in the property list format defined here.
    public var propertyListItem: PropertyListItem {
        var dict = [String: PropertyListItem]()

        // sourceFile is not in this dictionary

        dict["outputFilePath"] = PropertyListItem(outputFile.str)

        // FIXME: Convert to bytes.
        dict["LanguageDialect"] = PropertyListItem(sourceLanguage.asString)
        // FIXME: Convert to bytes.
        dict["clangASTCommandArguments"] = PropertyListItem(commandLine.map{ $0.asString })
        dict["clangASTBuiltProductsDir"] = PropertyListItem(builtProductsDir.str)
        dict["assetSymbolIndexPath"] = PropertyListItem(assetSymbolIndexPath.str)

        if let prefixInfo = self.prefixInfo {
            dict["clangPrefixFilePath"] = PropertyListItem(prefixInfo.input.str)

            if let pch = prefixInfo.pch {
                dict["clangPCHFilePath"] = PropertyListItem(pch.output.str)

                if let hashCriteria = pch.hashCriteria {
                    dict["clangPCHHashCriteria"] = PropertyListItem(hashCriteria.str)
                }

                // FIXME: Convert to bytes.
                dict["clangPCHCommandArguments"] = PropertyListItem(pch.commandLine.map{ $0.asString })
            }
        }

        dict["toolchains"] = PropertyListItem(toolchains)

        return .plDict(dict)
    }
}

extension OutputPathIndexingInfo {
    fileprivate init(task: any ExecutableTask, payload: ClangIndexingPayload) {
        self.outputFile = Path(task.commandLine[payload.outputFileIndex].asString)
    }
}

public enum ClangOutputParserRegex {
    // 'Foo/Foo.h' file not found
    public static let headerNotFoundRegEx = (RegEx(patternLiteral: "^'([^/]+)/.*' file not found$"), false)

    // module 'Foo' not found
    public static let moduleNotFoundRegEx = (RegEx(patternLiteral: "^module '(.+)' not found$"), true)
}

final class ClangOutputParser: TaskOutputParser {
    private let task: any ExecutableTask
    private let payload: ClangTaskPayload

    let workspaceContext: WorkspaceContext
    let buildRequestContext: BuildRequestContext
    let delegate: any TaskOutputParserDelegate

    init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.task = task
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
        self.payload = task.payload as! ClangTaskPayload
    }

    func write(bytes: ByteString) {
        // Forward the unparsed bytes immediately (without line buffering).
        delegate.emitOutput(bytes)

        // Disable diagnostic scraping, since we use serialized diagnostics.
    }

    func close(result: TaskResult?) {
        defer {
            delegate.close()
        }
        // Don't try to read diagnostics if the process crashed or got cancelled as they were almost certainly not written in this case.
        if result.shouldSkipParsingDiagnostics { return }

        for path in task.type.serializedDiagnosticsPaths(task, workspaceContext.fs) {
            delegate.processSerializedDiagnostics(at: path, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext)
        }

        // Read optimization remarks if the build succeeded.
        if result?.isSuccess ?? false {
            // If the object file path is not there, remarks might not be generated.
            if let path = payload.outputObjectFilePath {
                delegate.processOptimizationRemarks(at: path, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext)
            }
        }
    }
}

public struct ClangExplicitModulesPayload: Serializable, Encodable, Sendable {
    public let uniqueID: String
    public let sourcePath: Path
    public let libclangPath: Path
    public let usesCompilerLauncher: Bool
    public let outputPath: Path
    public let scanningOutputPath: Path
    public let casOptions: CASOptions?
    public let cacheFallbackIfNotAvailable: Bool
    public let dependencyFilteringRootPath: Path?
    public let reportRequiredTargetDependencies: BooleanWarningLevel
    public let verifyingModule: String?

    fileprivate init(uniqueID: String, sourcePath: Path, libclangPath: Path, usesCompilerLauncher: Bool, outputPath: Path, scanningOutputPath: Path, casOptions: CASOptions?, cacheFallbackIfNotAvailable: Bool, dependencyFilteringRootPath: Path?, reportRequiredTargetDependencies: BooleanWarningLevel, verifyingModule: String?) {
        self.uniqueID = uniqueID
        self.sourcePath = sourcePath
        self.libclangPath = libclangPath
        self.usesCompilerLauncher = usesCompilerLauncher
        self.outputPath = outputPath
        self.scanningOutputPath = scanningOutputPath
        self.casOptions = casOptions
        self.cacheFallbackIfNotAvailable = cacheFallbackIfNotAvailable
        self.dependencyFilteringRootPath = dependencyFilteringRootPath
        self.reportRequiredTargetDependencies = reportRequiredTargetDependencies
        self.verifyingModule = verifyingModule
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(11) {
            serializer.serialize(uniqueID)
            serializer.serialize(sourcePath)
            serializer.serialize(libclangPath)
            serializer.serialize(usesCompilerLauncher)
            serializer.serialize(outputPath)
            serializer.serialize(scanningOutputPath)
            serializer.serialize(casOptions)
            serializer.serialize(cacheFallbackIfNotAvailable)
            serializer.serialize(dependencyFilteringRootPath)
            serializer.serialize(reportRequiredTargetDependencies)
            serializer.serialize(verifyingModule)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(11)
        self.uniqueID = try deserializer.deserialize()
        self.sourcePath = try deserializer.deserialize()
        self.libclangPath = try deserializer.deserialize()
        self.usesCompilerLauncher = try deserializer.deserialize()
        self.outputPath = try deserializer.deserialize()
        self.scanningOutputPath = try deserializer.deserialize()
        self.casOptions = try deserializer.deserialize()
        self.cacheFallbackIfNotAvailable = try deserializer.deserialize()
        self.dependencyFilteringRootPath = try deserializer.deserialize()
        self.reportRequiredTargetDependencies = try deserializer.deserialize()
        self.verifyingModule = try deserializer.deserialize()
    }

}

public protocol ClangModuleVerifierPayloadType: TaskPayload {
    var fileNameMapPath: Path? { get }
}

struct ClangModuleVerifierPayload: ClangModuleVerifierPayloadType {
    var fileNameMapPath: Path?

    func serialize<T>(to serializer: T) where T : SWBUtil.Serializer {
        serializer.serialize(fileNameMapPath)
    }

    init(from deserializer: any SWBUtil.Deserializer) throws {
        self.fileNameMapPath = try deserializer.deserialize()
    }

    init(fileNameMapPath: Path?) {
        self.fileNameMapPath = fileNameMapPath
    }
}

public struct ClangTaskPayload: ClangModuleVerifierPayloadType, DependencyInfoEditableTaskPayload, Encodable {
    let dependencyInfoEditPayload: DependencyInfoEditPayload?

    /// The path to the serialized diagnostic output.  Every clang task must provide this path.
    public let serializedDiagnosticsPath: Path?

    /// Additional information used to answer indexing queries.  Not all clang tasks will need to provide indexing info (for example, precompilation tasks don't).
    fileprivate let indexingPayload: ClangIndexingPayload?

    /// Additional information used by explicit modules support.
    public let explicitModulesPayload: ClangExplicitModulesPayload?

    /// Additional information used by optimization remarks support.
    fileprivate let outputObjectFilePath: Path?

    public let fileNameMapPath: Path?

    fileprivate init(serializedDiagnosticsPath: Path?, indexingPayload: ClangIndexingPayload?, explicitModulesPayload: ClangExplicitModulesPayload? = nil, outputObjectFilePath: Path? = nil, fileNameMapPath: Path? = nil, developerPathString: String? = nil) {
        if let developerPathString, explicitModulesPayload == nil {
            self.dependencyInfoEditPayload = .init(removablePaths: [], removableBasenames: [], developerPath: Path(developerPathString))
        } else {
            dependencyInfoEditPayload = nil
        }
        self.serializedDiagnosticsPath = serializedDiagnosticsPath
        self.indexingPayload = indexingPayload
        self.explicitModulesPayload = explicitModulesPayload
        self.outputObjectFilePath = outputObjectFilePath
        self.fileNameMapPath = fileNameMapPath
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(6) {
            serializer.serialize(serializedDiagnosticsPath)
            serializer.serialize(indexingPayload)
            serializer.serialize(explicitModulesPayload)
            serializer.serialize(outputObjectFilePath)
            serializer.serialize(fileNameMapPath)
            serializer.serialize(dependencyInfoEditPayload)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.serializedDiagnosticsPath = try deserializer.deserialize()
        self.indexingPayload = try deserializer.deserialize()
        self.explicitModulesPayload = try deserializer.deserialize()
        self.outputObjectFilePath = try deserializer.deserialize()
        self.fileNameMapPath = try deserializer.deserialize()
        self.dependencyInfoEditPayload = try deserializer.deserialize()
    }
}

/// Helper for fast argument matching.
//
// FIXME: We should eventually just redefine this to be based on regular
// expressions, not fnmatch, and then use a fast regular expression engine to
// manage this.
public enum FlagPattern: Sendable {
    /// Check for an exact string.
    case exact(String)

    /// Check for a prefix.
    case prefix(String)

    /// Use a general purpose fnmatch pattern.
    case fnmatch(String)

    /// Create a flag pattern from a fnmatch(3) style pattern.
    public static func fromFnmatch(_ pattern: String) -> FlagPattern {
        // If the pattern contains any particularly special fnmatch characters, fall back.
        if pattern.contains("?") || pattern.contains("[") {
            return .fnmatch(pattern)
        }

        // If the pattern contains only the special '*' character at the end,
        // see if we can use a prefix match.
        if pattern.contains("*") {
            if pattern.hasSuffix("*") && !pattern.hasSuffix("\\*") && !pattern.dropLast(1).contains("*") {
                return .prefix(String(pattern.dropLast(1)))
            } else {
                return .fnmatch(pattern)
            }
        }

        // Otherwise, we have an exact match.
        return .exact(pattern)
    }

    /// Check if the pattern matches a given string.
    public func matches(_ string: String) -> Bool {
        switch self {
        case .exact(let pattern):
            return string == pattern
        case .prefix(let pattern):
            return string.hasPrefix(pattern)
        case .fnmatch(let pattern):
            // `fnmatch` is not really expected to fail so there is not a lot of
            // benefit in handling the errors.
            return (try? SWBUtil.fnmatch(pattern: pattern, input: string)) == true
        }
    }
}


public class ClangCompilerSpec : CompilerSpec, SpecIdentifierType, GCCCompatibleCompilerCommandLineBuilder, @unchecked Sendable {
    /// Clang compiler data cache, used to cache constant flags.
    fileprivate final class DataCache: SpecDataCache {
        fileprivate struct ConstantFlagsKey: Hashable, Sendable {
            /// The scope in use.
            let scope: MacroEvaluationScope

            /// The input file type.
            let inputFileType: FileTypeSpec

            public func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(scope))
                hasher.combine(inputFileType)
            }
        }
        fileprivate struct ConstantFlags {
            /// The flags themselves.
            let flags: [String]

            /// The header search path arguments used to compute these flags.
            let headerSearchPaths: SearchPaths

            /// The compilation inputs implied by these flags.
            let inputs: [Path]

            /// Maps response files in `flags` to the corresponding recorded attachment in the build description.
            let responseFileMapping: [Path: Path]

        }

        /// Cache of constant flags, keyed by the scope and input file type.
        private let constantFlagsCache = Registry<ConstantFlagsKey, ConstantFlags>()

        required init() { }

        func getStandardFlags(_ spec: ClangCompilerSpec, producer: any CommandProducer, scope: MacroEvaluationScope, optionContext: (any BuildOptionGenerationContext)?, delegate: any TaskGenerationDelegate, inputFileType: FileTypeSpec) -> ConstantFlags {
            // This cache is per-producer, so it is guaranteed to be invariant based on that.
            constantFlagsCache.getOrInsert(ConstantFlagsKey(scope: scope, inputFileType: inputFileType)) {
                return spec.standardFlags(producer, scope: scope, optionContext: optionContext, delegate: delegate, inputFileType: inputFileType)
            }
        }
    }

    private typealias ConstantFlags = DataCache.ConstantFlags

    /// The class name under which we’re known in .xcspec files.
    public class var identifier: String {
        "com.apple.compilers.llvm.clang.1_0.compiler"
    }

    /// The GCC language names to support precompiling for.
    static let gccLanguagesToPrecompile = GCCCompatibleLanguageDialect.allCLanguages

    /// The output file extension to use (an extension point for the static analyzer, as well as generating assembly and preprocessor output).
    func outputFileExtension(for input: FileToBuild) -> String {
        return ".o"
    }

    /// Whether to add serialize diagnostics options (an extension point for the static analyzer).
    func serializedDiagnosticsOptions(scope: MacroEvaluationScope, outputPath: Path) -> (path: Path, flags: [String])? {
        if scope.evaluate(BuiltinMacros.CLANG_DISABLE_SERIALIZED_DIAGNOSTICS) {
            return nil
        }
        let diagFilePath = Path(outputPath.withoutSuffix + ".dia")
        return (diagFilePath, ["--serialize-diagnostics", diagFilePath.str])
    }

    var effectiveSourceFileOption: String {
        return sourceFileOption ?? "-c"
    }

    var shouldPrecompilePrefixHeader: Bool {
        return true
    }

    /// List of fnmatch()-style patterns for command line arguments that do not affect the validity of a precompiled header.  Could be empty.
    let precompNeutralFlagPatterns: [FlagPattern]

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        // Parse an array of fnmatch()-style patterns for command line arguments that do not affect the validity of a precompiled header.
        self.precompNeutralFlagPatterns = (parser.parseStringList("PatternsOfFlagsNotAffectingPrecomps") ?? []).map(FlagPattern.fromFnmatch)

        // Parse and ignore the 'RuleName' key (for now).
        //
        // This is handled by the generic spec in Xcode, but we more strictly enforce the separation between "generic" tools and non-generic ones.
        parser.parseObject("RuleName")

        super.init(parser, basedOnSpec, isGeneric: false)
    }

    private func standardFlags(_ producer: any CommandProducer, scope: MacroEvaluationScope, optionContext: (any BuildOptionGenerationContext)?, delegate: any TaskGenerationDelegate, inputFileType: FileTypeSpec) -> ConstantFlags {
        var commandLine = Array<String>()

        // Add the arguments from the specification.
        commandLine += self.commandLineFromOptions(producer, scope: scope, inputFileType: inputFileType, optionContext: optionContext,lookup: { declaration in
            if declaration.name == "CLANG_INDEX_STORE_ENABLE" && optionContext is DiscoveredClangToolSpecInfo {
                let clangToolInfo = optionContext as! DiscoveredClangToolSpecInfo
                if !clangToolInfo.isAppleClang {
                    return BuiltinMacros.namespace.parseString("NO")
                }
            }
            return nil
        }).map(\.asString)

        // Add the common header search paths.
        let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(producer, scope, usesModules: scope.evaluate(BuiltinMacros.CLANG_ENABLE_MODULES))
        commandLine += headerSearchPaths.searchPathArguments(for: self, scope: scope)

        // Add per-architecture flags (this is slated for deprecation, since there are now simpler ways to accomplish the same thing).
        commandLine += scope.evaluate(BuiltinMacros.PER_ARCH_CFLAGS)

        // Add warning flags (this is slated for deprecation, since there are now simpler ways to accomplish the same thing).
        commandLine += scope.evaluate(BuiltinMacros.WARNING_CFLAGS)

        // Add optimization flags (this is slated for deprecation, since there are now simpler ways to accomplish the same thing).
        commandLine += scope.evaluate(BuiltinMacros.OPTIMIZATION_CFLAGS)

        // Add the common framework search paths.
        let frameworkSearchPaths = GCCCompatibleCompilerSpecSupport.frameworkSearchPathArguments(producer, scope)
        commandLine += frameworkSearchPaths.searchPathArguments(for: self, scope: scope)

        // Add GLOBAL_CFLAGS (this is slated for deprecation, since there are now simpler ways to accomplish the same thing).
        commandLine += scope.evaluate(BuiltinMacros.GLOBAL_CFLAGS)

        // Add either OTHER_CPLUSPLUSFLAGS or OTHER_CFLAGS.
        if let dialect = inputFileType.languageDialect, dialect.isPlusPlus {
            commandLine += scope.evaluate(BuiltinMacros.OTHER_CPLUSPLUSFLAGS)
        } else {
            commandLine += scope.evaluate(BuiltinMacros.OTHER_CFLAGS)
        }

        // Add per-variant flags (this is slated for deprecation, since there are now simpler ways to accomplish the same thing).
        commandLine += scope.evaluate(BuiltinMacros.PER_VARIANT_CFLAGS)

        // If we’re building the “profile” variant and if GCC_GENERATE_PROFILING_CODE is true then also add "-pg".
        if scope.evaluate(BuiltinMacros.CURRENT_VARIANT) == "profile" && scope.evaluate(BuiltinMacros.GCC_GENERATE_PROFILING_CODE) {
            commandLine.append("-pg")
        }

        // Add search paths for sparse SDKs.
        let sparseSDKSearchPaths = GCCCompatibleCompilerSpecSupport.sparseSDKSearchPathArguments(producer.sparseSDKs, headerSearchPaths.headerSearchPaths, frameworkSearchPaths.frameworkSearchPaths)
        commandLine += sparseSDKSearchPaths.searchPathArguments(for: self, scope: scope)

        if scope.evaluate(BuiltinMacros.CLANG_USE_RESPONSE_FILE) && (optionContext?.toolPath.basenameWithoutSuffix == "clang" || optionContext?.toolPath.basenameWithoutSuffix == "clang++") {
            var responseFileCommandLine: [String] = []
            var regularCommandLine: [String] = []

            var iterator = commandLine.makeIterator()
            var previousArg: ByteString? = nil
            while let arg = iterator.next() {
                let argAsByteString = ByteString(encodingAsUTF8: arg)
                if ClangSourceFileIndexingInfo.skippedArgsWithValues.contains(argAsByteString) || arg == "-include" {
                    // Relevant to indexing, so exclude arg and value from response file.
                    regularCommandLine.append(arg)
                    if let nextArg = iterator.next() {
                        regularCommandLine.append(nextArg)
                    }
                } else if ClangSourceFileIndexingInfo.skippedArgsWithoutValues.contains(argAsByteString) || arg.starts(with: "-fbuild-session-file=") {
                    // Relevant to indexing, so exclude arg from response file.
                    regularCommandLine.append(arg)
                } else if isOutputAgnosticCommandLineArgument(argAsByteString, prevArgument: previousArg) {
                    // Output agnostic, so exclude from response file.
                    regularCommandLine.append(arg)
                } else if precompNeutralFlagPatterns.map({ $0.matches(arg) }).reduce(false, { $0 || $1 }) && !(previousArg ?? "").hasPrefix("-X") {
                    // Exclude from response file.
                    regularCommandLine.append(arg)
                } else {
                    responseFileCommandLine.append(arg)
                }
                previousArg = argAsByteString
            }

            let ctx = InsecureHashContext()
            ctx.add(string: inputFileType.identifier)
            ctx.add(string: self.identifier)

            let responseFilePath = scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR).join("\(ctx.signature.asString)-common-args.resp")
            let attachmentPath = producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: producer, scope: scope, inputs: [], output: responseFilePath), delegate, contents: ByteString(encodingAsUTF8: ResponseFiles.responseFileContents(args: responseFileCommandLine)), permissions: nil, logContents: true, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])

            return ConstantFlags(flags: regularCommandLine + ["@\(responseFilePath.str)"], headerSearchPaths: headerSearchPaths, inputs: [responseFilePath], responseFileMapping: [responseFilePath: attachmentPath])
        } else {
            return ConstantFlags(flags: commandLine, headerSearchPaths: headerSearchPaths, inputs: [], responseFileMapping: [:])
        }
    }

    override public func resolvedSourceFileType(file: FileToBuild, inBuildContext cbc: CommandBuildContext, delegate: any TaskGenerationDelegate) -> FileTypeSpec {
        var fileType = super.resolvedSourceFileType(file: file, inBuildContext: cbc, delegate: delegate)

        // If the target uses GCC_INPUT_FILETYPE to override the language, use that
        let overrideFileTypeIdent = cbc.scope.evaluate(BuiltinMacros.GCC_INPUT_FILETYPE)
        if !overrideFileTypeIdent.isEmpty && overrideFileTypeIdent != "automatic" {
            if let overriddenType = cbc.producer.lookupFileType(identifier: overrideFileTypeIdent) {
                fileType = overriddenType
            } else {
                delegate.warning("unsupported value '\(overrideFileTypeIdent)' for build setting GCC_INPUT_FILETYPE")
            }
        }

        let targetFlags: [String]
        if let dialect = fileType.languageDialect, dialect.isPlusPlus {
            targetFlags = cbc.scope.evaluate(BuiltinMacros.OTHER_CPLUSPLUSFLAGS)
        } else {
            targetFlags = cbc.scope.evaluate(BuiltinMacros.OTHER_CFLAGS)
        }

        let fileFlags: [String]
        if let additionalArgs = file.additionalArgs {
            fileFlags = cbc.scope.evaluate(additionalArgs)
        } else {
            fileFlags = []
        }

        // If OTHER_C[PLUSPLUS]FLAGS or file-specific flags use -x to override the language, use that
        if let dialectName = [targetFlags, fileFlags].compactMap({ $0.byExtractingElementsHavingPrefix("-x").last }).last {
            if let overriddenType = cbc.producer.lookupFileType(languageDialect: GCCCompatibleLanguageDialect(dialectName: dialectName)) {
                fileType = overriddenType
            }
        }

        return fileType
    }

    static let outputAgnosticCompilerArguments = Set<ByteString>([
        // https://clang.llvm.org/docs/UsersManual.html#formatting-of-diagnostics
        "-fshow-column",
        "-fno-show-column",
        "-fshow-source-location",
        "-fno-show-source-location",
        "-fcaret-diagnostics",
        "-fno-caret-diagnostics",
        "-fcolor-diagnostics",
        "-fno-color-diagnostics",
        "-fansi-escape-codes",
        "-fdiagnostics-show-option",
        "-fno-diagnostics-show-option",
        "-fdiagnostics-show-hotness",
        "-fno-diagnostics-show-hotness",
        "-fdiagnostics-fixit-info",
        "-fno-diagnostics-fixit-info",
        "-fdiagnostics-print-source-range-info",
        "-fdiagnostics-parseable-fixits",
        "-fno-elide-type",
        "-fdiagnostics-show-template-tree",

        // https://clang.llvm.org/docs/ClangCommandLineReference.html
        "-fdiagnostics-show-note-include-stack",
        "-fno-diagnostics-show-note-include-stack",
        "-fmodules-validate-once-per-build-session",
    ])

    static let outputAgnosticCompilerArgumentPrefixes = Set<ByteString>([
        // https://clang.llvm.org/docs/UsersManual.html#formatting-of-diagnostics
        "-fdiagnostics-format=",
        "-fdiagnostics-show-category=",
        "-fdiagnostics-hotness-threshold=",

        // https://clang.llvm.org/docs/ClangCommandLineReference.html
        "-fmessage-length=",
        "-fmacro-backtrace-limit=",
        "-fbuild-session-timestamp=",
    ])

    static let outputAgnosticCompilerArgumentsWithValues = Set<ByteString>([
        "-index-store-path",
        "-index-unit-output-path",
    ])

    func isOutputAgnosticCommandLineArgument(_ argument: ByteString, prevArgument: ByteString?) -> Bool {
        if ClangCompilerSpec.outputAgnosticCompilerArguments.contains(argument) ||
           ClangCompilerSpec.outputAgnosticCompilerArgumentsWithValues.contains(argument) {
            return true
        }

        if ClangCompilerSpec.outputAgnosticCompilerArgumentPrefixes.first(where: { argument.hasPrefix($0) }) != nil {
            return true
        }

        if let prevArgument, ClangCompilerSpec.outputAgnosticCompilerArgumentsWithValues.contains(prevArgument) {
          return true
        }

        return false
    }

    public override func commandLineForSignature(for task: any ExecutableTask) -> [ByteString] {
        // TODO: We should probably allow the specs themselves to mark options
        // as output agnostic, rather than always postprocessing the command
        // line. In some cases we will have to postprocess, because of settings
        // like OTHER_CFLAGS where the user can't possibly add this metadata to
        // the values, but those settings be handled on a case-by-case basis.
        return task.commandLine.indices.compactMap { index in
            let arg = task.commandLine[index].asByteString
            let prevArg = index > task.commandLine.startIndex ? task.commandLine[index - 1].asByteString : nil
            if isOutputAgnosticCommandLineArgument(arg, prevArgument: prevArg) {
                return nil
            }
            return arg
        }
    }

    func cachingBuildEnabled(
        _ cbc: CommandBuildContext,
        language: GCCCompatibleLanguageDialect,
        clangInfo: DiscoveredClangToolSpecInfo?
    ) -> Bool {
        guard cbc.producer.supportsCompilationCaching else { return false }

        // Disabling compilation caching for index build, for now.
        guard !cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA) else {
            return false
        }

        let enabledCppModules: Bool = {
            guard language.isPlusPlus else {
                return false
            }
            // When response file is used the flag is in the response file, not in the commandLine array,
            // so check the build setting.
            if cbc.scope.evaluate(BuiltinMacros.OTHER_CPLUSPLUSFLAGS).contains("-fcxx-modules") {
                return true
            }
            return false
        }()

        guard !enabledCppModules else {
            return false
        }

        let buildSettingEnabled = cbc.scope.evaluate(BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE)

        // If a blocklist is provided in the toolchain, use it to determine the default for the current project
        guard let blocklist = clangInfo?.clangCachingBlocklist else {
            return buildSettingEnabled
        }

        // If this project is on the blocklist, override the blocklist default enable for it
        if blocklist.isProjectListed(cbc.scope) {
            return false
        }
        return buildSettingEnabled
    }

    private func createExplicitModulesActionAndPayload(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ compilerLauncher: Path?, _ input: FileToBuild, _ language: GCCCompatibleLanguageDialect?, commandLine: [String], scanningOutputPath: Path, isForPCHTask: Bool, clangInfo: DiscoveredClangToolSpecInfo?) -> (action: (any PlannedTaskAction)?, usesExecutionInputs: Bool, payload: ClangExplicitModulesPayload?, signatureData: String?) {
        guard let language else {
            // Unknown language.
            return (nil, false, nil, nil)
        }

        // SourceKit does not currently use explicit modules when generating an AST. Don't generate a payload here, or we might build a PCH it can't load later.
        guard !cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA) else {
            return (nil, false, nil, nil)
        }

        let cachedBuild = cachingBuildEnabled(cbc, language: language, clangInfo: clangInfo)
        let explicitModules = cbc.scope.evaluate(BuiltinMacros.CLANG_ENABLE_MODULES)
        && (cbc.scope.evaluate(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES) || cbc.scope.evaluate(BuiltinMacros._EXPERIMENTAL_CLANG_EXPLICIT_MODULES))

        let explicitModulesLanguages: Set<GCCCompatibleLanguageDialect> = [
            .c, .objectiveC
        ]
        let supportedLanguages = cachedBuild ? GCCCompatibleLanguageDialect.allCLanguages : explicitModulesLanguages

        // Only enable dep scanner if requested by the user and if the language supports it.
        EXPLICIT_MODULES: if cachedBuild || explicitModules, supportedLanguages.contains(language) {

            let usesCompilerLauncher = compilerLauncher != nil

            if !explicitModules && explicitModulesLanguages.contains(language) && cbc.scope.evaluate(BuiltinMacros.CLANG_ENABLE_MODULES) {
                delegate.warning("Compile caching is not supported with implicit modules; enable CLANG_ENABLE_EXPLICIT_MODULES")
                break EXPLICIT_MODULES
            }

            if usesCompilerLauncher && !cbc.scope.evaluate(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER) {
                delegate.remark("Explicit modules is not supported with C_COMPILER_LAUNCHER; disable explicit modules with CLANG_ENABLE_EXPLICIT_MODULES=NO, or enable CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER=YES if using a compatible launcher")
                break EXPLICIT_MODULES
            }

            guard let compiler = commandLine[safe: usesCompilerLauncher ? 1 : 0].map(Path.init)?.normalize() else {
                break EXPLICIT_MODULES
            }

            // Check that we are using a recognized clang.
            switch compiler.basenameWithoutSuffix {
                case "clang", "clang++":
                    break
                default:
                    // Not recognized as clang; assume the worst.
                    delegate.remark("Explicit modules is enabled but the compiler was not recognized; disable explicit modules with CLANG_ENABLE_EXPLICIT_MODULES=NO, or use C_COMPILER_LAUNCHER with CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER=YES if using a compatible launcher")
                    break EXPLICIT_MODULES
            }

            // Verify we have a clang version with the latest explicit modules bugfixes.
            if let clangVersion = clangInfo?.clangVersion, clangVersion < Version(1403, 0, 300, 5)  {
                delegate.warning("Explicit modules is not supported with Clang version \(clangVersion), continuing with explicit modules disabled.")
                break EXPLICIT_MODULES
            }

            func findLibclang() -> Path? {
                // Let the user define the path to libclang
                let userLibclang = cbc.scope.evaluate(BuiltinMacros.CLANG_EXPLICIT_MODULES_LIBCLANG_PATH)
                if !userLibclang.isEmpty {
                    return Path(userLibclang)
                }

                // If not defined, try to find one from the toolchain.
                var candidatesSkipped: [Path] = []
                for (toolchainPath, toolchainLibrarySearchPath) in cbc.producer.toolchains.map({ ($0.path, $0.librarySearchPaths) }) {
                    if let path = toolchainLibrarySearchPath.findLibrary(operatingSystem: cbc.producer.hostOperatingSystem, basename: "clang") {
                        // Check that this is the same toolchain and version as the compiler. Mismatched clang/libclang is not supported with explicit modules.
                        let compilerAndLibraryAreInSameToolchain = toolchainPath.isAncestor(of: compiler)
                        let libclangVersion = cbc.producer.lookupLibclang(path: path).version
                        let compilerAndLibraryVersionsMatch = libclangVersion != nil && libclangVersion == clangInfo?.clangVersion
                        if compilerAndLibraryAreInSameToolchain && (compilerAndLibraryVersionsMatch || cbc.scope.evaluate(BuiltinMacros.CLANG_EXPLICIT_MODULES_IGNORE_LIBCLANG_VERSION_MISMATCH)) {
                            return path
                        }
                        candidatesSkipped.append(path)
                    }
                }

                // If an open-source Swift toolchain is in use, suppress warnings about libclang mismatch.
                if !cbc.producer.toolchains.contains(where: { toolchain in
                    toolchain.identifier.hasPrefix("org.swift.")
                }) {
                    delegate.remark("Explicit modules is enabled but could not resolve libclang.dylib, continuing with explicit modules disabled.")
                    for path in candidatesSkipped {
                        delegate.note("Candidate '\(path.str)' skipped because it did not match the configured compiler")
                    }
                }
                return nil
            }

            // Find the first libclang.dylib in the configured toolchains, and set it into the environment so that the scan action can read it.
            if let libclangPath = findLibclang() {
                let action = delegate.taskActionCreationDelegate.createClangCompileTaskAction()

                let casOptions: CASOptions? = {
                    guard cachedBuild else { return nil }
                    do {
                        var casOpts = try CASOptions.create(cbc.scope, .compiler(language))
                        if casOpts.enableIntegratedCacheQueries, let clangInfo {
                            if !clangInfo.toolFeatures.has(.libclangCacheQueries) {
                                delegate.warning("COMPILATION_CACHE_ENABLE_INTEGRATED_QUERIES ignored because it's not supported by the toolchain")
                                casOpts.enableIntegratedCacheQueries = false
                            }
                        }
                        return casOpts
                    } catch {
                        delegate.error(error.localizedDescription)
                        return nil
                    }
                }()
                let explicitModulesPayload = ClangExplicitModulesPayload(
                    uniqueID: String(commandLine.hashValue),
                    sourcePath: input.absolutePath,
                    libclangPath: libclangPath,
                    usesCompilerLauncher: usesCompilerLauncher,
                    // This path is scoped to the project, so ideally different targets that use the same modules would
                    // share precompiled modules.
                    outputPath: Path(cbc.scope.evaluate(BuiltinMacros.CLANG_EXPLICIT_MODULES_OUTPUT_PATH)),
                    scanningOutputPath: scanningOutputPath,
                    casOptions: casOptions,
                    cacheFallbackIfNotAvailable: cbc.scope.evaluate(BuiltinMacros.CLANG_CACHE_FALLBACK_IF_UNAVAILABLE),
                    // To match the behavior of -MMD, our scan task should filter out headers in the SDK when discovering dependencies. In the long run, libclang should do this for us.
                    dependencyFilteringRootPath: isForPCHTask ? nil : cbc.producer.sdk?.path,
                    reportRequiredTargetDependencies: cbc.scope.evaluate(BuiltinMacros.DIAGNOSE_MISSING_TARGET_DEPENDENCIES),
                    verifyingModule: verifyingModule(cbc)
                )
                let explicitModulesSignatureData = cachedBuild ? "cached" : nil

                return (action, true, explicitModulesPayload, explicitModulesSignatureData)
            }
        }

        return (nil, false, nil, nil)
    }

    func createClangModuleVerifierPayload(_ cbc: CommandBuildContext) -> ClangModuleVerifierPayload? {
        return nil
    }

    private func compilerWorkingDirectory(_ cbc: CommandBuildContext) -> Path {
        cbc.scope.evaluate(BuiltinMacros.COMPILER_WORKING_DIRECTORY).nilIfEmpty.map { Path($0) } ?? cbc.producer.defaultWorkingDirectory
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Fetch the current architecture and variant from the command build context.
        let arch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)
        let variant = cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT)

        // Compute the input path.
        // FIXME: Disabled for now because some projects manage to end up getting here with multiple files. <rdar://problem/23682348> Project groups multiple .c files together for C compiler?
        //let input = cbc.input
        let input = cbc.inputs[0]
        let inputPath = input.absolutePath
        let inputBasename = inputPath.basename
        let (inputPrefix, _) = Path(inputBasename).splitext()

        // Our command build context should not contain any outputs, since we construct the output path ourselves.
        //
        // FIXME: This is currently possible to reach by putting source files in the resources phase, and Xcode has things that do this (maybe by virtue of being generated sources). We need to figure out how Xcode handles this and match it (or continue to warn/error).
        if !cbc.outputs.isEmpty {
            delegate.warning("unexpected C compiler invocation with specified outputs: \(cbc.outputs.map({ "'\($0.str)'" }).joined(separator: ", ")) (for input: '\(inputPath.str)')")
            return
        }

        // Compute the primary output path (the compiled object file).
        let outputPrefix = inputPrefix + input.uniquingSuffix
        let outputFileDir = self.outputFileDir(cbc)
        let outputNode = delegate.createNode(outputFileDir.join(outputPrefix + self.outputFileExtension(for: input)))

        // FIXME: Diagnose invalid file types.
        // Determine the file type of the source file — this will in turn give us the language to compile with.
        let resolvedInputFileType = resolvedSourceFileType(file: input, inBuildContext: cbc, delegate: delegate)

        // Determine the source language based on the file type.
        // It should not be an error or warning if we cannot determine the language name.
        // A user may be passing a custom file type to the compiler with a custom rule, and which does not use the -x option.
        let language = resolvedInputFileType.languageDialect?.dialectNameForCompilerCommandLineArgument

        // Create the rule info to match what Xcode does.
        let ruleInfo = self.ruleInfo(cbc, input: input.absolutePath, output: outputNode.path, variant: variant, arch: arch, language: language)

        let clangInfo: DiscoveredClangToolSpecInfo?
        do {
            clangInfo = try await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate, forLanguageOfFileType: resolvedInputFileType)
        } catch {
            delegate.error(error)
            return
        }

        let hasEnabledIndexBuildArena = cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)

        // Create the command line, as well as any input dependencies.
        var commandLine = [String]()
        var inputDeps = [Path]()
        var additionalOutput = [String]()

        // Start with the executable.
        let compilerExecPath = resolveExecutablePath(cbc, forLanguageOfFileType: resolvedInputFileType)
        let launcher = resolveCompilerLauncher(cbc, compilerPath: compilerExecPath, delegate: delegate)
        if let launcher {
            commandLine += [launcher.str]
        }
        commandLine += [compilerExecPath.str]

        // Add the source language.
        if let language {
            commandLine += ["-x", language]
        }

        // Add the build fallback VFS overlay before all other arguments so that any user-defined overlays can also be found from the regular build folder (if not found in the index arena).
        if hasEnabledIndexBuildArena && !cbc.scope.evaluate(BuiltinMacros.INDEX_REGULAR_BUILD_PRODUCTS_DIR).isEmpty && !cbc.scope.evaluate(BuiltinMacros.INDEX_DISABLE_VFS_DIRECTORY_REMAP) {
            let overlayPath = cbc.scope.evaluate(BuiltinMacros.INDEX_DIRECTORY_REMAP_VFS_FILE)
            commandLine += ["-ivfsoverlay", overlayPath]
            inputDeps.append(Path(overlayPath))
        }

        if await cbc.producer.shouldUseSDKStatCache() {
            let cachePath = Path(cbc.scope.evaluate(BuiltinMacros.SDK_STAT_CACHE_PATH))
            commandLine += ["-ivfsstatcache", cachePath.str]
        }

        // Add “standard flags”, which are ones that depend only on the scope and input file type.
        //
        // This is very expensive to compute, so we cache this across all compiler invocations based on the scope and the input file type.
        //
        // FIXME: Eventually we should just apply this optimization to all generic specs, and then find a way to piggy back on that.
        let dataCache = cbc.producer.getSpecDataCache(self, cacheType: DataCache.self)
        let constantFlags = dataCache.getStandardFlags(self, producer: cbc.producer, scope: cbc.scope, optionContext: clangInfo, delegate: delegate, inputFileType: resolvedInputFileType)
        commandLine += constantFlags.flags
        let responseFileAdditionalOutput = constantFlags.responseFileMapping.keys.sorted().map({"Using response file: \($0.str)"})
        additionalOutput.append(contentsOf: responseFileAdditionalOutput)
        inputDeps.append(contentsOf: constantFlags.inputs)

        // Add search paths for sparse SDKs.
        // FIXME: We need to add this, but it is not currently needed for the present milestone.  We will need to add some SDK APIs before we can do it.

        // NOTE: We intentionally *DO NOT* depend on the headermap inputs here.
        //
        // This is a build consistency issue, but the problem is that currently to do so would cause many unnecessary rebuilds when a new header is added or the VFS contents are rewritten (something which happens whenever a scheme changes).
        //
        // In practice, changes which actually are likely to impact the project will usually result in other source changes which will cause the necessary rebuild, but we should ultimately close this loophole: <rdar://problem/31843906> Move to stronger dependencies on headermaps and VFS
        //
        // We currently don't need to worry about any ordering constraint, because all of the headermap production tasks are forced into an early phase.
#if false
        // Mark as depending on search paths which should be treated as inputs.
        inputDeps.append(contentsOf: constantFlags.headerSearchPaths.inputPaths)
#endif

        // Add custom per-file flags.
        var perFileFlags = [String]()
        if let perFileArgs = input.additionalArgs {
            perFileFlags = cbc.scope.evaluate(perFileArgs)
            commandLine += perFileFlags
        }

        // Add the prefix header arguments, if used.
        let prefixInfo = addPrefixHeaderArgs(cbc, delegate, inputFileType: resolvedInputFileType, perFileFlags: perFileFlags, inputDeps: &inputDeps, commandLine: &commandLine, clangInfo: clangInfo)

        // Add dependencies on the SDK used.

        // Depend on the PGO (Profile-Guided Optimization) file, if appropriate.
        //
        // If CLANG_INSTRUMENT_FOR_OPTIMIZATION_PROFILING is enabled, the profile file will be auto-generated.
        if cbc.scope.evaluate(BuiltinMacros.CLANG_USE_OPTIMIZATION_PROFILE) && !cbc.scope.evaluate(BuiltinMacros.CLANG_INSTRUMENT_FOR_OPTIMIZATION_PROFILING) {
            let profileFile = cbc.scope.evaluate(BuiltinMacros.CLANG_OPTIMIZATION_PROFILE_FILE)
            if !profileFile.isEmpty {
                inputDeps.append(profileFile)
            }
        }

        // Add -D arguments for any preprocessor definitions in GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS.
        commandLine += cbc.scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS).map{ "-D\($0)" }

        // Add -D arguments for any preprocessor definitions in the SDK.
        // FIXME: We don’t yet have the SDK API that we’d need, but perhaps we should instead have the Settings object pass such things down through more general-purpose settings.

        // Add extra flags that are to be passed to compilation but not precompilation (see <rdar>//4539182>).
        commandLine += cbc.scope.evaluate(BuiltinMacros.GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS)

        // Add the Swift package resources bundle accessor header for Objective-C files.
        if !cbc.scope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_BUNDLE_NAME).isEmpty && cbc.scope.evaluate(BuiltinMacros.GENERATE_RESOURCE_ACCESSORS) && resolvedInputFileType.languageDialect?.isObjective == true {
            let headerFile = cbc.scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("resource_bundle_accessor.h")
            inputDeps.append(headerFile)
            commandLine += ["-include", headerFile.str]
        }

        let recordSystemHeaderDepsOutsideSysroot = cbc.scope.evaluate(BuiltinMacros.RECORD_SYSTEM_HEADER_DEPENDENCIES_OUTSIDE_SYSROOT)

        // Add arguments to collect dependency information from the compiler.
        let dependencyData: DependencyDataStyle?
        if !cbc.scope.evaluate(BuiltinMacros.CLANG_DISABLE_DEPENDENCY_INFO_FILE) {
            let depInfoFile = outputNode.path.withoutSuffix + ".d"
            dependencyData = .makefile(Path(depInfoFile))
            commandLine += [recordSystemHeaderDepsOutsideSysroot ? "-MD" : "-MMD", "-MT", "dependencies", "-MF", depInfoFile]
        } else {
            dependencyData = nil
        }

        // Add the diagnostics serialization flag.  We currently place the diagnostics file right next to the output object file.
        let diagFilePath: Path?
        if let serializedDiagnosticsOptions = self.serializedDiagnosticsOptions(scope: cbc.scope, outputPath: outputNode.path) {
            diagFilePath = serializedDiagnosticsOptions.path
            commandLine += serializedDiagnosticsOptions.flags
        } else {
            diagFilePath = nil
        }

        let LTO = cbc.scope.evaluate(BuiltinMacros.LLVM_LTO)
        // Pass the flags to emit remarks to the compiler invocation when LTO is disabled. When LTO is enabled, the flags are passed to the linker invocation.
        let shouldGenerateRemarks = cbc.scope.evaluate(BuiltinMacros.CLANG_GENERATE_OPTIMIZATION_REMARKS) && (LTO.isEmpty || LTO == "NO")
        if  shouldGenerateRemarks {
            let remarkFilePath = Path(outputNode.path.withoutSuffix + ".opt.bitstream")
            commandLine += ["-fsave-optimization-record=bitstream", "-foptimization-record-file=" + remarkFilePath.str]
            let filter = cbc.scope.evaluate(BuiltinMacros.CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER)
            if !filter.isEmpty {
                commandLine += ["-foptimization-record-passes=\(filter)"]
            }
        }

        // Add the source file argument.
        commandLine += [effectiveSourceFileOption, inputPath.str]

        // Mark us as depending on the source file.
        inputDeps.append(inputPath)

        // Add the output file argument.
        commandLine += ["-o", outputNode.path.str]

        var indexOutputPath: Path = outputNode.path
        if let clangInfo {
            if hasEnabledIndexBuildArena {
                commandLine += Self.supplementalIndexingArgs(allowCompilerErrors: clangInfo.toolFeatures.has(.allowPcmWithCompilerErrors))
            }

            if clangInfo.toolFeatures.has(.indexUnitOutputPath) &&
                (commandLine.contains("-index-store-path") || hasEnabledIndexBuildArena) {
                // Remap the index output file path if either the index store is enabled (checked through the argument since it is conditional on more than just SWIFT_INDEX_STORE_ENABLE) or the build arena is enabled.
                let basePath = cbc.scope.evaluate(BuiltinMacros.OBJROOT)
                if let newPath = generateIndexOutputPath(from: outputNode.path, basePath: basePath) {
                    indexOutputPath = newPath
                    commandLine += ["-index-unit-output-path", indexOutputPath.str]
                } else if delegate.userPreferences.enableDebugActivityLogs {
                    delegate.note("Output path '\(outputNode.path.str)' could not be mapped to a relocatable index path using base path '\(basePath.str)'")
                }
            }

            if clangInfo.toolFeatures.has(.globalAPINotesPath) {
                let globalAPINotesPath = Path(cbc.scope.evaluate(BuiltinMacros.GLOBAL_API_NOTES_PATH))
                if !globalAPINotesPath.isEmpty && delegate.fileExists(at: globalAPINotesPath) {
                    commandLine += ["-iapinotes-path", globalAPINotesPath.str]
                    inputDeps.append(globalAPINotesPath)
                }
            }
        }

        let environmentBindings = EnvironmentBindings(environmentFromSpec(cbc, delegate))

        // Create indexing payload only for the preferred arch.
        let indexingPayload: ClangIndexingPayload?
        if let language, cbc.producer.preferredArch == nil || cbc.producer.preferredArch == arch {
            // BUILT_PRODUCTS_DIR and PROJECT_DIR here are guaranteed to be absolute
            // by `getCommonTargetTaskOverrides`.
            indexingPayload = ClangIndexingPayload(
                sourceFileIndex: commandLine.firstIndex(of: inputPath.str)!,
                outputFileIndex: commandLine.firstIndex(of: indexOutputPath.str)!,
                sourceLanguageIndex: commandLine.firstIndex(of: language)!,
                builtProductsDir: cbc.scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR),
                assetSymbolIndexPath: cbc.makeAbsolute(
                    cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_INDEX_PATH)
                ),
                workingDir: cbc.scope.evaluate(BuiltinMacros.PROJECT_DIR),
                prefixInfo: prefixInfo,
                toolchains: cbc.producer.toolchains.map{ $0.identifier },
                responseFileAttachmentPaths: constantFlags.responseFileMapping
            )
        } else {
            indexingPayload  = nil
        }

        // If we're generating module map files, then make the compile task depend on them.
        // We might not need to include this dependency if the module is 'Swift only', but it shouldn't hurt.
        if let moduleInfo = cbc.producer.moduleInfo {
            inputDeps.append(moduleInfo.moduleMapPaths.builtPath)
            if let privateModuleMapPath = moduleInfo.privateModuleMapPaths?.builtPath {
                inputDeps.append(privateModuleMapPath)
            }
        }

        // Handle explicit modules build.
        let scanningOutput = delegate.createNode(outputNode.path.dirname.join(outputNode.path.basename + ".scan"))
        let (action, usesExecutionInputs, explicitModulesPayload, explicitModulesSignatureData) = createExplicitModulesActionAndPayload(cbc, delegate, launcher, input, resolvedInputFileType.languageDialect, commandLine: commandLine, scanningOutputPath: scanningOutput.path, isForPCHTask: false, clangInfo: clangInfo)

        let verifierPayload = createClangModuleVerifierPayload(cbc)

        // Create the task payloads.
        let scannerPayload = ClangTaskPayload(
            serializedDiagnosticsPath: diagFilePath,
            indexingPayload: nil,
            explicitModulesPayload: explicitModulesPayload,
            outputObjectFilePath: nil
        )

        let payload = ClangTaskPayload(
            serializedDiagnosticsPath: diagFilePath,
            indexingPayload: indexingPayload,
            explicitModulesPayload: explicitModulesPayload,
            outputObjectFilePath: shouldGenerateRemarks ? outputNode.path : nil,
            fileNameMapPath: verifierPayload?.fileNameMapPath,
            developerPathString: recordSystemHeaderDepsOutsideSysroot ? cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR).str : nil
        )

        var inputNodes: [any PlannedNode] = inputDeps.map { delegate.createNode($0) }
        if await cbc.producer.shouldUseSDKStatCache() {
            inputNodes.append(delegate.createVirtualNode("ClangStatCache \(cbc.scope.evaluate(BuiltinMacros.SDK_STAT_CACHE_PATH))"))
        }

        var additionalSignatureData: String
        if let clangVersion = clangInfo?.clangVersion?.description, !clangVersion.isEmpty {
            additionalSignatureData = "CLANG: \(clangVersion)"
        } else {
            additionalSignatureData = ""
        }
        if let explicitModulesSignatureData {
            additionalSignatureData += "|\(explicitModulesSignatureData)"
        }

        let fineGrainedCacheEnabled = cbc.scope.evaluate(BuiltinMacros.CLANG_CACHE_FINE_GRAINED_OUTPUTS) == .enabled

        if fineGrainedCacheEnabled, let casOptions = explicitModulesPayload?.casOptions, !casOptions.hasRemoteCache {
            commandLine += ["-Xclang", "-fcas-backend"]
            if cbc.scope.evaluate(BuiltinMacros.CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION) == .enabled {
                commandLine += ["-Xclang", "-fcas-backend-mode=verify"]
            }
            commandLine += ["-mllvm", "-cas-friendly-debug-info"]
        }

        // If explicit modules are enabled we need to create the scan task first
        let extraInputs: [any PlannedNode]
        if action != nil {
            var scanningRuleInfo: [String]
            if ruleInfo.first == "CompileC" || ruleInfo.first == "VerifyModuleC" {
                scanningRuleInfo = ["ScanDependencies"] + ruleInfo.dropFirst()
            } else {
                scanningRuleInfo = ["ScanDependencies"] + ruleInfo
            }
            var scannerCLIPrefix = ["builtin-ScanDependencies", "-o", scanningOutput.path.str]
            if let clangVersion = clangInfo?.clangVersion, clangVersion < Version(1500, 0, 17, 5) {
                // When using older compilers, Swift Build must expand response files for the scanner
                scannerCLIPrefix += ["--expand-response-files"]
            }
            scannerCLIPrefix += ["--"]
            delegate.createTask(type: self, payload: scannerPayload, ruleInfo: scanningRuleInfo, additionalSignatureData: additionalSignatureData, commandLine: scannerCLIPrefix + commandLine, additionalOutput: responseFileAdditionalOutput, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: inputNodes, outputs: [scanningOutput], action: delegate.taskActionCreationDelegate.createClangScanTaskAction(), execDescription: "Scan dependencies of \(cbc.input.absolutePath.basename)", enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilationForIndexableSourceFile], usesExecutionInputs: usesExecutionInputs)

            extraInputs = [scanningOutput]
        } else {
            extraInputs = []
        }

        // Finally, create the task.
        delegate.createTask(type: self, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: commandLine, additionalOutput: additionalOutput, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: inputNodes + extraInputs, outputs: [outputNode], action: action ?? delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences), execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilationForIndexableSourceFile], usesExecutionInputs: usesExecutionInputs, showEnvironment: true, priority: .preferred)

        // If the object file verifier is enabled and we are building with explicit modules, also create a job to produce adjacent objects using implicit modules, then compare the results.
        if cbc.scope.evaluate(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES_OBJECT_FILE_VERIFIER) && action != nil {
            // Create a parallel compile task using implicit modules.
            let implicitModulesOutput = outputNode.path.dirname.join(outputNode.path.basenameWithoutSuffix + "-implicit.o.dontlink")
            let implicitModulesOutputNode = delegate.createNode(implicitModulesOutput)
            let depInfoFile = implicitModulesOutput.str + ".d"
            let dependencyData = DependencyDataStyle.makefile(Path(depInfoFile))
            let diagnosticsFile = implicitModulesOutput.str + ".dia"
            var updatedCommandLine: [String] = []
            var iterator = commandLine.makeIterator()
            while let arg = iterator.next() {
                if arg == "-o" {
                    // Replace the output path
                    _ = iterator.next()
                    updatedCommandLine.append(contentsOf: ["-o", implicitModulesOutput.str])
                } else if Set(["-index-store-path", "-index-unit-output-path"]).contains(arg) {
                    // Skip the flag and argument
                    _ = iterator.next()
                } else if arg == "-MF" {
                    // Replace the dependencies path.
                    _ = iterator.next()
                    updatedCommandLine.append(contentsOf: ["-MF", depInfoFile])
                } else if arg == "--serialize-diagnostics" {
                    // Replace the diagnostics path.
                    _ = iterator.next()
                    updatedCommandLine.append(contentsOf: ["--serialize-diagnostics", diagnosticsFile])
                } else if arg.hasSuffix(".pch") {
                    updatedCommandLine.append(arg.appending("-implicit.pch"))
                } else {
                    updatedCommandLine.append(arg)
                }
            }

            let updatedInputs = inputDeps.map { dep in dep.fileExtension == "gch" ? dep.dirname.join(dep.basenameWithoutSuffix + "-implicit.pch.gch") : dep }

            // This variable is otherwise unused, but probably should be used somewhere.
            // rdar://100580399 (Compare object files produced by explicit/implicit modules)
            _ = updatedInputs

            let payload = ClangTaskPayload(serializedDiagnosticsPath: Path(diagnosticsFile), indexingPayload: nil)

            delegate.createTask(type: self, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo + ["(implicit-copy)"], additionalSignatureData: additionalSignatureData, commandLine: updatedCommandLine, additionalOutput: responseFileAdditionalOutput, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: inputNodes + extraInputs, outputs: [implicitModulesOutputNode], action: delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences), execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilationForIndexableSourceFile], usesExecutionInputs: false)

            // Create a task to copy-aside the explicit modules object.
            let explicitModulesOutput = outputNode.path.dirname.join(outputNode.path.basenameWithoutSuffix + "-explicit.o.dontlink")
            await cbc.producer.copySpec.constructCopyTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [FileToBuild(absolutePath: outputNode.path, inferringTypeUsing: cbc.producer)], output: explicitModulesOutput), delegate)

            // Strip the debug info from both objects
            await cbc.producer.stripSpec.constructStripDebugSymbolsTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [FileToBuild(absolutePath: implicitModulesOutput, inferringTypeUsing: cbc.producer)]), delegate)
            await cbc.producer.stripSpec.constructStripDebugSymbolsTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [FileToBuild(absolutePath: explicitModulesOutput, inferringTypeUsing: cbc.producer)]), delegate)

            // Diff the stripped objects
            await cbc.producer.diffSpec.constructTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [FileToBuild(absolutePath: explicitModulesOutput, inferringTypeUsing: cbc.producer), FileToBuild(absolutePath: implicitModulesOutput, inferringTypeUsing: cbc.producer)], commandOrderingInputs: [delegate.createVirtualNode("Strip \(explicitModulesOutput.str)"), delegate.createVirtualNode("Strip \(implicitModulesOutput.str)")]), delegate)
        }

        if cbc.isPreferredArch,
           self.identifier == "com.apple.compilers.llvm.clang.1_0.compiler",
           let sourcecodeCFileType = cbc.producer.lookupFileType(identifier: "sourcecode.c"),
           resolvedInputFileType.conformsTo(sourcecodeCFileType),
           !hasEnabledIndexBuildArena {
            // If the static analyzer is enabled, also construct tasks for it.
            let skipAnalyzer = cbc.scope.evaluate(BuiltinMacros.SKIP_CLANG_STATIC_ANALYZER)
            if cbc.scope.evaluate(BuiltinMacros.RUN_CLANG_STATIC_ANALYZER) && !skipAnalyzer {
                await cbc.producer.clangStaticAnalyzerSpec.constructTasks(cbc, delegate)
            }

            if cbc.producer.generateAssemblyCommands {
                await cbc.producer.clangAssemblerSpec.constructTasks(cbc, delegate)
            }

            if cbc.producer.generatePreprocessCommands {
                await cbc.producer.clangPreprocessorSpec.constructTasks(cbc, delegate)
            }
        }
    }

    /// Compute the output file directory to use.
    func outputFileDir(_ cbc: CommandBuildContext) -> Path {
        return cbc.scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR)
    }

    /// Compute the rule information to use.
    func ruleInfo(_ cbc: CommandBuildContext, input: Path, output: Path, variant: String, arch: String, language: String?) -> [String] {
        return ["CompileC", output.str, input.str, variant, arch, language ?? "?", identifier]
    }

    /// Returns the path for prefix header module map, if one should be generated.
    public static func getPrefixHeaderModuleMap(_ prefixHeader: Path, _ scope: MacroEvaluationScope) -> Optional<Path> {
        guard scope.evaluate(BuiltinMacros.GCC_PRECOMPILE_PREFIX_HEADER) && scope.evaluate(BuiltinMacros.CLANG_IMPORT_PREFIX_HEADER_AS_MODULE) && scope.evaluate(BuiltinMacros.CLANG_ENABLE_MODULES) else {
            return nil
        }

        let md5 = InsecureHashContext()
        md5.add(string: prefixHeader.str)
        let sharingIdentHashValue = md5.signature
        let baseCachePath = scope.evaluate(BuiltinMacros.SHARED_PRECOMPS_DIR)
        return baseCachePath.join("SharedPrefixModuleMaps").join("\(prefixHeader.basename)-\(sharingIdentHashValue).modulemap")
    }

    @_spi(Testing) public static func sharedPrecompiledHeaderSharingIdentifier(commandLine: [String]) -> (string: String, hashValue: UInt64) {
        // FIXME: The way in which we do this right now is very preliminary.
        let sharingIdentString = commandLine.joined(separator: "|")
        let sharingIdentHashValue = sharingIdentString.utf8.reduce(UInt64(0)) { UInt64($0) &* 13 &+ UInt64($1) }
        return (sharingIdentString, sharingIdentHashValue)
    }

    /// Adds the arguments to use the prefix header, in the appropriate manner for the target.
    private func addPrefixHeaderArgs(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, inputFileType: FileTypeSpec, perFileFlags: [String], inputDeps: inout [Path], commandLine: inout [String], clangInfo: DiscoveredClangToolSpecInfo?) -> ClangPrefixInfo? {
        // Don't use the prefix header if the input file opted out.
        guard cbc.inputs[0].shouldUsePrefixHeader else {
            return nil
        }

        // If there is not prefix header, we are done.
        var prefixHeader = cbc.scope.evaluate(BuiltinMacros.GCC_PREFIX_HEADER)
        guard !prefixHeader.isEmpty else {
            return nil
        }

        // Make the path absolute.
        prefixHeader = delegate.createNode(prefixHeader).path

        // Only use a prefix header for supported languages.  GCC_PFE_FILE_C_DIALECTS defaults to the four C-language dialects.
        guard let language = inputFileType.languageDialect, ClangCompilerSpec.gccLanguagesToPrecompile.contains(language), cbc.scope.evaluate(BuiltinMacros.GCC_PFE_FILE_C_DIALECTS).contains(language.dialectNameForCompilerCommandLineArgument) else {
            return nil
        }

        let pchAsModuleLanguages: Set<GCCCompatibleLanguageDialect> = [.c, .objectiveC]
        let prefixModuleMapFile = ClangCompilerSpec.getPrefixHeaderModuleMap(prefixHeader, cbc.scope)

        if let prefixModuleMapFile, shouldPrecompilePrefixHeader && pchAsModuleLanguages.contains(language) {
            guard cbc.scope.evaluate(BuiltinMacros.OTHER_PRECOMP_CFLAGS).isEmpty else {
                delegate.error("'OTHER_PRECOMP_CFLAGS' setting is incompatible with 'CLANG_IMPORT_PREFIX_HEADER_AS_MODULE'")
                return nil
            }

            commandLine += ["-include", prefixHeader.str, "-fmodule-map-file=\(prefixModuleMapFile.str)"]

            inputDeps.append(prefixHeader)
            inputDeps.append(prefixModuleMapFile)

            return ClangPrefixInfo(input: prefixHeader, pch: nil)
        }

        // Precompile the prefix header, if needed.
        if cbc.scope.evaluate(BuiltinMacros.GCC_PRECOMPILE_PREFIX_HEADER) && shouldPrecompilePrefixHeader {
            // First determine the name of the precomp file.
            // FIXME: We need to add the hash etc to this.
            let baseCachePath = cbc.scope.evaluate(BuiltinMacros.SHARED_PRECOMPS_DIR)

            // Determine the command line arguments that should be included in the hash.
            //
            // Filter the commandline args that should not contribute to the hash.
            var commandLineForHash = commandLine.filter {
                for pattern in precompNeutralFlagPatterns {
                    if pattern.matches($0) {
                        return false
                    }
                }
                return true
            }

            commandLineForHash.append(prefixHeader.str)

            // FIXME: Add the compiler version and target strings to the array.

            // FIXME: Remove other compiler options that don't affect PCH validity, e.g. warning flags.

            // FIXME: Remove some compiler options in order to increase PCH sharing, if directed to do so by the target.
            if cbc.scope.evaluate(BuiltinMacros.GCC_INCREASE_PRECOMPILED_HEADER_SHARING) {
                // remove certain search path arguments
            }

            // FIXME: Remove some other options which we don't want to take into account for PCH validity.  This is somewhat magical.

            // If an index store is used, remove it from the hash, since it doesn't affect PCH validity.
            if cbc.scope.evaluate(BuiltinMacros.CLANG_INDEX_STORE_ENABLE) {
                if let idx = commandLineForHash.firstIndex(of: "-index-store-path") {
                    // Remove both the flag and the argument that follows it.
                    // FIXME: This is a common case, and we should have a more standardized way of dealing with it.
                    commandLineForHash.remove(at: idx)
                    if idx < commandLineForHash.endIndex {
                        commandLineForHash.remove(at: idx)
                    }
                }
            }

            // FIXME: Also respect PRECOMPS_INCLUDE_HEADERS_FROM_BUILT_PRODUCTS_DIR

            // FIXME: Add MACOSX_DEPLOYMENT_TARGET — which is normally an environment variable — to the list of items used for uniquing, if appropriate.

            // FIXME: Add the version of the SDK we're building against.  This way when a machine's SDKs are changed (a common practice for internal developers, especially those developing iOS) the PCHs will automatically be regenerated.  This value comes from $(SDKROOT)/System/Library/CoreServices/SystemVersion.plist  Note that this will even affect building against the boot system, which means applying a software update will cause projects building against the boot system to rebuild their SDKs!
            let sdkProductBuildVersion = cbc.scope.evaluate(BuiltinMacros.SDK_PRODUCT_BUILD_VERSION)
            if !sdkProductBuildVersion.isEmpty {
                commandLineForHash.append("SDK_PRODUCT_BUILD_VERSION=\(sdkProductBuildVersion)")
            }

            // Construct an identifier from the command line arguments that should contribute to making the precomp unique.
            let (sharingIdentString, sharingIdentHashValue) = Self.sharedPrecompiledHeaderSharingIdentifier(commandLine: commandLineForHash)

            // Look up any existing precomp node for the identifier, or create it if it’s the first time we see it.
            //
            // FIXME: We need to be very careful here, we are still providing the build context for the current file, and the local scope. This means that the thing we compute here may depend on whatever target happens to produce it first, in subtle ways. We actually know this happens with the headermaps: <rdar://problem/24605739> [Swift Build] Stop sharing precompiled PCH files across targets
            let (precompFile, pchInfoAny) = delegate.createOrReuseSharedNodeWithIdentifier(sharingIdentString) { () -> (any PlannedNode, any Sendable) in
                // This block is invoked only when we need to create a task to precompile a header.

                // Construct the full path of the precomp file, which includes the hash to make it unique.
                // FIXME: This needs to actually include a hash code, and it should ideally (for comparison reasons) be the same as Xcode.
                let precompPath = baseCachePath.join("SharedPrecompiledHeaders").join("\(sharingIdentHashValue)").join(prefixHeader.basename + ".gch")

                // Start by invoking our logic to create a task to precompile the prefix header.
                let pchInfo = self.precompile(cbc, delegate, headerPath: prefixHeader, language: language, inputFileType: inputFileType, extraArgs: perFileFlags, precompPath: precompPath, clangInfo: clangInfo)

                // Return the output node for the precomp file.
                return (delegate.createNode(precompPath), pchInfo)
            }

            let pchInfo = pchInfoAny as! ClangPrefixInfo.PCHInfo

            // Include the precomp file.
            commandLine += ["-include", precompFile.path.withoutSuffix]

            // Mark us as depending on the precompiled file.
            inputDeps.append(precompFile.path)

            return ClangPrefixInfo(input: prefixHeader, pch: pchInfo)
        } else {
            // Not precompiling the prefix header, so just include it as source.
            commandLine += ["-include", prefixHeader.str]

            // Mark us as depending directly on the prefix header.
            inputDeps.append(prefixHeader)

            return ClangPrefixInfo(input: prefixHeader, pch: nil)
        }
    }

    /// Specialized function that creates a task for precompiling a particular header.
    private func precompile(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, headerPath: Path, language: GCCCompatibleLanguageDialect, inputFileType: FileTypeSpec, extraArgs: [String], precompPath: Path, clangInfo: DiscoveredClangToolSpecInfo?) -> ClangPrefixInfo.PCHInfo {

        // FIXME: Disabled for now because some projects manages to end up getting here with multiple files. <rdar://problem/23682348> Project groups multiple .c files together for C compiler?
        //let input = cbc.input
        let input = cbc.inputs[0]

        // Fetch the current architecture and variant from the command build context.
        let arch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)
        let variant = cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT)

        // Create the rule info to match what Xcode does.
        //
        let ruleType = language.isPlusPlus ? "ProcessPCH++" : "ProcessPCH"
        let ruleInfo = [ruleType, precompPath.str, headerPath.str, variant, arch, language.dialectNameForCompilerCommandLineArgument, identifier]
        assert(ruleInfo[ClangCompilerSpec.ruleInfoInputPathIndex] == headerPath.str)

        // Create the command line, as well as any input dependencies.
        var commandLine = Array<String>()

        // Start with the executable.
        let compilerExecPath = resolveExecutablePath(cbc, forLanguageOfFileType: inputFileType)
        let launcher = resolveCompilerLauncher(cbc, compilerPath: compilerExecPath, delegate: delegate)
        if let launcher {
            commandLine += [launcher.str]
        }
        commandLine += [compilerExecPath.str]

        // Add the source language (which, because we’re precompiling a header, is the original language with a “-header” suffix).
        commandLine += ["-x", language.dialectNameForCompilerCommandLineArgument + "-header"]

        // Add “standard flags”, which are ones that depend only on the variant, architecture, and language (in addition to the identifier, of course).
        let dataCache = cbc.producer.getSpecDataCache(self, cacheType: DataCache.self)
        let constantFlags = dataCache.getStandardFlags(self, producer: cbc.producer, scope: cbc.scope, optionContext: clangInfo, delegate: delegate, inputFileType: inputFileType)
        let responseFileAdditionalOutput = constantFlags.responseFileMapping.keys.sorted().map({"Using response file: \($0.str)"})
        commandLine += constantFlags.flags

        // Add the source file argument.
        commandLine += [effectiveSourceFileOption, headerPath.str]

        // Add the extra flags we were given, if any.
        commandLine += extraArgs

        // Add OTHER_PRECOMP_CFLAGS.
        commandLine += cbc.scope.evaluate(BuiltinMacros.OTHER_PRECOMP_CFLAGS)

        // FIXME: Add implicit dependencies for the SDK.

        // Add arguments to collect dependency information from the compiler.
        // We pass -MD to capture dependencies on system headers.  (Regular compilation passes -MMD to not collect those dependencies.)
        let depInfoFile = precompPath.withoutSuffix + ".d"
        let dependencyData = DependencyDataStyle.makefile(Path(depInfoFile))
        commandLine += ["-MD", "-MT", "dependencies", "-MF", depInfoFile]

        // NOTE: We intentionally chose not to depend on the headermaps here, see the comment below in the main compiler handling method: <rdar://problem/31843906> Move to stronger dependencies on headermaps and VFS

        // Add the output file argument.
        commandLine += ["-o", precompPath.str]

        // Add the diagnostics serialization flag.  We currently place the diagnostics file right next to the output object file.
        let diagFilePath = precompPath.withoutSuffix + ".dia"
        commandLine += ["--serialize-diagnostics", diagFilePath]

        let hasEnabledIndexBuildArena = cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        if hasEnabledIndexBuildArena {
            commandLine += Self.supplementalIndexingArgs(allowCompilerErrors: false)
        }

        // Compute the final input and output path lists.
        var inputPaths = [ headerPath ] + constantFlags.inputs
        let outputPaths = [ precompPath ]

        // If we're generating module map files, then make PCH generation depend on them.
        // We might not need to include this dependency if the module is 'Swift only', but it shouldn't hurt.
        if let moduleInfo = cbc.producer.moduleInfo {
            inputPaths.append(moduleInfo.moduleMapPaths.builtPath)
            if let privateModuleMapPath = moduleInfo.privateModuleMapPaths?.builtPath {
                inputPaths.append(privateModuleMapPath)
            }
        }

        let byteStringCommandLine = commandLine.map{ ByteString(encodingAsUTF8: $0) }

        // Handle explicit modules build.
        let scanningOutput = precompPath.appendingFileNameSuffix("scan")
        let (action, usesExecutionInputs, explicitModulesPayload, explicitModulesSignatureData) = createExplicitModulesActionAndPayload(cbc, delegate, launcher, input, language, commandLine: commandLine, scanningOutputPath: scanningOutput, isForPCHTask: true, clangInfo: clangInfo)

        // Create the task payload.  The precompilation task doesn't provide any indexing information.
        let payload = ClangTaskPayload(
            serializedDiagnosticsPath: Path(diagFilePath),
            indexingPayload: nil,
            explicitModulesPayload: explicitModulesPayload
        )

        // Add the input file which caused this PCH to be built to the build log.
        // Unfortunately in this context we only know a single file, and any other files which need it with the same compile parameters will match this task later, so we can't make any inferences or report any behavior based on the collection of files at this point.
        var additionalOutput = ["Precompile of '\(headerPath.str)' required by '\(input.absolutePath.str)'"]
        additionalOutput.append(contentsOf: responseFileAdditionalOutput)

        var additionalSignatureData: String
        if let clangVersion = clangInfo?.clangVersion?.description, !clangVersion.isEmpty {
            additionalSignatureData = "CLANG: \(clangVersion)"
        } else {
            additionalSignatureData = ""
        }
        if let explicitModulesSignatureData {
            additionalSignatureData += "|\(explicitModulesSignatureData)"
        }

        let environmentBindings = EnvironmentBindings(environmentFromSpec(cbc, delegate))

        // If explicit modules are enabled we need to create the scan task first
        let extraInputs: [Path]
        if action != nil {
            delegate.createTask(type: self, payload: payload, ruleInfo: ["ScanDependencies"] + ruleInfo.dropFirst(), additionalSignatureData: additionalSignatureData, commandLine: ["builtin-ScanDependencies", "-o", scanningOutput.str, "--"] + commandLine, additionalOutput: responseFileAdditionalOutput, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: inputPaths, outputs: [scanningOutput], action: delegate.taskActionCreationDelegate.createClangScanTaskAction(), execDescription: "Scan dependencies of \(headerPath.basename)", preparesForIndexing: true, enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilationForIndexableSourceFile], usesExecutionInputs: usesExecutionInputs)

            extraInputs = [scanningOutput]
        } else {
            extraInputs = []
        }

        // Finally, create the task.
        delegate.createTask(type: self, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo, additionalSignatureData: additionalSignatureData, commandLine: byteStringCommandLine, additionalOutput: additionalOutput, environment: environmentBindings, workingDirectory: compilerWorkingDirectory(cbc), inputs: inputPaths + extraInputs, outputs: outputPaths, action: action ?? delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences), execDescription: "Precompile \(headerPath.basename) (\(arch))", enableSandboxing: enableSandboxing, usesExecutionInputs: usesExecutionInputs, showEnvironment: true)

        // If the object file verifier is enabled and we are building with explicit modules, also create a job to produce an adjacent PCH using implicit modules.
        if cbc.scope.evaluate(BuiltinMacros.CLANG_ENABLE_EXPLICIT_MODULES_OBJECT_FILE_VERIFIER) && action != nil {
            // Create a parallel precompile task using implicit modules.
            let implicitModulesOutput = precompPath.dirname.join(precompPath.basenameWithoutSuffix + "-implicit.pch.gch")
            let implicitModulesOutputNode = delegate.createNode(implicitModulesOutput)
            let depInfoFile = implicitModulesOutput.str + ".d"
            let dependencyData = DependencyDataStyle.makefile(Path(depInfoFile))
            let diagnosticsFile = implicitModulesOutput.str + ".dia"
            var updatedCommandLine: [String] = []
            var iterator = commandLine.makeIterator()
            while let arg = iterator.next() {
                if arg == "-o" {
                    // Replace the output path
                    _ = iterator.next()
                    updatedCommandLine.append(contentsOf: ["-o", implicitModulesOutput.str])
                } else if arg == "-MF" {
                    // Replace the dependencies path.
                    _ = iterator.next()
                    updatedCommandLine.append(contentsOf: ["-MF", depInfoFile])
                } else if arg == "--serialize-diagnostics" {
                    // Replace the diagnostics path.
                    _ = iterator.next()
                    updatedCommandLine.append(contentsOf: ["--serialize-diagnostics", diagnosticsFile])
                } else {
                    updatedCommandLine.append(arg)
                }
            }

            let payload = ClangTaskPayload(serializedDiagnosticsPath: Path(diagnosticsFile), indexingPayload: nil)

            delegate.createTask(type: self, dependencyData: dependencyData, payload: payload, ruleInfo: ruleInfo + ["(implicit-copy)"], additionalSignatureData: additionalSignatureData, commandLine: updatedCommandLine.map{ ByteString(encodingAsUTF8: $0) }, additionalOutput: responseFileAdditionalOutput, environment: EnvironmentBindings(), workingDirectory: compilerWorkingDirectory(cbc), inputs: inputPaths + extraInputs, outputs: [ implicitModulesOutputNode.path ], action: delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences), execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilationForIndexableSourceFile], usesExecutionInputs: false)
        }

        return ClangPrefixInfo.PCHInfo(
            output: precompPath,
            hashCriteria: nil, // rdar://problem/24469921
            commandLine: ClangSourceFileIndexingInfo.indexingCommandLine(from: byteStringCommandLine, workingDir: cbc.scope.evaluate(BuiltinMacros.PROJECT_DIR), addSupplementary: !hasEnabledIndexBuildArena, replaceCompile: false, responseFileMapping: constantFlags.responseFileMapping)
        )
    }

    /// Get the serialized diagnostics used by a task, if any.
    override public func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        // We expect every clang task to have a payload of the right type.
        let payload = task.payload! as! ClangTaskPayload
        return payload.serializedDiagnosticsPath.map { [$0] } ?? []
    }

    /// Examines the task and returns the indexing information for the source file it compiles.
    override public func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        // We expect every clang task to have a payload of the right type.  But not all clang tasks will have an indexing property in their payload.
        let payload = task.payload! as! ClangTaskPayload
        guard let indexingPayload = payload.indexingPayload else { return [] }
        let sourceFile = indexingPayload.sourceFile(for: task)
        guard input.requestedSourceFiles.contains(sourceFile) else { return [] }
        let indexingInfo: any SourceFileIndexingInfo
        if input.outputPathOnly {
            indexingInfo = OutputPathIndexingInfo(task: task, payload: indexingPayload)
        } else {
            indexingInfo = ClangSourceFileIndexingInfo(task: task, payload: indexingPayload, enableIndexBuildArena: input.enableIndexBuildArena)
        }
        return [.init(path: sourceFile, indexingInfo: indexingInfo)]
    }

    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        // Scanning modules runs in process and produces no parseable output
        guard task.ruleInfo.first != "ScanDependencies" else { return nil }
        return ClangOutputParser.self
    }

    public override var payloadType: (any TaskPayload.Type)? { return ClangTaskPayload.self }


    // MARK: Discovering info by invoking the tool

    /// Creates and returns a discovered info object for the clang compiler for the given command producer, scope, and language.
    public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, forLanguageOfFileType fileType: FileTypeSpec?) async throws -> DiscoveredClangToolSpecInfo? {
        // Get the components of the cache key, and create the key.
        let toolPath = self.resolveExecutablePath(producer, scope, forLanguageOfFileType: fileType)
        guard toolPath.isAbsolute else {
            return nil
        }
        let arch = scope.evaluate(BuiltinMacros.CURRENT_ARCH)
        let sdk = producer.sdk
        let userSpecifiedBlocklists = scope.evaluate(BuiltinMacros.BLOCKLISTS_PATH).nilIfEmpty.map { Path($0) }

        return try await discoveredClangToolInfo(producer, delegate, toolPath: toolPath, arch: arch, sysroot: sdk?.path, language: fileType?.languageDialect?.dialectNameForCompilerCommandLineArgument ?? "c", blocklistsPathOverride: userSpecifiedBlocklists)
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await discoveredCommandLineToolSpecInfo(producer, scope, delegate, forLanguageOfFileType: nil)
        } catch {
            delegate.error(error)
            return nil
        }
    }

    /// Resolve the executable path for the given dialect.
    internal func resolveExecutablePath(_ cbc: CommandBuildContext, forLanguageOfFileType fileType: FileTypeSpec?) -> Path {
        return resolveExecutablePath(cbc.producer, cbc.scope, forLanguageOfFileType: fileType)
    }

    /// Resolve the executable path for the given dialect.
    private func resolveExecutablePath(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, forLanguageOfFileType fileType: FileTypeSpec?) -> Path {
        // Find the first non-empty entry in a language-specific search list.
        let searchList: [PathMacroDeclaration]
        switch (fileType?.languageDialect?.isPlusPlus ?? false, fileType?.languageDialect?.isObjective ?? false) {
        case (false, false):
            searchList = [BuiltinMacros.CC]
        case (true, false):
            searchList = [BuiltinMacros.CPLUSPLUS, BuiltinMacros.CC]
        case (false, true):
            searchList = [BuiltinMacros.OBJCC, BuiltinMacros.CC]
        case (true, true):
            searchList = [BuiltinMacros.OBJCPLUSPLUS, BuiltinMacros.CPLUSPLUS, BuiltinMacros.CC]
        }
        for macro in searchList {
            let value = scope.evaluate(macro)
            if !value.isEmpty {
                return value
            }
        }

        // The Clang static analyzer spec set ExecPath=$(CLANG_ANALYZER_EXEC),
        // so make sure we take the opportunity to read ExecPath for any
        // override of the Clang binary name instead of falling back to the
        // static string straight away.
        let fallback: Path = {
            if let execPath = self.execPath {
                let path = scope.evaluate(execPath)
                if !path.isEmpty {
                    return Path(producer.hostOperatingSystem.imageFormat.executableName(basename: path))
                }
            }
            return Path(producer.hostOperatingSystem.imageFormat.executableName(basename: "clang"))
        }()

        return resolveExecutablePath(producer, fallback)
    }

    /// Resolve the compiler launcher, if used.
    private func resolveCompilerLauncher(_ cbc: CommandBuildContext, compilerPath: Path, delegate: any TaskGenerationDelegate) -> Path? {
        let value = cbc.scope.evaluate(BuiltinMacros.C_COMPILER_LAUNCHER)
        if !value.isEmpty {
            return resolveExecutablePath(cbc, Path(value))
        }
        if cbc.scope.evaluate(BuiltinMacros.CLANG_CACHE_ENABLE_LAUNCHER) {
            let name = Path("clang-cache")
            let resolved = resolveExecutablePath(cbc, name)
            // Only set it as launcher if it has been found and is next to the compiler.
            if resolved != name && resolved.dirname == compilerPath.dirname {
                return resolved
            }
            if !cbc.scope.evaluate(BuiltinMacros.CLANG_CACHE_FALLBACK_IF_UNAVAILABLE) {
                // Fail if `clang-cache` was not setup.
                delegate.error("'clang-cache' was not found next to compiler (clang-cache: '\(resolved.str)', compiler:\(compilerPath.str)")
            }
        }
        return nil
    }

    public override func interestingPath(for task: any ExecutableTask) -> Path? {
        return Path(task.ruleInfo[ClangCompilerSpec.ruleInfoInputPathIndex])
    }
    private static let ruleInfoInputPathIndex = 2

    func verifyingModule(_ cbc: CommandBuildContext) -> String? { nil }
}

extension ClangCompilerSpec {
    public static func supplementalIndexingArgs(allowCompilerErrors: Bool) -> [String] {
        var args: [String] = []

        // Retain extra information for indexing
        args.append("-fretain-comments-from-system-headers")
        args.append("-Xclang")
        args.append("-detailed-preprocessing-record")

        // libclang uses 'raw' module-format. Match it so we can reuse the module cache and PCHs that libclang uses.
        args.append("-Xclang")
        args.append("-fmodule-format=raw")

        // Be less strict - we want to continue and typecheck/index as much as possible
        args.append("-Xclang")
        args.append("-fallow-pch-with-compiler-errors")
        if allowCompilerErrors {
            args.append("-Xclang")
            args.append("-fallow-pcm-with-compiler-errors")
        }
        args.append("-Wno-non-modular-include-in-framework-module")
        args.append("-Wno-incomplete-umbrella")

        // Avoid a crash in Clang when system headers change
        args.append("-fmodules-validate-system-headers")

        return args
    }
}

public final class ClangStaticAnalyzerSpec : ClangCompilerSpec, @unchecked Sendable {
    public class override var identifier: String {
        "com.apple.compilers.llvm.clang.1_0.analyzer"
    }

    static let outputFileExpression = BuiltinMacros.namespace.parseString("$(CLANG_ANALYZER_OUTPUT_DIR)/StaticAnalyzer/$(PROJECT_NAME)/$(TARGET_NAME)/$(CURRENT_VARIANT)/$(CURRENT_ARCH)")

    /// Ensure we get a unique output file from the main compiler.
    override func outputFileExtension(for input: FileToBuild) -> String {
        return ".plist"
    }

    /// Whether to add serialize diagnostics options (an extension point for the static analyzer).
    override func serializedDiagnosticsOptions(scope: MacroEvaluationScope, outputPath: Path) -> (path: Path, flags: [String])? {
        // When using the static analyzer, the diagnostics path is the ".plist" output.
        return (outputPath, [])
    }

    /// Compute the output file directory to use.
    override func outputFileDir(_ cbc: CommandBuildContext) -> Path {
        return Path(cbc.scope.evaluate(ClangStaticAnalyzerSpec.outputFileExpression))
    }

    /// Customize the rule info.
    override func ruleInfo(_ cbc: CommandBuildContext, input: Path, output: Path, variant: String, arch: String, language: String?) -> [String] {
        let analyzerMode = cbc.scope.evaluate(BuiltinMacros.CLANG_STATIC_ANALYZER_MODE)
        let ruleName: String
        switch analyzerMode {
        case "shallow":
            ruleName = "AnalyzeShallow"
        case "deep", "":
            ruleName = "Analyze"
        default:
            ruleName = "Analyze_\(analyzerMode)"
        }
        return [ruleName, input.str, variant, arch]
    }

    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return nil
    }

    public override func interestingPath(for task: any ExecutableTask) -> Path? {
        return Path(task.ruleInfo[1])
    }
}

func createSpecParser(for proxy: SpecProxy, registry: SpecRegistry) -> SpecParser {
    // FIXME: Clean up manual initialization of objects.
    struct Delegate: SpecParserDelegate {
        private let _diagnosticsEngine = DiagnosticsEngine()
        var internalMacroNamespace: MacroNamespace { specRegistry.internalMacroNamespace }
        let specRegistry: SpecRegistry

        init(registry: SpecRegistry) {
            specRegistry = registry
        }

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            return .init(_diagnosticsEngine)
        }

        func groupingStrategy(name: String, specIdentifier: String) -> (any InputFileGroupingStrategy)? {
            specRegistry.inputFileGroupingStrategyFactories[name]?.makeStrategy(specIdentifier: specIdentifier)
        }
    }
    let delegate = Delegate(registry: registry)
    return SpecParser(delegate, proxy)
}

public final class ClangPreprocessorSpec : ClangCompilerSpec, SpecImplementationType, @unchecked Sendable {
    public class override var identifier: String {
        "com.apple.compilers.llvm.clang.1_0.preprocessor"
    }

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ClangPreprocessorSpec(createSpecParser(for: proxy, registry: registry), registry.getSpec("com.apple.compilers.llvm.clang.1_0"))
    }

    override var effectiveSourceFileOption: String {
        return "-E"
    }

    override var shouldPrecompilePrefixHeader: Bool {
        return false
    }

    /// Ensure we get a unique output file from the main compiler.
    override func outputFileExtension(for input: FileToBuild) -> String {
        return input.fileType.languageDialect?.preprocessedSourceFileNameSuffix ?? ""
    }

    /// Customize the rule info.
    override func ruleInfo(_ cbc: CommandBuildContext, input: Path, output: Path, variant: String, arch: String, language: String?) -> [String] {
        return ["Preprocess", input.str, variant, arch]
    }

    public override func resolveExecutionDescription(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        return "Preprocess \(cbc.input.absolutePath.basename)"
    }

    public override func interestingPath(for task: any ExecutableTask) -> Path? {
        return Path(task.ruleInfo[1])
    }
}

public final class ClangAssemblerSpec : ClangCompilerSpec, SpecImplementationType, @unchecked Sendable {
    public class override var identifier: String {
        "com.apple.compilers.llvm.clang.1_0.assembler"
    }

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ClangAssemblerSpec(createSpecParser(for: proxy, registry: registry), registry.getSpec("com.apple.compilers.llvm.clang.1_0"))
    }

    override var effectiveSourceFileOption: String {
        return "-S"
    }

    override var shouldPrecompilePrefixHeader: Bool {
        return false
    }

    /// Ensure we get a unique output file from the main compiler.
    override func outputFileExtension(for input: FileToBuild) -> String {
        return ".s"
    }

    /// Customize the rule info.
    override func ruleInfo(_ cbc: CommandBuildContext, input: Path, output: Path, variant: String, arch: String, language: String?) -> [String] {
        return ["Assemble", input.str, variant, arch]
    }

    public override func resolveExecutionDescription(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        return "Assemble \(cbc.input.absolutePath.basename)"
    }

    public override func interestingPath(for task: any ExecutableTask) -> Path? {
        return Path(task.ruleInfo[1])
    }
}

public final class ClangModuleVerifierSpec: ClangCompilerSpec, SpecImplementationType, @unchecked Sendable {
    public class override var identifier: String {
        "com.apple.compilers.llvm.clang.1_0.verify_module"
    }

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ClangModuleVerifierSpec(createSpecParser(for: proxy, registry: registry), registry.getSpec("com.apple.compilers.llvm.clang.1_0"))
    }

    /// Customize the rule info.
    public override func ruleInfo(_ cbc: CommandBuildContext, input: Path, output: Path, variant: String, arch: String, language: String?) -> [String] {
        let productName = cbc.scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME)
        let targetVariant = cbc.scope.evaluate(BuiltinMacros.CLANG_TARGET_TRIPLE_VARIANTS).first ?? ""
        let location = cbc.scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
        let std = cbc.scope.evaluate(language?.hasSuffix("++") == true ? BuiltinMacros.CLANG_CXX_LANGUAGE_STANDARD : BuiltinMacros.GCC_C_LANGUAGE_STANDARD)
        let lsv = cbc.scope.evaluate(BuiltinMacros.CLANG_MODULE_LSV) ? "lsv" : ""
        // FIXME: rename to VerifyModule once we remove the old one.
        return ["VerifyModuleC", "\(location.str)/\(productName.str)", targetVariant, variant, arch, language ?? "?", std, lsv, identifier]
    }

    public override func resolveExecutionDescription(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        let productName = cbc.scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME)
        return "Verify Modularization of \(productName.str) (new)"
    }

    public override func interestingPath(for task: any ExecutableTask) -> Path? {
        return Path(task.ruleInfo[1])
    }

    override func verifyingModule(_ cbc: CommandBuildContext) -> String? {
        return cbc.scope.evaluate(BuiltinMacros.PRODUCT_NAME)
    }

    override public func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        // Scanning modules runs in process and produces no parseable output
        guard task.ruleInfo.first != "ScanDependencies" else { return nil }
        return ClangModuleVerifierOutputParser.self
    }

    override func createClangModuleVerifierPayload(_ cbc: CommandBuildContext) -> ClangModuleVerifierPayload? {
        guard let fileNameMap = cbc.commandOrderingInputs.first(where: { $0.path.fileExtension == "json" }) else {
            return nil
        }
        return ClangModuleVerifierPayload(fileNameMapPath: fileNameMap.path)
    }
}

private func ==(lhs: ClangCompilerSpec.DataCache.ConstantFlagsKey, rhs: ClangCompilerSpec.DataCache.ConstantFlagsKey) -> Bool {
    return ObjectIdentifier(lhs.scope) == ObjectIdentifier(rhs.scope) && lhs.inputFileType == rhs.inputFileType
}
