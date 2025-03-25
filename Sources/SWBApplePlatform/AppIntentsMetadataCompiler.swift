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
import SWBMacro
public import SWBCore

/// The minimal data we need to serialize to reconstruct `generateLocalizationInfo`
private struct AppIntentsLocalizationPayload: TaskPayload {
    struct StringsdataFile: Serializable {
        let buildVariant: String
        let architecture: String
        let path: Path

        init(buildVariant: String, arch: String, path: Path) {
            self.buildVariant = buildVariant
            self.architecture = arch
            self.path = path
        }

        func serialize<T>(to serializer: T) where T : Serializer {
            serializer.serializeAggregate(3) {
                serializer.serialize(buildVariant)
                serializer.serialize(architecture)
                serializer.serialize(path)
            }
        }

        init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(3)
            self.buildVariant = try deserializer.deserialize()
            self.architecture = try deserializer.deserialize()
            self.path = try deserializer.deserialize()
        }
    }

    let effectivePlatformName: String
    let stringsdata: [StringsdataFile]

    init(effectivePlatformName: String, stringsdata: [StringsdataFile]) {
        self.effectivePlatformName = effectivePlatformName
        self.stringsdata = stringsdata
    }

    func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(2) {
            serializer.serialize(effectivePlatformName)
            serializer.serialize(stringsdata)
        }
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.effectivePlatformName = try deserializer.deserialize()
        self.stringsdata = try deserializer.deserialize()
    }
}

final public class AppIntentsMetadataCompilerSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.appintentsmetadata"
    public func shouldConstructAppIntentsMetadataTask(_ cbc: CommandBuildContext) -> Bool {
        return cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT) == "normal" &&
        cbc.producer.canConstructAppIntentsMetadataTask &&
        !cbc.inputs.filter({ $0.fileType.extensions.contains("swift") }).isEmpty
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        guard shouldConstructAppIntentsMetadataTask(cbc) else {
            return
        }

        var allInputs: [any PlannedNode] = cbc.inputs.map { input in
            return delegate.createNode(input.absolutePath)
        }
        var outputs = [any PlannedNode]()

        let binaryOutput = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_PATH)).normalize()
        allInputs.append(delegate.createNode(binaryOutput))

        let effectivePlatformName = LocalizationBuildPortion.effectivePlatformName(scope: cbc.scope, sdkVariant: cbc.producer.sdkVariant)
        let archs: [String] = cbc.scope.evaluate(BuiltinMacros.ARCHS)
        let buildVariants = cbc.scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        var dependencyFiles = [String]()
        var stringDataFiles = [AppIntentsLocalizationPayload.StringsdataFile]()
        var sourceFileListFiles = [String]()
        var swiftConstValuesFileListFiles = [String]()
        var metadataDependencyFileListFiles = [String]()
        var staticMetadataDependencyFileListFiles = [String]()

        func constructFileList(path: Path, inputs: [FileToBuild]) {
            let fileListContents = OutputByteStream()
            for inputFile in inputs {
                // appintentsmetadataprocessor splits by newline, and then replaces all backslashes in each entry with the empty string
                fileListContents <<< inputFile.absolutePath.str.quotedStringListRepresentation <<< "\n"
            }

            cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: path), delegate, contents: fileListContents.bytes, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        let metadataFileListPath = cbc.scope.evaluate(BuiltinMacros.LM_AUX_INTENTS_METADATA_FILES_LIST_PATH)
        if !metadataFileListPath.isEmpty {
            metadataDependencyFileListFiles.append(metadataFileListPath.str)
            allInputs.append(delegate.createNode(metadataFileListPath))
        }
        let staticMetadataFileListPath = cbc.scope.evaluate(BuiltinMacros.LM_AUX_INTENTS_STATIC_METADATA_FILES_LIST_PATH)
        if !staticMetadataFileListPath.isEmpty {
            staticMetadataDependencyFileListFiles.append(staticMetadataFileListPath.str)
            allInputs.append(delegate.createNode(staticMetadataFileListPath))
        }

        let isStaticLibrary = cbc.scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "staticlib"
        let isObject = cbc.scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_object"
        for variant in buildVariants {
            let scope = cbc.scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
            for arch in archs {
                let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
                let dependencyInfoFile = scope.evaluate(BuiltinMacros.LD_DEPENDENCY_INFO_FILE)
                let libtoolDependencyInfo = scope.evaluate(BuiltinMacros.LIBTOOL_DEPENDENCY_INFO_FILE)
                if !isStaticLibrary && !dependencyInfoFile.isEmpty {
                    dependencyFiles.append(dependencyInfoFile.str)
                    allInputs.append(delegate.createNode(dependencyInfoFile))
                } else if isStaticLibrary && !libtoolDependencyInfo.isEmpty {
                    dependencyFiles.append(libtoolDependencyInfo.str)
                    allInputs.append(delegate.createNode(libtoolDependencyInfo))
                }
                let stringDataDir = scope.evaluate(BuiltinMacros.STRINGSDATA_DIR)
                if !stringDataDir.isEmpty {
                    let stringsdataPath = stringDataDir.join("ExtractedAppShortcutsMetadata.stringsdata")
                    stringDataFiles.append(.init(buildVariant: variant, arch: arch, path: stringsdataPath))
                    outputs.append(delegate.createNode(stringsdataPath))
                }
                let sourceFileListPath = scope.evaluate(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH)
                if !sourceFileListPath.isEmpty {
                    sourceFileListFiles.append(sourceFileListPath.str)
                    allInputs.append(delegate.createNode(sourceFileListPath))
                }
                let swiftConstValuesFileListPath = scope.evaluate(BuiltinMacros.LM_AUX_CONST_METADATA_LIST_PATH)
                if !swiftConstValuesFileListPath.isEmpty {
                    let fileListInputs = cbc.inputs.filter { $0.absolutePath.fileExtension == "swiftconstvalues" }
                    constructFileList(path: swiftConstValuesFileListPath, inputs: fileListInputs)
                    swiftConstValuesFileListFiles.append(swiftConstValuesFileListPath.str)
                    allInputs.append(delegate.createNode(swiftConstValuesFileListPath))
                }
            }
        }

        let stringsFileType = cbc.producer.lookupFileType(identifier: "text.plist.strings")!
        let xcstringsFileType = cbc.producer.lookupFileType(identifier: "text.json.xcstrings")!

        let noLocalizationFiles = cbc.inputs.filter {
            guard $0.fileType.conformsTo(stringsFileType) || $0.fileType.conformsTo(xcstringsFileType) else { return false }
            guard $0.absolutePath.basename == "AppShortcuts.strings" || $0.absolutePath.basename == "AppShortcuts.xcstrings" else { return false }
            return true
        }.isEmpty

        let payload = AppIntentsLocalizationPayload(effectivePlatformName: effectivePlatformName, stringsdata: stringDataFiles)

        let toolSpecInfo = await (cbc.producer.swiftCompilerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo)

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.LM_OUTPUT_DIR:
                if isStaticLibrary || isObject {
                    let staticLibraryMetadataOutputDirectory = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
                        .join(cbc.scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME) + ".appintents").normalize()
                    return cbc.scope.table.namespace.parseLiteralString("\(staticLibraryMetadataOutputDirectory.str)")
                }
                return nil
            case BuiltinMacros.LM_FORCE_LINK_GENERATION:
                return (isStaticLibrary || isObject) ? cbc.scope.table.namespace.parseLiteralString("YES") : nil
            case BuiltinMacros.LM_BINARY_PATH:
                return cbc.scope.table.namespace.parseLiteralString(binaryOutput.str)
            case BuiltinMacros.LM_DEPENDENCY_FILES:
                return cbc.scope.table.namespace.parseLiteralStringList(dependencyFiles)
            case BuiltinMacros.LM_STRINGSDATA_FILES:
                return cbc.scope.table.namespace.parseLiteralStringList(stringDataFiles.map(\.path.str))
            case BuiltinMacros.LM_COMPILE_TIME_EXTRACTION:
                if cbc.scope.evaluate(BuiltinMacros.LM_COMPILE_TIME_EXTRACTION),
                   let toolSpecInfo,
                   toolSpecInfo.hasFeature(DiscoveredSwiftCompilerToolSpecInfo.FeatureFlag.constExtractCompleteMetadata.rawValue) {
                    return cbc.scope.table.namespace.parseLiteralString("YES")
                }
                return cbc.scope.table.namespace.parseLiteralString("NO")
            case BuiltinMacros.LM_SOURCE_FILE_LIST_PATH:
                return cbc.scope.table.namespace.parseLiteralStringList(sourceFileListFiles)
            case BuiltinMacros.LM_SWIFT_CONST_VALS_LIST_PATH:
                return cbc.scope.table.namespace.parseLiteralStringList(swiftConstValuesFileListFiles)
            case BuiltinMacros.LM_INTENTS_METADATA_FILES_LIST_PATH:
                return cbc.scope.table.namespace.parseLiteralStringList(metadataDependencyFileListFiles)
            case BuiltinMacros.LM_INTENTS_STATIC_METADATA_FILES_LIST_PATH:
                return cbc.scope.table.namespace.parseLiteralStringList(staticMetadataDependencyFileListFiles)
            case BuiltinMacros.LM_NO_APP_SHORTCUT_LOCALIZATION:
                return noLocalizationFiles ? cbc.scope.table.namespace.parseLiteralString("YES") : cbc.scope.table.namespace.parseLiteralString("NO")
            default:
                return nil
            }
        }

        // Workaround until we have rdar://93626172 (Re-enable AppIntentsMetadataProcessor outputs)

        let nodeName = (isObject || isStaticLibrary) ? "ExtractAppIntentsMetadata \(cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)) \(cbc.scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME) + "/Metadata.appintents")" : "ExtractAppIntentsMetadata \(cbc.resourcesDir?.join("Metadata.appintents").str ?? "")"
        let orderingNode = delegate.createVirtualNode(nodeName)
        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)
        delegate.createTask(type: self,
                            payload: payload,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: allInputs,
                            outputs: outputs + [orderingNode],
                            action: nil,
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            enableSandboxing: enableSandboxing)
    }

    public override var payloadType: (any TaskPayload.Type)? { return AppIntentsLocalizationPayload.self }

    public override func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
        guard let payload = task.payload as? AppIntentsLocalizationPayload else { return [] }

        var stringsdata = [LocalizationBuildPortion: [Path]]()
        for stringsdataFile in payload.stringsdata {
            let buildPortion = LocalizationBuildPortion(effectivePlatformName: payload.effectivePlatformName, variant: stringsdataFile.buildVariant, architecture: stringsdataFile.architecture)
            stringsdata[buildPortion, default: []].append(stringsdataFile.path)
        }

        return [TaskGenerateLocalizationInfoOutput(producedStringsdataPaths: stringsdata)]
    }
}
