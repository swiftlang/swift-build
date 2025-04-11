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

import SWBProtocol
import SWBUtil
import SWBMacro

public final class LipoToolSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {

    // Custom override to erase the "linker" nature as specified in Xcode's xcspecs, which doesn't fit with how we model things.

    public static let identifier = "com.apple.xcode.linkers.lipo"

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        parser.parseStringList("BinaryFormats")

        super.init(parser, basedOnSpec)
    }

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        let lipo = cbc.scope.evaluate(BuiltinMacros.LIPO)
        return lipo.isEmpty ? "lipo" : lipo
    }

    private func lipoToolPath(_ cbc: CommandBuildContext) -> Path {
        return resolveExecutablePath(cbc, Path(computeExecutablePath(cbc)))
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // The Lipo spec is broken, and doesn't generate the right command lines, we do the setup manually.
        //
        // FIXME: Resolve this, and use the actual lipo spec: <rdar://problem/24644883> [Swift Build] Fix and then use actual Lipo.xcspec

        let variant = cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT)
        let outputPath = cbc.output

        var commandLine = [String]()
        if cbc.scope.evaluate(BuiltinMacros.CREATE_UNIVERSAL_STATIC_LIBRARY_USING_LIBTOOL) && cbc.scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "staticlib" {
                    commandLine.append(cbc.producer.libtoolLinkerSpec.libtoolToolPath(cbc).str)
                    commandLine.append("-static")
                    for input in cbc.inputs {
                        commandLine.append(input.absolutePath.str)
                    }
                    commandLine += ["-o", outputPath.str]

        } else {
            commandLine.append(lipoToolPath(cbc).str)

            commandLine.append("-create")
            for input in cbc.inputs {
                commandLine.append(input.absolutePath.str)
            }
            commandLine += cbc.scope.evaluate(BuiltinMacros.OTHER_LIPOFLAGS)
            commandLine += cbc.scope.evaluate(BuiltinMacros.PER_VARIANT_OTHER_LIPOFLAGS)
            commandLine += ["-output", outputPath.str]
        }

        let archsString = cbc.scope.evaluateAsString(BuiltinMacros.ARCHS)
        let outputs: [any PlannedNode] = [delegate.createNode(outputPath)] + cbc.commandOrderingOutputs
        delegate.createTask(type: self, ruleInfo: ["CreateUniversalBinary", outputPath.str, variant, archsString], commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ delegate.createNode($0.absolutePath) }), outputs: outputs, action: delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences), execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }

    /// Invoke lipo to copy a fat Mach-O to a destination path with certain architectures removed.
    public func constructCopyAndProcessArchsTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, executionDescription: String? = nil, archsToRemove: [String]) {
        return constructCopyAndProcessArchsTasks(cbc, delegate, executionDescription: executionDescription, archsToProcess: archsToRemove, flag: "-remove", ruleName: "CopyAndRemoveArchs")
    }

    /// Invoke lipo to copy a fat Mach-O to a destination path with only certain architectures preserved, and the rest removed.
    public func constructCopyAndProcessArchsTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, executionDescription: String? = nil, archsToPreserve: [String]) {
        return constructCopyAndProcessArchsTasks(cbc, delegate, executionDescription: executionDescription, archsToProcess: archsToPreserve, flag: "-extract", ruleName: "CopyAndPreserveArchs")
    }

    private func constructCopyAndProcessArchsTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, executionDescription: String?, archsToProcess: [String], flag: String, ruleName: String) {
        var commandLine = [String]()
        let outputPath = cbc.output

        commandLine.append(lipoToolPath(cbc).str)
        commandLine.append(cbc.input.absolutePath.str)
        commandLine += ["-output", outputPath.str]

        for arch in archsToProcess {
            commandLine.append(flag)
            commandLine.append(arch)
        }

        let inputs: [any PlannedNode] = [delegate.createNode(cbc.input.absolutePath)] + cbc.commandOrderingInputs
        let outputs: [any PlannedNode] = [delegate.createNode(outputPath)] + cbc.commandOrderingOutputs
        delegate.createTask(type: self, ruleInfo: [ruleName, outputPath.str], commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, action: nil, execDescription: executionDescription ?? "Prune architectures for \(outputPath.basename)", enableSandboxing: enableSandboxing)
    }
}
