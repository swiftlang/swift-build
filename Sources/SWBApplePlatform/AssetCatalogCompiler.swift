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
import SWBUtil
public import SWBCore
import SWBTaskConstruction
public import SWBMacro

public final class ActoolCompilerSpec : GenericCompilerSpec, SpecIdentifierType, IbtoolCompilerSupport, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.assetcatalog"

    private func constructAssetPackOutputSpecificationsTask(catalogInputs inputs: [FileToBuild], _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async -> Path? {
        guard cbc.scope.evaluate(BuiltinMacros.ENABLE_ON_DEMAND_RESOURCES) else { return nil }

        for input in inputs {
            delegate.access(path: input.absolutePath)
        }

        let assetTagSets: Set<Set<String>>
        do {
            assetTagSets = try await assetTagCombinations(catalogInputs: inputs, cbc, delegate)
        } catch {
            delegate.error("failed to read asset tags: \(error)")
            assetTagSets = []
        }

        let assetPacks = assetTagSets.compactMap { cbc.producer.onDemandResourcesAssetPack(for: $0) }
        guard !assetPacks.isEmpty else { return nil }

        // Construct a plist that maps tag sets to asset pack directory paths.  Tools that have an internal notion of asset tags need this to know where to put output files.
        let path = cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("AssetPackOutputSpecifications.plist")
        let plist = AssetPackOutputSpecificationsPlist(assetPacks: assetPacks).propertyListItem

        let data: [UInt8]
        do {
            data = try plist.asBytes(.xml)
        }
        catch {
            delegate.error("failed to format plist for \(path): \(plist): \(error)")
            return nil
        }

        cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: path), delegate, contents: ByteString(data), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        return path
    }

    private func assetTagCombinations(catalogInputs inputs: [FileToBuild], _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async throws -> Set<Set<String>> {
        return try await executeExternalTool(cbc, delegate, commandLine: [resolveExecutablePath(cbc, cbc.scope.actoolExecutablePath()).str, "--print-asset-tag-combinations", "--output-format", "xml1"] + inputs.map { $0.absolutePath.str }, workingDirectory: cbc.producer.defaultWorkingDirectory.str, environment: environmentFromSpec(cbc, delegate).bindingsDictionary, executionDescription: "Compute asset tag combinations") { output in
            struct AssetCatalogToolOutput: Decodable {
                struct Diagnostic: Decodable {
                    let description: String
                }
                let assetTagCombinations: Set<Set<String>>?
                let errors: [Diagnostic]?
                let warnings: [Diagnostic]?
                let notices: [Diagnostic]?

                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let combinations = try container.decodeIfPresent([[String]].self, forKey: .assetTagCombinations) {
                        assetTagCombinations = Set(combinations.map(Set.init))
                    } else {
                        assetTagCombinations = nil
                    }
                    errors = try container.decodeIfPresent([Diagnostic].self, forKey: .errors)
                    warnings = try container.decodeIfPresent([Diagnostic].self, forKey: .warnings)
                    notices = try container.decodeIfPresent([Diagnostic].self, forKey: .notices)
                }

                enum CodingKeys: String, CodingKey {
                    case assetTagCombinations = "com.apple.actool.asset-tag-combinations"
                    case errors = "com.apple.actool.errors"
                    case warnings = "com.apple.actool.warnings"
                    case notices = "com.apple.actool.notices"
                }
            }

            let toolOutput = try PropertyList.decode(AssetCatalogToolOutput.self, from: PropertyList.fromBytes(output.bytes))
            guard let combinations = toolOutput.assetTagCombinations else {
                for error in toolOutput.errors ?? [] {
                    delegate.error(error.description)
                }
                for warning in toolOutput.warnings ?? [] {
                    delegate.warning(warning.description)
                }
                for note in toolOutput.notices ?? [] {
                    delegate.note(note.description)
                }

                // If we failed to get any asset tags AND there were no errors, make sure to emit an error
                if toolOutput.errors?.count == 0 {
                    delegate.error("failed to read asset tags because the actool output could not be parsed and no errors were emitted")
                }

                return Set()
            }

            return combinations
        }
    }

    // Support generating asset symbols during installapi action.
    public override var supportsInstallAPI: Bool {
        return true
    }

    // Support generating asset symbols during installhdrs action.
    public override var supportsInstallHeaders: Bool {
        return true
    }

    /// Override to compute the special arguments.
    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let buildComponents = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let isMainPackageWithResourceBundle = !cbc.scope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_BUNDLE_NAME).isEmpty

        var specialArgs = [String]()

        specialArgs += targetDeviceArguments(cbc, delegate)
        specialArgs += minimumDeploymentTargetArguments(cbc, delegate)

        // Add the platform options.
        var platformName = cbc.scope.evaluate(BuiltinMacros.RESOURCES_PLATFORM_NAME)
        if platformName.isEmpty {
            platformName = cbc.scope.evaluate(BuiltinMacros.PLATFORM_NAME)
        }
        specialArgs += ["--platform", platformName]

        // File types
        let catalogFileTypes = ["folder.assetcatalog", "folder.stickers"].map { cbc.producer.lookupFileType(identifier: $0)! }
        let stringsFileType = cbc.producer.lookupFileType(identifier: "text.plist.strings")!

        // Construct the command line using this custom lookup function.
        let inputs = cbc.inputs.map({ delegate.createDirectoryTreeNode($0.absolutePath) as (any PlannedNode) })
        let catalogInputs = cbc.inputs.compactMap { ftb in catalogFileTypes.contains { ftb.fileType.conformsTo($0) } ? ftb : nil }
        let catalogInputPaths = catalogInputs.map { $0.absolutePath }
        let stringsInputPaths = cbc.inputs.compactMap { ftb in ftb.fileType.conformsTo(stringsFileType) ? ftb : nil }

        // ODR
        var odrInputs = [any PlannedNode]()
        if let assetPackInfoFile = await constructAssetPackOutputSpecificationsTask(catalogInputs: catalogInputs, cbc, delegate) {
            specialArgs += [
                "--asset-pack-output-specifications",
                assetPackInfoFile.str
            ]

            odrInputs.append(delegate.createNode(assetPackInfoFile))
        }

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.ASSETCATALOG_COMPILER_INPUTS:
                return cbc.scope.table.namespace.parseLiteralStringList(catalogInputPaths.map({ $0.str }))

            case BuiltinMacros.ASSETCATALOG_COMPILER_STICKER_PACK_STRINGS:
                return cbc.scope.table.namespace.parseLiteralStringList(stringsInputPaths.map({ stringsFile in
                    let base = stringsFile.absolutePath.basenameWithoutSuffix
                    let region = stringsFile.regionVariantName ?? ""
                    let path = stringsFile.absolutePath.str
                    return [base, region, path].joined(separator: ":")
                }))

            default:
                return nil
            }
        }

        func effectiveCommandLine(unthinned: Bool = false, outputDirectoryOverride: String? = nil, dependencyFileOverride: String? = nil, infoPlistContentOverride: String? = nil, lookup: @escaping (MacroDeclaration) -> MacroExpression? = lookup) async -> [CommandLineArgument] {
            await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), specialArgs: specialArgs) { decl in
                switch decl {
                case BuiltinMacros.UnlocalizedProductResourcesDir:
                    if let outputDirectoryOverride {
                        return cbc.scope.table.namespace.parseLiteralString(outputDirectoryOverride)
                    }
                case BuiltinMacros.ASSETCATALOG_COMPILER_DEPENDENCY_INFO_FILE:
                    if let dependencyFileOverride {
                        return cbc.scope.table.namespace.parseLiteralString(dependencyFileOverride)
                    }
                case BuiltinMacros.ASSETCATALOG_COMPILER_INFOPLIST_CONTENT_FILE:
                    if let infoPlistContentOverride {
                        return cbc.scope.table.namespace.parseLiteralString(infoPlistContentOverride)
                    }
                case BuiltinMacros.ENABLE_ONLY_ACTIVE_RESOURCES where unthinned, BuiltinMacros.BUILD_ACTIVE_RESOURCES_ONLY where unthinned:
                    return cbc.scope.table.namespace.parseLiteralString("NO")
                default:
                    break
                }
                return lookup(decl)
            }
        }

        // Get the directories which must be created before this task is run.  This currently has a very narrow behavior where only directories being created by the ProductStructureTaskProducer in the task construction framework will be respected - others will be ignored.
        func effectiveRequiredDirectories(outputDirectoryOverride: String? = nil) -> [any PlannedNode] {
            (evaluatedRequiredDirectories(cbc, delegate) { decl in
                switch decl {
                case BuiltinMacros.UnlocalizedProductResourcesDir:
                    if let outputDirectoryOverride {
                        return cbc.scope.table.namespace.parseLiteralString(outputDirectoryOverride)
                    }
                default:
                    break
                }
                return lookup(decl)
            } ?? []).flatMap { [delegate.createVirtualNode("MkDir \($0.str)") as (any PlannedNode), delegate.createNode($0) as (any PlannedNode)] }
        }

        func realInputs(outputDirectoryOverride: String? = nil) -> [any PlannedNode] {
            inputs + effectiveRequiredDirectories(outputDirectoryOverride: outputDirectoryOverride) + odrInputs
        }

        // Compute the outputs.
        let evaluatedOutputsResult = evaluatedOutputs(cbc, delegate) ?? []

        let additionalEvaluatedOutputsResult = await additionalEvaluatedOutputs(cbc, delegate)
        // Only declare generated info plist content during the build action (when we compile asset catalogs), not installapi or installhdrs.
        // Never compile asset catalogs in main package targets with synthesized resource bundles since they're compiled in the latter.
        if let infoPlistContent = additionalEvaluatedOutputsResult.generatedInfoPlistContent, buildComponents.contains("build"), !isMainPackageWithResourceBundle {
            delegate.declareGeneratedInfoPlistContent(infoPlistContent)
        }

        // <rdar://39810592&39762975> Add the .car file as a declared output until llbuild adds support for discovered outputs,
        // which it currently receives a listing of via the assetcatalog_dependencies file produced by actool.
        let carFiles = [cbc.resourcesDir?.join("Assets.car")].compactMap { $0 }.map(delegate.createNode)

        let outputs = evaluatedOutputsResult + (additionalEvaluatedOutputsResult.outputs ).map(delegate.createNode)
        guard !outputs.isEmpty else { preconditionFailure("ActoolCompilerSpec.constructTasks() invoked with no outputs defined") }

        let assetSymbolInputs = cbc.inputs
            .filter { isAssetCatalog(scope: cbc.scope, fileType: $0.fileType, absolutePath: $0.absolutePath, includeGenerated: false) }
            .map { delegate.createDirectoryTreeNode($0.absolutePath) as (any PlannedNode) }
        let sourceFiles = (cbc.producer.configuredTarget?.target as? StandardTarget)?.sourcesBuildPhase?.buildFiles.count ?? 0
        let generateAssetSymbols = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS)
        // Generate asset symbols during the build, installapi, and installhdrs actions.
        // This ensures generated -Swift.h files match between phases.
        if generateAssetSymbols && (sourceFiles > 0) && !assetSymbolInputs.isEmpty {
            var generatedFiles = [Path]()
            var symbolsCommandLineArgs = [CommandLineArgument]()

            symbolsCommandLineArgs += ["--bundle-identifier", .literal(.init(encodingAsUTF8: cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_BUNDLE_IDENTIFIER)))]

            let generatedWarnings = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_WARNINGS)
            if !generatedWarnings {
                symbolsCommandLineArgs += ["--generate-asset-symbol-warnings", generatedWarnings ? "YES" : "NO"]
            }

            let generatedErrors = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_ERRORS)
            if !generatedErrors {
                symbolsCommandLineArgs += ["--generate-asset-symbol-errors", generatedErrors ? "YES" : "NO"]
            }

            // Only generate Swift asset symbols for targets that already compile Swift sources to avoid introducing build errors in pure Objective-C targets.
            let targetContainsSwiftSources = (cbc.producer.configuredTarget?.target as? StandardTarget)?.sourcesBuildPhase?.containsSwiftSources(cbc.producer, cbc.producer, cbc.scope, cbc.producer.filePathResolver) ?? false
            if targetContainsSwiftSources {
                let generatedExtensions = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS)
                if !generatedExtensions {
                    symbolsCommandLineArgs += ["--generate-swift-asset-symbol-extensions", generatedExtensions ? "YES" : "NO"]
                }

                let generatedFrameworkSupport = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_FRAMEWORKS)
                if Set(generatedFrameworkSupport) != Set(["SwiftUI", "UIKit", "AppKit"]) {
                    for framework in generatedFrameworkSupport {
                        symbolsCommandLineArgs += ["--generate-asset-symbol-framework-support", .literal(.init(encodingAsUTF8: framework))]
                    }
                }

                let generatedBackwardsDeploymentSupport = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_BACKWARDS_DEPLOYMENT_SUPPORT)
                if generatedBackwardsDeploymentSupport != "" {
                    symbolsCommandLineArgs += ["--generate-asset-symbol-backwards-deployment-support", .literal(.init(encodingAsUTF8: generatedBackwardsDeploymentSupport))]
                }

                let generatedSwiftAssetSymbols = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOLS_PATH)
                delegate.declareOutput(FileToBuild(absolutePath: generatedSwiftAssetSymbols, inferringTypeUsing: cbc.producer))
                generatedFiles.append(generatedSwiftAssetSymbols)
                symbolsCommandLineArgs += ["--generate-swift-asset-symbols", .path(generatedSwiftAssetSymbols)]
            }

            let generatedObjCAssetSymbols = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_OBJC_ASSET_SYMBOLS_PATH)
            delegate.declareOutput(FileToBuild(absolutePath: generatedObjCAssetSymbols, inferringTypeUsing: cbc.producer))
            delegate.declareGeneratedSourceFile(generatedObjCAssetSymbols)
            generatedFiles.append(generatedObjCAssetSymbols)
            symbolsCommandLineArgs += ["--generate-objc-asset-symbols", .path(generatedObjCAssetSymbols)]

            let assetSymbolIndexPath = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_INDEX_PATH)
            symbolsCommandLineArgs += ["--generate-asset-symbol-index", .path(assetSymbolIndexPath)]
            generatedFiles.append(assetSymbolIndexPath)

            if generatedFiles.count > 0 {
                func assetSymbolLookup(_ macro: MacroDeclaration) -> MacroExpression? {
                    (macro == BuiltinMacros.ASSETCATALOG_COMPILER_INPUTS) ? cbc.scope.table.namespace.parseLiteralStringList(assetSymbolInputs.map { $0.path.str }) : lookup(macro)
                }

                let action: (any PlannedTaskAction)?
                if let deferredAction = delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences) {
                    action = deferredAction
                } else if cbc.scope.evaluate(BuiltinMacros.ENABLE_GENERIC_TASK_CACHING), let casOptions = try? CASOptions.create(cbc.scope, .generic) {
                    action = delegate.taskActionCreationDelegate.createGenericCachingTaskAction(
                        enableCacheDebuggingRemarks: cbc.scope.evaluate(BuiltinMacros.GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS),
                        enableTaskSandboxEnforcement: !cbc.scope.evaluate(BuiltinMacros.DISABLE_TASK_SANDBOXING),
                        sandboxDirectory: cbc.scope.evaluate(BuiltinMacros.TEMP_SANDBOX_DIR),
                        extraSandboxSubdirectories: [],
                        developerDirectory: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR),
                        casOptions: casOptions
                    )
                } else {
                    action = nil
                }

                // Note that if one invocation of actool spins up a shared instance of ibtoold, it may not have the required sandbox permissions to write to the required locations for another invocation of actool. rdar://105753069
                delegate.createTask(
                    type: self,
                    dependencyData: nil,
                    payload: nil,
                    ruleInfo: ["GenerateAssetSymbols"] + assetSymbolInputs.map { $0.path.str },
                    additionalSignatureData: "",
                    commandLine: await effectiveCommandLine(unthinned: true, lookup: assetSymbolLookup) + symbolsCommandLineArgs,
                    additionalOutput: [],
                    environment: environmentFromSpec(cbc, delegate),
                    workingDirectory: cbc.producer.defaultWorkingDirectory,
                    inputs: assetSymbolInputs,
                    outputs: generatedFiles.map(delegate.createNode),
                    mustPrecede: [],
                    action: action,
                    execDescription: "Generate asset symbols",
                    preparesForIndexing: true,
                    enableSandboxing: enableSandboxing,
                    llbuildControlDisabled: true,
                    additionalTaskOrderingOptions: []
                )
            }
        }

        let realOutputs = outputs + carFiles

        func dependencyInfoPath(variant: AssetCatalogVariant? = nil) -> String {
            let dependencyInfoPath = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_DEPENDENCY_INFO_FILE)
            return variant.map { "\(dependencyInfoPath.str)_\($0.rawValue)" } ?? dependencyInfoPath.str
        }

        func infoPlistContentPath(variant: AssetCatalogVariant? = nil) -> String {
            let infoPlistContentPath = cbc.scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_INFOPLIST_CONTENT_FILE)
            return variant.map { "\(infoPlistContentPath.str)_\($0.rawValue)" } ?? infoPlistContentPath.str
        }

        @discardableResult func createAssetCatalogTask(variant: AssetCatalogVariant) async -> (PlannedDirectoryTreeNode)? {
            let overrideDir = cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("assetcatalog_output").join(variant.rawValue)
            let commandLine = await effectiveCommandLine(unthinned: variant == .unthinned, outputDirectoryOverride: overrideDir.str, dependencyFileOverride: dependencyInfoPath(variant: variant), infoPlistContentOverride: infoPlistContentPath(variant: variant))
            let outputNode = delegate.createDirectoryTreeNode(overrideDir)
            let outputNodes: [any PlannedNode] = [outputNode, delegate.createNode(Path(dependencyInfoPath(variant: variant))), delegate.createNode(Path(infoPlistContentPath(variant: variant)))]
            var ruleInfo = defaultRuleInfo(cbc, delegate, lookup: lookup)
            ruleInfo[0..<1] = ["CompileAssetCatalogVariant", variant.rawValue]

            let action: (any PlannedTaskAction)?
            if let deferredAction = delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences) {
                action = deferredAction
            } else if cbc.scope.evaluate(BuiltinMacros.ENABLE_GENERIC_TASK_CACHING), let casOptions = try? CASOptions.create(cbc.scope, .generic) {
                action = delegate.taskActionCreationDelegate.createGenericCachingTaskAction(
                    enableCacheDebuggingRemarks: cbc.scope.evaluate(BuiltinMacros.GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS),
                    enableTaskSandboxEnforcement: !cbc.scope.evaluate(BuiltinMacros.DISABLE_TASK_SANDBOXING),
                    sandboxDirectory: cbc.scope.evaluate(BuiltinMacros.TEMP_SANDBOX_DIR),
                    extraSandboxSubdirectories: [Path("outputs/0/\(overrideDir.basename)")],
                    developerDirectory: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR),
                    casOptions: casOptions
                )
            } else {
                action = nil
            }

            delegate.createTask(
                type: self,
                dependencyData: .dependencyInfo(Path(dependencyInfoPath(variant: variant))),
                payload: AssetCatalogPayload.init(assetCatalogVariant: variant),
                ruleInfo: ruleInfo,
                additionalSignatureData: "",
                commandLine: commandLine,
                additionalOutput: [],
                environment: environmentFromSpec(cbc, delegate),
                workingDirectory: cbc.producer.defaultWorkingDirectory,
                inputs: realInputs(outputDirectoryOverride: overrideDir.str),
                outputs: outputNodes,
                mustPrecede: [],
                action: action,
                execDescription: resolveExecutionDescription(cbc, delegate),
                preparesForIndexing: false,
                enableSandboxing: enableSandboxing,
                llbuildControlDisabled: true,
                additionalTaskOrderingOptions: []
            )
            await cbc.producer.mkdirSpec.constructTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: overrideDir), delegate)
            return outputNode
        }

        // Only compile asset catalogs during the build action, not installapi or installhdrs.
        // Never compile asset catalogs in main package targets with synthesized resource bundles since they're compiled in the latter.
        if buildComponents.contains("build") && !isMainPackageWithResourceBundle {
                let variants: [(variant: AssetCatalogVariant, node: PlannedDirectoryTreeNode)] = await [.thinned, .unthinned].asyncMap { variant in
                    await createAssetCatalogTask(variant: variant).map { (variant, $0) }
                }.compactMap { $0 }

                let signaturePath = cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("assetcatalog_signature")

                delegate.createTask(type: self, ruleInfo: ["LinkAssetCatalogSignature"], commandLine: ["builtin-linkAssetCatalogSignature", signaturePath.str], environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [], outputs: [signaturePath], action: delegate.taskActionCreationDelegate.createLinkAssetCatalogTaskAction(), enableSandboxing: false, alwaysExecuteTask: true, showInLog: false)

            guard let plistOutputPath = await additionalEvaluatedOutputs(cbc, delegate).generatedInfoPlistContent else {
                delegate.error("Unable to determine output path for asset catalog Info.plist content")
                return
            }

            let commandLine: [String] = ["builtin-linkAssetCatalog"] + variants.flatMap { ["--\($0.variant.rawValue)", $0.node.path.str, "--\($0.variant.rawValue)-dependencies", dependencyInfoPath(variant: $0.variant), "--\($0.variant.rawValue)-info-plist-content", infoPlistContentPath(variant: $0.variant)] } + ["--output", cbc.scope.evaluate(BuiltinMacros.UnlocalizedProductResourcesDir, lookup: { self.lookup($0, cbc, delegate) }).str, "--plist-output", plistOutputPath.str]

            delegate.createTask(
                type: self,
                dependencyData: .dependencyInfo(Path(dependencyInfoPath())),
                ruleInfo: ["LinkAssetCatalog"] + cbc.inputs.flatMap { [$0.absolutePath.str] },
                commandLine: commandLine,
                environment: environmentFromSpec(cbc, delegate),
                workingDirectory: cbc.producer.defaultWorkingDirectory,
                inputs: realInputs() + variants.map(\.node) + [delegate.createNode(signaturePath)],
                outputs: realOutputs,
                action: delegate.taskActionCreationDelegate.createLinkAssetCatalogTaskAction(),
                execDescription: "Link asset catalogs",
                preparesForIndexing: false,
                enableSandboxing: false,
                llbuildControlDisabled: true
            )
        }
    }

    override public func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return AssetCatalogCompilerOutputParser.self
    }

    public override func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await discoveredIbtoolToolInfo(producer, delegate, at: self.resolveExecutablePath(producer, scope.actoolExecutablePath()))
        } catch {
            delegate.error(error)
            return nil
        }
    }

    override public func environmentFromSpec(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [(String, String)] {
        let cachingEnabled = cbc.scope.evaluate(BuiltinMacros.ENABLE_GENERIC_TASK_CACHING)

        var environment: [(String, String)] = super.environmentFromSpec(cbc, delegate)
        if cachingEnabled {
            environment.append(("IBToolNeverDeque", "1"))
        }
        return environment
    }

    public override var payloadType: (any TaskPayload.Type)? {
        AssetCatalogPayload.self
    }

    public override func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        if !super.shouldStart(task, buildCommand: buildCommand) {
            return false
        }

        if let payload = task.payload as? AssetCatalogPayload {
            switch payload.assetCatalogVariant {
            case .thinned:
                return buildCommand != .preview(style: .xojit)
            case .unthinned:
                return buildCommand == .preview(style: .xojit)
            }
        }

        return true
    }
}

enum AssetCatalogVariant: String, Codable {
    case thinned
    case unthinned
}

struct AssetCatalogPayload: TaskPayload, SerializableCodable {
    let assetCatalogVariant: AssetCatalogVariant
}

extension MacroEvaluationScope {
    func actoolExecutablePath(lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Path {
        return evaluate(BuiltinMacros.ASSETCATALOG_EXEC).nilIfEmpty ?? Path("actool")
    }
}
