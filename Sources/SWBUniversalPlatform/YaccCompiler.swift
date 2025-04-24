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

final class YaccCompilerSpec : CompilerSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.compilers.yacc"

    static let extensionMappings = [
        ".ym": ".m", ".YM": ".M",
        ".ymm": ".mm", ".YMM": ".MM",
        ".yp": ".cp", ".YP": ".CP",
        ".ypp": ".cpp", ".YPP": ".CPP",
        ".yxx": ".cxx", ".YXX": ".CXX"]

    override var toolBasenameAliases: [String] {
        return ["bison"]
    }

    required convenience init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.init(parser, basedOnSpec, isGeneric: false)
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Compute the input and output path.
        let input = cbc.input
        let inputBasename = input.absolutePath.basename
        let (inputPrefix,inputExt) = Path(inputBasename).splitext()

        let outputPrefix: String
        if cbc.scope.evaluate(BuiltinMacros.YACC_GENERATED_FILE_STEM) == "InputFileStem" {
            outputPrefix = inputPrefix
        } else {
            outputPrefix = "y"
        }

        let outputExt = YaccCompilerSpec.extensionMappings[inputExt] ?? ".c"

        // As a hack around a Yacc warning about the output extension not being '.c' (and not just fixing yacc), Xcode generates a move through a temporary file if the desired extension is not '.c'.
        let derivedFileDir = cbc.scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR)
        let outputPathBase = derivedFileDir.join(outputPrefix)
        let outputPath = Path(outputPathBase.str + ".tab" + outputExt)

        let intermediatePath: Path
        if outputExt != ".c" {
            intermediatePath = derivedFileDir.join(outputPrefix + ".tab.c")
        } else {
            intermediatePath = outputPath
        }
        let outputHeaderPath = derivedFileDir.join(outputPrefix + ".tab.h")
        // FIXME: We shouldn't need to lookup known file types.
        delegate.declareOutput(FileToBuild(absolutePath: outputHeaderPath, fileType: cbc.producer.lookupFileType(identifier: "sourcecode.c.h")!))
        delegate.declareGeneratedSourceFile(outputHeaderPath)

        // Compute the command arguments.
        var args = [resolveExecutablePath(cbc, cbc.scope.evaluate(BuiltinMacros.YACC)).str]
        // FIXME: Add the auto-generated options.
        args += cbc.scope.evaluate(BuiltinMacros.YACCFLAGS)
        if let perFileArgs = input.additionalArgs {
            args += cbc.scope.evaluate(perFileArgs)
        }
        args.append("-d")
        args.append("-b")
        args.append(outputPathBase.str)
        args.append(input.absolutePath.str)

        delegate.declareOutput(FileToBuild(absolutePath: outputPath, inferringTypeUsing: cbc.producer))
        delegate.declareGeneratedSourceFile(outputPath)

        delegate.createTask(type: self, ruleInfo: ["Yacc", input.absolutePath.str], commandLine: args, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }), outputs: [intermediatePath, outputHeaderPath], action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)

        // Generate the rename task, if used (see comment above).
        if outputPath != intermediatePath {
            let args = [cbc.scope.evaluate(BuiltinMacros.CP).str, intermediatePath.str, outputPath.str]
            delegate.createTask(type: self, ruleInfo: ["Rename", intermediatePath.str, outputPath.basename], commandLine: args, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [intermediatePath], outputs: [outputPath], mustPrecede: [], action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
        }
    }
}
