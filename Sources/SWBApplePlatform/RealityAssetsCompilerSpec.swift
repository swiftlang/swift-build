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

import Foundation
package import SWBCore
import SWBUtil
import SWBMacro

//---------------------
//
// These structs are used in RealityAssetsTaskProducer.swift in Swift Build
// to write the JSON file to transport the module name and list of swift files for the main target
// and its dependencies.  Also, they are use in realitytool CreateSchemaCommand (RealitySymbolCache)
// to read and parse that JSON file.  They are then used by RealitySymbolCache for parameter transport.
// Versioning can be accomplished later easily and submitted such that there should be no breaking dependency.
//
public struct ModuleSpec: Codable, Hashable, Equatable {
    public let moduleName: String
    public let swiftFiles: [String]
    public init(moduleName: String, swiftFiles: [String]) {
        self.moduleName = moduleName
        self.swiftFiles = swiftFiles
    }
}
public struct ModuleWithDependencies: Codable, Equatable {
    public let module: ModuleSpec
    public let dependencies: [ModuleSpec]
    public init(module: ModuleSpec, dependencies: [ModuleSpec]) {
        self.module = module
        self.dependencies = dependencies
    }
}
//
//---------------------

package final class RealityAssetsCompilerSpec: GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tasks.compile-rk-assets.xcplugin"

    private func environmentBindings(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> EnvironmentBindings {
        var environmentBindings: [(String, String)] = environmentFromSpec(cbc, delegate)

        // this is required to pass the functional/integration tests in sandbox mode
        // because LLVM seems to create default.profraw files in the test directories
        environmentBindings.append(("LLVM_PROFILE_FILE", Path.null.str))

        return EnvironmentBindings(environmentBindings)
    }

    private func constructRealityAssetsCreateSchemaTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, moduleWithDependencies: ModuleWithDependencies) async {
        let components = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if !components.contains("build") {
            return
        }

        // for this task, only one input is expected to be .json
        guard let inputFileToBuild = cbc.inputs.only else {
            return
        }
        let targetWithDependenciesPath = inputFileToBuild.absolutePath
        guard targetWithDependenciesPath.fileExtension == "json" else {
            return
        }

        // for this task, only one output is expected to be .usda
        guard let outputPath = cbc.outputs.only else {
            return
        }
        let outputFile = outputPath.str
        guard outputPath.fileExtension == "usda" else {
            return
        }

        // add build dependency -> .usda schema file
        delegate.declareOutput(FileToBuild(absolutePath: outputPath, inferringTypeUsing: cbc.producer))

        // Generate the command line from the xcspec.
        // CommandLine = "realitytool compile [options] -o=$(ProductResourcesDir) $(InputFile)";
        let baseCommandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)

        // commandline from template is not usable...create our own for create-schema
        var commandLine: [String] = [baseCommandLine[0]] // get executable from template
        commandLine.append("create-schema")
        commandLine.append("--output-schema")
        commandLine.append(outputFile)
        commandLine.append(targetWithDependenciesPath.str)

        // for tool sandboxing, we need to add all the swift files referenced by the .json so that
        // realitytool can read them without warnings
        let moduleSwiftFilesPaths = moduleWithDependencies.module.swiftFiles.map { Path($0) }
        let dependencySwiftFilesPaths = moduleWithDependencies.dependencies.map { $0.swiftFiles.map { Path($0) } }.joined()
        let inputs = [targetWithDependenciesPath] + moduleSwiftFilesPaths + dependencySwiftFilesPaths

        let ruleInfo = ["RealityAssetsSchemaGen", outputFile]
        delegate.createTask(type: self,
                            ruleInfo: ruleInfo,
                            commandLine: commandLine,
                            environment: environmentBindings(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs,
                            outputs: [outputPath],
                            execDescription: "Generate Reality Asset USD schema",
                            preparesForIndexing: true,
                            enableSandboxing: true)
    }

    private func constructRealityAssetCompilerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let components = cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        if !components.contains("build") {
            return
        }

        // inputs can be optional .usda schema file and .rkassets bundle path...

        // search inputs to get .rkassets bundle path...split filter and only due to swift warning about captures
        let rkAssetsFilesToBuild = cbc.inputs.filter { $0.fileType.conformsTo(identifier: "folder.rkassets") }
        guard !rkAssetsFilesToBuild.isEmpty else {
            // no .rkassets means this pass was to create the schema
            return
        }
        guard let rkAssetsFileToBuild = rkAssetsFilesToBuild.only else {
            delegate.error("multiple .rkassets")
            return
        }
        let rkAssetsPath = rkAssetsFileToBuild.absolutePath

        // search inputs to get .usda optional schema file
        let usdaSchemaFilesToBuild = cbc.inputs.filter { $0.absolutePath.fileExtension == "usda" }
        guard usdaSchemaFilesToBuild.count <= 1 else {
            delegate.error("multiple .usda")
            return
        }
        let usdaSchemaPath = usdaSchemaFilesToBuild.only?.absolutePath

        // Generate the command line from the xcspec.
        // CommandLine = "realitytool export [options] -o=$(ProductResourcesDir) $(InputFile)";
        let baseCommandLine = await commandLineArgumentsFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate))
        // Expected:
        // baseCommandLine=[
        //    "/Applications/Xcode.app/Contents/Developer/usr/bin/realitytool",
        //    "compile",
        //    "--platform",
        //    "xros",
        //    "--deployment-target",
        //    "1.0",
        //    "-o=",
        //    "...<>.rkassets"
        // ]
        // commandline from template is usable...just need to add info, and replace output path
        var commandLine = baseCommandLine
        // leave 1 as "compile"
        // leave 2 and 3 as platform
        // leave 4 and 5 and deployment target
        guard commandLine[6].asString.starts(with: "-o=") else {
            delegate.error("realitytool template commandline '-o=' not found where expected")
            return
        }
        commandLine[6...6] = [.literal("-o"), .path(cbc.output)]

        // inputs start with .rkassets, but we may add the .usda schema
        var inputs = [delegate.createDirectoryTreeNode(rkAssetsPath) as (any PlannedNode)]
        let outputs = [delegate.createNode(cbc.output) as (any PlannedNode)]

        // need to add in optional --schema-file
        if let usdaSchemaPath {
            commandLine.append("--schema-file")
            commandLine.append(.path(usdaSchemaPath))
            inputs.append(delegate.createNode(usdaSchemaPath) as (any PlannedNode))
        }

        let action: (any PlannedTaskAction)?
        let cachingEnabled: Bool
        if cbc.scope.evaluate(BuiltinMacros.ENABLE_GENERIC_TASK_CACHING), let casOptions = try? CASOptions.create(cbc.scope, .generic) {
            action = delegate.taskActionCreationDelegate.createGenericCachingTaskAction(
                enableCacheDebuggingRemarks: cbc.scope.evaluate(BuiltinMacros.GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS),
                enableTaskSandboxEnforcement: !cbc.scope.evaluate(BuiltinMacros.DISABLE_TASK_SANDBOXING),
                sandboxDirectory: cbc.scope.evaluate(BuiltinMacros.TEMP_SANDBOX_DIR),
                extraSandboxSubdirectories: [],
                developerDirectory: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR),
                casOptions: casOptions
            )
            cachingEnabled = true
        } else {
            action = nil
            cachingEnabled = false
        }


        let ruleInfo = ["RealityAssetsCompile", cbc.output.str]
        delegate.createTask(type: self,
                            dependencyData: nil,
                            payload: nil,
                            ruleInfo: ruleInfo,
                            additionalSignatureData: "",
                            commandLine: commandLine,
                            additionalOutput: [],
                            environment: environmentBindings(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs,
                            outputs: outputs,
                            mustPrecede: [],
                            action: action,
                            execDescription: "Compile Reality Asset \(rkAssetsPath.basename)",
                            preparesForIndexing: true,
                            enableSandboxing: !cachingEnabled,
                            llbuildControlDisabled: false,
                            additionalTaskOrderingOptions: [])
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, moduleWithDependencies: ModuleWithDependencies) async {
        // Construct the realitytool 'create-schema' preprocess swift -> schema .usda task.
        await constructRealityAssetsCreateSchemaTasks(cbc, delegate, moduleWithDependencies: moduleWithDependencies)
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Construct the realitytool 'compile' .rkassets [schema .usda] -> .reality task.
        await constructRealityAssetCompilerTasks(cbc, delegate)
    }
}
