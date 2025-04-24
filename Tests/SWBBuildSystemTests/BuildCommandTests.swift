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

import SWBCore
import SWBProtocol
import SWBTestSupport
import SwiftBuildTestSupport
import SWBUtil
import Testing
import Foundation

/// Tests the behavior of various alternative build commands of a build request, including single-file compiles.
@Suite
fileprivate struct BuildCommandTests: CoreBasedTests {
    /// Check compilation of a single file in C, ObjC and Swift, including the `uniquingSuffix` behavior.
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func singleFileCompile() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("CFile.c"), TestFile("SwiftFile.swift"), TestFile("ObjCFile.m")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                            "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                                            "SWIFT_VERSION": swiftVersion])],
                        targets: [
                            TestStandardTarget(
                                "aLibrary", type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [TestSourcesBuildPhase(["CFile.c", "SwiftFile.swift", "ObjCFile.m"])]
                            )
                        ]
                    )
                ]
            )
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            let cFile = testWorkspace.sourceRoot.join("aProject/CFile.c")
            try await tester.fs.writeFileContents(cFile) { stream in }
            let swiftFile = testWorkspace.sourceRoot.join("aProject/SwiftFile.swift")
            try await tester.fs.writeFileContents(swiftFile) { stream in }
            let objcFile = testWorkspace.sourceRoot.join("aProject/ObjCFile.m")
            try await tester.fs.writeFileContents(objcFile) { stream in }

            // Create a build request context to compute the output paths - can't use one from the tester because it's an _output_ of checkBuild.
            let buildRequestContext = BuildRequestContext(workspaceContext: tester.workspaceContext)

            // Construct the output paths.
            let excludedTypes: Set<String> = ["Copy", "Gate", "MkDir", "SymLink", "WriteAuxiliaryFile", "CreateBuildDirectory", "SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftMergeGeneratedHeaders", "ClangStatCache", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports"]
            let runDestination = RunDestinationInfo.host
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: runDestination)
            let target = tester.workspace.allTargets.first(where: { _ in true })!
            let cOutputPath = try #require(buildRequestContext.computeOutputPaths(for: cFile, workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)
            let objcOutputPath = try #require(buildRequestContext.computeOutputPaths(for: objcFile, workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)
            let swiftOutputPath = try #require(buildRequestContext.computeOutputPaths(for: swiftFile, workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)

            // Check building just the Swift file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [swiftOutputPath: swiftFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTaskExists(.matchRule(["SwiftCompile", "normal", results.runDestinationTargetArchitecture, "Compiling \(swiftFile.basename)", swiftFile.str]))
                results.checkTaskExists(.matchRule(["SwiftEmitModule", "normal", results.runDestinationTargetArchitecture, "Emitting module for aLibrary"]))
                if runDestination == .linux {  // FIXME: This needs to be investigated... We should be able to use core.hostOperatingSystem.imageFormat.requiresSwiftModulewrap to test for this, but on Windows using this causes the test to fail as the SwiftModuleWrap does not seem to be added.
                    results.checkTaskExists(.matchRule(["SwiftModuleWrap", "normal", results.runDestinationTargetArchitecture,  "Wrapping Swift module aLibrary"]))
                }
                results.checkNoTask()
            }

            // Check building just the C file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [cOutputPath: cFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTaskExists(.matchRule(["CompileC", tmpDirPath.join("Test/aProject/build/aProject.build/Debug\(runDestination.builtProductsDirSuffix)/aLibrary.build/Objects-normal/\(results.runDestinationTargetArchitecture)/CFile.o").str, cFile.str, "normal", results.runDestinationTargetArchitecture, "c", "com.apple.compilers.llvm.clang.1_0.compiler"]))
                if runDestination == .linux {  // FIXME: This needs to be investigated... iIs not clear why this task is added when building a C file, and only on Linux.
                    results.checkTaskExists(.matchRule(["SwiftEmitModule", "normal", results.runDestinationTargetArchitecture, "Emitting module for aLibrary"]))
                }
                results.checkNoTask()
            }

            // Check building just the ObjC file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [objcOutputPath: objcFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTaskExists(.matchRule(["CompileC", tmpDirPath.join("Test/aProject/build/aProject.build/Debug\(runDestination.builtProductsDirSuffix)/aLibrary.build/Objects-normal/\(results.runDestinationTargetArchitecture)/ObjCFile.o").str, objcFile.str, "normal", results.runDestinationTargetArchitecture, "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"]))
                results.checkNoTask()
            }

            try await tester.checkBuild(runDestination: runDestination, persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    // Helper method with sets up a single file build with a single ObjC file.
    func runSingleFileTask(_ parameters: BuildParameters, buildCommand: BuildCommand, fileName: String, fileType: String? = nil, multipleTargets: Bool = false, body: @escaping (_ results: BuildOperationTester.BuildResults, _ excludedTypes: Set<String>, _ inputs: [Path], _ outputs: [String]) throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            var targets: [any TestTarget] = [
                TestAggregateTarget("All", dependencies: ["aFramework"] + (multipleTargets ? ["bFramework"] : [])),
                TestStandardTarget(
                    "aFramework", type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile(fileName)
                        ]),
                    ])
            ]
            if multipleTargets {
                targets.append(TestStandardTarget(
                    "bFramework", type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile(fileName)
                        ]),
                    ]))
            }
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile(fileName, fileType: fileType),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"])],
                        targets: targets)
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input file.
            let input = testWorkspace.sourceRoot.join("aProject/\(fileName)")
            try await tester.fs.writeFileContents(input) { stream in }

            // Create a build request context to compute the output paths - can't use one from the tester because it's an _output_ of checkBuild.
            let buildRequestContext = BuildRequestContext(workspaceContext: tester.workspaceContext)

            // Construct the output paths.
            let excludedTypes: Set<String> = ["Copy", "Gate", "MkDir", "SymLink", "WriteAuxiliaryFile", "CreateBuildDirectory", "ClangStatCache"]
            let outputs = try tester.workspace.allTargets.dropFirst().map { target in
                try #require(buildRequestContext.computeOutputPaths(for: input, workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: buildCommand).only)
            }

            // Check analyzing the file.
            try await tester.checkBuild(parameters: parameters, runDestination: nil, buildRequest: BuildRequest(parameters: parameters, buildTargets: tester.workspace.allTargets.dropFirst().map { .init(parameters: parameters, target: $0) }, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false, buildCommand: buildCommand), persistent: true, buildOutputMap: Dictionary(uniqueKeysWithValues: outputs.map { ($0, input.str) })) { results in
                try body(results, excludedTypes, [input], outputs)
            }
        }
    }

    /// Check analyze of a single file.
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func singleFileAnalyze() async throws {
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .host, overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), buildCommand: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, _, _ in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            results.checkTask(.matchRuleType("AnalyzeShallow"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { _ in }
            results.checkNoTask()
        }
    }

    /// Check preprocessing of a single file.
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func preprocessSingleFile() async throws {
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .host), buildCommand: .generatePreprocessedFile(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Preprocess"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-E", #require(inputs.first).str, "-o", #require(outputs.first)])
            }
            results.checkNoTask()
        }

        // Ensure that files with a non-default type work too
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .host), buildCommand: .generatePreprocessedFile(buildOnlyTheseFiles: [Path("")]), fileName: "File.cpp", fileType: "sourcecode.cpp.objcpp") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Preprocess"), .matchRuleItemBasename("File.cpp"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c++"])
                try task.checkCommandLineContainsUninterrupted(["-E", #require(inputs.first).str, "-o", #require(outputs.first)])
            }
            results.checkNoTask()
        }

        // Ensure that RUN_CLANG_STATIC_ANALYZER=YES doesn't interfere with the preprocess build command
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .host, overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), buildCommand: .generatePreprocessedFile(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Preprocess"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-E", #require(inputs.first).str, "-o", #require(outputs.first)])
            }
            results.checkNoTask()
        }
    }

    /// Check assembling of a single file.
    @Test(.requireSDKs(.macOS))
    func assembleSingleFile() async throws {
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .host), buildCommand: .generateAssemblyCode(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Assemble"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-S", #require(inputs.first).str, "-o", #require(outputs.first)])
                let assembly = try String(contentsOfFile: #require(outputs.first), encoding: .utf8)
                #expect(assembly.hasPrefix("\t.section\t__TEXT,__text,regular,pure_instructions"))
            }
            results.checkNoTask()
        }

        // Ensure that RUN_CLANG_STATIC_ANALYZER=YES doesn't interfere with the assemble build command
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .host, overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), buildCommand: .generateAssemblyCode(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Assemble"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-S", #require(inputs.first).str, "-o", #require(outputs.first)])
                let assembly = try String(contentsOfFile: #require(outputs.first), encoding: .utf8)
                #expect(assembly.hasPrefix("\t.section\t__TEXT,__text,regular,pure_instructions"))
            }
            results.checkNoTask()
        }

        // Include the single file to assemble in multiple targets
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .host), buildCommand: .generateAssemblyCode(buildOnlyTheseFiles: [Path("")]), fileName: "File.m", multipleTargets: true) { results, excludedTypes, inputs, outputs in
            let firstOutput = try #require(outputs.sorted()[safe: 0])
            let secondOutput = try #require(outputs.sorted()[safe: 1])
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Assemble"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture), .matchTargetName("aFramework")) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-S", #require(inputs.first).str, "-o", firstOutput])
                let assembly = try String(contentsOfFile: firstOutput, encoding: .utf8)
                #expect(assembly.hasPrefix("\t.section\t__TEXT,__text,regular,pure_instructions"))
            }
            try results.checkTask(.matchRuleType("Assemble"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture), .matchTargetName("bFramework")) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-S", #require(inputs.first).str, "-o", secondOutput])
                let assembly = try String(contentsOfFile: secondOutput, encoding: .utf8)
                #expect(assembly.hasPrefix("\t.section\t__TEXT,__text,regular,pure_instructions"))
            }
            results.checkNoTask()
            results.checkNoErrors()
        }
    }

    /// Check behavior of the skip dependencies flag.
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func skipDependenciesFlag() async throws {
        func runTest(skipDependencies: Bool, checkAuxiliaryTarget: (_ results: BuildOperationTester.BuildResults) throws -> Void) async throws {
            try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup("Sources", children: [
                                TestFile("CFile.c"),
                            ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"])],
                            targets: [
                                TestStandardTarget(
                                    "aLibrary", type: .staticLibrary,
                                    buildConfigurations: [TestBuildConfiguration("Debug")],
                                    buildPhases: [
                                        TestSourcesBuildPhase(["CFile.c"]),
                                    ],
                                    dependencies: ["aLibraryDep"]),
                                TestStandardTarget(
                                    "aLibraryDep", type: .staticLibrary,
                                    buildConfigurations: [TestBuildConfiguration("Debug")],
                                    buildPhases: [
                                        TestSourcesBuildPhase(["CFile.c"]),
                                    ])
                            ])
                    ])
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // Create the input files.
                let cFile = testWorkspace.sourceRoot.join("aProject/CFile.c")
                try await tester.fs.writeFileContents(cFile) { stream in }

                let runDestination = RunDestinationInfo.host
                let parameters = BuildParameters(configuration: "Debug", activeRunDestination: runDestination)

                try await tester.checkBuild(parameters: parameters, runDestination: runDestination, buildCommand: .build(style: .buildOnly, skipDependencies: skipDependencies), persistent: true) { results in
                    results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "RegisterExecutionPolicyException", "SymLink", "Touch", "WriteAuxiliaryFile", "GenerateTAPI", "ClangStatCache", "ProcessSDKImports", "Libtool"])

                    results.consumeTasksMatchingRuleTypes(["CompileC", "Ld"], targetName: "aLibrary")

                    try checkAuxiliaryTarget(results)

                    results.checkNoTask()
                    results.checkNoDiagnostics()
                }
            }
        }

        try await runTest(skipDependencies: true) { results in
            results.checkNoTask(.matchTargetName("aLibraryDep"))
        }

        try await runTest(skipDependencies: false) { results in
            results.consumeTasksMatchingRuleTypes(["CompileC", "Ld"], targetName: "aLibraryDep")
        }
    }

    @Test(.requireSDKs(.macOS), .requireXcode16())
    func singleFileCompileMetal() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("Metal.metal")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                            "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                                            "SWIFT_VERSION": swiftVersion])],
                        targets: [
                            TestStandardTarget(
                                "aLibrary", type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [TestSourcesBuildPhase(["Metal.metal"])]
                            )
                        ]
                    )
                ]
            )
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let metalFile = testWorkspace.sourceRoot.join("aProject/Metal.metal")
            try await tester.fs.writeFileContents(metalFile) { stream in }

            // Create a build request context to compute the output paths - can't use one from the tester because it's an _output_ of checkBuild.
            let buildRequestContext = BuildRequestContext(workspaceContext: tester.workspaceContext)

            // Construct the output paths.
            let excludedTypes: Set<String> = ["Copy", "Gate", "MkDir", "SymLink", "WriteAuxiliaryFile", "CreateBuildDirectory", "SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftMergeGeneratedHeaders", "ClangStatCache", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports"]
            let runDestination = RunDestinationInfo.host
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: runDestination)
            let target = tester.workspace.allTargets.first(where: { _ in true })!
            let metalOutputPath = try #require(buildRequestContext.computeOutputPaths(for: metalFile, workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)

            // Check building just the Metal file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [metalOutputPath: metalFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTask(.matchRule(["CompileMetalFile", metalFile.str])) { _ in }
                results.checkNoTask()
            }

            try await tester.checkBuild(runDestination: runDestination, persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
