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
import SWBMacro
import SWBCore

final class OpenCLCompilerSpec : CompilerSpec, SpecIdentifierType, GCCCompatibleCompilerCommandLineBuilder, @unchecked Sendable {
    static let identifier = "com.apple.compilers.opencl"

    private let openCLOutputs: [MacroStringExpression]?

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        // We need to parse 'Outputs' manually, because we more strictly enforce the separation between "generic" tools and non-generic ones.
        self.openCLOutputs = parser.parseStringList("Outputs", inherited: false)?.map {
            return parser.delegate.internalMacroNamespace.parseString($0) { diag in
                parser.handleMacroDiagnostic(diag, "macro parsing error in 'Outputs'")
            }
        }

        super.init(parser, basedOnSpec, isGeneric: false)
    }

    override func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate) -> [(path: Path, isDirectory: Bool)]? {
        return self.openCLOutputs?.map {
            let pathString = cbc.scope.evaluate($0, lookup: { return self.lookup($0, cbc, delegate) })
            return (Path(pathString).normalize(), pathString.hasSuffix("/"))
        }
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let scope = cbc.scope
        let input = cbc.input

        let filePath = input.absolutePath
        let fileName = filePath.basename
        let inputFileNode = delegate.createNode(filePath)

        let bcDirRelativeToResources = "OpenCL"
        let bcDirPath = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).join(bcDirRelativeToResources).normalize()

        let openclc = scope.evaluate(BuiltinMacros.OPENCLC)
        let compilerVersionFlag = "-cl-std=" + scope.evaluate(BuiltinMacros.OPENCL_COMPILER_VERSION)

        let preprocessorDefinitionsFlags = scope.evaluate(BuiltinMacros.OPENCL_PREPROCESSOR_DEFINITIONS).map{ "-D" + $0 }
        let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(cbc.producer, scope, usesModules: scope.evaluate(BuiltinMacros.CLANG_ENABLE_MODULES))
        let headerSearchPathFlags = headerSearchPaths.searchPathArguments(for: self, scope: scope)
        let frameworkSearchPaths = GCCCompatibleCompilerSpecSupport.frameworkSearchPathArguments(cbc.producer, scope)
        let frameworkSearchPathFlags = frameworkSearchPaths.searchPathArguments(for: self, scope: scope)

        let optimizationLevelValue = scope.evaluate(BuiltinMacros.OPENCL_OPTIMIZATION_LEVEL)
        let optimizationLevelFlag: String? = optimizationLevelValue.isEmpty ? nil : "-O" + optimizationLevelValue

        // Emit one bitcode file per arch.
        for arch in scope.evaluate(BuiltinMacros.OPENCL_ARCHS) {
            let bcPath = bcDirPath.join(fileName + "." + arch + ".bc")
            let bcNode = delegate.createNode(bcPath)

            let ruleInfo = ["CreateBitcode", filePath.str, arch]

            let executionDescription = "Create \(arch) bitcode for \(filePath.basename)"

            var commandLine = [resolveExecutablePath(cbc, Path(openclc)).str]
            commandLine += ["-x", "cl", compilerVersionFlag]
            optimizationLevelFlag.map{ commandLine.append($0) }
            commandLine += preprocessorDefinitionsFlags
            commandLine += headerSearchPathFlags
            commandLine += frameworkSearchPathFlags

            if arch == "gpu_32" && scope.evaluate(BuiltinMacros.OPENCL_DOUBLE_AS_SINGLE) {
                commandLine.append("-cl-double-as-single")
            }

            commandLine += scope.evaluate(BuiltinMacros.OPENCL_OTHER_BC_FLAGS)
            if let perFileArgs = input.additionalArgs {
                commandLine += cbc.scope.evaluate(perFileArgs)
            }

            commandLine += ["-arch", arch, "-emit-llvm", "-c", filePath.str, "-o", bcPath.str]

            delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [inputFileNode], outputs: [bcNode], action: nil, execDescription: executionDescription, enableSandboxing: enableSandboxing)

            // Mark the output file as a generated file.
            delegate.declareOutput(FileToBuild(absolutePath: bcPath, fileType: cbc.producer.lookupFileType(identifier: "file")!))
        }

        // Emit one .h and one .c file.
        do {
            let derivedSourcesDir = scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).normalize()

            let executionDescription = "Compile \(filePath.basename)"

            let ruleInfo = ["Compile", filePath.str]

            var commandLine = [resolveExecutablePath(cbc, Path(openclc)).str]
            commandLine += ["-x", "cl", compilerVersionFlag]
            if scope.evaluate(BuiltinMacros.OPENCL_MAD_ENABLE) {
                commandLine.append("-cl-mad-enable")
            }
            if scope.evaluate(BuiltinMacros.OPENCL_FAST_RELAXED_MATH) {
                commandLine.append("-cl-fast-relaxed-math")
            }
            if scope.evaluate(BuiltinMacros.OPENCL_DENORMS_ARE_ZERO) {
                commandLine.append("-cl-denorms-are-zero")
            }
            commandLine.append(scope.evaluate(BuiltinMacros.OPENCL_AUTO_VECTORIZE_ENABLE) ? "-cl-auto-vectorize-enable" : "-cl-auto-vectorize-disable")


            let bundleIdentifier = scope.evaluate(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER)
            if !bundleIdentifier.isEmpty {
                commandLine += ["-gcl-bc-bundle-identifier", bundleIdentifier]
            }
            commandLine += ["-gcl-bc-dir", bcDirRelativeToResources]

            commandLine += ["-emit-gcl", filePath.str]
            commandLine += ["-gcl-output-dir", derivedSourcesDir.str]

            // Declare the generated .h and .c files for reprocessing.
            let evaluatedOutputs = self.evaluatedOutputs(cbc, delegate) ?? []
            for output in evaluatedOutputs {
                delegate.declareOutput(FileToBuild(absolutePath: output.path, inferringTypeUsing: cbc.producer))
                delegate.declareGeneratedSourceFile(output.path)
            }

            delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [inputFileNode], outputs: evaluatedOutputs, action: nil, execDescription: executionDescription, enableSandboxing: enableSandboxing)
        }
    }
}
