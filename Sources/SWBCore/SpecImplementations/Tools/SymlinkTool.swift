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

public final class SymlinkToolSpec : CommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.symlink"

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    /// Construct a new task to create a symlink at the output path, containing `toPath`.
    public func constructSymlinkTask(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, toPath destination: Path, makeRelative: Bool = false, repairViaOwnershipAnalysis: Bool = false) {
        precondition(cbc.inputs.isEmpty)

        let outputPath = cbc.output

        let toPath: String
        if makeRelative && destination.isAbsolute {
            do {
                let outputPathAbs = try SWBUtil.AbsolutePath(validating: outputPath.str)
                let destinationAbs = try SWBUtil.AbsolutePath(validating: destination.normalize().str)
                toPath = destinationAbs.relative(to: outputPathAbs.dirname).path.str
            } catch {
                delegate.error(error)
                return
            }
        } else {
            toPath = destination.normalize().str
        }

        let commandLine = ["/bin/ln", "-sfh", toPath, outputPath.str]
        delegate.createTask(
            type: self, ruleInfo: ["SymLink", outputPath.str, toPath],
            commandLine: commandLine, environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: [], outputs: [ outputPath ], action: nil,
            execDescription: resolveExecutionDescription(cbc, delegate),
            preparesForIndexing: cbc.preparesForIndexing,
            enableSandboxing: enableSandboxing,
            repairViaOwnershipAnalysis: repairViaOwnershipAnalysis
        )
    }
}
