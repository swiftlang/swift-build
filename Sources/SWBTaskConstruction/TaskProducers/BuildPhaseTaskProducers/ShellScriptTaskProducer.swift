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

final class ShellScriptTaskProducer: PhasedTaskProducer, TaskProducer, ShellBasedTaskProducer {
    /// The shell script build phase this task producer is working with.
    unowned let shellScriptBuildPhase: SWBCore.ShellScriptBuildPhase

    init(_ context: TargetTaskProducerContext, shellScriptBuildPhase: SWBCore.ShellScriptBuildPhase, phaseStartNodes: [any PlannedNode], phaseEndNode: any PlannedNode, phaseEndTask: any PlannedTask) {
        self.shellScriptBuildPhase = shellScriptBuildPhase
        super.init(context, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
    }

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        var options: [TaskOrderingOptions] = [.unsignedProductRequirement]
        if context.settings.globalScope.evaluate(BuiltinMacros.EAGER_COMPILATION_ALLOW_SCRIPTS) {
            // Allows running the script eagerly
            options.append(.compilation)
        } else {
            // Forces downstream work to wait for the script to finish.
            options.append(.compilationRequirement)
        }
        return TaskOrderingOptions(options)
    }

    func prepare() {
        // FIXUP: It would be better to refactor this and generateTasks() to share the same info, but this computation below is not expensive and is a less risky change.

        func pathsFromXCFileLists(_ lists: [MacroStringExpression], scope: MacroEvaluationScope) -> [Path] {
            let xcfilelistPaths: [Path] = lists.compactMap { expr in
                let path = Path(scope.evaluate(expr))
                return path.isEmpty ? nil : context.makeAbsolute(path).normalize()
            }

            // Get all of the paths from the xcfilelist; we'll process them later.
            let groups: [[Path]] = xcfilelistPaths
                .map { xcfilelist in
                    let outputs: [Path]
                    do {
                        outputs = try parseXCFileList(xcfilelist, scope: scope)
                    } catch {
                        context.warning(("Unable to read contents of XCFileList '\(xcfilelist.str)'"))
                        outputs = []
                    }
                    return outputs
                }

            // In theory, this could be merged above, but Swift is having a hard time determining the type...
            return groups.flatMap { $0 }
        }

        let scope = context.settings.globalScope

        // This is to provide a fallback to prevent any unexpected side-effects this close to shipping...
        guard scope.evaluate(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING) else { return }

        // Due to the free-form nature of how script outputs can be formed, it can be problematic to blanket add these as doing so can trigger cycles from downstream targets.
        guard scope.evaluate(BuiltinMacros.ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS) else { return }

        // There is no reason to process any files if we're not building into a wrapper.
        let wrapperName = scope.evaluate(BuiltinMacros.WRAPPER_NAME)
        guard !wrapperName.isEmpty else { return }
        let wrapperPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(wrapperName, preserveRoot: true)

        // Determine the paths for any outputs the user has individually set.
        let outputPaths: [Path] = shellScriptBuildPhase.outputFilePaths.compactMap { expr in
            let path = Path(scope.evaluate(expr))
            return path.isEmpty ? nil : context.makeAbsolute(path).normalize()
        }

        // Determine the paths for the xcfilelists that contain any output files we may care about.
        let outputs = outputPaths + pathsFromXCFileLists(shellScriptBuildPhase.outputFileListPaths, scope: scope)

        // All of the outputs of a script that end up in the product wrapper need to be tracked. Note that this is NOT sufficient to track changes to these files that happen during the build, but since these are files that could potentially be updated by the user in other means, it is good to track them as well.
        for output in outputs {
            if wrapperPath.isAncestorOrEqual(of: output) {
                // The file is always added here, even if it doesn't exist (it won't on first build!) as we know that a task will be created that generates this file, so there can be no diagnostic issues with the project.
                context.addAdditionalCodeSignInput(output, scope: scope, alwaysAdd: true)
            }
        }

        // NOTE: This code is making the assumption that it is the user's responsibility to track any outputs of a script phase that may end up in the product wrapper in order for codesign to be re-trigger. Optionally, we could add some additional code to track the inputs of all script phases as well and treat them as an input to codesign, but that should be a last resort.
    }

    func serializeFileList(_ tasks: inout [any PlannedTask], to path: Path, paths: [any PlannedNode], context: TaskProducerContext) async -> any PlannedNode {
        let node = context.createNode(path)
        await appendGeneratedTasks(&tasks) { delegate in
            let contents = OutputByteStream()
            for path in paths {
                contents <<< (path.path.str + "\n")
            }
            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: path), delegate, contents: contents.bytes, permissions: 0o755, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        return node
    }

    func pathForResolvedFileList(_ scope: MacroEvaluationScope, prefix: String, fileList: Path) -> Path {
        return scope.evaluate(BuiltinMacros.TEMP_DIR).join("\(prefix)-\(shellScriptBuildPhase.originalObjectID)-\(fileList.basenameWithoutSuffix)-\(fileList.str.md5())-resolved.xcfilelist")
    }

    // Resolve the script input and output paths.
    func exportPaths(_ environment: inout [String: String], _ paths: [MacroStringExpression], prefix: String, considerAllPathsDirectories: Bool = false) -> [any PlannedNode] {
        let scope = context.settings.globalScope
        environment["\(prefix)_COUNT"] = String(paths.count)
        var exportedPaths: [any PlannedNode] = []
        for (i, expr) in paths.enumerated() {
            var path = Path(scope.evaluate(expr))
            if !path.isEmpty {
                // FIXME: We shouldn't need to 'normalize' here, the nodes should handle it: <rdar://problem/24568541> [Swift Build] Support node normalization at some point in the build system
                path = context.makeAbsolute(path).normalize()

                // <rdar://problem/41126633> TCI: Changes to script phases not detected when input file is a directory
                // This is an experiment to see if we can simply treat all of the inputs as a directory node. This will be hidden behind a default that we can toggle.
                let legacyCondition = considerAllPathsDirectories && (SWBFeatureFlag.treatScriptInputsAsDirectoryNodes.value || scope.evaluate(BuiltinMacros.USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES))

                let modernCondition = scope.evaluate(BuiltinMacros.ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES)

                if (SWBFeatureFlag.performOwnershipAnalysis.value && modernCondition) || legacyCondition {
                    exportedPaths.append(context.createDirectoryTreeNode(path, excluding: []))
                } else {
                    exportedPaths.append(context.createNode(path))
                }
            }
            environment["\(prefix)_\(i)"] = path.str
        }

        return exportedPaths
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks = [any PlannedTask]()

        // If this phase is only for deployment processing, don't run when we are not installing.
        guard !shellScriptBuildPhase.runOnlyForDeploymentPostprocessing || scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING) else {
            return []
        }

        // Scripts are run for the "build" component, or the "headers" component if $(INSTALLHDRS_SCRIPT_PHASE) is enabled or the `alwaysRunForInstallHdrs` property is set, or the "installLoc" component if $(INSTALLLOC_SCRIPT_PHASE) is enabled.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard buildComponents.contains("build") || (buildComponents.contains("headers") && (shellScriptBuildPhase.alwaysRunForInstallHdrs || scope.evaluate(BuiltinMacros.INSTALLHDRS_SCRIPT_PHASE))) || (buildComponents.contains("installLoc") && scope.evaluate(BuiltinMacros.INSTALLLOC_SCRIPT_PHASE)) else {
            return []
        }

        // Compute the environment to use for the shell script.
        var environment = computeScriptEnvironment(.shellScriptPhase, scope: scope, settings: context.settings, workspaceContext: context.workspaceContext)

        // Create the set of resolved paths and export the proper variables to the script environment.
        var inputs = exportPaths(&environment, shellScriptBuildPhase.inputFilePaths, prefix: "SCRIPT_INPUT_FILE", considerAllPathsDirectories: true)
        let inputFileLists = exportPaths(&environment, shellScriptBuildPhase.inputFileListPaths, prefix: "SCRIPT_INPUT_FILE_LIST", considerAllPathsDirectories: true)
        var outputs = exportPaths(&environment, shellScriptBuildPhase.outputFilePaths, prefix: "SCRIPT_OUTPUT_FILE", considerAllPathsDirectories: SWBFeatureFlag.performOwnershipAnalysis.value)
        let outputFileLists = exportPaths(&environment, shellScriptBuildPhase.outputFileListPaths, prefix: "SCRIPT_OUTPUT_FILE_LIST", considerAllPathsDirectories: SWBFeatureFlag.performOwnershipAnalysis.value)

        // Lastly, we need to inspect the contents of the file lists and append their paths accordingly.
        await handleFileLists(&tasks, &inputs, &outputs, &environment, scope, inputFileLists, outputFileLists)


        let enabledIndexBuildArena = scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        let disableScriptExecutionForIndexBuild = scope.evaluate(BuiltinMacros.INDEX_DISABLE_SCRIPT_EXECUTION)
        let forceScriptExecutionForIndexBuild = scope.evaluate(BuiltinMacros.INDEX_FORCE_SCRIPT_EXECUTION)
        // Scripts are only relevant to run for indexing if they affect the build root for compilation purposes (e.g. they produce a header or a swift file). Use the heuristic that scripts with no outputs do not modify the build root (e.g. they are for linting diagnostics), therefore they do not need to run for indexing.
        //
        // We may miss on a script that has no outputs but modifies the build root for compilation purpose, but:
        //   1. These scripts should be setting outputs in the first place
        //   2. Running no-output scripts is unnecessarily costly if they do linting, and some "creative" uses of such scripts may cause problems when running them in the background for indexing.
        //
        // Scripts that generate files outside of the build directory may cause a situation where the script is continually run. This is because both the regular build and index build will see the same path for those files, causing each to run every time because the other has changed the mtimes.
        //
        // Ideally scripts would only ever output to within derived data, but unfortunately this case is relatively common. Avoid this situation by also skipping scripts that have output files outside the build directory.
        let symRoot = scope.evaluate(BuiltinMacros.SYMROOT)
        let objRoot = scope.evaluate(BuiltinMacros.OBJROOT)
        let invalidOutputsForIndexBuild = outputs.isEmpty || outputs.contains(where: { n in !symRoot.isAncestor(of: n.path) && !objRoot.isAncestor(of: n.path) })
        let shouldPrepareForIndexing = enabledIndexBuildArena && !disableScriptExecutionForIndexBuild && (!invalidOutputsForIndexBuild || forceScriptExecutionForIndexBuild)

        // Create a task to emit the script contents to a file.
        let scriptFilePath = scope.evaluate(BuiltinMacros.TEMP_DIR).join("Script-\(shellScriptBuildPhase.originalObjectID).sh")
        let scriptFileNode = context.createNode(scriptFilePath)
        await appendGeneratedTasks(&tasks) { delegate in
            let scriptContents = OutputByteStream()
            // FIXME: The quoting here is wrong, this should be a string list and then escaped as such.
            scriptContents <<< "#!" <<< scope.evaluate(shellScriptBuildPhase.shellPath) <<< "\n"
            scriptContents <<< shellScriptBuildPhase.scriptContents <<< "\n"
            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: scriptFilePath), delegate, contents: scriptContents.bytes, permissions: 0o755, preparesForIndexing: shouldPrepareForIndexing, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        // Create the task to run the script.
        let ruleInfo = ["PhaseScriptExecution", shellScriptBuildPhase.name, scriptFilePath.str]
        // NOTE: We must escape the script path, as `/bin/sh -c` will reevaluate.
        let execDescription = "Run custom shell script '\(shellScriptBuildPhase.name)'"
        let commandLine = ["/bin/sh", "-c", scriptFilePath.str.escaped]

        let isSandboxingEnabled: Bool

        switch shellScriptBuildPhase.sandboxingOverride {
        case .forceEnabled:
            isSandboxingEnabled = true
        case .forceDisabled:
            isSandboxingEnabled = false
        case .basedOnBuildSetting:
            isSandboxingEnabled = ShellScriptTaskProducer.isSandboxingEnabled(context, shellScriptBuildPhase)
        }

        inputs.append(scriptFileNode)       // The generated script file is also an input.

        // Determine if the shell script should always be run. NOTE!! This must come before the virtual output node creation.
        let alwaysExecuteTask = outputs.isEmpty || self.shellScriptBuildPhase.alwaysOutOfDate

        // Warn if the script phase has not been marked as always out of date, but we need to treat it that way because it has no outputs.
        if outputs.isEmpty && !self.shellScriptBuildPhase.alwaysOutOfDate {
            context
                .emit(
                    scope.evaluate(BuiltinMacros.TREAT_MISSING_SCRIPT_PHASE_OUTPUTS_AS_ERRORS) ? .error : .warning,
                    "Run script build phase '\(shellScriptBuildPhase.name)' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase."
                )
        }

        if self.shellScriptBuildPhase.alwaysOutOfDate {
            context.note("Run script build phase '\(shellScriptBuildPhase.name)' will be run during every build because the option to run the script phase \"Based on dependency analysis\" is unchecked.")
        }

        // If the script has no real outputs, add a virtual output node which can be used as a dependency.
        //
        // FIXME: This doesn't match Xcode's behavior yet, we need to always run the script if it has no outputs.
        if outputs.isEmpty {
            var scriptGuid = shellScriptBuildPhase.guid
            if let configuredTarget = context.configuredTarget {
                // The phase guid is not unique enough on its own when the target has been configured for multiple platforms.
                scriptGuid += "-\(configuredTarget.guid)"
            }
            let outputNode = context.createVirtualNode("execute-shell-script-\(scriptGuid)")
            outputs.append(outputNode)
            context.addShellScriptVirtualOutput(outputNode)
        }

        if context.requiresEagerCompilation(scope) && !scope.evaluate(BuiltinMacros.EAGER_COMPILATION_ALLOW_SCRIPTS) {
            context.warning("target '\(context.settings.target!.name)' requires eager compilation, but build phase '\(shellScriptBuildPhase.name)' is delaying eager compilation")
        }

        let dependencyData: DependencyDataStyle?
        if let dependencyInfo = shellScriptBuildPhase.dependencyInfo {
            switch dependencyInfo {
            case .makefile(let path):
                let path = context.makeAbsolute(Path(scope.evaluate(path))).normalize()
                outputs.append(context.createNode(path))
                dependencyData = .makefile(path)
            case .dependencyInfo(let path):
                let path = context.makeAbsolute(Path(scope.evaluate(path))).normalize()
                outputs.append(context.createNode(path))
                dependencyData = .dependencyInfo(path)

            case .makefiles(let paths):
                let paths = paths.map{ context.makeAbsolute(Path(scope.evaluate($0))).normalize() }
                outputs.append(contentsOf: paths.map{ context.createNode($0) })
                dependencyData = .makefiles(paths)
            }
        } else {
            dependencyData = nil
        }

        var mustBeCompilationRequirement = false
        for output in outputs {
            if context.lookupFileType(fileName: output.path.basename)?.conformsToAny(context.compilationRequirementOutputFileTypes) == true {
                mustBeCompilationRequirement = true
            }
        }

        // Construct the script task.
        //
        // FIXME: We should move almost all of the logic from this method into the task spec, and simplify this.
        let options = defaultTaskOrderingOptions.union(mustBeCompilationRequirement ? [.compilationRequirement] : [])
        await appendGeneratedTasks(&tasks, options: options) { delegate in
            context.shellScriptSpec.constructShellScriptTasks(
                CommandBuildContext(producer: context, scope: scope, inputs: [], preparesForIndexing: shouldPrepareForIndexing),
                delegate,
                ruleInfo: ruleInfo,
                commandLine: commandLine,
                environment: EnvironmentBindings(environment),
                inputs: inputs,
                outputs: outputs,
                dependencyData: dependencyData,
                execDescription: execDescription,
                showEnvironment: shellScriptBuildPhase.emitEnvironment,
                alwaysExecuteTask: alwaysExecuteTask,
                enableSandboxing: isSandboxingEnabled,
                repairViaOwnershipAnalysis: true
            )
        }

        return tasks
    }



    /// Construct the tasks for an individual shell-script build rule.
    ///
    /// NOTE: External targets are basically shell scripts. It lives here because the behavior shares some significant logical pieces with the behavior of shell script build phases.
    static func constructTasksForExternalTarget(_ target: SWBCore.ExternalTarget, _ context: TaskProducerContext, cbc: CommandBuildContext, delegate: any TaskGenerationDelegate) {
        let action = cbc.scope.evaluate(BuiltinMacros.ACTION)

        let (executable, arguments, workingDirectory, environment) = constructCommandLine(for: target, action: action, settings: context.settings, workspaceContext: context.workspaceContext, scope: cbc.scope)

        // FIXME: Need the model name.

        // FIXME: We should move almost all of the logic from this method into the task spec, and simplify this.
        let ruleInfo = ["ExternalBuildToolExecution", target.name]
        let output = delegate.createVirtualNode("build-tool-\(target.guid)")
        context.shellScriptSpec.constructShellScriptTasks(cbc, delegate, ruleInfo: ruleInfo, commandLine: [executable] + arguments, environment: EnvironmentBindings(environment), workingDirectory: workingDirectory, inputs: [], outputs: [output], dependencyData: nil, execDescription: "Run external build tool", showEnvironment: target.passBuildSettingsInEnvironment, alwaysExecuteTask: true, enableSandboxing: context.shellScriptSpec.enableSandboxing)
    }
}
