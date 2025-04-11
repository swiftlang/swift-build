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

final class LexCompilerSpec : CompilerSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.compilers.lex"

    static let extensionMappings = [
        ".lm": ".m", ".LM": ".M",
        ".lmm": ".mm", ".LMM": ".MM",
        ".lp": ".cp", ".LP": ".CP",
        ".lpp": ".cpp", ".LPP": ".CPP",
        ".lxx": ".cxx", ".LXX": ".CXX"]

    override var toolBasenameAliases: [String] {
        return ["flex"]
    }

    required convenience init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.init(parser, basedOnSpec, isGeneric: false)
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Compute the input and output path.
        let input = cbc.input
        let inputBasename = input.absolutePath.basename
        let (inputPrefix,inputExt) = Path(inputBasename).splitext()
        let outputExt = LexCompilerSpec.extensionMappings[inputExt] ?? ".c"
        let outputPath = cbc.scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(inputPrefix + ".yy" + outputExt)
        let lexFlags = cbc.scope.evaluate(BuiltinMacros.LEXFLAGS)

        // Compute the command line arguments.
        var commandLine = [resolveExecutablePath(cbc, cbc.scope.evaluate(BuiltinMacros.LEX)).str]
        commandLine += await commandLineFromOptions(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)
        commandLine += lexFlags
        if let perFileArgs = input.additionalArgs {
            commandLine += cbc.scope.evaluate(perFileArgs)
        }
        commandLine += ["-o", outputPath.str, input.absolutePath.str]

        // Lex calls xcrun behind the scenes, so pass M4 in the env with
        // the pre-resolved path to m4, and DEVELOPER_DIR as a backstop.
        var env: [(String, String)] = environmentFromSpec(cbc, delegate)
        env.append(("DEVELOPER_DIR", cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR).str))
        env.append(("M4", resolveExecutablePath(cbc.producer, Path("gm4")).str))

        let headers = lexFlags.byExtractingElementsHavingPrefix("--header-file=").map { Path($0).normalize() }

        delegate.declareOutput(FileToBuild(absolutePath: outputPath, inferringTypeUsing: cbc.producer))
        delegate.createTask(type: self, ruleInfo: ["Lex", input.absolutePath.str], commandLine: commandLine, environment: EnvironmentBindings(env), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [input.absolutePath], outputs: [outputPath] + headers, action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }
}
