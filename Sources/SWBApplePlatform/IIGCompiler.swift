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
public import SWBCore
public import SWBMacro

public struct DiscoveredIiGToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let toolPath: Path
    public var toolVersion: Version?
}

public final class IIGCompilerSpec: GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.iig"

    public override var supportsInstallHeaders: Bool {
        return true
    }

    public override var supportsInstallAPI: Bool {
        return true
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let outputPath = TargetHeaderInfo.outputPath(for: cbc.input.absolutePath, visibility: cbc.input.headerVisibility, scope: cbc.scope)

        // Copy or unifdef the .iig file if the input has public or private visibility.
        if let outputPath {
            await constructCopyOrUnifdefTask(inputs: cbc.inputs, outputPath: outputPath)
        }

        // TODO: Make unconditionally true once the following lands:
        // <rdar://69764671> Utilize the iig-produced trace files to inform installhdrs dependency ordering for DriverKit projects
        guard (getEnvironmentVariable("IIG_TRACE_HEADERS")?.nilIfEmpty != nil) || cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else {
            return
        }

        let evaluatedOutputs = self.evaluatedOutputs(cbc, delegate) ?? []

        // Create the iig compilation task which produces the generated .h and .iig.cpp
        await delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString), environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ delegate.createNode($0.absolutePath) }), outputs: evaluatedOutputs + cbc.commandOrderingOutputs, action: nil, execDescription: resolveExecutionDescription(cbc, delegate), preparesForIndexing: true, enableSandboxing: enableSandboxing)

        func constructCopyOrUnifdefTask(inputs: [FileToBuild], outputPath: Path, ruleName: String? = nil) async {
            if cbc.scope.evaluate(BuiltinMacros.COPY_HEADERS_RUN_UNIFDEF) {
                // FIXME: We should consider making an actual "CpHeader" tool, then sinking the Unifdef conditional into it.
                await cbc.producer.unifdefSpec.constructTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: inputs, output: outputPath), delegate, additionalTaskOrderingOptions: .compilationRequirement)
            } else {
                await cbc.producer.copySpec.constructCopyTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: inputs, output: outputPath, preparesForIndexing: true), delegate, ruleName: ruleName, additionalTaskOrderingOptions: .compilationRequirement)
            }
        }

        // Loop over the generated .h and .iig.cpp files...
        for evaluatedOutput in evaluatedOutputs {
            let copiedOutputPath: Path
            if evaluatedOutput.path.fileSuffix == ".h", let outputPath {
                // Copy or unifdef the .h file
                copiedOutputPath = outputPath.dirname.join(evaluatedOutput.path.basename)
                await constructCopyOrUnifdefTask(inputs: [FileToBuild(absolutePath: evaluatedOutput.path, inferringTypeUsing: cbc.producer)], outputPath: copiedOutputPath, ruleName: "CpHeader")
            } else {
                // The else case will be the iig-generated .cpp file,
                // or the iig-generated .h file if the iig file was set to project visibility.
                copiedOutputPath = evaluatedOutput.path
            }

            // Declare the generated .h or .cpp file for reprocessing.
            delegate.declareOutput(FileToBuild(absolutePath: copiedOutputPath, inferringTypeUsing: cbc.producer))
            delegate.declareGeneratedSourceFile(copiedOutputPath)
        }
    }

    static func discoveredIiGToolInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, at toolPath: Path) async throws -> DiscoveredIiGToolSpecInfo {
        try await DiscoveredIiGToolSpecInfo.parseProjectNameAndSourceVersionStyleVersionInfo(producer, delegate, commandLine: [toolPath.str, "--version"]) { versionInfo in
            DiscoveredIiGToolSpecInfo(toolPath: toolPath, toolVersion: versionInfo.version)
        }
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = self.resolveExecutablePath(producer, scope.iigExecutablePath())

        // Get the info from the global cache.
        do {
            return try await Self.discoveredIiGToolInfo(producer, delegate, at: toolPath)
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

extension MacroEvaluationScope {
    func iigExecutablePath(lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Path {
        return evaluate(BuiltinMacros.IIG_EXEC).nilIfEmpty ?? Path("iig")
    }
}
