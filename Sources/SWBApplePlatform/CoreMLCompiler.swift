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
import SWBProtocol

public struct DiscoveredCoreMLToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let toolPath: Path
    public var toolVersion: Version?
}

/// Payload information for CoreML tasks.
fileprivate struct CoreMLTaskPayload: TaskPayload, Encodable {
    /// The input path the payload applies to.
    let inputPath: Path
    /// The indexing specific information.
    let indexingPayload: CoreMLIndexingInfo

    init(inputPath: Path, indexingPayload: CoreMLIndexingInfo) {
        self.inputPath = inputPath
        self.indexingPayload = indexingPayload
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(inputPath)
            serializer.serialize(indexingPayload)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.inputPath = try deserializer.deserialize()
        self.indexingPayload = try deserializer.deserialize()
    }
}

/// The indexing info for a CoreML file.  This will be sent to the client in a property list format described below.
fileprivate enum CoreMLIndexingInfo: Serializable, SourceFileIndexingInfo, Encodable {
    /// Setting up the code generation task did not generate an error.  It might have been disabled, which is treated as success.
    case success(generatedFilePaths: [Path]?, languageToGenerate: String, notice: String?)
    /// Setting up the code generation task failed, and we use the index to propagate an error back to Xcode.
    case failure(error: String)

    func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .success(let generatedFilePaths, let languageToGenerate, let notice):
                serializer.serialize(0 as Int)
                serializer.serializeAggregate(3) {
                    serializer.serialize(generatedFilePaths)
                    serializer.serialize(languageToGenerate)
                    serializer.serialize(notice)
                }
            case .failure(let error):
                serializer.serialize(1 as Int)
                serializer.serialize(error)
            }
        }
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as Int {
        case 0:
            try deserializer.beginAggregate(3)
            self = .success(generatedFilePaths: try deserializer.deserialize() as [Path]?, languageToGenerate: try deserializer.deserialize(), notice: try deserializer.deserialize())
        case 1:
            self = .failure(error: try deserializer.deserialize())
        case let v:
            throw DeserializerError.unexpectedValue("Unexpected type code (\(v))")
        }
    }

    /// The indexing info is packaged and sent to the client in the property list format defined here.
    public var propertyListItem: PropertyListItem {
        var dict = [String: PropertyListItem]()

        switch self {
            case .success(let generatedFilePaths, let languageToGenerate, let notice):
                if let generatedFilePaths {
                    dict["COREMLCOMPILER_GENERATED_FILE_PATHS"] = PropertyListItem(generatedFilePaths.map({ $0.str }))
                }
                dict["COREMLCOMPILER_LANGUAGE_TO_GENERATE"] = PropertyListItem(languageToGenerate)
                if let notice {
                    dict["COREMLCOMPILER_GENERATOR_NOTICE"] = PropertyListItem(notice)
                }
            case .failure(let error):
                dict["COREMLCOMPILER_GENERATOR_ERROR"] = PropertyListItem(error)
        }

        return .plDict(dict)
    }
}

public final class CoreMLCompilerSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.coreml"

    public override var supportsInstallHeaders: Bool {
        return true
    }

    public override var supportsInstallAPI: Bool {
        return true
    }

    public override var enableSandboxing: Bool {
        return true
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Construct the code generation task.  This may return a CoreMLIndexingInfo struct to be added to the payload of the coremlc task (created below).  This struct can include diagnostic information which is needed even if no code generation task is created, so we associate it with the compiler task instead.
        let indexingInfo = await constructCoreMLCodeGenerationTasks(cbc, delegate)

        // Construct the coremlc task.
        await constructCoreMLCompilerTasks(cbc, delegate, indexingInfo)
    }

    private func constructCoreMLCodeGenerationTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async -> CoreMLIndexingInfo? {
        // Compute the output directory.
        let input = cbc.input
        let modelName = input.absolutePath.basenameWithoutSuffix
        let outputDir = cbc.scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join("CoreMLGenerated").join(modelName).normalize()

        // Compute the language to use for the generated files based on $(COREML_CODEGEN_LANGUAGE).
        var codegenLanguage: String
        var languageSettingValue = cbc.scope.evaluate(BuiltinMacros.COREML_CODEGEN_LANGUAGE)
        // Support for deprecated setting $(MLKIT_CODEGEN_LANGUAGE), c.f. rdar://31583635
        if languageSettingValue.isEmpty {
            languageSettingValue = cbc.scope.evaluate(BuiltinMacros.MLKIT_CODEGEN_LANGUAGE)
        }
        //TODO: rdar://59938938 rename intentsCodegenVisibility to a more generic name
        guard let codeGenVisibility = input.intentsCodegenVisibility else {
            return nil
        }

        if codeGenVisibility == .noCodegen {
            return nil
        }

        // When the build setting is empty or is set to Automatic, then use an appropriate string based on the predominant source code language for the target.
        if languageSettingValue.isEmpty || languageSettingValue == "Automatic" {
            // Note that it would be pretty weird here to not have a configured target, or to have a target which is not a StandardTarget.
            let predominantSourceCodeLanguage = (cbc.producer.configuredTarget?.target as? SWBCore.StandardTarget)?.predominantSourceCodeLanguage ?? .undefined
            switch predominantSourceCodeLanguage {
            case .swift:
                codegenLanguage = "Swift"
            case .objectiveC, .cPlusPlus, .objectiveCPlusPlus:
                codegenLanguage = "Objective-C"
            case .undefined:
                // If there is no predominant source code language, then emit an error and return.
                delegate.error("\(input.absolutePath.basename): No predominant language detected.  Set COREML_CODEGEN_LANGUAGE to preferred language.")
                return .failure(error: "Unknown language")
            default:
                // Other source code languages emit a warning and default to Objective-C.
                let languageString: String
                switch predominantSourceCodeLanguage {
                case .other(let string):
                    languageString = string
                default:
                    languageString = predominantSourceCodeLanguage.description
                }
                delegate.warning("\(input.absolutePath.basename): Target's predominant language \"\(languageString)\" is not supported for CoreML code generation.  Selecting Objective-C by default.  Set COREML_CODEGEN_LANGUAGE to preferred language.")
                codegenLanguage = "Objective-C"
            }
        }
        else {
            guard Set<String>(["Swift", "Objective-C", "None"]).contains(languageSettingValue) else {
                // If the setting is set to an unexpected value, then emit an error and return.
                delegate.error("\(input.absolutePath.basename): COREML_CODEGEN_LANGUAGE set to unsupported language \"\(languageSettingValue)\".  Set COREML_CODEGEN_LANGUAGE to preferred language.")
                return .failure(error: "Unknown language [2]")
            }
            codegenLanguage = languageSettingValue
        }

        // Assemble the additional command-line options for the code generation task.
        var additionalOptions = ["--language", codegenLanguage]
        switch codegenLanguage {
        case "None":
            // Setting the language to "None" disables code generation, without an error.
            return .success(generatedFilePaths: nil, languageToGenerate: "None", notice: "Disabled in project (CoreML Code Generation Language set to \"none\")")
        case "Swift":
            // Add additional options for Swift.
            var swiftVersionSettingValue = cbc.scope.evaluate(BuiltinMacros.COREML_CODEGEN_SWIFT_VERSION)
            // Support for deprecated setting $(MLKIT_CODEGEN_SWIFT_VERSION), c.f. rdar://31583635
            if swiftVersionSettingValue.isEmpty {
                swiftVersionSettingValue = cbc.scope.evaluate(BuiltinMacros.MLKIT_CODEGEN_SWIFT_VERSION)
            }

            guard !swiftVersionSettingValue.isEmpty else {
                // If the Swift version isn't set, then emit an error and return.
                delegate.error("\(input.absolutePath.basename): No Swift version specified.  Set COREML_CODEGEN_SWIFT_VERSION to preferred Swift version.")
                return .failure(error: "Unsupported Swift Version")
            }
            additionalOptions.append(contentsOf: ["--swift-version", swiftVersionSettingValue])
            if codeGenVisibility == .public {
                additionalOptions.append("--public-access")
            }
            if cbc.scope.evaluate(BuiltinMacros.COREML_CODEGEN_SWIFT_GLOBAL_MODULE) {
                additionalOptions.append("--globalmodule")
            }
        case "Objective-C":
            // No other options are needed for Objective-C.
            break
        default:
            // We should never get here.
            preconditionFailure("CoreML code generation language set to unsupported value '\(codegenLanguage)'.")
        }

        // Generate the command line from the xcspec.
        let baseCommandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)

        // Support .mlpackage
        let inputs = cbc.inputs.map { input -> (any PlannedNode) in
                                        if input.fileType.isWrapper {
                                            return delegate.createDirectoryTreeNode(input.absolutePath)
                                        }
                                        return delegate.createNode(input.absolutePath)
        }

        let ruleInfo = ["CoreMLModelCodegen", input.absolutePath.str]
        var commandLine = baseCommandLine
        commandLine[1] = "generate"
        commandLine[3] = outputDir.str
        commandLine.append(contentsOf: additionalOptions)

        // Ask the client delegate for the list of paths of generated files.
        let generatedFiles: [Path]
        do {
            // Mark the file as being watched by the build system to invalidate the build description.
            delegate.access(path: input.absolutePath)

            generatedFiles = try await generatedFilePaths(cbc, delegate, commandLine: commandLine[0...3] + ["--dry-run", "yes"] + commandLine[4...], workingDirectory: cbc.producer.defaultWorkingDirectory.str, environment: self.environmentFromSpec(cbc, delegate).bindingsDictionary, executionDescription: "Compute CoreML model \(input.absolutePath.basename) code generation output paths") { output in
                return output.unsafeStringValue.split(separator: "\n").map(Path.init)
            }
            guard !generatedFiles.isEmpty else {
                // If we were given an empty list of generated files, then there were just no files to be generated, so we return.
                // FIXME: Should we emit a generic error in this case?  Should the code generator ever return no files to be generated?
                return nil
            }
        } catch {
            delegate.error("Could not determine generated file paths for CoreML code generation: \(error)")
            return .failure(error: "Error preparing CoreML model \"\(input.absolutePath.basename)\" for code generation: \(error)")
        }

        // If we got this far, then we know we have a non-empty list of generated files.
        let outputs = generatedFiles
        let outputFilesToBuild = outputs.map { output -> FileToBuild in

            let fileType = cbc.producer.lookupFileType(fileName: output.basename) ?? cbc.producer.lookupFileType(identifier: "file")!
            // Force compiling with ARC if it's an ObjC file.
            let isObjCFile = fileType.conformsTo(cbc.producer.lookupFileType(identifier: "sourcecode.c.objc")!) || fileType.conformsTo(cbc.producer.lookupFileType(identifier: "sourcecode.cpp.objcpp")!)
            let namespace = cbc.scope.namespace
            let additionalArgs = isObjCFile ? namespace.parseLiteralStringList(["-fobjc-arc"]) : nil
            return FileToBuild(absolutePath: output, inferringTypeUsing: cbc.producer, additionalArgs: additionalArgs)
        }

        // Declare the output files so they can be processed by the build phase which called us.
        for outputFile in outputFilesToBuild {
            delegate.declareOutput(outputFile)
        }

        delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs.map(delegate.createNode), execDescription: "Generate \(codegenLanguage) language interface for CoreML model document \(input.absolutePath.basename)", preparesForIndexing: true, enableSandboxing: enableSandboxing)

        // Also add the generated headers to the generated files headermap.
        for outputFile in outputFilesToBuild {
            // Somehow the file type specification infrastructure doesn't define an 'isHeader' property, so we look at the file extension.
            if outputFile.absolutePath.fileExtension == "h" {
                delegate.declareGeneratedSourceFile(outputFile.absolutePath)

                let headerOutputPath: Path?
                switch codeGenVisibility {
                case .public:
                    headerOutputPath = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH)).join(outputFile.absolutePath.basename)
                case .private:
                    headerOutputPath = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.PRIVATE_HEADERS_FOLDER_PATH)).join(outputFile.absolutePath.basename)
                case .project, .noCodegen:
                    headerOutputPath = nil
                }

                guard
                    let target = cbc.producer.configuredTarget?.target as? SWBCore.BuildPhaseTarget,
                    let outputPath = headerOutputPath,
                    target.headersBuildPhase != nil else { continue }

                await cbc.producer.copySpec.constructCopyTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [outputFile], output: outputPath, preparesForIndexing: true), delegate, additionalTaskOrderingOptions: .compilationRequirement)
            }
        }

        // Return the indexing info for the generated files.
        return .success(generatedFilePaths: generatedFiles, languageToGenerate: codegenLanguage, notice: nil)
    }

    private func constructCoreMLCompilerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ indexingInfo: CoreMLIndexingInfo?) async {
        let input = cbc.input

        let components = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if !components.contains("build") { return }

        // Create the payload for the task, if we were passed an indexing info struct.
        var payload: CoreMLTaskPayload? = nil
        if let indexingInfo {
            payload = CoreMLTaskPayload(inputPath: input.absolutePath, indexingPayload: indexingInfo)
        }

        // Invoke the generic implementation in CommandLineToolSpec to generate the mlkitc task using the xcspec.
        await constructTasks(cbc, delegate, specialArgs: [], payload: payload)
    }

    /// Generate and return the indexing information for the given task.
    public override func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        guard let payload = task.payload as? CoreMLTaskPayload else { return [] }
        guard input.requestedSourceFiles.contains(payload.inputPath) else { return [] }
        return [.init(path: payload.inputPath, indexingInfo: payload.indexingPayload)]
    }

    public override var payloadType: (any TaskPayload.Type)? { return CoreMLTaskPayload.self }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = self.resolveExecutablePath(producer, Path("coremlc"))

        // Get the info from the global cache.
        do {
            return try await DiscoveredCoreMLToolSpecInfo.parseWhatStyleVersionInfo(producer, delegate, toolPath: toolPath) { versionInfo in
                DiscoveredCoreMLToolSpecInfo(toolPath: toolPath, toolVersion: versionInfo.version)
            }
        } catch {
            delegate.error(error)
            return nil
        }
    }
}
