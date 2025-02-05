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
import SWBUtil
import Testing

/// Tests the behavior of various alternative build commands of a build request, including single-file compiles.
@Suite
fileprivate struct BuildCommandTests: CoreBasedTests {
    /// Check compilation of a single file in C, ObjC and Swift, including the `uniquingSuffix` behaviour.
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func singleFileCompile() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("CFile.c"),
                            TestFile("SwiftFile.swift"),
                            TestFile("ObjCFile.m"),
                            TestFile("Metal.metal"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                            "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                                            "SWIFT_VERSION": swiftVersion])],
                        targets: [
                            TestStandardTarget(
                                "aFramework", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["CFile.c", "SwiftFile.swift", "ObjCFile.m", "Metal.metal"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            let cFile = testWorkspace.sourceRoot.join("aProject/CFile.c")
            try await tester.fs.writeFileContents(cFile) { stream in }
            let swiftFile = testWorkspace.sourceRoot.join("aProject/SwiftFile.swift")
            try await tester.fs.writeFileContents(swiftFile) { stream in }
            let objcFile = testWorkspace.sourceRoot.join("aProject/ObjCFile.m")
            try await tester.fs.writeFileContents(objcFile) { stream in }
            let metalFile = testWorkspace.sourceRoot.join("aProject/Metal.metal")
            try await tester.fs.writeFileContents(metalFile) { stream in }

            // Create a build request context to compute the output paths - can't use one from the tester because it's an _output_ of checkBuild.
            let buildRequestContext = BuildRequestContext(workspaceContext: tester.workspaceContext)

            // Construct the output paths.
            let excludedTypes: Set<String> = ["Copy", "Gate", "MkDir", "SymLink", "WriteAuxiliaryFile", "CreateBuildDirectory", "SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftMergeGeneratedHeaders", "ClangStatCache", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm"]
            let runDestination = RunDestinationInfo.macOS
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: runDestination)
            let target = tester.workspace.allTargets.first(where: { _ in true })!
            let cOutputPath = try #require(buildRequestContext.computeOutputPaths(for: [cFile], workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)
            let objcOutputPath = try #require(buildRequestContext.computeOutputPaths(for: [objcFile], workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)
            let swiftOutputPath = try #require(buildRequestContext.computeOutputPaths(for: [swiftFile], workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)
            let metalOutputPath = try #require(buildRequestContext.computeOutputPaths(for: [metalFile], workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), parameters: parameters).only)

            // Check building just the Swift file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [swiftOutputPath: swiftFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTaskExists(.matchRule(["SwiftCompile", "normal", results.runDestinationTargetArchitecture, "Compiling \(swiftFile.basename)", swiftFile.str]))
                results.checkTaskExists(.matchRule(["SwiftEmitModule", "normal", results.runDestinationTargetArchitecture, "Emitting module for aFramework"]))
                results.checkNoTask()
            }

            // Check building just the C file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [cOutputPath: cFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTaskExists(.matchRule(["CompileC", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/aFramework.build/Objects-normal/\(results.runDestinationTargetArchitecture)/CFile.o", cFile.str, "normal", results.runDestinationTargetArchitecture, "c", "com.apple.compilers.llvm.clang.1_0.compiler"]))
                results.checkNoTask()
            }

            // Check building just the ObjC file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [objcOutputPath: objcFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTaskExists(.matchRule(["CompileC", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/aFramework.build/Objects-normal/\(results.runDestinationTargetArchitecture)/ObjCFile.o", objcFile.str, "normal", results.runDestinationTargetArchitecture, "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"]))
                results.checkNoTask()
            }

            // Check building just the Metal file.
            try await tester.checkBuild(parameters: parameters, runDestination: runDestination, persistent: true, buildOutputMap: [metalOutputPath: metalFile.str]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTask(.matchRule(["CompileMetalFile", metalFile.str])) { _ in }
                results.checkNoTask()
            }

            try await tester.checkBuild(persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    // Helper method with sets up a single file build with a single ObjC file.
    func runSingleFileTask(_ parameters: BuildParameters, buildCommand: BuildCommand, fileName: String, fileType: String? = nil, body: @escaping (_ results: BuildOperationTester.BuildResults, _ excludedTypes: Set<String>, _ inputs: [Path], _ outputs: [String]) throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
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
                        targets: [
                            TestStandardTarget(
                                "aFramework", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        TestBuildFile(fileName)
                                    ]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input file.
            let input = testWorkspace.sourceRoot.join("aProject/\(fileName)")
            try await tester.fs.writeFileContents(input) { stream in }

            // Create a build request context to compute the output paths - can't use one from the tester because it's an _output_ of checkBuild.
            let buildRequestContext = BuildRequestContext(workspaceContext: tester.workspaceContext)

            // Construct the output paths.
            let excludedTypes: Set<String> = ["Copy", "Gate", "MkDir", "SymLink", "WriteAuxiliaryFile", "CreateBuildDirectory", "ClangStatCache"]
            let target = tester.workspace.allTargets.first(where: { _ in true })!
            let output = buildRequestContext.computeOutputPaths(for: [input], workspace: tester.workspace, target: BuildRequest.BuildTargetInfo(parameters: parameters, target: target), command: buildCommand).first!

            // Check analyzing the file.
            try await tester.checkBuild(parameters: parameters, buildCommand: buildCommand, persistent: true, buildOutputMap: [output: input.str]) { results in
                try body(results, excludedTypes, [input], [output])
            }
        }
    }

    /// Check analyze of a single file.
    @Test(.requireSDKs(.macOS))
    func singleFileAnalyze() async throws {
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .macOS, overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), buildCommand: .singleFileBuild(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, _, _ in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            results.checkTask(.matchRuleType("AnalyzeShallow"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { _ in }
            results.checkNoTask()
        }
    }

    /// Check preprocessing of a single file.
    @Test(.requireSDKs(.macOS))
    func preprocessSingleFile() async throws {
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .macOS), buildCommand: .generatePreprocessedFile(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Preprocess"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-E", #require(inputs.first).str, "-o", #require(outputs.first)])
            }
            results.checkNoTask()
        }

        // Ensure that files with a non-default type work too
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .macOS), buildCommand: .generatePreprocessedFile(buildOnlyTheseFiles: [Path("")]), fileName: "File.cpp", fileType: "sourcecode.cpp.objcpp") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Preprocess"), .matchRuleItemBasename("File.cpp"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c++"])
                try task.checkCommandLineContainsUninterrupted(["-E", #require(inputs.first).str, "-o", #require(outputs.first)])
            }
            results.checkNoTask()
        }

        // Ensure that RUN_CLANG_STATIC_ANALYZER=YES doesn't interfere with the preprocess build command
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .macOS, overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), buildCommand: .generatePreprocessedFile(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
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
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .macOS), buildCommand: .generateAssemblyCode(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
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
        try await runSingleFileTask(BuildParameters(configuration: "Debug", activeRunDestination: .macOS, overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), buildCommand: .generateAssemblyCode(buildOnlyTheseFiles: [Path("")]), fileName: "File.m") { results, excludedTypes, inputs, outputs in
            results.consumeTasksMatchingRuleTypes(excludedTypes)
            try results.checkTask(.matchRuleType("Assemble"), .matchRuleItemBasename("File.m"), .matchRuleItem("normal"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                task.checkCommandLineContainsUninterrupted(["-x", "objective-c"])
                try task.checkCommandLineContainsUninterrupted(["-S", #require(inputs.first).str, "-o", #require(outputs.first)])
                let assembly = try String(contentsOfFile: #require(outputs.first), encoding: .utf8)
                #expect(assembly.hasPrefix("\t.section\t__TEXT,__text,regular,pure_instructions"))
            }
            results.checkNoTask()
        }
    }

    /// Check behavior of the skip dependencies flag.
    @Test(.requireSDKs(.macOS))
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
                                    "aFramework", type: .framework,
                                    buildConfigurations: [TestBuildConfiguration("Debug")],
                                    buildPhases: [
                                        TestSourcesBuildPhase(["CFile.c"]),
                                    ],
                                    dependencies: ["aFrameworkDep"]),
                                TestStandardTarget(
                                    "aFrameworkDep", type: .framework,
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

                let runDestination = RunDestinationInfo.macOS
                let parameters = BuildParameters(configuration: "Debug", activeRunDestination: runDestination)

                try await tester.checkBuild(parameters: parameters, runDestination: runDestination, buildCommand: .build(style: .buildOnly, skipDependencies: skipDependencies), persistent: true) { results in
                    results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "RegisterExecutionPolicyException", "SymLink", "Touch", "WriteAuxiliaryFile", "GenerateTAPI", "ClangStatCache"])

                    results.consumeTasksMatchingRuleTypes(["CompileC", "Ld"], targetName: "aFramework")

                    try checkAuxiliaryTarget(results)

                    results.checkNoTask()
                    results.checkNoDiagnostics()
                }
            }
        }

        try await runTest(skipDependencies: true) { results in
            results.checkNoTask(.matchTargetName("aFrameworkDep"))
        }

        try await runTest(skipDependencies: false) { results in
            results.consumeTasksMatchingRuleTypes(["CompileC", "Ld"], targetName: "aFrameworkDep")
        }
    }
}
