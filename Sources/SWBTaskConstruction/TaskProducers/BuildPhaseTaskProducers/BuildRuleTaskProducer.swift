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
import SWBCore
import SWBMacro
import SWBProtocol

final class BuildRuleTaskProducer: StandardTaskProducer, TaskProducer, ShellBasedTaskProducer {
    private unowned let action: BuildRuleScriptAction
    private let cbc: CommandBuildContext
    private unowned let delegate: any TaskGenerationDelegate
    private unowned let buildPhase: SWBCore.BuildPhase

    init(_ context: TaskProducerContext, action: BuildRuleScriptAction, cbc: CommandBuildContext, delegate: any TaskGenerationDelegate, buildPhase: SWBCore.BuildPhase) {
        self.action = action
        self.cbc = cbc
        self.delegate = delegate
        self.buildPhase = buildPhase
        super.init(context)
    }

    func serializeFileList(_ tasks: inout [any PlannedTask], to path: Path, paths: [any PlannedNode], context: TaskProducerContext) async -> any PlannedNode {
        let node = context.createNode(path)

        let contents = OutputByteStream()
        for path in paths {
            contents <<< (path.path.str + "\n")
        }
        context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: path), delegate, contents: contents.bytes, permissions: 0o755, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])

        return node
    }

    func pathForResolvedFileList(_ scope: MacroEvaluationScope, prefix: String, fileList: Path) -> Path {
        let checksumRawData = [
            scope.evaluate(BuiltinMacros.EFFECTIVE_PLATFORM_NAME),
            buildPhase.guid,
            action.identifier,
            scope.evaluate(BuiltinMacros.CURRENT_VARIANT),
            scope.evaluate(BuiltinMacros.CURRENT_ARCH),
            fileList.str,
        ] + cbc.inputs.map { $0.absolutePath.str }

        return scope.evaluate(BuiltinMacros.TEMP_DIR).join("\(prefix)-\(checksumRawData.joined(separator: "\n").md5())-\(fileList.basenameWithoutSuffix)-resolved.xcfilelist")
    }

    func createNodeForRule(_ delegate: any TaskGenerationDelegate, cbc: CommandBuildContext, context: TaskProducerContext, path: Path) -> any PlannedNode {
        // TODO: rdar://99446855 (Should we support USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES in build rules?)

        let ftb = FileToBuild(absolutePath: path, inferringTypeUsing: cbc.producer)
        if ftb.fileType.isWrapper {
            return delegate.createDirectoryTreeNode(path, excluding: [])
        } else {
            return delegate.createNode(path)
        }
    }

    // Resolve the rule input and output paths.
    func exportPathsRule(_ delegate: any TaskGenerationDelegate, _ environment: inout [String: String], _ cbc: CommandBuildContext, _ context: TaskProducerContext, _ paths: [MacroStringExpression], prefix: String, considerAllPathsDirectories: Bool = false) -> [any PlannedNode] {
        environment["\(prefix)_COUNT"] = String(paths.count)
        var exportedPaths: [any PlannedNode] = []
        for (i, expr) in paths.enumerated() {
            var path = Path(cbc.scope.evaluate(expr))
            if !path.isEmpty {
                // FIXME: We shouldn't need to 'normalize' here, the nodes should handle it: <rdar://problem/24568541> [Swift Build] Support node normalization at some point in the build system
                path = context.makeAbsolute(path).normalize()

                exportedPaths.append(createNodeForRule(delegate, cbc: cbc, context: context, path: path))
            }
            environment["\(prefix)_\(i)"] = path.str
        }

        return exportedPaths
    }

    /// Construct the tasks for an individual shell-script build rule.
    func generateTasks() async -> [any PlannedTask] {
        var tasks = [any PlannedTask]()
        // Shell script rules do not support grouping, currently.
        precondition(cbc.inputs.count == 1)
        let arch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)
        let variant = cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT)

        let input = cbc.inputs[0]
        let inputPath = input.absolutePath
        let inputDir = inputPath.dirname
        let inputName = inputPath.basename
        let (inputBase,inputSuffix) = Path(inputName).splitext()
        var inputVariables: [MacroDeclaration: String] = [
            BuiltinMacros.INPUT_FILE_PATH: inputPath.str,
            BuiltinMacros.INPUT_FILE_DIR: inputDir.str,
            BuiltinMacros.INPUT_FILE_NAME: inputName,
            BuiltinMacros.INPUT_FILE_BASE: inputBase,
            BuiltinMacros.INPUT_FILE_SUFFIX: inputSuffix,
            BuiltinMacros.INPUT_FILE_REGION_PATH_COMPONENT: cbc.input.regionVariantPathComponent,
        ]
        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            if let value = inputVariables[macro] {
                return cbc.scope.namespace.parseLiteralString(value)
            }
            return nil
        }

        // Should the outputs of the script be declared as generated
        var declareOutputsGenerated: Bool = true

        // Compute the arguments to the shell.
        let commandLine = [action.interpreterPath, "-c", action.scriptSource]

        // Compute the environment to use for the shell script.
        var environment = computeScriptEnvironment(.shellScriptPhase, scope: cbc.scope, settings: context.settings, workspaceContext: context.workspaceContext)

        // If we are in a headers build phase, expose visibility and output dir
        // information to the script and set the HEADER_OUTPUT_DIR macro value
        // for output path resolution.
        if buildPhase is SWBCore.HeadersBuildPhase {
            if let headerVisibility = input.headerVisibility, let outputDir = TargetHeaderInfo.outputPath(for: input.absolutePath, visibility: headerVisibility, scope: cbc.scope)?.dirname {
                environment["SCRIPT_HEADER_VISIBILITY"] = headerVisibility.rawValue
                inputVariables[BuiltinMacros.HEADER_OUTPUT_DIR] = outputDir.str

                // Although ostensibly the script may be generating these headers, we explicitly do not declare them as generated so that they do not end up in the auto-generated headermaps.
                declareOutputsGenerated = false
            } else {
                // Per the semantics of copy headers, we do not process files that have 'project' visibility.
                return []
            }
        }

        // Add the input file variables.
        for (macro,name) in inputVariables {
            environment[macro.name] = name
        }

        if let inputFlags = input.buildFile?.additionalArgs {
            environment["OTHER_INPUT_FILE_FLAGS"] = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .argumentsOnly).encode(cbc.scope.evaluate(inputFlags))
        }

        // Add the inputs and outputs.
        environment["SCRIPT_INPUT_FILE"] = inputPath.str
        // FIXME: We shouldn't need to 'normalize' here, the nodes should handle it: <rdar://problem/24568541> [Swift Build] Support node normalization at some point in the build system
        var inputs = [inputPath.normalize()]
        environment["SCRIPT_INPUT_FILE_COUNT"] = String(action.inputFiles.count)
        for (i, inputFile) in (action.inputFiles).enumerated() {
            // FIXME: We shouldn't need to 'normalize' here, the nodes should handle it: <rdar://problem/24568541> [Swift Build] Support node normalization at some point in the build system
            let inputPath = context.makeAbsolute(Path(cbc.scope.evaluate(inputFile, lookup: lookup))).normalize()
            inputs.append(inputPath)
            environment["SCRIPT_INPUT_FILE_\(i)"] = inputPath.str
        }

        var outputs = [Path]()
        environment["SCRIPT_OUTPUT_FILE_COUNT"] = String(action.outputFiles.count)
        for (i, outputFile) in action.outputFiles.enumerated() {
            // FIXME: We shouldn't need to 'normalize' here, the nodes should handle it: <rdar://problem/24568541> [Swift Build] Support node normalization at some point in the build system
            let outputPath = context.makeAbsolute(Path(cbc.scope.evaluate(outputFile.path, lookup: lookup))).normalize()
            outputs.append(outputPath)
            // Propagate the uniquing suffix from the input to the output, so a downstream tool which processes the output has access to it.
            delegate.declareOutput(FileToBuild(absolutePath: outputPath, inferringTypeUsing: cbc.producer, additionalArgs: outputFile.additionalCompilerFlags, uniquingSuffix: input.uniquingSuffix))
            if declareOutputsGenerated {
                delegate.declareGeneratedSourceFile(outputPath)
            }
            environment["SCRIPT_OUTPUT_FILE_\(i)"] = outputPath.str
        }

        let inputFileLists = exportPathsRule(delegate, &environment, cbc, context, action.inputFileLists, prefix: "SCRIPT_INPUT_FILE_LIST", considerAllPathsDirectories: true)
        let outputFileLists = exportPathsRule(delegate, &environment, cbc, context, action.outputFileLists, prefix: "SCRIPT_OUTPUT_FILE_LIST")

        func createNode(_ delegate: any TaskGenerationDelegate, path: Path) -> any PlannedNode {
            let ftb = FileToBuild(absolutePath: path, inferringTypeUsing: cbc.producer)
            if ftb.fileType.isWrapper {
                return delegate.createDirectoryTreeNode(path, excluding: [])
            } else {
                return delegate.createNode(path)
            }
        }

        let dependencyData: DependencyDataStyle?
        if let dependencyInfo = action.dependencyInfo {
            switch dependencyInfo {
            case .makefile(let path):
                let path = context.makeAbsolute(Path(cbc.scope.evaluate(path, lookup: lookup))).normalize()
                outputs.append(path)
                dependencyData = .makefile(path)
            case .dependencyInfo(let path):
                let path = context.makeAbsolute(Path(cbc.scope.evaluate(path, lookup: lookup))).normalize()
                outputs.append(path)
                dependencyData = .dependencyInfo(path)

            case .makefiles(let paths):
                let paths = paths.map{ context.makeAbsolute(Path(cbc.scope.evaluate($0, lookup: lookup))).normalize() }
                outputs.append(contentsOf: paths)
                dependencyData = .makefiles(paths)
            }
        } else {
            dependencyData = nil
        }

        var inputNodes = inputs.map{ createNodeForRule(delegate, cbc: cbc, context: context, path: $0) }
        var outputNodes = outputs.map{ delegate.createNode($0) as (any PlannedNode) }

        await handleFileLists(&tasks, &inputNodes, &outputNodes, &environment, cbc.scope, inputFileLists, outputFileLists, lookup: lookup)

        if outputNodes.isEmpty {
            delegate.error("shell script build rule for '\(inputPath.str)' must declare at least one output file")
            return []
        }

        let isSandboxingEnabled = BuildRuleTaskProducer.isSandboxingEnabled(context, buildPhase)
        // FIXME: We should move almost all of the logic from this method into the task spec, and simplify this.
        let execDescription = "Run shell script build rule on \(inputPath.str)"
        let ruleInfo = ["RuleScriptExecution"] + outputs.map { $0.str } + [inputPath.str, variant, arch]
        let enabledIndexBuildArena = cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        let disabledScriptExecutionForIndexBuild = cbc.scope.evaluate(BuiltinMacros.INDEX_DISABLE_SCRIPT_EXECUTION)

        var taskCBC = cbc
        taskCBC.preparesForIndexing = enabledIndexBuildArena && !disabledScriptExecutionForIndexBuild
        context.shellScriptSpec.constructShellScriptTasks(
            taskCBC,
            delegate,
            ruleInfo: ruleInfo,
            commandLine: commandLine,
            environment: EnvironmentBindings(environment),
            inputs: inputNodes,
            outputs: outputNodes,
            dependencyData: dependencyData,
            execDescription: execDescription,
            showEnvironment: false,
            alwaysExecuteTask: false,
            enableSandboxing: isSandboxingEnabled
        )

        return []
    }

}
