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

import SWBUtil
public import SWBCore
import SWBProtocol
import SWBMacro

/// Payload information for Intents tasks.
fileprivate struct IntentsTaskPayload: TaskPayload, Encodable {
    /// The input path the payload applies to.
    let inputPath: Path
    /// The indexing specific information.
    let indexingPayload: IntentsIndexingInfo

    init(inputPath: Path, indexingPayload: IntentsIndexingInfo) {
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

/// The indexing info for an Intents file.  This will be sent to the client in a property list format described below.
fileprivate enum IntentsIndexingInfo: Serializable, SourceFileIndexingInfo, Encodable {
    /// Setting up the code generation task did not generate an error.  It might have been disabled, which is treated as success.
    case success(generatedFilePaths: [Path])
    /// Setting up the code generation task failed, and we use the index to propagate an error back to Xcode.
    case failure(error: String)

    func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .success(let generatedFilePaths):
                serializer.serialize(0 as Int)
                serializer.serialize(generatedFilePaths)
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
            self = .success(generatedFilePaths: try deserializer.deserialize())
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
        case .success(let generatedFilePaths):
            dict["INTENTS_GENERATED_FILE_PATHS"] = PropertyListItem(generatedFilePaths.map({ $0.str }))
        case .failure(let error):
            dict["INTENTS_GENERATOR_ERROR"] = PropertyListItem(error)
        }

        return .plDict(dict)
    }
}

public final class IntentsCompilerSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.intents"

    public override var supportsInstallAPI: Bool {
        return true
    }

    public override var supportsInstallHeaders: Bool {
        return true
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Construct the intentbuilderc task.
        await constructIntentsCompilerTasks(cbc, delegate)

        // Construct the code generation task.
        await constructIntentsCodeGenerationTasks(cbc, delegate)
    }

    private func constructIntentsCompilerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // NOTE: Tasks can be constructed during `installhdrs` and `build`, and as such, the compiler should only be invoked when there is a "build" component. This is necessary due to how SourcesTaskProducer works and normally skips all task generation, unless `supportsInstallHeaders` or `supportsInstallAPI` are true for a given spec.

        let components = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if !components.contains("build") { return }

        // Invoke the generic implementation in CommandLineToolSpec to generate the intentbuilderc task using the xcspec.
        await constructTasks(cbc, delegate, specialArgs: ["-classPrefix", cbc.scope.evaluate(BuiltinMacros.PROJECT_CLASS_PREFIX)])
    }

    private func constructIntentsCodeGenerationTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Compute the output directory.
        let input = cbc.input
        let modelName = input.absolutePath.basenameWithoutSuffix
        let outputDir = cbc.scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join("IntentDefinitionGenerated").join(modelName).normalize()

        guard
            let target = cbc.producer.configuredTarget?.target as? SWBCore.BuildPhaseTarget,
            target.sourcesBuildPhase != nil,
            let intentsCodegenVisibility = input.intentsCodegenVisibility else { return }

        if case .noCodegen = intentsCodegenVisibility {
            return
        }

        var codegenLanguage: String
        let languageSettingValue = cbc.scope.evaluate(BuiltinMacros.INTENTS_CODEGEN_LANGUAGE)

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
                delegate.error("\(input.absolutePath.basename): No predominant language detected. Please set \"Intent Class Generation Language\" (INTENTS_CODEGEN_LANGUAGE) to Objective-C or Swift")
                return
            default:
                // Other source code languages emit a warning and default to Objective-C.
                let languageString: String
                switch predominantSourceCodeLanguage {
                case .other(let string):
                    languageString = string
                default:
                    languageString = predominantSourceCodeLanguage.description
                }
                delegate.warning("\(input.absolutePath.basename): Target's predominant language \"\(languageString)\" is not supported for Intents code generation. Selecting Objective-C by default. Please set \"Intent Class Generation Language\" (INTENTS_CODEGEN_LANGUAGE) to Objective-C or Swift as required")
                codegenLanguage = "Objective-C"
            }
        } else {
            guard Set<String>(["Swift", "Objective-C", "None"]).contains(languageSettingValue) else {
                // If the setting is set to an unexpected value, then emit an error and return.
                delegate.error("\(input.absolutePath.basename): Unknown language \"\(languageSettingValue)\". Please set \"Intent Class Generation Language\" (INTENTS_CODEGEN_LANGUAGE) to Objective-C or Swift")
                return
            }
            codegenLanguage = languageSettingValue
        }

        // If we got this far, then we know we have a non-empty list of generated files.
        let inputs = [input.absolutePath]
        let ruleInfo = ["IntentDefinitionCodegen", input.absolutePath.str]
        var specialArgs = ["-classPrefix", cbc.scope.evaluate(BuiltinMacros.PROJECT_CLASS_PREFIX), "-language", codegenLanguage]
        if codegenLanguage == "Swift" {
            specialArgs += ["-swiftVersion", cbc.scope.evaluate(BuiltinMacros.SWIFT_VERSION)]
        }
        switch intentsCodegenVisibility {
        case .public, .private, .project:
            specialArgs += ["-visibility", intentsCodegenVisibility.rawValue]
        case .noCodegen: break
        }
        if let productType = cbc.producer.productType, productType.supportsDefinesModule && cbc.scope.evaluate(BuiltinMacros.DEFINES_MODULE) {
            specialArgs += ["-moduleName", cbc.scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME)]
        }
        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), specialArgs: specialArgs).map(\.asString)
        commandLine[1] = "generate"
        commandLine[5] = outputDir.str

        // Ask the client delegate for the list of paths of generated files.
        let generatedFiles: [Path]
        do {
            // Mark the file as being watched by the build system to invalidate the build description.
            delegate.access(path: input.absolutePath)

            generatedFiles = try await generatedFilePaths(cbc, delegate, commandLine: commandLine[0...1] + ["-dryRun"] + commandLine[2...], workingDirectory: cbc.producer.defaultWorkingDirectory.str, environment: self.environmentFromSpec(cbc, delegate).bindingsDictionary, executionDescription: "Compute Intent Definition \(input.absolutePath.basename) code generation output paths") { output in
                return output.unsafeStringValue.split(separator: "\n").map(Path.init).map { $0.prependingPrivatePrefixIfNeeded(otherPath: outputDir) }
            }
            guard !generatedFiles.isEmpty else {
                // If we were given an empty list of generated files, then there were just no files to be generated, so we return.
                // FIXME: Should we emit a generic error in this case?  Should the code generator ever return no files to be generated?
                return
            }
        } catch {
            delegate.error("Could not determine generated file paths for Intent Definition code generation: \(error)")
            return
        }

        // If we got this far, then we know we have a non-empty list of generated files.
        let outputs = generatedFiles

        let outputFilesToBuild = outputs.map { FileToBuild(absolutePath: $0, inferringTypeUsing: cbc.producer) }

        // Declare the output files so they can be processed by the build phase which called us.
        for outputFile in outputFilesToBuild {
            delegate.declareOutput(outputFile)
        }

        let payload = IntentsTaskPayload(inputPath: input.absolutePath, indexingPayload: .success(generatedFilePaths: generatedFiles))

        delegate.createTask(type: self, payload: payload, ruleInfo: ruleInfo, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, execDescription: "Generate code for intent definition \(input.absolutePath.basename)", preparesForIndexing: true, enableSandboxing: enableSandboxing)

        // Also add the generated headers to the generated files headermap.
        for outputFile in outputFilesToBuild {
            // Somehow the file type specification infrastructure doesn't define an 'isHeader' property, so we look at the file extension.
            if outputFile.absolutePath.fileExtension == "h" {
                delegate.declareGeneratedSourceFile(outputFile.absolutePath)

                let headerOutputPath: Path?
                switch intentsCodegenVisibility {
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
    }

    /// Generate and return the indexing information for the given task.
    public override func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        guard let payload = task.payload as? IntentsTaskPayload else { return [] }
        guard input.requestedSourceFiles.contains(payload.inputPath) else { return [] }
        return [.init(path: payload.inputPath, indexingInfo: payload.indexingPayload)]
    }

    public override var payloadType: (any TaskPayload.Type)? { return IntentsTaskPayload.self }
}
