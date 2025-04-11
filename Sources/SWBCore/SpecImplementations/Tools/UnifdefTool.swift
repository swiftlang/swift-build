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

public final class UnifdefToolSpec : CommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "public.build-task.unifdef"

    public override func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate) -> [(path: Path, isDirectory: Bool)]? {
        let outputs = cbc.outputs.map { ($0, false) }
        return outputs.nilIfEmpty ?? cbc.resourcesDir.map { resourcesDir in
            cbc.inputs.map { (resourcesDir.join($0.absolutePath.basename), false) }
        }
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        await constructTasks(cbc, delegate, additionalTaskOrderingOptions: [])
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, additionalTaskOrderingOptions: TaskOrderingOptions) async {
        let input = cbc.input
        let outputPath = cbc.output

        let extraFlags = cbc.scope.evaluate(BuiltinMacros.COPY_HEADERS_UNIFDEF_FLAGS)

        // Set the exit status mode to 2, which is "exit status is 0 on success". (The default is 0 if nothing
        // changed and 1 if something changed.)
        var args = [resolveExecutablePath(cbc, Path("unifdef")).str, "-x", "2"]
        args += extraFlags
        if cbc.scope.evaluate(BuiltinMacros.IS_UNOPTIMIZED_BUILD) && !extraFlags.contains("-B") {
            // Add empty lines for any removed lines so that the source locations still match and thus we can go to
            // the original file rather than the copied for any generated diagnostics.
            args.append("-b")
        }
        args += ["-o", outputPath.str, input.absolutePath.str]
        delegate.createTask(type: self, ruleInfo: ["Unifdef", outputPath.str, input.absolutePath.str], commandLine: args, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [input.absolutePath], outputs: [outputPath], action: nil, execDescription: resolveExecutionDescription(cbc, delegate), preparesForIndexing: true, enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: additionalTaskOrderingOptions)
    }
}
