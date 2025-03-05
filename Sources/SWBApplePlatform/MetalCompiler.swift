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
public import SWBCore
public import SWBMacro

/// The indexing info for a file being compiled by metal.  This will be sent to the client in a property list format described below.
struct MetalSourceFileIndexingInfo: SourceFileIndexingInfo {
    let outputFile: Path
    let commandLine: [ByteString]
    let builtProductsDir: Path
    let toolchains: [String]

    init(outputFile: Path, commandLine: [ByteString], builtProductsDir: Path, toolchains: [String]) {
        self.outputFile = outputFile
        self.commandLine = commandLine
        self.builtProductsDir = builtProductsDir
        self.toolchains = toolchains
    }

    fileprivate init(task: any ExecutableTask, payload: MetalIndexingPayload) {
        self.outputFile = Path(task.commandLine[payload.outputFileIndex].asString)
        self.commandLine = ClangSourceFileIndexingInfo.indexingCommandLine(from: task.commandLine.map(\.asByteString), workingDir: payload.workingDir, responseFileMapping: [:])
        self.builtProductsDir = payload.builtProductsDir
        self.toolchains = payload.toolchains
    }

    /// The indexing info is packaged and sent to the client in the property list format defined here.
    public var propertyListItem: PropertyListItem {
        return .plDict([
            "outputFilePath": .plString(outputFile.str),
            "LanguageDialect": .plString("metal"),
            "metalASTCommandArguments": .plArray(commandLine.map { .plString($0.asString) }),
            "metalASTBuiltProductsDir": .plString(builtProductsDir.str),
            "toolchains": .plArray(toolchains.map {.plString($0)})
            ] as [String: PropertyListItem])
    }
}

extension OutputPathIndexingInfo {
    fileprivate init(task: any ExecutableTask, payload: MetalIndexingPayload) {
        self.init(outputFile: Path(task.commandLine[payload.outputFileIndex].asString))
    }
}

/// The minimal data we need to serialize to reconstruct `MetalSourceFileIndexingInfo` from `generateIndexingInfo`
fileprivate struct MetalIndexingPayload: Serializable, Encodable {
    let sourceFileIndex: Int
    let outputFileIndex: Int
    let builtProductsDir: Path
    let workingDir: Path
    let toolchains: [String]

    init(sourceFileIndex: Int,
         outputFileIndex: Int,
         builtProductsDir: Path,
         workingDir: Path,
         toolchains: [String]) {
        self.sourceFileIndex = sourceFileIndex
        self.outputFileIndex = outputFileIndex
        self.builtProductsDir = builtProductsDir
        self.workingDir = workingDir
        self.toolchains = toolchains
    }

    func sourceFile(for task: any ExecutableTask) -> Path {
        return Path(task.commandLine[self.sourceFileIndex].asString)
    }

    func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(5) {
            serializer.serialize(sourceFileIndex)
            serializer.serialize(outputFileIndex)
            serializer.serialize(builtProductsDir)
            serializer.serialize(workingDir)
            serializer.serialize(toolchains)
        }
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.sourceFileIndex = try deserializer.deserialize()
        self.outputFileIndex = try deserializer.deserialize()
        self.builtProductsDir = try deserializer.deserialize()
        self.workingDir = try deserializer.deserialize()
        self.toolchains = try deserializer.deserialize()
    }
}

fileprivate struct MetalTaskPayload: TaskPayload, Encodable {
    /// The path to the serialized diagnostic output.  Every clang task must provide this path.
    let serializedDiagnosticsPath: Path

    /// Additional information used to answer indexing queries.
    let indexingPayload: MetalIndexingPayload?

    init(serializedDiagnosticsPath: Path, indexingPayload: MetalIndexingPayload?) {
        self.serializedDiagnosticsPath = serializedDiagnosticsPath
        self.indexingPayload = indexingPayload
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(serializedDiagnosticsPath)
            serializer.serialize(indexingPayload)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.serializedDiagnosticsPath = try deserializer.deserialize()
        self.indexingPayload = try deserializer.deserialize()
    }
}

public final class MetalCompilerSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.metal"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let input = cbc.inputs[0]
        let inputPath = input.absolutePath

        let evaluatedOutputs = self.evaluatedOutputs(cbc, delegate)
        let outputs = evaluatedOutputs ?? []
        let outputNode = outputs[0]

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            if macro == BuiltinMacros.OutputPath, let output = evaluatedOutputs?.first {
                return cbc.scope.table.namespace.parseLiteralString(output.path.str)
            }
            return nil
        }

        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), specialArgs: [], lookup: lookup).map(\.asString)
        let indexingPayload = { () -> MetalIndexingPayload? in
            guard let sourceFileIndex = commandLine.firstIndex(of: inputPath.str), let outputFileIndex = commandLine.firstIndex(of: outputNode.path.str) else {
                delegate.warning("Failed to generate source indexing info for \"\(inputPath.str)\"")
                return nil
            }

            return MetalIndexingPayload(
                sourceFileIndex: sourceFileIndex,
                outputFileIndex: outputFileIndex,
                builtProductsDir: cbc.scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR),
                workingDir: cbc.scope.evaluate(BuiltinMacros.PROJECT_DIR),
                toolchains: cbc.producer.toolchains.map{ $0.identifier }
            )
        }()

        let diagFilePath = cbc.scope.evaluate(BuiltinMacros.CLANG_DIAGNOSTICS_FILE, lookup: { self.lookup($0, cbc, delegate) })

        // Create the task payload.
        let payload = MetalTaskPayload(
            serializedDiagnosticsPath: diagFilePath,
            indexingPayload: indexingPayload)

        await super.constructTasks(cbc, delegate, specialArgs: [], payload: payload, commandLine: commandLine, additionalTaskOrderingOptions: [.compilationForIndexableSourceFile], toolLookup: nil)
    }

    public override func lookup(_ macro: MacroDeclaration, _ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, _ lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> MacroExpression? {
        switch macro {
        case cbc.scope.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, "InputFileBaseUniquefier"):
            return cbc.scope.namespace.parseLiteralString(cbc.input.uniquingSuffix)
        default:
            return super.lookup(macro, cbc, delegate, lookup)
        }
    }

    override public func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        let payload = task.payload! as! MetalTaskPayload
        return [payload.serializedDiagnosticsPath]
    }

    /// Examines the task and returns the indexing information for the source file it compiles.
    override public func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        let payload = task.payload! as! MetalTaskPayload
        guard let indexingPayload = payload.indexingPayload else { return [] }
        let sourceFile = indexingPayload.sourceFile(for: task)
        guard input.requestedSourceFiles.contains(sourceFile) else { return [] }
        let indexingInfo: any SourceFileIndexingInfo
        if input.outputPathOnly {
            indexingInfo = OutputPathIndexingInfo(task: task, payload: indexingPayload)
        } else {
            indexingInfo = MetalSourceFileIndexingInfo(task: task, payload: indexingPayload)
        }
        return [.init(path: sourceFile, indexingInfo: indexingInfo)]
    }

    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return SerializedDiagnosticsOutputParser.self
    }

    override public var payloadType: (any TaskPayload.Type)? { return MetalTaskPayload.self }
}

public final class MetalLinkerSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.metal-linker"
}
