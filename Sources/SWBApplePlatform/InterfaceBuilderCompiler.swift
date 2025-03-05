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
public import SWBMacro

public class IbtoolCompilerSpec : GenericCompilerSpec, IbtoolCompilerSupport, @unchecked Sendable {
    /// The info object collects information across the build phase so that an ibtool task doesn't try to produce a ~device output which is already being explicitly produced from another input.
    private final class BuildPhaseInfo: BuildPhaseInfoForToolSpec {
        var allInputFilenames = Set<String>()

        func addToContext(_ ftb: FileToBuild) {
            // Only collect info about files we want to match against.
            // FIXME: We should be using FileTypeSpec.conformsTo() here, but we don't have a good way in this context to look up the file type.
            guard ftb.fileType.identifier == "file.xib" else {
                return
            }
            allInputFilenames.insert(ftb.absolutePath.basenameWithoutSuffix)
        }

        func filterOutputFiles(_ outputs: [any PlannedNode], inputs: [Path]) -> [any PlannedNode] {
            // This filter is operating on basenames-without-suffix, since ibtool is going to transform xibs into nibs.
            return outputs.filter {
                let outputFilename = $0.path.basenameWithoutSuffix
                let inputFilenames = Set(inputs.map { $0.basenameWithoutSuffix })

                // If this output filename is the same as one of our own input filenames, then we keep it.
                guard !inputFilenames.contains(outputFilename) else {
                    return true
                }

                // If this output filename is among any of the input filenames that *aren't* one of our own inputs, then we remove it.
                let otherInputFilenames = allInputFilenames.subtracting(inputFilenames)
                guard !otherInputFilenames.contains(outputFilename) else {
                    return false
                }

                // If this output filename is something like ~ipad~ipad or ~iphone~iphone then we remove it (just to avoid ugliness).
                guard !outputFilename.contains("~ipad~") && !outputFilename.contains("~iphone~") else {
                    return false
                }

                // Otherwise we keep it.
                return true
            }
        }
    }

    public override func newBuildPhaseInfo() -> (any BuildPhaseInfoForToolSpec)? {
        return BuildPhaseInfo()
    }

    /// Override to compute the special arguments.
    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        var specialArgs = [String]()

        specialArgs += targetDeviceArguments(cbc, delegate)
        specialArgs += minimumDeploymentTargetArguments(cbc, delegate)

        // Get the strings file paths and regions.
        let stringsFiles = stringsFilesAndRegions(cbc)

        // Define the inputs, including the strings files from any variant groups.
        let inputs = cbc.inputs.map({ $0.absolutePath }) + stringsFiles.map({ $0.stringsFile })

        // Compute and declare the outputs.
        var outputs = evaluatedOutputs(cbc, delegate) ?? []
        if let buildPhaseInfo = cbc.buildPhaseInfo as? BuildPhaseInfo {
            outputs = buildPhaseInfo.filterOutputFiles(outputs, inputs: inputs)
        }
        for output in outputs {
            delegate.declareOutput(FileToBuild(absolutePath: output.path, inferringTypeUsing: cbc.producer))
        }

        // FIXME: Add the output paths for the .strings files.  I think this is a little tricky because ibtool will lay down strings files for .xibs, but not for .storyboards; instead the storyboard linker will put the .strings files in place.  I'm not certain about that, though.

        // Add the additional outputs defined by the spec.  These are not declared as outputs but should be processed by the tool separately.
        let additionalEvaluatedOutputsResult = await additionalEvaluatedOutputs(cbc, delegate)
        outputs += additionalEvaluatedOutputsResult.outputs.map(delegate.createNode)

        if let infoPlistContent = additionalEvaluatedOutputsResult.generatedInfoPlistContent {
            delegate.declareGeneratedInfoPlistContent(infoPlistContent)
        }

        // Construct the command line.
        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.IBC_REGIONS_AND_STRINGS_FILES:
                return stringsFiles.count > 0 ? cbc.scope.table.namespace.parseLiteralStringList(stringsFiles.map({ "\($0.region):\($0.stringsFile.str)" })) : nil
            default:
                return nil
            }
        }

        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), specialArgs: specialArgs, lookup: lookup)

        delegate.createTask(
            type: self,
            dependencyData: nil,
            payload: nil,
            ruleInfo: defaultRuleInfo(cbc, delegate),
            additionalSignatureData: "",
            commandLine: commandLine,
            additionalOutput: [],
            environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs.map(delegate.createNode),
            outputs: outputs,
            mustPrecede: [],
            action: createTaskAction(cbc, delegate),
            execDescription: resolveExecutionDescription(cbc, delegate),
            preparesForIndexing: false,
            enableSandboxing: enableSandboxing,
            llbuildControlDisabled: true,
            additionalTaskOrderingOptions: []
        )
    }

    override public func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return InterfaceBuilderCompilerOutputParser.self
    }

    public override func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await discoveredIbtoolToolInfo(producer, delegate, at: self.resolveExecutablePath(producer, scope.ibtoolExecutablePath()))
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

public final class IbtoolCompilerSpecNIB: IbtoolCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.xcode.tools.ibtool.compiler"
}

public final class IbtoolCompilerSpecStoryboard: IbtoolCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.xcode.tools.ibtool.storyboard.compiler"

    override public func environmentFromSpec(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [(String, String)] {
        let cachingEnabled = cbc.scope.evaluate(BuiltinMacros.ENABLE_GENERIC_TASK_CACHING)

        var environment: [(String, String)] = super.environmentFromSpec(cbc, delegate)
        if cachingEnabled {
            environment.append(("IBToolNeverDeque", "1"))
        }
        return environment
    }

    override public func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        if cbc.scope.evaluate(BuiltinMacros.ENABLE_GENERIC_TASK_CACHING), let casOptions = try? CASOptions.create(cbc.scope, .generic) {
            return delegate.taskActionCreationDelegate.createGenericCachingTaskAction(
                enableCacheDebuggingRemarks: cbc.scope.evaluate(BuiltinMacros.GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS),
                enableTaskSandboxEnforcement: !cbc.scope.evaluate(BuiltinMacros.DISABLE_TASK_SANDBOXING),
                sandboxDirectory: cbc.scope.evaluate(BuiltinMacros.TEMP_SANDBOX_DIR),
                extraSandboxSubdirectories: [],
                developerDirectory: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR),
                casOptions: casOptions)
        } else {
            return nil
        }
    }

    override public func commandLineFromTemplate(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, optionContext: (any DiscoveredCommandLineToolSpecInfo)?, specialArgs: [String] = [], lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [CommandLineArgument] {
        var commandLine = super.commandLineFromTemplate(cbc, delegate, optionContext: optionContext, specialArgs: specialArgs, lookup: lookup)
        guard let primaryOutput = evaluatedOutputs(cbc, delegate)?.first else {
            delegate.error("Unable to determine primary output for storyboard compilation")
            return []
        }
        commandLine.append(contentsOf: [.literal("--compilation-directory"), .parentPath(primaryOutput.path)])
        return commandLine
    }
}
