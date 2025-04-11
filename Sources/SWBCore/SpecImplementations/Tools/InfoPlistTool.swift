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
import SWBMacro
import Foundation

public final class InfoPlistToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.info-plist-utility"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public func constructInfoPlistTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, generatedPkgInfoFile: Path? = nil, additionalContentFilePaths: [Path] = [], requiredArch: String? = nil, appPrivacyContentFiles: [Path] = [], clientLibrariesForCodelessBundle: [String] = []) async {
        let input = cbc.input
        let inputPath = input.absolutePath
        let outputPath = cbc.output
        var outputs = [outputPath]

        var effectiveAdditionalContentFilePaths = additionalContentFilePaths

        let productTypeAdditionalContentFilePath: Path? = {
            guard let additions = cbc.producer.productType?.infoPlistAdditions, !additions.isEmpty else { return nil }
            let contents: SWBUtil.ByteString
            do {
                contents = try ByteString(additions.asBytes(.binary))
            }
            catch {
                delegate.error("failed to serialize product type infoPlistAdditions: \(error)")
                return nil
            }

            let path = cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("ProductTypeInfoPlistAdditions.plist").normalize()
            cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: path), delegate, contents: contents, permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
            return path
        }()

        if let path = productTypeAdditionalContentFilePath {
            effectiveAdditionalContentFilePaths.append(path)
        }

        // Even though this is generic spec, we bypass the fully generic machinery in order to support our custom behaviors.
        //
        // FIXME: Figure out how this should work, when we get a better mechanism for binding specs to custom behavior.
        var commandLine = ["builtin-infoPlistUtility", inputPath.str]

        if let productType = cbc.producer.productType {
            commandLine += ["-producttype", productType.identifier]
        }
        if let generatedPkgInfoFile = generatedPkgInfoFile?.normalize() {
            commandLine += ["-genpkginfo", generatedPkgInfoFile.str]
            outputs.append(generatedPkgInfoFile)
        }
        if cbc.scope.evaluate(BuiltinMacros.INFOPLIST_ENFORCE_MINIMUM_OS) {
            commandLine.append("-enforceminimumos")
        }
        if cbc.scope.evaluate(BuiltinMacros.INFOPLIST_EXPAND_BUILD_SETTINGS) {
            commandLine.append("-expandbuildsettings")
        }
        switch cbc.scope.evaluate(BuiltinMacros.INFOPLIST_OUTPUT_FORMAT) {
        case "same-as-input":
            // Do nothing.
            break
        case "XML":
            commandLine += ["-format", "xml"]
        case let value:
            commandLine += ["-format", value]
        }
        commandLine += await commandLineFromOptions(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)
        for path in effectiveAdditionalContentFilePaths {
            commandLine += ["-additionalcontentfile", path.str]
        }

        for path in filteredPrivacyLocations(appPrivacyContentFiles, cbc) {
            commandLine += ["-scanforprivacyfile", path.str]
        }

        var cleanupArchs = Set<String>()
        func addCleanupArchs(_ platform: Platform) {
            for spec in platform.specRegistryProvider.specRegistry.findSpecs(ArchitectureSpec.self, domain: platform.name) {
                if spec.archSetting == nil && spec.realArchs == nil {
                    cleanupArchs.insert(spec.canonicalName)
                }
            }
        }
        if let platform = cbc.producer.platform {
            addCleanupArchs(platform)
        }
        if let platform = cbc.producer.platform?.correspondingDevicePlatform {
            addCleanupArchs(platform)
        }
        if let platform = cbc.producer.platform?.correspondingSimulatorPlatform {
            addCleanupArchs(platform)
        }

        if let requiredArch {
            commandLine += ["-requiredArchitecture", requiredArch]
        }

        commandLine += ["-o", outputPath.str]

        let context = InfoPlistProcessorTaskActionContext(scope: cbc.scope, productType: cbc.producer.productType, platform: cbc.producer.platform, sdk: cbc.producer.sdk, sdkVariant: cbc.producer.sdkVariant, cleanupRequiredArchitectures: cleanupArchs.sorted(), clientLibrariesForCodelessBundle: clientLibrariesForCodelessBundle)
        let inputs = [inputPath] + effectiveAdditionalContentFilePaths + appPrivacyContentFiles
        let serializer = MsgPackSerializer()
        serializer.serialize(context)
        let contextPath = delegate.recordAttachment(contents: serializer.byteString)
        let action = delegate.taskActionCreationDelegate.createInfoPlistProcessorTaskAction(contextPath)
        delegate.createTask(type: self, ruleInfo: ["ProcessInfoPlistFile", outputPath.str, inputPath.str], commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, action: action, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }

    // Returns a filtered, sorted list of privacy file locations to scan.
    func filteredPrivacyLocations(_ files: [Path], _ cbc: CommandBuildContext) -> [Path] {
        /*
         The idea is to group the items based on their basename (e.g. 'MyCoolStuff.framework') so that if the items is being embedded
         within the target, that is the one that is scanned vs. the path on disk that the item is being linked from.
         It's possible to have linkage to items that are not actually embedded within your target, so we need to have this heuristic
         to avoid unnecessary scanning.
         If we decide to change this to be only for embedded items, we can remove all of this and remove the code from `SourcesTaskProducer`
         that tracks the usage of these potential items.
         */
        var privacyFiles: [Path] = []
        var privacyFilesMap: [String:[Path]] = [:]
        for path in files {
            let basename = path.basename
            privacyFilesMap[basename, default: []].append(path)
        }
        for (_, paths) in privacyFilesMap {
            if paths.count > 1 {
                // If there are multiple variants of the same library,
                let targetBuildDir = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
                let targetName = cbc.scope.evaluate(BuiltinMacros.TARGET_NAME)
                let targetPath = targetBuildDir.join(targetName)

                if let pathToUse = paths.filter({ $0.str.hasPrefix(targetPath.str) }).first {
                    privacyFiles.append(pathToUse)
                }
                else {
                    // Unclear which one to use so pass them all.
                    privacyFiles.append(contentsOf: paths)
                }
            }
            else {
                privacyFiles.append(contentsOf: paths)
            }
        }

        // Keep this in a stable order, primarily for testing, but also for consistency in merging as
        // last-in-wins for any merge conflicts.
        return privacyFiles.sorted()
    }
}
