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

public final class CopyToolSpec : CompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.pbxcp"

    /// Construct a `Copy` task to copy a source file to a destination with default behaviors.
    ///
    /// This is the entry point when `Copy` is set as the tool for a custom build rule in a target.  Most clients should use `constructCopyTasks()` directly.
    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        await constructCopyTasks(cbc, delegate)
    }

    /// Construct a `Copy` task to copy a source file to a destination.
    public func constructCopyTasks(
        _ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate,
        ruleName: String? = nil, executionDescription: String? = nil,
        removeHeaderDirectories: Bool = false, removeStaticExecutables: Bool = false,
        excludeSubpaths: [String] = [], includeOnlySubpaths: [String] = [],
        stripUnsignedBinaries: Bool? = nil, stripSubpaths: [String] = [],
        stripBitcode: Bool = false, skipCopyIfContentsEqual: Bool = false,
        additionalFilesToRemove: [String]? = nil,
        additionalPresumedOutputs: [any PlannedNode] = [],
        ignoreMissingInputs: Bool = false,
        additionalTaskOrderingOptions: TaskOrderingOptions = [],
        repairViaOwnershipAnalysis: Bool = false
    ) async {
        let input = cbc.input
        let inputPath = input.absolutePath
        let outputPath = cbc.output

        // Lookup function for computing the command line.
        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.COPY_PHASE_STRIP, BuiltinMacros.PBXCP_STRIP_UNSIGNED_BINARIES:
                return stripUnsignedBinaries.map { enable in
                    if enable {
                        return Static { cbc.scope.namespace.parseLiteralString("YES") } as MacroStringExpression
                    } else {
                        return Static { cbc.scope.namespace.parseLiteralString("NO") } as MacroStringExpression
                    }
                } ?? nil
            case BuiltinMacros.PBXCP_STRIP_SUBPATHS:
                guard !stripSubpaths.isEmpty else {
                    return nil
                }
                return cbc.scope.namespace.parseStringList(stripSubpaths + ["$(inherited)"])
            case BuiltinMacros.PBXCP_STRIP_BITCODE:
                guard stripBitcode else {
                    return nil
                }
                // Always strip all bitcode.
                return Static { cbc.scope.namespace.parseLiteralString("YES") } as MacroStringExpression
            case BuiltinMacros.PBXCP_BITCODE_STRIP_MODE:
                guard stripBitcode else {
                    return nil
                }
                // Always strip all bitcode.
                return Static { cbc.scope.namespace.parseLiteralString("all") } as MacroStringExpression
            case BuiltinMacros.PBXCP_BITCODE_STRIP_TOOL:
                guard stripBitcode else {
                    return nil
                }
                // FIXME: We should change the .xcspec file to make this setting conditional on $(PBXCP_STRIP_BITCODE).  Then we can just always generate this value.
                // Find bitcode_strip in our effective toolchains.
                if let bitcodeStripPath = cbc.producer.toolchains.lazy.compactMap({ $0.executableSearchPaths.lookup(Path("bitcode_strip")) }).first {
                    return cbc.scope.namespace.parseLiteralString(bitcodeStripPath.str) as MacroStringExpression
                }
                return nil
            case BuiltinMacros.PBXCP_EXCLUDE_SUBPATHS:
                guard !excludeSubpaths.isEmpty else {
                    return nil
                }
                return cbc.scope.namespace.parseStringList(excludeSubpaths + ["$(inherited)"])
            case BuiltinMacros.PBXCP_INCLUDE_ONLY_SUBPATHS:
                guard !includeOnlySubpaths.isEmpty else {
                    return nil
                }
                return cbc.scope.namespace.parseStringList(includeOnlySubpaths + ["$(inherited)"])
            default:
                return nil
            }
        }

        // We manually add the executable, input, and output here, since we are not using the command line template.
        //
        // FIXME: <rdar://problem/41991658> Pass a lookup block to commandLineFromOptions() here which maps the build settings in PbxCp.xcspec to the parameters passed in to this method.  Then we can get rid of a bunch of the special-case code below which adds the options those settings represent.
        var commandLine = ["builtin-copy"]
        await commandLine.append(contentsOf: commandLineFromOptions(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString))

        // We enact `removeHeaderDirectories` by manually adding the arguments in the right place.
        //
        // FIXME: Figure out the right way to do this, going forward. Xcode does this by injecting build settings, but we don't have infrastructure for that yet. We could easily changed commandLineFromOptions to support custom overrides, if we do want to go that approach, although it might also make sense to design a more strict / efficient / type safe mechanism that directly allowed the generic spec data to delegate to methods on the spec class.
        if removeHeaderDirectories {
            let insertIndex = commandLine.firstIndex(of: ".hg").map({ $0 + 1 }) ?? commandLine.endIndex
            commandLine.replaceSubrange(insertIndex..<insertIndex, with: ["-exclude", "Headers", "-exclude", "PrivateHeaders", "-exclude", "Modules", "-exclude", "*.tbd"])
        }

        if removeStaticExecutables {
            commandLine.append("-remove-static-executable")
        }

        if skipCopyIfContentsEqual {
            commandLine.append("-skip-copy-if-contents-equal")
        }

        // If we were passed additional files to remove, then add -exclude options for them.
        //
        // FIXME: Note that unlike the above there is presently no way to do this via the xcspec.
        if let additionalFilesToRemove {
            let insertIndex = commandLine.firstIndex(of: "-strip-unsigned-binaries") ?? commandLine.endIndex
            commandLine.replaceSubrange(insertIndex..<insertIndex, with: additionalFilesToRemove.flatMap({ ["-exclude", $0] }))
        }

        // If one of the strip options are enabled, also pass the strip tool path.
        //
        // FIXME: The same comment above (w.r.t. how to bind this logic) applies here.
        if cbc.scope.evaluate(BuiltinMacros.PBXCP_STRIP_UNSIGNED_BINARIES, lookup: lookup) || !cbc.scope.evaluate(BuiltinMacros.PBXCP_STRIP_SUBPATHS, lookup: lookup).isEmpty {
            let insertIndex = commandLine.firstIndex(of: "-resolve-src-symlinks") ?? commandLine.endIndex
            commandLine.replaceSubrange(insertIndex..<insertIndex, with: ["-strip-tool", resolveExecutablePath(cbc, Path("strip")).str])
        }

        // Skip the copy without erroring if the input item is missing. This is used for handling embedded bundles with the installloc action.
        if ignoreMissingInputs {
            commandLine.append("-ignore-missing-inputs")
        }

        // The copy tool expects a destination directory, unless specifying a rename for the output file name.
        if inputPath.basename != outputPath.basename {
            commandLine.append("-rename")
            commandLine.append(inputPath.str)
            commandLine.append(outputPath.str)
        } else {
            commandLine.append(inputPath.str)
            commandLine.append(outputPath.dirname.str)
        }

        // Create rule info and add index of input path to payload.
        let ruleInfo = [ruleName ?? "Copy", outputPath.str, inputPath.str]
        let payload = CopyToolTaskPayload(inputIndexInRuleInfo: 2)
        assert(inputPath.str == ruleInfo[payload.inputIndexInRuleInfo])

        // Note that the order of rule info here is against the usual conventions.
        let action = delegate.taskActionCreationDelegate.createFileCopyTaskAction(FileCopyTaskActionContext(cbc))
        let inputs: [any PlannedNode] = cbc.inputs.map{ delegate.createDirectoryTreeNode($0.absolutePath) } + cbc.commandOrderingInputs
        let outputs: [any PlannedNode] = [delegate.createNode(outputPath)] + additionalPresumedOutputs + cbc.commandOrderingOutputs
        delegate.createTask(
            type: self, payload: payload, ruleInfo: ruleInfo,
            commandLine: commandLine, environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs, outputs: outputs, action: action,
            execDescription: executionDescription ?? resolveExecutionDescription(cbc, delegate),
            preparesForIndexing: cbc.preparesForIndexing, enableSandboxing: enableSandboxing,
            additionalTaskOrderingOptions: additionalTaskOrderingOptions,
            repairViaOwnershipAnalysis: repairViaOwnershipAnalysis
        )
    }

    public override func interestingPath(for task: any ExecutableTask) -> Path? {
        let payload = task.payload! as! CopyToolTaskPayload
        return Path(task.ruleInfo[payload.inputIndexInRuleInfo])
    }

    public override var payloadType: (any TaskPayload.Type)? { return CopyToolTaskPayload.self }

    /// Copy tool task payload.
    private struct CopyToolTaskPayload: TaskPayload {
        /// Contains the index of input path in rule info.
        let inputIndexInRuleInfo: Int

        init(inputIndexInRuleInfo: Int) {
            self.inputIndexInRuleInfo = inputIndexInRuleInfo
        }

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(1) {
                serializer.serialize(inputIndexInRuleInfo)
            }
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(1)
            self.inputIndexInRuleInfo = try deserializer.deserialize()
        }
    }
}
