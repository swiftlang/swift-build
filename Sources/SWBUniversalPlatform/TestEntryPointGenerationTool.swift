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

final class TestEntryPointGenerationToolSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "org.swift.test-entry-point-generator"

    override func commandLineFromTemplate(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, optionContext: (any DiscoveredCommandLineToolSpecInfo)?, specialArgs: [String] = [], lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) async -> [CommandLineArgument] {
        var args = await super.commandLineFromTemplate(cbc, delegate, optionContext: optionContext, specialArgs: specialArgs, lookup: lookup)
        if cbc.scope.evaluate(BuiltinMacros.GENERATED_TEST_ENTRY_POINT_INCLUDE_DISCOVERED_TESTS) {
            args.append("--discover-tests")
            
            let format = cbc.scope.evaluate(BuiltinMacros.LINKER_FILE_LIST_FORMAT)
            args.append(contentsOf: ["--linker-file-list-format", .literal(.init(encodingAsUTF8: format.rawValue))])
            
            for toolchainLibrarySearchPath in cbc.producer.toolchains.map({ StackedSearchPath(paths: $0.librarySearchPaths.paths + $0.fallbackLibrarySearchPaths.paths, fs: $0.librarySearchPaths.fs) } ) {
                if let path = toolchainLibrarySearchPath.findLibrary(operatingSystem: cbc.producer.hostOperatingSystem, basename: "IndexStore") {
                    args.append(contentsOf: ["--index-store-library-path", .path(path)])
                    break
                }
            }
            for input in cbc.inputs {
                if input.fileType.conformsTo(identifier: "text") {
                    args.append(contentsOf: ["--linker-filelist", .path(input.absolutePath)])
                } else if input.fileType.conformsTo(identifier: "compiled.mach-o") {
                    // Do nothing
                } else {
                    delegate.error("Unexpected input of type '\(input.fileType)' to test entry point generation")
                }
            }
        }
        return args
    }

    override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        TestEntryPointGenerationTaskAction()
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, indexStorePaths: [Path], indexUnitBasePaths: [Path]) async {
        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: nil)

        if cbc.scope.evaluate(BuiltinMacros.GENERATED_TEST_ENTRY_POINT_INCLUDE_DISCOVERED_TESTS) {
            for indexStorePath in indexStorePaths {
                commandLine.append(contentsOf: ["--index-store", .path(indexStorePath)])
            }
            
            for basePath in indexUnitBasePaths {
                commandLine.append(contentsOf: ["--index-unit-base-path", .path(basePath)])
            }
        }

        delegate.createTask(
            type: self,
            dependencyData: nil,
            payload: nil,
            ruleInfo: defaultRuleInfo(cbc, delegate),
            additionalSignatureData: "",
            commandLine: commandLine,
            additionalOutput: [],
            environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: cbc.inputs.map { delegate.createNode($0.absolutePath) },
            outputs: cbc.outputs.map { delegate.createNode($0) },
            mustPrecede: [],
            action: createTaskAction(cbc, delegate),
            execDescription: resolveExecutionDescription(cbc, delegate),
            preparesForIndexing: true,
            enableSandboxing: enableSandboxing,
            llbuildControlDisabled: true,
            additionalTaskOrderingOptions: []
        )
    }
}
