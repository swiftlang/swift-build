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
import SWBMacro

public final class CoreDataModelCompilerSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.model.coredata"

    public override var supportsInstallHeaders: Bool {
        return true
    }

    public override var supportsInstallAPI: Bool {
        return true
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Construct the momc task.
        await constructCoreDataModelCompilerTasks(cbc, delegate)

        // Construct the code generation task.
        await constructCoreDataCodeGenerationTasks(cbc, delegate)
    }

    private func constructCoreDataModelCompilerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        if cbc.scope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_TARGET_KIND) == .regular {
            return
        }

        let components = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if !components.contains("build") { return }

        // Invoke the generic implementation in CommandLineToolSpec to generate the momc task using the xcspec.
        await constructTasks(cbc, delegate, specialArgs: [])
    }

    private func constructCoreDataCodeGenerationTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        if cbc.scope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_TARGET_KIND) == .resource {
            return
        }

        // Compute the output directory.
        let input = cbc.input
        let modelName = input.absolutePath.basenameWithoutSuffix
        let outputDir = cbc.scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join("CoreDataGenerated").join(modelName).normalize()

        let inputs = [input.absolutePath]
        let ruleInfo = ["DataModelCodegen", input.absolutePath.str]
        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)
        commandLine.insert(contentsOf: ["--action", "generate"] + (cbc.scope.evaluate(BuiltinMacros.SWIFT_VERSION).nilIfEmpty.map { ["--swift-version", $0] } ?? []), at: 1)
        commandLine[commandLine.count - 1] = outputDir.str

        // Ask the client delegate for the list of paths of generated files.
        let generatedFiles: [Path]
        do {
            // Mark the entire directory structure as being watched by the build system.
            delegate.access(path: input.absolutePath)

            generatedFiles = try await generatedFilePaths(cbc, delegate, commandLine: [commandLine[0]] + ["--dry-run"] + commandLine[1...], workingDirectory: cbc.producer.defaultWorkingDirectory.str, environment: self.environmentFromSpec(cbc, delegate).bindingsDictionary, executionDescription: "Compute data model \(input.absolutePath.basename) code generation output paths") { output in
                return output.unsafeStringValue.split(separator: "\n").map(Path.init).map { $0.prependingPrivatePrefixIfNeeded(otherPath: outputDir) }
            }
            guard !generatedFiles.isEmpty else {
                // If we were given an empty list of generated files, then there were just no files to be generated, so we return.
                // FIXME: Should we emit a generic error in this case?  Should the code generator ever return no files to be generated?
                return
            }
        } catch {
            delegate.error("Could not determine generated file paths for Core Data code generation: \(error)")
            return
        }

        // If we got this far, then we know we have a non-empty list of generated files.
        let outputs = generatedFiles

        // Declare the output files so they can be processed by the build phase which called us.
        for output in outputs {
            delegate.declareOutput(FileToBuild(absolutePath: output, inferringTypeUsing: cbc.producer))
        }

        delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs.map { delegate.createDirectoryTreeNode($0) }, outputs: outputs.map { delegate.createNode($0) }, execDescription: "Generate code for data model \(input.absolutePath.basename)", preparesForIndexing: true, enableSandboxing: enableSandboxing)
        // Also add the generated headers to the generated files headermap.
        for output in outputs {
            // Somehow the file type specification infrastructure doesn't define an 'isHeader' property, so we look at the file extension.
            if output.fileExtension == "h" {
                delegate.declareGeneratedSourceFile(output)
            }
        }
    }
}
