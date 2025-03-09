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

// Tests that check that task construction for individual build tools works.

import Foundation
import Testing

import SWBCore
import enum SWBProtocol.BuildAction
import enum SWBProtocol.ExternalToolResult
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct BuildToolTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func unifdef() async throws {
        // Test situations where task construction can detect errors and warnings.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Header.h"),
                    TestFile("Header.hpp"),
                    TestFile("ModuleMap.modulemap"),
                    TestFile("Entitlements.entitlements"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "APPLY_RULES_IN_COPY_FILES": "YES",
                        "COPY_HEADERS_RUN_UNIFDEF": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildPhases: [
                        // Whatever gets dragged into a Headers build phase will be unifdef'ed.
                        TestHeadersBuildPhase([
                            TestBuildFile("Header.h", headerVisibility: .public),
                            TestBuildFile("Header.hpp", headerVisibility: .public),
                            TestBuildFile("ModuleMap.modulemap", headerVisibility: .public),
                            TestBuildFile("Entitlements.entitlements", headerVisibility: .public),
                        ]),
                        // Copy Files doesn't use COPY_HEADERS_RUN_UNIFDEF even if
                        // APPLY_RULES_IN_COPY_FILES is set.
                        TestCopyFilesBuildPhase([
                            "Header.h",
                        ], destinationSubfolder: .resources, destinationSubpath: "", onlyForDeployment: false),
                    ]),
                TestStandardTarget(
                    "CustomBuildRule",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "COPY_HEADERS_RUN_UNIFDEF": "NO",
                            ]),
                    ],
                    buildPhases: [
                        // The Headers build phase only uses COPY_HEADERS_RUN_UNIFDEF
                        // and doesn't pay attention to build rules.
                        TestHeadersBuildPhase([
                            TestBuildFile("Header.h", headerVisibility: .public),
                        ]),
                        // A custom build rule will make files unifdef independent of
                        // COPY_HEADERS_RUN_UNIFDEF and the spec's InputFileTypes.
                        TestCopyFilesBuildPhase([
                            "Header.h",
                            "ModuleMap.modulemap",
                            "Entitlements.entitlements",
                        ], destinationSubfolder: .resources, destinationSubpath: "", onlyForDeployment: false),
                    ],
                    buildRules: [
                        TestBuildRule(fileTypeIdentifier: "sourcecode.c.h", compilerIdentifier: "public.build-task.unifdef"),
                        TestBuildRule(fileTypeIdentifier: "text.plist.entitlements", compilerIdentifier: "public.build-task.unifdef"),
                    ]),
                TestStandardTarget(
                    "NoApplyRules",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "APPLY_RULES_IN_COPY_FILES": "NO",
                            ]),
                    ],
                    buildPhases: [
                        // Copy Files will not unifdef unless APPLY_RULES_IN_COPY_FILES is set.
                        TestCopyFilesBuildPhase([
                            "Header.h",
                            "ModuleMap.modulemap",
                        ], destinationSubfolder: .resources, destinationSubpath: "", onlyForDeployment: false),
                    ],
                    buildRules: [
                        TestBuildRule(fileTypeIdentifier: "sourcecode.c.h", compilerIdentifier: "public.build-task.unifdef"),
                        TestBuildRule(fileTypeIdentifier: "sourcecode.module-map", compilerIdentifier: "public.build-task.unifdef"),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the debug build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("AppTarget") { target in
                // Check that we have an unifdef task.
                results.checkTask(.matchTarget(target), .matchRule(["Unifdef", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/Header.h", "\(SRCROOT)/Sources/Header.h"])) { task in
                    #expect(task.preparesForIndexing)
                    task.checkCommandLine(["unifdef", "-x", "2", "-o", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/Header.h", "\(SRCROOT)/Sources/Header.h"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["Unifdef", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/Header.hpp", "\(SRCROOT)/Sources/Header.hpp"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Unifdef", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/ModuleMap.modulemap", "\(SRCROOT)/Sources/ModuleMap.modulemap"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Unifdef", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/Entitlements.entitlements", "\(SRCROOT)/Sources/Entitlements.entitlements"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/Header.h", "\(SRCROOT)/Sources/Header.h"])) { _ in }

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }

        await tester.checkBuild(runDestination: .macOS, targetName: "CustomBuildRule") { results in
            results.checkTarget("CustomBuildRule") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/CustomBuildRule.app/Contents/Headers/Header.h", "\(SRCROOT)/Sources/Header.h"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["Unifdef", "\(SRCROOT)/build/Debug/CustomBuildRule.app/Contents/Resources/Header.h", "\(SRCROOT)/Sources/Header.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/CustomBuildRule.app/Contents/Resources/ModuleMap.modulemap", "\(SRCROOT)/Sources/ModuleMap.modulemap"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Unifdef", "\(SRCROOT)/build/Debug/CustomBuildRule.app/Contents/Resources/Entitlements.entitlements", "\(SRCROOT)/Sources/Entitlements.entitlements"])) { _ in }
            }
        }

        await tester.checkBuild(runDestination: .macOS, targetName: "NoApplyRules") { results in
            results.checkTarget("NoApplyRules") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/NoApplyRules.app/Contents/Resources/Header.h", "\(SRCROOT)/Sources/Header.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/NoApplyRules.app/Contents/Resources/ModuleMap.modulemap", "\(SRCROOT)/Sources/ModuleMap.modulemap"])) { _ in }
            }
        }
    }

    /// Check that unhandled files in source phases generate a diagnostic.
    @Test(.requireSDKs(.macOS))
    func missingRuleDiagnostic() async throws {
        let testProject = TestProject("aProject",
                                      groupTree: TestGroup("SomeFiles", path: "Sources",
                                                           children: [
                                                            TestFile("SourceFile1.fake-ext"),
                                                            TestFile("SourceFile2.fake-ext")]),
                                      buildConfigurations: [
                                        TestBuildConfiguration("Debug",
                                                               buildSettings: [
                                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                                "CODE_SIGN_IDENTITY": "",
                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                               ])],
                                      targets: [
                                        TestStandardTarget("AppTarget",
                                                           type: .application,
                                                           buildPhases: [
                                                            TestSourcesBuildPhase([
                                                                "SourceFile1.fake-ext",
                                                                .init("SourceFile2.fake-ext", shouldWarnIfNoRuleToProcess: false)
                                                            ])
                                                           ])
                                      ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("AppTarget") { target in
                // Check that we warned about the missing source file.
                results.checkWarning(.prefix("no rule to process file"))

                // There shouldn't be any other diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test generating tasks with the core data compiler.
    @Test(.requireSDKs(.macOS))
    func coreDataCompiler() async throws {
        let targetName = "FrameworkTarget"
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("\(targetName).xcmappingmodel"),
                    TestVersionGroup("\(targetName).xcdatamodeld",
                                     children: [
                                        TestFile("\(targetName)-4.6.xcdatamodel"),
                                        TestFile("\(targetName)-5.0.xcdatamodel"),
                                        TestFile("\(targetName).xcdatamodel"),
                                     ]),
                    TestFile("MyInfo.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("SourceOne.m"),
                            TestBuildFile("FrameworkTarget.xcmappingmodel", additionalArgs: ["--mapc-no-warnings"]),
                            TestBuildFile("FrameworkTarget.xcdatamodeld", additionalArgs: ["--no-warnings"]),
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

        /// Client to generate files from the core data model.
        final class TestCoreDataCompilerTaskPlanningClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first.map(Path.init)?.basename != "momc" {
                    return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                }
                if let modelName = commandLine[safe: commandLine.count - 2].map(Path.init)?.basenameWithoutSuffix,
                   let outputDir = commandLine.last.map(Path.init) {
                    return .result(status: .exit(0), stdout: Data([
                        outputDir.join("\(modelName)+CoreDataModel.h"),
                        outputDir.join("\(modelName)+CoreDataModel.m"),
                        outputDir.join("EntityOne+CoreDataClass.h"),
                        outputDir.join("EntityOne+CoreDataClass.m"),
                        outputDir.join("EntityOne+CoreDataProperties.h"),
                        outputDir.join("EntityOne+CoreDataProperties.m"),
                    ].map { $0.str }.joined(separator: "\n").utf8), stderr: .init())
                }
                throw StubError.error("Could not determine generated file paths for Core Data code generation: Unit test should implement its own instance of TaskPlanningClientDelegate.")
            }
        }

        func checkBuild(params: BuildParameters) async throws {
            // Check the debug build.
            try await tester.checkBuild(params, runDestination: .macOS, clientDelegate: TestCoreDataCompilerTaskPlanningClientDelegate()) { results in
                try results.checkTarget(targetName) { target in

                    if params.action == .build || params.action == .installAPI || params.action == .installHeaders {
                        // There should be a DataModelCodegen task.
                        results.checkTask(.matchTarget(target), .matchRuleType("DataModelCodegen")) { task in
                            task.checkRuleInfo(["DataModelCodegen", "\(SRCROOT)/\(targetName).xcdatamodeld"])
                            task.checkCommandLine(["momc", "--action", "generate", "--sdkroot", core.loadSDK(.macOS).path.str, "--macosx-deployment-target", MACOSX_DEPLOYMENT_TARGET, "--module", targetName, "--no-warnings", "\(SRCROOT)/\(targetName).xcdatamodeld", "\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build/DerivedSources/CoreDataGenerated/FrameworkTarget"])
                            task.checkInputs([
                                .path("\(SRCROOT)/\(targetName).xcdatamodeld"),
                                .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/\(targetName)+CoreDataModel.h"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/\(targetName)+CoreDataModel.m"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataClass.h"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataClass.m"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataProperties.h"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataProperties.m"),
                            ])
                        }
                    }

                    if params.action == .build {
                        // Confirm that the generated header files are in the generated files headermap.
                        results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(targetName)-generated-files.hmap")) { headermap in
                            // Quote inclusions
                            headermap.checkEntry("EntityOne+CoreDataClass.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataClass.h")
                            headermap.checkEntry("EntityOne+CoreDataProperties.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataProperties.h")
                            headermap.checkEntry("\(targetName)+CoreDataModel.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/\(targetName)+CoreDataModel.h")

                            // Framework-style inclusions
                            headermap.checkEntry("\(targetName)/EntityOne+CoreDataClass.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataClass.h")
                            headermap.checkEntry("\(targetName)/EntityOne+CoreDataProperties.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/EntityOne+CoreDataProperties.h")
                            headermap.checkEntry("\(targetName)/\(targetName)+CoreDataModel.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreDataGenerated/\(targetName)/\(targetName)+CoreDataModel.h")

                            headermap.checkNoEntries()
                        }

                        // Check the CompileC tasks, including those generated from the model.
                        try results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { tasks in
                            let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                            #expect(sortedTasks.count == 4)
                            for (idx, fileBasename) in ["EntityOne+CoreDataClass", "EntityOne+CoreDataProperties", "\(targetName)+CoreDataModel", "SourceOne"].enumerated() {
                                try #require(sortedTasks[safe: idx]).checkRuleInfo([.equal("CompileC"), .suffix("\(fileBasename).o"), .suffix("\(fileBasename).m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                            }
                        }

                        // There should be one link task, and a task to generate its link file list.
                        results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName).LinkFileList"])) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                            task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/\(targetName)", "normal"])
                        }

                        // There should be one DataModelCompile task.
                        results.checkTask(.matchTarget(target), .matchRuleType("DataModelCompile")) { task in
                            task.checkRuleInfo(["DataModelCompile", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Resources/", "\(SRCROOT)/\(targetName).xcdatamodeld"])
                            task.checkCommandLine(["momc", "--sdkroot", core.loadSDK(.macOS).path.str, "--macosx-deployment-target", MACOSX_DEPLOYMENT_TARGET, "--module", targetName, "--no-warnings", "\(SRCROOT)/\(targetName).xcdatamodeld", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Resources/"])
                            task.checkInputs([
                                .path("\(SRCROOT)/\(targetName).xcdatamodeld"),
                                .path("\(SRCROOT)/\(targetName).xcdatamodeld"),
                                .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Resources/\(targetName).momd"),
                            ])
                        }

                        results.checkTask(.matchTarget(target), .matchRuleType("MappingModelCompile")) { task in
                            task.checkRuleInfo(["MappingModelCompile", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Resources/\(targetName).cdm", "\(SRCROOT)/\(targetName).xcmappingmodel"])
                            task.checkCommandLine(["mapc", "--sdkroot", core.loadSDK(.macOS).path.str, "--macosx-deployment-target", MACOSX_DEPLOYMENT_TARGET, "--mapc-no-warnings", "--module", targetName, "\(SRCROOT)/\(targetName).xcmappingmodel", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Resources/\(targetName).cdm"])
                            task.checkInputs([
                                .path("\(SRCROOT)/\(targetName).xcmappingmodel"),
                                .path("\(SRCROOT)/\(targetName).xcmappingmodel"),
                                .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Resources/\(targetName).cdm"),
                            ])
                        }
                    }

                    if params.action == .installAPI {
                        results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { task in
                            task.checkRuleInfo(["GenerateTAPI", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd", "normal", "x86_64"])
                        }
                    } else if params.action == .build {
                        results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { task in
                            task.checkRuleInfo(["GenerateTAPI", "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd"])
                        }
                    }

                    // Match other expected task types.
                    results.checkTasks(.matchRuleType("Gate")) { _ in }
                    results.checkTasks(.matchRuleType("MkDir")) { _ in }
                    results.checkTasks(.matchRuleType("SymLink")) { _ in }
                    results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                    results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
                    results.checkTasks(.matchRuleType("Touch")) { _ in }
                    results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                    results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

                    // Check that there are no other tasks.
                    results.checkNoTask()
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Ensure that the correct commands are run for each of the build flavors.
        try await checkBuild(params: BuildParameters(action: .build, configuration: "Debug"))
        try await checkBuild(params: BuildParameters(action: .installAPI, configuration: "Debug", overrides: ["SUPPORTS_TEXT_BASED_API": "YES"]))
        try await checkBuild(params: BuildParameters(action: .installHeaders, configuration: "Debug", overrides: ["EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING": "YES"]))

        // Check a build which emits an error when trying to get the generated file paths for the model.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget(targetName) { _ in }

            // Check diagnostics.
            results.checkError(.prefix("Could not determine generated file paths for Core Data code generation: Unit test should implement its own instance of TaskPlanningClientDelegate."))
            results.checkNoDiagnostics()
        }
    }

    /// Test generating tasks with the CoreML compiler.
    @Test(.requireSDKs(.macOS))
    func coreMLCompiler() async throws {
        let targetName = "FrameworkTarget"

        let core = try await getCore()

        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion

        let fs = PseudoFS()
        try fs.createDirectory(Path("/path"), recursive: true)
        try fs.write(Path("/path/to.key"), contents: "123")

        let toolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let coremlcPath = toolchain.path.join("usr").join("bin").join("coremlc")
        try fs.createDirectory(coremlcPath.dirname, recursive: true)
        try fs.write(coremlcPath, contents: ByteString())

        func taskConstructionTesterForProject(with visibility: IntentsCodegenVisibility) async throws -> TaskConstructionTester {
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("SourceOne.swift"),
                        TestFile("SmartStuff.mlmodel"),
                        TestFile("SmartStuff2.mlpackage"),
                        TestFile("SmartStuff3.mlmodel"),
                        TestFile("MyInfo.plist"),
                    ].compactMap { $0 }),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "DEFINES_MODULE": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            "COREML_CODEGEN_SWIFT_VERSION": swiftVersion,
                            "COREML_CODEGEN_SWIFT_GLOBAL_MODULE": "YES",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([]),
                            TestSourcesBuildPhase([
                                "SourceOne.swift",
                                TestBuildFile("SmartStuff.mlmodel", intentsCodegenVisibility: visibility),
                                TestBuildFile("SmartStuff2.mlpackage", intentsCodegenVisibility: visibility),
                                TestBuildFile("SmartStuff3.mlmodel",
                                              additionalArgs: ["--encrypt", "/path/to.key"],
                                              intentsCodegenVisibility: visibility),
                            ].compactMap { $0 })
                        ],
                        predominantSourceCodeLanguage: .swift
                    ),
                ])
            return try TaskConstructionTester(core, testProject)
        }

        /// Client to generate files from the CoreML model.
        final class TestCoreMLCompilerTaskPlanningClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first.map(Path.init)?.basename == "coremlc",
                   let outputDir = commandLine[safe: 3].map(Path.init),
                   let input = commandLine.firstIndex(where: { $0.hasSuffix(".mlmodel") || $0.hasSuffix(".mlpackage") }).map({ Path(commandLine[$0]) }),
                   let language = commandLine.elementAfterElements(["--language"]) {
                    let modelName = input.basenameWithoutSuffix
                    switch language {
                    case "Swift":
                        return .result(status: .exit(0), stdout: Data(outputDir.join("\(modelName).swift").str.utf8), stderr: .init())
                    case "Objective-C":
                        return .result(status: .exit(0), stdout: Data([outputDir.join("\(modelName).h").str, outputDir.join("\(modelName).m").str].joined(separator: "\n").utf8), stderr: .init())
                    default:
                        throw StubError.error("unknown language '\(language)'")
                    }
                }
                return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
            }
        }

        func checkBuild(action: BuildAction, with results: TaskConstructionTester.PlanningResults, srcroot: String, expectedVisibility visibility: IntentsCodegenVisibility, expectedCodegenLanguage: StandardTarget.SourceCodeLanguage, mainTestBody: (TaskConstructionTester.PlanningResults, ConfiguredTarget) throws -> Void) throws {
            // Match Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }

            try results.checkTarget(targetName) { target in
                // Match other task types we don't plan to check.
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("Ld")) { _ in }
                results.checkTasks(.matchRuleType("Touch")) { _ in }
                results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

                if action == .build {
                    if case .objectiveC = expectedCodegenLanguage {
                        switch visibility {
                        case .public:
                            results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff.h")) { task in
                                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Headers"])
                            }
                            results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff2.h")) { task in
                                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Headers"])
                            }
                            results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff3.h")) { task in
                                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Headers"])
                            }
                        case .private:
                            results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff.h")) { task in
                                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/PrivateHeaders"])
                            }
                            results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff2.h")) { task in
                                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/PrivateHeaders"])
                            }
                            results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff3.h")) { task in
                                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/PrivateHeaders"])
                            }
                        default:
                            // Consume remaining tasks
                            results.checkTasks(.matchRuleType("Copy")) { _ in }
                            results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff.h"))
                            results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff2.h"))
                            results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("SmartStuff3.h"))
                        }
                    }
                }

                try mainTestBody(results, target)

                if action == .build {
                    // There should be one DataModelCompile task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CoreMLModelCompile"), .matchRuleItemBasename("SmartStuff.mlmodel")) { task in
                        task.checkRuleInfo(["CoreMLModelCompile", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "\(srcroot)/SmartStuff.mlmodel"])
                        task.checkSandboxedCommandLine([coremlcPath.str, "compile", "\(srcroot)/SmartStuff.mlmodel", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                        "--sdkroot",
                                                        core.loadSDK(.macOS).path.str,
                                                        "--platform", "macos", "--output-partial-info-plist", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff-CoreMLPartialInfo.plist", "--container", "bundle-resources"].compactMap { $0 })
                        task.checkInputs([
                            .path("\(srcroot)/SmartStuff.mlmodel"),
                            .path("\(srcroot)/SmartStuff.mlmodel"),
                            .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                            .pathPattern(.and(.prefix("\(srcroot)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                            .name("WorkspaceHeaderMapVFSFilesWritten")
                        ])
                        task.checkOutputs([
                            .path("\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/SmartStuff.mlmodelc"),
                            .path("\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff-CoreMLPartialInfo.plist"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CoreMLModelCompile"), .matchRuleItemBasename("SmartStuff2.mlpackage")) { task in
                        task.checkRuleInfo(["CoreMLModelCompile", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "\(srcroot)/SmartStuff2.mlpackage"])
                        task.checkSandboxedCommandLine([coremlcPath.str, "compile", "\(srcroot)/SmartStuff2.mlpackage", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                        "--sdkroot",
                                                        core.loadSDK(.macOS).path.str,
                                                        "--platform", "macos", "--output-partial-info-plist", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff2-CoreMLPartialInfo.plist",
                                                        "--container", "bundle-resources"].compactMap { $0 })
                        task.checkInputs([
                            .path("\(srcroot)/SmartStuff2.mlpackage"),
                            .path("\(srcroot)/SmartStuff2.mlpackage"),
                            .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                            .pathPattern(.and(.prefix("\(srcroot)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                            .name("WorkspaceHeaderMapVFSFilesWritten")
                        ])
                        task.checkOutputs([
                            .path("\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/SmartStuff2.mlmodelc"),
                            .path("\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff2-CoreMLPartialInfo.plist"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CoreMLModelCompile"), .matchRuleItemBasename("SmartStuff3.mlmodel")) { task in
                        task.checkRuleInfo(["CoreMLModelCompile", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "\(srcroot)/SmartStuff3.mlmodel"])
                        task.checkSandboxedCommandLine([coremlcPath.str, "compile", "\(srcroot)/SmartStuff3.mlmodel", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                        "--sdkroot",
                                                        core.loadSDK(.macOS).path.str,
                                                        "--platform", "macos", "--output-partial-info-plist", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff3-CoreMLPartialInfo.plist", "--container", "bundle-resources"].compactMap { $0 })
                        task.checkInputs([
                            .path("\(srcroot)/SmartStuff3.mlmodel"),
                            .path("\(srcroot)/SmartStuff3.mlmodel"),
                            .path("/path/to.key"),
                            .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                            .pathPattern(.and(.prefix("\(srcroot)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                            .name("WorkspaceHeaderMapVFSFilesWritten")
                        ])
                        task.checkOutputs([
                            .path("\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/SmartStuff3.mlmodelc"),
                            .path("\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff3-CoreMLPartialInfo.plist"),
                        ])
                    }
                    // There should be a ProcessInfoPlistFile task which incorporates the PartialInfo.plist generated by coremlc.
                    results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                        task.checkCommandLine(["builtin-infoPlistUtility", "\(srcroot)/MyInfo.plist", "-producttype", "com.apple.product-type.framework", "-expandbuildsettings", "-platform", "macosx", "-additionalcontentfile", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff-CoreMLPartialInfo.plist",
                                               "-additionalcontentfile",
                                               "\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff2-CoreMLPartialInfo.plist",
                                               "-additionalcontentfile",
                                               "\(srcroot)/build/aProject.build/Debug/\(targetName).build/SmartStuff3-CoreMLPartialInfo.plist",
                                               "-o",
                                               "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/Info.plist"].compactMap { $0 })
                    }
                }

                if action == .installAPI {
                    results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI"), .matchRuleItemBasename("FrameworkTarget.tbd")) { _ in }
                }

                // Match any other tasks.
                results.consumeTasksMatchingRuleTypes(["WriteAuxiliaryFile", "CreateBuildDirectory", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "Copy", "SwiftMergeGeneratedHeaders", "GenerateTAPI"])

                // Check that there are no other tasks.
                results.checkNoTask()
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        func verifyTask(for visibilityBeingTested: IntentsCodegenVisibility,
                        with results: TaskConstructionTester.PlanningResults,
                        in target: ConfiguredTarget,
                        matching conditions: TaskCondition...,
                        body: (any PlannedTask) -> Void) {
            if visibilityBeingTested == .noCodegen {
                results.checkNoTask([.matchTarget(target)] + conditions)
            } else {
                results.checkTask([.matchTarget(target)] + conditions, body: body)
            }
        }

        func checkBuild(action: BuildAction, overrides: [String:String] = [:]) async throws {
            for visibilityBeingTested in IntentsCodegenVisibility.allCases {
                let tester = try await taskConstructionTesterForProject(with: visibilityBeingTested)
                let SRCROOT = tester.workspace.projects[0].sourceRoot.str

                // Test generating for Swift via an explicit override.
                try await tester.checkBuild(BuildParameters(action: action, configuration: "Debug", overrides: overrides.addingContents(of: ["COREML_CODEGEN_LANGUAGE": "Swift"])), runDestination: .macOS, fs: fs, clientDelegate: TestCoreMLCompilerTaskPlanningClientDelegate()) { results in

                    try checkBuild(action: action, with: results, srcroot: SRCROOT, expectedVisibility: visibilityBeingTested, expectedCodegenLanguage: .swift) { results, target in
                        // There should be a CoreMLModelCodegen task.
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff.mlmodel")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff.mlmodel"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff.mlmodel", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--language", "Swift", "--swift-version", swiftVersion, visibilityBeingTested == .public ? "--public-access" : nil, "--globalmodule"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff.mlmodel"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.swift"),
                            ])
                        }
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff2.mlpackage")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff2.mlpackage"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff2.mlpackage", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff2-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--language", "Swift", "--swift-version", swiftVersion, visibilityBeingTested == .public ? "--public-access" : nil, "--globalmodule"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff2.mlpackage"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.swift"),
                            ])
                        }
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff3.mlmodel")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff3.mlmodel"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff3.mlmodel", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff3-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--encrypt", "/path/to.key", "--language", "Swift", "--swift-version", swiftVersion, visibilityBeingTested == .public ? "--public-access" : nil, "--globalmodule"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff3.mlmodel"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.swift"),
                            ])
                        }
                        if action == .build || action == .installAPI {
                            // Check the CompileSwiftSources task, which should include the file generated from the model.
                            do {
                                let responseFilePath = "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/FrameworkTarget.SwiftFileList"
                                var inputFiles = ["\(SRCROOT)/SourceOne.swift"]
                                if visibilityBeingTested != .noCodegen {
                                    inputFiles.append("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.swift")
                                    inputFiles.append("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.swift")
                                    inputFiles.append("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.swift")
                                }
                                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                                    task.checkCommandLineContains([swiftCompilerPath.str, "@" + responseFilePath])
                                    for input in inputFiles {
                                        task.checkCommandLineDoesNotContain(input)
                                    }
                                }

                                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", responseFilePath])) { task, contents in
                                    let lines = contents.asString.components(separatedBy: .newlines)
                                    #expect(lines == inputFiles + [""])
                                }
                            }
                        }
                    }
                }

                // Test generating for Objective-C.
                try await tester.checkBuild(BuildParameters(action: action, configuration: "Debug", overrides: overrides.addingContents(of: ["COREML_CODEGEN_LANGUAGE": "Objective-C"])), runDestination: .macOS, fs: fs, clientDelegate: TestCoreMLCompilerTaskPlanningClientDelegate()) { results in

                    try checkBuild(action: action, with: results, srcroot: SRCROOT, expectedVisibility: visibilityBeingTested, expectedCodegenLanguage: .objectiveC) { results, target in
                        // There should be a CoreMLModelCodegen task.
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff.mlmodel")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff.mlmodel"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff.mlmodel", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--language", "Objective-C"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff.mlmodel"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.h"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.m"),
                            ])
                        }
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff2.mlpackage")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff2.mlpackage"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff2.mlpackage", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff2-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--language", "Objective-C"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff2.mlpackage"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.h"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.m"),
                            ])
                        }
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff3.mlmodel")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff3.mlmodel"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff3.mlmodel", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff3-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--encrypt", "/path/to.key", "--language", "Objective-C"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff3.mlmodel"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.h"),
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.m"),
                            ])
                        }
                        if action == .build {
                            // Confirm that the generated header file is in the generated files headermap.
                            results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(targetName)-generated-files.hmap")) { headermap in
                                // Framework-style inclusions
                                switch visibilityBeingTested {
                                case .public,
                                        .project,
                                        .private:
                                    headermap.checkEntry("\(targetName)/SmartStuff.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.h")
                                    headermap.checkEntry("\(targetName)/SmartStuff2.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.h")
                                    headermap.checkEntry("\(targetName)/SmartStuff3.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.h")
                                    // Quote inclusions
                                    headermap.checkEntry("SmartStuff.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.h")
                                    headermap.checkEntry("SmartStuff2.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.h")
                                    headermap.checkEntry("SmartStuff3.h", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.h")
                                case .noCodegen:
                                    break
                                }

                                headermap.checkNoEntries()
                            }
                        }

                        if action == .build || action == .installAPI {
                            // Check the CompileSwiftSources task, which should include the file generated from the model.
                            do {
                                let responseFilePath = "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/FrameworkTarget.SwiftFileList"
                                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                                    task.checkCommandLineContains([swiftCompilerPath.str, "@" + responseFilePath])
                                    task.checkCommandLineDoesNotContain("\(SRCROOT)/SourceOne.swift")
                                }

                                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", responseFilePath])) { task, contents in
                                    let lines = contents.asString.components(separatedBy: .newlines)
                                    #expect(!lines.contains(where: { Path($0).basename == "SmartStuff.swift" }))
                                    #expect(!lines.contains(where: { Path($0).basename == "SmartStuff2.swift" }))
                                    #expect(!lines.contains(where: { Path($0).basename == "SmartStuff3.swift" }))
                                }
                            }
                        }

                        if action == .build {
                            // Check the CompileC task for the file generated from the model.
                            verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CompileC"), .matchRuleItemBasename("SmartStuff.m")) { task in
                                task.checkRuleInfo([.equal("CompileC"), .suffix("SmartStuff.o"), .suffix("SmartStuff.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                                task.checkCommandLineContains(["-fobjc-arc"])
                            }
                            verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CompileC"), .matchRuleItemBasename("SmartStuff2.m")) { task in
                                task.checkRuleInfo([.equal("CompileC"), .suffix("SmartStuff2.o"), .suffix("SmartStuff2.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                                task.checkCommandLineContains(["-fobjc-arc"])
                            }
                            verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CompileC"), .matchRuleItemBasename("SmartStuff3.m")) { task in
                                task.checkRuleInfo([.equal("CompileC"), .suffix("SmartStuff3.o"), .suffix("SmartStuff3.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                                task.checkCommandLineContains(["-fobjc-arc"])
                            }
                        }
                    }
                }

                // Test generating for Swift using the target's defined predominant source code language.
                try await tester.checkBuild(BuildParameters(action: action, configuration: "Debug", overrides: overrides), runDestination: .macOS, fs: fs, clientDelegate: TestCoreMLCompilerTaskPlanningClientDelegate()) { results in

                    try checkBuild(action: action, with: results, srcroot: SRCROOT, expectedVisibility: visibilityBeingTested, expectedCodegenLanguage: .swift) { results, target in
                        // There should be a CoreMLModelCodegen task.
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff.mlmodel")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff.mlmodel"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff.mlmodel", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--language", "Swift", "--swift-version", swiftVersion, visibilityBeingTested == .public ? "--public-access" : nil, "--globalmodule"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff.mlmodel"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.swift"),
                            ])
                        }
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff2.mlpackage")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff2.mlpackage"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff2.mlpackage", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff2-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--language", "Swift", "--swift-version", swiftVersion, visibilityBeingTested == .public ? "--public-access" : nil, "--globalmodule"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff2.mlpackage"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.swift"),
                            ])
                        }
                        verifyTask(for: visibilityBeingTested, with: results, in: target, matching: .matchRuleType("CoreMLModelCodegen"), .matchRuleItemBasename("SmartStuff3.mlmodel")) { task in
                            task.checkRuleInfo(["CoreMLModelCodegen", "\(SRCROOT)/SmartStuff3.mlmodel"])
                            task.checkSandboxedCommandLine([coremlcPath.str, "generate", "\(SRCROOT)/SmartStuff3.mlmodel", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3", "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                                            "--sdkroot",
                                                            core.loadSDK(.macOS).path.str,
                                                            "--platform", "macos", "--output-partial-info-plist", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/SmartStuff3-CoreMLPartialInfo.plist", "--container", "bundle-resources", "--encrypt", "/path/to.key", "--language", "Swift", "--swift-version", swiftVersion, visibilityBeingTested == .public ? "--public-access" : nil, "--globalmodule"].compactMap { $0 })
                            task.checkInputs([
                                .path("\(SRCROOT)/SmartStuff3.mlmodel"),
                                .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                                .pathPattern(.and(.prefix("\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build"), .suffix(".sb"))),
                                .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                                .name("WorkspaceHeaderMapVFSFilesWritten")
                            ])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.swift"),
                            ])
                        }
                        if action == .build || action == .installAPI {
                            // Check the CompileSwiftSources task, which should include the file generated from the model.
                            do {
                                let responseFilePath = "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/FrameworkTarget.SwiftFileList"
                                var inputFiles = ["\(SRCROOT)/SourceOne.swift"]
                                if visibilityBeingTested != .noCodegen {
                                    inputFiles.append("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.swift")
                                    inputFiles.append("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff2/SmartStuff2.swift")
                                    inputFiles.append("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/CoreMLGenerated/SmartStuff3/SmartStuff3.swift")
                                }
                                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                                    task.checkCommandLineContains([swiftCompilerPath.str, "@" + responseFilePath])
                                    for input in inputFiles {
                                        task.checkCommandLineDoesNotContain(input)
                                        task.checkCommandLineDoesNotContain("-fobjc-arc")
                                    }
                                }

                                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", responseFilePath])) { task, contents in
                                    let lines = contents.asString.components(separatedBy: .newlines)
                                    #expect(lines == inputFiles + [""])
                                }
                            }
                        }
                    }
                }
            }

            let tester = try await taskConstructionTesterForProject(with: .public)

            // Check some builds which emit errors when trying to get the generated file paths for the model.
            await tester.checkBuild(BuildParameters(action: action, configuration: "Debug", overrides: overrides.addingContents(of: ["COREML_CODEGEN_SWIFT_VERSION": ""])), runDestination: .macOS, fs: fs, clientDelegate: TestCoreMLCompilerTaskPlanningClientDelegate()) { results in
                results.checkTarget(targetName) { _ in }

                // Check diagnostics.
                results.checkError(.prefix("SmartStuff.mlmodel: No Swift version specified.  Set COREML_CODEGEN_SWIFT_VERSION to preferred Swift version."))
                results.checkError(.prefix("SmartStuff2.mlpackage: No Swift version specified.  Set COREML_CODEGEN_SWIFT_VERSION to preferred Swift version."))
                results.checkError(.prefix("SmartStuff3.mlmodel: No Swift version specified.  Set COREML_CODEGEN_SWIFT_VERSION to preferred Swift version."))
                results.checkNoDiagnostics()
            }
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: overrides.addingContents(of: ["COREML_CODEGEN_LANGUAGE": "C"])), runDestination: .macOS, fs: fs, clientDelegate: TestCoreMLCompilerTaskPlanningClientDelegate()) { results in
                results.checkTarget(targetName) { _ in }

                // Check diagnostics.
                results.checkError(.prefix("SmartStuff.mlmodel: COREML_CODEGEN_LANGUAGE set to unsupported language \"C\".  Set COREML_CODEGEN_LANGUAGE to preferred language."))
                results.checkError(.prefix("SmartStuff2.mlpackage: COREML_CODEGEN_LANGUAGE set to unsupported language \"C\".  Set COREML_CODEGEN_LANGUAGE to preferred language."))
                results.checkError(.prefix("SmartStuff3.mlmodel: COREML_CODEGEN_LANGUAGE set to unsupported language \"C\".  Set COREML_CODEGEN_LANGUAGE to preferred language."))
                results.checkNoDiagnostics()
            }
        }

        try await checkBuild(action: .build)
        try await checkBuild(action: .installAPI, overrides: ["SUPPORTS_TEXT_BASED_API": "YES"])
        try await checkBuild(action: .installHeaders, overrides: ["EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING": "YES"])
    }

    /// Test generating tasks with the Intents compiler.
    @Test(.requireSDKs(.macOS))
    func intentsCompiler() async throws {
        let targetName = "FrameworkTarget"

        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion

        func taskConstructionTesterForProject(with visibility: IntentsCodegenVisibility, targetType: TestStandardTarget.TargetType = .framework) async throws -> TaskConstructionTester {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("SourceOne.swift"),
                        TestFile("Intents.intentdefinition"),
                        TestFile("MyInfo.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: targetType,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([]),
                            TestSourcesBuildPhase([
                                "SourceOne.swift",
                                TestBuildFile("Intents.intentdefinition", intentsCodegenVisibility: visibility),
                            ]),
                        ],
                        predominantSourceCodeLanguage: .swift
                    ),
                ], classPrefix: "XC")
            return try await TaskConstructionTester(getCore(), testProject)
        }

        func checkBuild(with results: TaskConstructionTester.PlanningResults, srcroot: String, visibility: IntentsCodegenVisibility, codegenLanguage: StandardTarget.SourceCodeLanguage, moduleName: String? = nil) {
            let shouldCodegen: Bool
            switch visibility {
            case .public, .private, .project:
                shouldCodegen = true
            case .noCodegen:
                shouldCodegen = false
            }

            // Match Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }

            results.checkTarget(targetName) { target in
                // Match other task types we don't plan to check.
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("Ld")) { _ in }
                results.checkTasks(.matchRuleType("GenerateTAPI")) { _ in }
                results.checkTasks(.matchRuleType("Touch")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

                if case .objectiveC = codegenLanguage {
                    switch visibility {
                    case .public:
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("XCOrderBurgerIntent.h")) { task in
                            task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Headers"])
                        }
                    case .private:
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("XCOrderBurgerIntent.h")) { task in
                            task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.h", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/PrivateHeaders"])
                        }
                    default:
                        results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("XCOrderBurgerIntent.h"))
                    }
                }
                results.checkTasks(.matchRuleType("Copy")) { _ in }
                results.checkTasks(.matchRuleType("SwiftMergeGeneratedHeaders")) { _ in }

                if shouldCodegen {
                    var specialArgs: [String] = []
                    if let moduleName = moduleName {
                        specialArgs = ["-moduleName", moduleName]
                    }
                    // There should be a IntentDefinitionCodegen task.
                    results.checkTask(.matchTarget(target), .matchRuleType("IntentDefinitionCodegen")) { task in
                        task.checkRuleInfo(["IntentDefinitionCodegen", "\(srcroot)/Intents.intentdefinition"])
                        task.checkInputs([
                            .path("\(srcroot)/Intents.intentdefinition"),
                            .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                            .name("WorkspaceHeaderMapVFSFilesWritten")
                        ])
                        switch codegenLanguage {
                        case .objectiveC:
                            var args = ["intentbuilderc", "generate", "-input", "\(srcroot)/Intents.intentdefinition", "-output", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents", "-classPrefix", "XC", "-language", "Objective-C", "-visibility", visibility.rawValue]
                            args += specialArgs
                            task.checkCommandLine(args)
                            task.checkOutputs([
                                .path("\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.h"),
                                .path("\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.m"),
                            ])
                        case .swift:
                            var args = ["intentbuilderc", "generate", "-input", "\(srcroot)/Intents.intentdefinition", "-output", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents", "-classPrefix", "XC", "-language", "Swift", "-swiftVersion", swiftVersion, "-visibility", visibility.rawValue]
                            args += specialArgs
                            task.checkCommandLine(args)
                            task.checkOutputs([
                                .path("\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.swift"),
                            ])
                        default:
                            Issue.record("unexpected codegen language: \(codegenLanguage)")
                        }
                    }
                }

                if case .objectiveC = codegenLanguage, shouldCodegen {
                    // Confirm that the generated header file is in the generated files headermap.
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(targetName)-generated-files.hmap")) { headermap in
                        // Framework-style inclusions
                        headermap.checkEntry("\(targetName)/XCOrderBurgerIntent.h", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.h")

                        // Quote inclusions
                        headermap.checkEntry("XCOrderBurgerIntent.h", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.h")

                        headermap.checkNoEntries()
                    }
                }

                // Check the CompileSwiftSources task, which should include the file generated from the model.
                do {
                    let responseFilePath = "\(srcroot)/build/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/FrameworkTarget.SwiftFileList"
                    let inputFiles = ["\(srcroot)/SourceOne.swift", "\(srcroot)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents/XCOrderBurgerIntent.swift"]
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains([swiftCompilerPath.str, "@" + responseFilePath])
                        for input in inputFiles {
                            task.checkCommandLineDoesNotContain(input)
                        }
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { _ in }

                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", responseFilePath])) { task, contents in
                        let lines = contents.asString.components(separatedBy: .newlines)
                        if !shouldCodegen {
                            #expect(lines.contains("\(srcroot)/SourceOne.swift"))
                            #expect(!lines.contains(where: { Path($0).basename == "XCOrderBurgerIntent.swift" }))
                        } else {
                            switch codegenLanguage {
                            case .objectiveC:
                                #expect(lines.contains("\(srcroot)/SourceOne.swift"))
                                #expect(!lines.contains(where: { Path($0).basename == "XCOrderBurgerIntent.swift" }))
                            case .swift:
                                #expect(lines == inputFiles + [""])
                            default:
                                Issue.record()
                            }
                        }
                    }
                }

                // Check the CompileC task for the file generated from the model.
                if case .objectiveC = codegenLanguage, shouldCodegen {
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkRuleInfo([.equal("CompileC"), .suffix("OrderBurgerIntent.o"), .suffix("OrderBurgerIntent.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                    }
                }

                // There should be one IntentDefinitionCompile task.
                results.checkTask(.matchTarget(target), .matchRuleType("IntentDefinitionCompile")) { task in
                    task.checkRuleInfo(["IntentDefinitionCompile", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "\(srcroot)/Intents.intentdefinition"])
                    task.checkCommandLine(["intentbuilderc", "compile", "-input", "\(srcroot)/Intents.intentdefinition", "-output", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/", "-classPrefix", "XC"])
                    task.checkInputs([
                        .path("\(srcroot)/Intents.intentdefinition"),
                        .path("\(srcroot)/Intents.intentdefinition"),
                        .namePattern(.and(.prefix("target-"), .suffix("-copy-headers"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])
                    task.checkOutputs([
                        .path("\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/Intents.intentdefinition"),
                    ])
                }

                // There should be a ProcessInfoPlistFile task which incorporates the PartialInfo.plist generated by coremlc.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkCommandLine(["builtin-infoPlistUtility", "\(srcroot)/MyInfo.plist", "-producttype", "com.apple.product-type.framework", "-expandbuildsettings", "-platform", "macosx", "-o", "\(srcroot)/build/Debug/\(targetName).framework/Versions/A/Resources/Info.plist"])
                }

                // Match any other tasks.
                results.consumeTasksMatchingRuleTypes(["WriteAuxiliaryFile"])

                // Check that there are no other tasks.
                results.checkNoTask()
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        /// Client to generate files from the intent definition.
        final class TestIntentsCompilerTaskPlanningClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            let visibility: IntentsCodegenVisibility
            let moduleName: String?

            init(visibility: IntentsCodegenVisibility, moduleName: String? = nil) {
                self.visibility = visibility
                self.moduleName = moduleName
            }

            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first.map(Path.init)?.basename == "intentbuilderc",
                   let outputDir = commandLine.elementAfterElements(["-output"]).map(Path.init),
                   let classPrefix = commandLine.elementAfterElements(["-classPrefix"]),
                   let language = commandLine.elementAfterElements(["-language"]),
                   let visibility = commandLine.elementAfterElements(["-visibility"]) {
                    if visibility != self.visibility.rawValue {
                        throw StubError.error("Undefined visibility '\(visibility)'")
                    }
                    let moduleName = commandLine.elementAfterElements(["-moduleName"])
                    if moduleName != self.moduleName {
                        throw StubError.error("Wrong module name \(moduleName ?? "<null>")")
                    }
                    switch language {
                    case "Swift":
                        return .result(status: .exit(0), stdout: Data(outputDir.join("\(classPrefix)OrderBurgerIntent.swift").str.utf8), stderr: .init())
                    case "Objective-C":
                        return .result(status: .exit(0), stdout: Data([outputDir.join("\(classPrefix)OrderBurgerIntent.h").str, outputDir.join("\(classPrefix)OrderBurgerIntent.m").str].joined(separator: "\n").utf8), stderr: .init())
                    default:
                        throw StubError.error("unknown language '\(language)'")
                    }
                }
                return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
            }
        }

        var tester = try await taskConstructionTesterForProject(with: .public)
        var SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Test passing the module name to intentbuilderc.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "Swift", "DEFINES_MODULE": "YES", "PRODUCT_MODULE_NAME": "TestModule"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .public, moduleName: "TestModule")) { results in
            checkBuild(with: results, srcroot: SRCROOT, visibility: .public, codegenLanguage: .swift, moduleName: "TestModule")
        }

        // We should not pass module name to intentbuilderc when building the app target
        // even if it has DEFINES_MODULE = YES.
        let applicationTester = try await taskConstructionTesterForProject(with: .public, targetType: .application)
        await applicationTester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "Objective-C", "DEFINES_MODULE": "YES", "PRODUCT_MODULE_NAME": "TestModule"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .public)) { results in
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("IntentDefinitionCodegen")) { task in
                    task.checkCommandLine(["intentbuilderc", "generate", "-input", "\(SRCROOT)/Intents.intentdefinition", "-output", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/IntentDefinitionGenerated/Intents", "-classPrefix", "XC", "-language", "Objective-C", "-visibility", "public"])
                }
            }
        }

        // Test generating for Swift via an explicit override.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "Swift"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .public)) { results in
            checkBuild(with: results, srcroot: SRCROOT, visibility: .public, codegenLanguage: .swift)
        }

        // Test generating for Objective-C.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "Objective-C"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .public)) { results in
            checkBuild(with: results, srcroot: SRCROOT, visibility: .public, codegenLanguage: .objectiveC)
        }

        // Test generating for Swift using the target's defined predominant source code language.
        await tester.checkBuild(runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .public)) { results in
            checkBuild(with: results, srcroot: SRCROOT, visibility: .public, codegenLanguage: .swift)
        }

        // Check some builds which emit errors when trying to get the generated file paths for the model.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "C"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .public)) { results in
            results.checkTarget(targetName) { _ in }

            // Check diagnostics.
            results.checkError(.prefix("Intents.intentdefinition: Unknown language \"C\". Please set \"Intent Class Generation Language\" (INTENTS_CODEGEN_LANGUAGE) to Objective-C or Swift"))
            results.checkNoDiagnostics()
        }

        tester = try await taskConstructionTesterForProject(with: .private)
        SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "Objective-C"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .private)) { results in
            checkBuild(with: results, srcroot: SRCROOT, visibility: .private, codegenLanguage: .objectiveC)
        }

        tester = try await taskConstructionTesterForProject(with: .project)
        SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "Objective-C"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .project)) { results in
            checkBuild(with: results, srcroot: SRCROOT, visibility: .project, codegenLanguage: .objectiveC)
        }

        tester = try await taskConstructionTesterForProject(with: .noCodegen)
        SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INTENTS_CODEGEN_LANGUAGE": "Objective-C"]), runDestination: .macOS, clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate(visibility: .noCodegen)) { results in
            checkBuild(with: results, srcroot: SRCROOT, visibility: .noCodegen, codegenLanguage: .objectiveC)
        }
    }

    @Test(.requireSDKs(.macOS))
    func metalCompiler() async throws {
        let core = try await getCore()
        let targetName = "MetalStuff"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Some.metal"),
                    TestFile("Others.metal"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "macosx",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("SourceFile.m"),
                            TestBuildFile("Some.metal", additionalArgs: ["-DHello"]),
                            TestBuildFile("Others.metal"),
                        ]),
                    ])
            ])
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

        func checkIndexingInfo(indexingInfo: any SourceFileIndexingInfo, expectedBuildDir: String, expectedArgs: [String], sourceLocation: SourceLocation = #_sourceLocation) {
            // Check we have a property list
            guard let propertyListDict = indexingInfo.propertyListItem.dictValue else {
                Issue.record("indexing property list missing or not a dictionary", sourceLocation: sourceLocation)
                return
            }
            // Check we have a language dialect, build products dir, and command args
            guard let lang = propertyListDict["LanguageDialect"]?.stringValue else {
                Issue.record("could not find 'LanguageDialect' entry in indexing property list, or it is not a string", sourceLocation: sourceLocation)
                return
            }
            guard let buildDir = propertyListDict["metalASTBuiltProductsDir"]?.stringValue else {
                Issue.record("could not find 'metalASTBuiltProductsDir' entry in indexing property list, or it is not a string", sourceLocation: sourceLocation)
                return
            }
            guard let args = propertyListDict["metalASTCommandArguments"]?.stringArrayValue else {
                Issue.record("could not find 'metalASTCommandArguments' entry in indexing property list, or it is not an array", sourceLocation: sourceLocation)
                return
            }

            // Check language is metal
            #expect(lang == "metal")

            // Check build products dir
            #expect(buildDir == expectedBuildDir)

            // Check command args
            let argsSet = Set<String>(args)
            // check command args set contain the follow indexer-related args
            let expectedIndexerArgs = ["-fsyntax-only", "-fretain-comments-from-system-headers", "-Xclang", "-detailed-preprocessing-record"]
            var notFoundIndexerArgs = [String]()
            for arg in expectedIndexerArgs {
                if !argsSet.contains(arg) {
                    notFoundIndexerArgs.append(arg)
                }
            }
            #expect(notFoundIndexerArgs.isEmpty, "could not find expected indexer args \(notFoundIndexerArgs) in args: \(args)", sourceLocation: sourceLocation)
            // check these args are not included in command args set
            let ignoredArgs = ["-c", "-MMD", "-fmodules-validate-once-per-build-session", "-MT", "-MF", "--serialize-diagnostics"]
            var unexpectedArgs = [String]()
            for arg in ignoredArgs {
                if argsSet.contains(arg) {
                    unexpectedArgs.append(arg)
                }
            }
            #expect(unexpectedArgs.isEmpty, "unexpected args \(unexpectedArgs) in args: \(args)", sourceLocation: sourceLocation)
            // check expected args are part of the command args set
            var notFoundArgs = [String]()
            for arg in expectedArgs {
                if !argsSet.contains(arg) {
                    notFoundArgs.append(arg)
                }
            }
            #expect(notFoundArgs.isEmpty, "could not find expected args \(notFoundArgs) in args: \(args)", sourceLocation: sourceLocation)
        }

        func checkIndexingInfo(indexingInfo: any SourceFileIndexingInfo, expectedOutputPath: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            // Check we have a property list
            let propertyListDict = try #require(indexingInfo.propertyListItem.dictValue, "indexing property list missing or not a dictionary", sourceLocation: sourceLocation)
            #expect(propertyListDict["metalASTCommandArguments"] == nil, "arguments included when only output path was requested", sourceLocation: sourceLocation)
            let outputPath = try #require(propertyListDict["outputFilePath"]?.stringValue, "could not find 'outputFilePath' entry in indexing property list, or it is not a string", sourceLocation: sourceLocation)
            // Check output path.
            #expect(outputPath == expectedOutputPath)
        }

        // tracked in rdar://58784841.
        let perFileFlagsAvailableWorkaround = try core.xcodeProductBuildVersion >= ProductBuildVersion("12A65")

        // Check the tasks.
        try await tester.checkBuild(runDestination: .macOS) { results in
            try results.checkTarget(targetName) { target in
                // There should be two CompileMetalFile tasks.
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("Some.metal")) { task in
                    let outFile = "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Some.air"
                    let commandLineArgs = ["metal", "-c", "-target", "air64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-I\(SRCROOT)/build/Debug/include", "-F\(SRCROOT)/build/Debug", "-isysroot", core.loadSDK(.macOS).path.str, "-fmetal-math-mode=fast", "-fmetal-math-fp32-functions=fast", "-serialize-diagnostics", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Some.dia", "-o", outFile] + (perFileFlagsAvailableWorkaround ? ["-DHello"] : [])  + ["-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Some.dat", "\(SRCROOT)/Sources/Some.metal"]

                    task.checkRuleInfo(["CompileMetalFile", "\(SRCROOT)/Sources/Some.metal"])
                    task.checkCommandLine(commandLineArgs)

                    // Validate indexing info
                    let ignoreArgs = ["metal", "-c", "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Some.dat"]
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .fullInfo)
                        let indexingInfo = try #require(indexInfo.first).indexingInfo
                        #expect(indexInfo.count == 1)
                        let expectedArgs = commandLineArgs.filter { !ignoreArgs.contains($0) }
                        checkIndexingInfo(indexingInfo: indexingInfo, expectedBuildDir: "\(SRCROOT)/build/Debug", expectedArgs: expectedArgs)
                    }
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .outputPathInfo)
                        let indexingInfo = try #require(indexInfo.first).indexingInfo
                        #expect(indexInfo.count == 1)
                        try checkIndexingInfo(indexingInfo: indexingInfo, expectedOutputPath: outFile)
                    }
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .init(requestedSourceFile: Path("\(SRCROOT)/Sources/Some.metal"), outputPathOnly: false))
                        let indexingInfo = try #require(indexInfo.first).indexingInfo
                        #expect(indexInfo.count == 1)
                        let expectedArgs = commandLineArgs.filter { !ignoreArgs.contains($0) }
                        checkIndexingInfo(indexingInfo: indexingInfo, expectedBuildDir: "\(SRCROOT)/build/Debug", expectedArgs: expectedArgs)
                    }
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .init(requestedSourceFile: Path("\(SRCROOT)/Sources/Others.metal"), outputPathOnly: false))
                        #expect(indexInfo.isEmpty, "Expected to not get indexing info")
                    }
                }
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("Others.metal")) { task in

                    let outFile = "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Others.air"
                    let commandLineArgs = ["metal", "-c", "-target", "air64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-I\(SRCROOT)/build/Debug/include", "-F\(SRCROOT)/build/Debug", "-isysroot", core.loadSDK(.macOS).path.str, "-fmetal-math-mode=fast", "-fmetal-math-fp32-functions=fast", "-serialize-diagnostics", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Others.dia", "-o", outFile, "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Others.dat", "\(SRCROOT)/Sources/Others.metal"]

                    task.checkRuleInfo(["CompileMetalFile", "\(SRCROOT)/Sources/Others.metal"])
                    task.checkCommandLine(commandLineArgs)

                    // Validate indexing info
                    let ignoreArgs = ["metal", "-c", "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Others.dat"]
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .fullInfo)
                        let indexingInfo = try #require(indexInfo.first).indexingInfo
                        #expect(indexInfo.count == 1)
                        let expectedArgs = commandLineArgs.filter { !ignoreArgs.contains($0) }
                        checkIndexingInfo(indexingInfo: indexingInfo, expectedBuildDir: "\(SRCROOT)/build/Debug", expectedArgs: expectedArgs)
                    }
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .outputPathInfo)
                        let indexingInfo = try #require(indexInfo.first).indexingInfo
                        #expect(indexInfo.count == 1)
                        try checkIndexingInfo(indexingInfo: indexingInfo, expectedOutputPath: outFile)
                    }
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .init(requestedSourceFile: Path("\(SRCROOT)/Sources/Others.metal"), outputPathOnly: false))
                        let indexingInfo = try #require(indexInfo.first).indexingInfo
                        #expect(indexInfo.count == 1)
                        let expectedArgs = commandLineArgs.filter { !ignoreArgs.contains($0) }
                        checkIndexingInfo(indexingInfo: indexingInfo, expectedBuildDir: "\(SRCROOT)/build/Debug", expectedArgs: expectedArgs)
                    }
                    do {
                        let indexInfo = task.generateIndexingInfo(input: .init(requestedSourceFile: Path("\(SRCROOT)/Sources/Some.metal"), outputPathOnly: false))
                        #expect(indexInfo.isEmpty, "Expected to not get indexing info")
                    }
                }

                // The should be one MetalLink task.
                results.checkTask(.matchTarget(target), .matchRuleType("MetalLink"), .matchRuleItemBasename("default.metallib")) { task in
                    task.checkRuleInfo(["MetalLink", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Resources/default.metallib"])
                    if task.commandLineAsStrings.contains("-split-module") {
                        task.checkCommandLine(["metal", "-split-module", "-o", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Resources/default.metallib", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Some.air", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Others.air"])
                    } else {
                        task.checkCommandLine(["metal", "-target", "air64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-o", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Resources/default.metallib", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Some.air", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Metal/Others.air"])
                    }
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func metalCompilerWithSameBasenameSources() async throws {
        let targetName = "MetalStuff"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.c"),
                    TestFile("Foo.metal", guid: "UPPER"),
                    TestFile("foo.metal", guid: "LOWER"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "macosx",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Foo.c"),
                            TestBuildFile("Foo.metal"),
                            TestBuildFile("foo.metal"),
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("Foo.metal")) { task in
                    task.checkCommandLineContains(["\(SRCROOT)/build/aProject.build/Debug/MetalStuff.build/Metal/Foo-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: Path(SRCROOT).join("Sources").join("Foo.metal"))).air"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("foo.metal")) { task in
                    task.checkCommandLineContains(["\(SRCROOT)/build/aProject.build/Debug/MetalStuff.build/Metal/foo-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: Path(SRCROOT).join("Sources").join("foo.metal"))).air"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .tvOS, .watchOS, .xrOS))
    func metalCompilerLanguageRevision() async throws {
        let core = try await getCore()

        func checkLanguageRevision(sdkName:String, languageRevision:String, expectedOption:String) async throws {
            let targetName = "MetalStuff"
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [TestFile("foo.metal")]),
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "SDKROOT": sdkName,
                                                    "MTL_LANGUAGE_REVISION": languageRevision,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("foo.metal")]),
                        ])
                ])

            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget(targetName) { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("foo.metal")) { task in
                        if languageRevision == "UseDeploymentTarget" {
                            task.checkCommandLineNoMatch([.prefix("-std=")])
                        } else {
                            task.checkCommandLineContains([expectedOption])
                        }
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("MetalLink")) { task in
                        if languageRevision == "UseDeploymentTarget" {
                            task.checkCommandLineNoMatch([.prefix("-std=")])
                        } else {
                            task.checkCommandLineContains([expectedOption])
                        }
                    }
                }
            }
        }

        let optionForLanguage = [ ["macosx", "UseDeploymentTarget"] : "",
                                  ["macosx", "Metal11"] : "-std=macos-metal1.1",
                                  ["macosx", "Metal12"] : "-std=macos-metal1.2",
                                  ["macosx", "Metal20"] : "-std=macos-metal2.0",
                                  ["macosx", "Metal21"] : "-std=macos-metal2.1",
                                  ["macosx", "Metal22"] : "-std=macos-metal2.2",
                                  ["macosx", "Metal23"] : "-std=macos-metal2.3",
                                  ["macosx", "Metal24"] : "-std=macos-metal2.4",
                                  ["macosx", "Metal30"] : "-std=metal3.0",
                                  ["macosx", "Metal31"] : "-std=metal3.1",
                                  ["macosx", "Metal32"] : "-std=metal3.2",

                                  ["iphoneos", "UseDeploymentTarget"] : "",
                                  ["iphoneos", "iOSMetal10"] : "-std=ios-metal1.0",
                                  ["iphoneos", "Metal11"] : "-std=ios-metal1.1",
                                  ["iphoneos", "Metal12"] : "-std=ios-metal1.2",
                                  ["iphoneos", "Metal20"] : "-std=ios-metal2.0",
                                  ["iphoneos", "Metal21"] : "-std=ios-metal2.1",
                                  ["iphoneos", "Metal22"] : "-std=ios-metal2.2",
                                  ["iphoneos", "Metal23"] : "-std=ios-metal2.3",
                                  ["iphoneos", "Metal24"] : "-std=ios-metal2.4",
                                  ["iphoneos", "Metal30"] : "-std=metal3.0",
                                  ["iphoneos", "Metal31"] : "-std=metal3.1",
                                  ["iphoneos", "Metal32"] : "-std=metal3.2",

                                  ["appletvos", "UseDeploymentTarget"] : "",
                                  ["appletvos", "Metal11"] : "-std=ios-metal1.1",
                                  ["appletvos", "Metal12"] : "-std=ios-metal1.2",
                                  ["appletvos", "Metal20"] : "-std=ios-metal2.0",
                                  ["appletvos", "Metal21"] : "-std=ios-metal2.1",
                                  ["appletvos", "Metal22"] : "-std=ios-metal2.2",
                                  ["appletvos", "Metal23"] : "-std=ios-metal2.3",
                                  ["appletvos", "Metal24"] : "-std=ios-metal2.4",
                                  ["appletvos", "Metal30"] : "-std=metal3.0",
                                  ["appletvos", "Metal31"] : "-std=metal3.1",
                                  ["appletvos", "Metal32"] : "-std=metal3.2",

                                  ["xros", "UseDeploymentTarget"] : "",
                                  ["xros", "Metal31"] : "-std=metal3.1",
                                  ["xros", "Metal32"] : "-std=metal3.2",
        ]

        for (language, expectedOption) in optionForLanguage {
            let (sdkName, languageRevision) = (language[0], language[1])
            try await checkLanguageRevision(sdkName:sdkName, languageRevision:languageRevision, expectedOption:expectedOption)
        }
    }

    @Test(.requireSDKs(.macOS))
    func metalCompilerEnableModules() async throws {
        let core = try await getCore()

        func checkEnableModules(enableModules:String, expectedOption:String) async throws {
            let targetName = "MetalStuff"
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [TestFile("foo.metal")]),
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "SDKROOT": "macosx",
                                                    "MTL_ENABLE_MODULES": enableModules,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("foo.metal")]),
                        ])
                ])

            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget(targetName) { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("foo.metal")) { task in
                        if enableModules == "STDLIB" {
                            task.checkCommandLineNoMatch([.prefix("-fmodules=")])
                        } else {
                            task.checkCommandLineContains([expectedOption])
                        }
                    }
                }
            }
        }

        let optionForEnableModules = [ "YES"    : "-fmodules=all",
                                       "STDLIB" : "",
                                       "NO"     : "-fmodules=none",
        ]

        for (enableModules, expectedOption) in optionForEnableModules {
            try await checkEnableModules(enableModules:enableModules, expectedOption:expectedOption)
        }
    }

    @Test(.requireSDKs(.macOS))
    func metalCompilerOptimizationLevelDefault() async throws {
        let targetName = "MetalStuff"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("foo.metal")]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "MTL_OPTIMIZATION_LEVEL": "default",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.metal")]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("foo.metal")) { task in
                    task.checkCommandLineNoMatch([.prefix("-O")])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func metalCompilerOptimizationLevelSize() async throws {
        let targetName = "MetalStuff"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("foo.metal")]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "MTL_OPTIMIZATION_LEVEL": "s",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.metal")]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("foo.metal")) { task in
                    task.checkCommandLineContains(["-Os"])
                }
            }
        }
    }

    func checkBasicOption(core:Core, property:String, value:String,
                          expectedOptions:[String]) async throws {
        let targetName = "MetalStuff"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("foo.metal")]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                property: value,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("foo.metal")]),
                    ])
            ])

        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileMetalFile"), .matchRuleItemBasename("foo.metal")) { task in
                    task.checkCommandLineContains(expectedOptions)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func metalCompilerMathModes() async throws {
        let core = try await getCore()

        let options = [ "UseLanguageDefault" : [],
                        "RELAXED" : ["-fmetal-math-mode=relaxed"],
                        "FAST" : ["-fmetal-math-mode=fast"],
                        "SAFE" : ["-fmetal-math-mode=safe"] ]

        for (value, expectedOptions) in options {
            try await checkBasicOption(core:core, property:"MTL_MATH_MODE",
                                       value:value, expectedOptions:expectedOptions)
        }
    }

    @Test(.requireSDKs(.macOS))
    func metalCompilerFP32MathFunctions() async throws {
        let core = try await getCore()

        let options = [ "UseLanguageDefault" : [],
                        "FAST" : ["-fmetal-math-fp32-functions=fast"],
                        "PRECISE" : ["-fmetal-math-fp32-functions=precise"] ]

        for (value, expectedOptions) in options {
            try await checkBasicOption(core:core, property:"MTL_MATH_FP32_FUNCTIONS",
                                       value:value, expectedOptions:expectedOptions)
        }
    }

    // Test the following:
    // MTL_FAST_MATH = YES => MTL_MATH_MODE = FAST; MTL_MATH_FP32_FUNCTIONS = FAST
    // MTL_FAST_MATH = NO  => MTL_MATH_MODE = SAFE; MTL_MATH_FP32_FUNCTIONS = PRECISE
    @Test(.requireSDKs(.macOS))
    func metalCompilerFastMath() async throws {
        let core = try await getCore()

        let options = [ "YES" : [ "-fmetal-math-mode=fast",
                                  "-fmetal-math-fp32-functions=fast" ],
                        "NO" : [ "-fmetal-math-mode=safe",
                                 "-fmetal-math-fp32-functions=precise" ] ]

        for (value, expectedOption) in options {
            try await checkBasicOption(core:core, property:"MTL_FAST_MATH",
                                       value:value, expectedOptions:expectedOption)
        }
    }

    /// Check that we handle architecture-neutral compiler specifications.
    @Test(.requireSDKs(.macOS, .iOS))
    func archNeutralCompilerSpecs() async throws {
        let targetName = "CoreFoo"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Scanner.l"),
                    TestFile("Parser.y"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "ARCHS": "arm64",
                                                "CODE_SIGN_IDENTITY": "",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "iphoneos",
                                                "LEXFLAGS": "--header-file=\"$(DERIVED_FILE_DIR)/LexOut.h\"",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Scanner.l"),
                            TestBuildFile("Parser.y")]
                                             ),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the tasks.
        await tester.checkBuild(runDestination: .anyiOSDevice) { results in
            // Ignore most tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("Touch")) { _ in }
            results.checkTasks(.matchRuleType("GenerateDSYMFile")) { _ in }
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            results.checkTarget(targetName) { target in
                // Find the lex task and its resulting compile task.
                var lexTaskOpt: (any PlannedTask)? = nil
                var lexCompileTasks = [any PlannedTask]()
                results.checkTask(.matchTarget(target), .matchRuleType("Lex")) { task in
                    lexTaskOpt = task
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("Scanner.yy.c")) { tasks in
                    lexCompileTasks.append(contentsOf: tasks)
                }
                guard let lexTask = lexTaskOpt else {
                    Issue.record("unable to find expected lex task")
                    return
                }
                // Make sure they have the inputs and outputs we expect.
                XCTAssertMatch(lexTask.inputs.map({ $0.name }), [
                        .equal("Scanner.l"),
                        .and(.prefix("target"), .suffix("Producer")),
                        .and(.prefix("target"), .suffix("-begin-compiling")),
                    ])
                XCTAssertMatch(lexTask.outputs.map({ $0.name }), [
                        .equal("Scanner.yy.c"),
                        .equal("LexOut.h"),
                    ])
                #expect(lexCompileTasks.count == 1)
                for lexCompileTask in lexCompileTasks {
                    XCTAssertMatch(lexCompileTask.inputs.map({ $0.name }), [
                            .equal("Scanner.yy.c"),
                            .and(.prefix("target"), .suffix("-generated-headers")),
                            .and(.prefix("target"), .suffix("-swift-generated-headers")),
                            .and(.prefix("target"), .suffix("Producer")),
                            .and(.prefix("target"), .suffix("-begin-compiling")),
                        ])
                    XCTAssertMatch(lexCompileTask.outputs.map({ $0.name }), [
                            .equal("Scanner.yy.o"),
                        ])
                }

                // Find the yacc task and its resulting compile task.
                var yaccTaskOpt: (any PlannedTask)? = nil
                var yaccCompileTasks = [any PlannedTask]()
                results.checkTask(.matchTarget(target), .matchRuleType("Yacc")) { task in
                    yaccTaskOpt = task
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("y.tab.c")) { tasks in
                    yaccCompileTasks.append(contentsOf: tasks)
                }
                guard let yaccTask = yaccTaskOpt else {
                    Issue.record("unable to find expected yacc task")
                    return
                }
                // Make sure they have the inputs and outputs we expect.
                XCTAssertMatch(yaccTask.inputs.map({ $0.name }), [
                        .equal("Parser.y"),
                        .and(.prefix("target"), .suffix("Producer")),
                        .and(.prefix("target"), .suffix("-begin-compiling")),
                    ])
                XCTAssertMatch(yaccTask.outputs.map({ $0.name }), [
                        .equal("y.tab.c"),
                        .equal("y.tab.h"),
                    ])
                #expect(yaccCompileTasks.count == 1)
                for yaccCompileTask in yaccCompileTasks {
                    XCTAssertMatch(yaccCompileTask.inputs.map({ $0.name }), [
                            .equal("y.tab.c"),
                            .and(.prefix("target"), .suffix("-generated-headers")),
                            .and(.prefix("target"), .suffix("-swift-generated-headers")),
                            .and(.prefix("target"), .suffix("Producer")),
                            .and(.prefix("target"), .suffix("-begin-compiling")),
                        ])
                    XCTAssertMatch(yaccCompileTask.outputs.map({ $0.name }), [
                            .equal("y.tab.o"),
                        ])
                }

                // Validate that the linker and lipo tasks are set up.
                results.checkTasks(.matchTarget(target), .matchRuleType("Ld")) { tasks in
                    #expect(tasks.count == 1)
                    for task in tasks {
                        XCTAssertMatch(task.inputs.map({ $0.name }), [
                                .equal("Scanner.yy.o"),
                                .equal("y.tab.o"),
                                .suffix(".LinkFileList"),
                                .suffix("Debug-iphoneos"),
                                .and(.prefix("target"), .suffix("-generated-headers")),
                                .and(.prefix("target"), .suffix("-swift-generated-headers")),
                                .and(.prefix("target"), .suffix("Producer")),
                                .and(.prefix("target"), .suffix("-begin-linking")),
                            ])
                        task.checkOutputs([
                            .name("CoreFoo"),
                            .name("Linked Binary /tmp/Test/aProject/build/Debug-iphoneos/CoreFoo.framework/CoreFoo"),
                            .name("CoreFoo_lto.o"),
                            .name("CoreFoo_dependency_info.dat"),
                        ])
                    }
                }
            }

            results.checkTasks(.matchRuleType("GenerateTAPI")) { _ in }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()

            // There should be no other tasks.
            results.checkNoTask()
        }
    }

    /// Check the OpenCL compilation commands.
    @Test(.requireSDKs(.macOS))
    func openCL() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.cl"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "ARCHS": "x86_64 x86_64h",
                                        "VALID_ARCHS": "$(inherited) x86_64h",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "CODE_SIGN_IDENTITY": "-",
                                        "SWIFT_VERSION": swiftVersion,
                                        "USE_HEADERMAP": "NO",
                                        "LIBTOOL": libtoolPath.str,
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.cl",]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .anyMac) { results in
            results.checkTarget("Foo") { target in
                // There should be one OpenCL code generation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Compile")) { task in
                    task.checkRuleInfo(["Compile", "\(SRCROOT)/Sources/Foo.cl"])
                    task.checkInputs([.path("\(SRCROOT)/Sources/Foo.cl"), .any, .any, .any])
                    task.checkOutputs([
                        .pathPattern(.suffix("Foo.cl.c")),
                        .pathPattern(.suffix("Foo.cl.h"))
                    ])
                    task.checkCommandLine([
                        "/System/Library/Frameworks/OpenCL.framework/Libraries/openclc",
                        "-x", "cl", "-cl-std=CL1.1", "-cl-auto-vectorize-enable",
                        "-gcl-bc-dir", "OpenCL",
                        "-emit-gcl", "\(SRCROOT)/Sources/Foo.cl",
                        "-gcl-output-dir", "\(SRCROOT)/build/aProject.build/Debug/Foo.build/DerivedSources"
                    ])
                }

                // There should be one C compile task per arch (for the generated source)
                for arch in ["x86_64", "x86_64h"] {
                    results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/Foo.build/Objects-normal/\(arch)/Foo.cl.o", "\(SRCROOT)/build/aProject.build/Debug/Foo.build/DerivedSources/Foo.cl.c", "normal", arch, "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                }

                // There should one CreateBitcode task per OpenCL arch.
                results.checkTasks(.matchTarget(target), .matchRuleType("CreateBitcode")) { tasks in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    // We expect one task per supported arch (32/64 x gpu/cpu)
                    // The OpenCL compiler task itself is architecture-neutral, but it does its own multiplexing over a set of architectures disjoint from the ARCHS build setting.
                    #expect(sortedTasks.count == 4)
                    for (i, arch) in ["gpu_32", "gpu_64", "i386", "x86_64"].enumerated() {
                        sortedTasks[i].checkRuleInfo(["CreateBitcode", "\(SRCROOT)/Sources/Foo.cl", arch])
                        sortedTasks[i].checkCommandLine([
                            "/System/Library/Frameworks/OpenCL.framework/Libraries/openclc",
                            "-x", "cl", "-cl-std=CL1.1", "-Os",
                            "-I\(SRCROOT)/build/Debug/include",
                            "-I\(SRCROOT)/build/aProject.build/Debug/Foo.build/DerivedSources-normal",
                            "-I\(SRCROOT)/build/aProject.build/Debug/Foo.build/DerivedSources",
                            "-F\(SRCROOT)/build/Debug", "-arch", arch, "-emit-llvm", "-c",
                            "\(SRCROOT)/Sources/Foo.cl", "-o", "\(SRCROOT)/build/Debug/OpenCL/Foo.cl.\(arch).bc"])
                    }
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test the logic for selecting the linker based on the project configuration.
    @Test(.requireSDKs(.macOS))
    func linkerSelection() async throws {
        // A project which does not use C++.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ClassOne.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "Application",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["ClassOne.m",]),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Default build uses clang.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LD to use a different linker path.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LD": "/usr/bin/ld"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["/usr/bin/ld", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LDPLUSPLUS to use a different linker path - has no effect here
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LDPLUSPLUS": "/usr/bin/ldplusplus"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // A project which does use C++.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ClassOne.m"),
                        TestFile("ClassTwo.mm"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "Application",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["ClassOne.m","ClassTwo.mm",]),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Default build uses clang++.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LD to use a different linker path - has no effect here.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LD": "/usr/bin/ld"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LDPLUSPLUS to use a different linker path
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LDPLUSPLUS": "/usr/bin/ldplusplus"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["/usr/bin/ldplusplus", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // A project which does use C++ but with a non-C++ file extension.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ClassOne.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "OTHER_CFLAGS": "-x objective-c++"
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "Application",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["ClassOne.m",]),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Default build uses clang++.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LD to use a different linker path - has no effect here.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LD": "/usr/bin/ld"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LDPLUSPLUS to use a different linker path
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LDPLUSPLUS": "/usr/bin/ldplusplus"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["/usr/bin/ldplusplus", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // A project which does use C++ but with a non-C++ file extension.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ClassOne.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "Application",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("ClassOne.m", additionalArgs: ["-x", "objective-c++"])]),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Default build uses clang++.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LD to use a different linker path - has no effect here.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LD": "/usr/bin/ld"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LDPLUSPLUS to use a different linker path
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LDPLUSPLUS": "/usr/bin/ldplusplus"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["/usr/bin/ldplusplus", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // A project which does use C++ but with a non-C++ file extension.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ClassOne.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "GCC_INPUT_FILETYPE": "sourcecode.cpp.objcpp"
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "Application",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["ClassOne.m",]),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Default build uses clang++.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LD to use a different linker path - has no effect here.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LD": "/usr/bin/ld"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LDPLUSPLUS to use a different linker path
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LDPLUSPLUS": "/usr/bin/ldplusplus"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["/usr/bin/ldplusplus", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // A project which does use C++ but with a non-C++ file extension, overriding the language dialect in a cascade.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ClassOne.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "GCC_INPUT_FILETYPE": "sourcecode.cpp.objcpp",
                                            "OTHER_CPLUSPLUSFLAGS": "-x c",
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "Application",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("ClassOne.m", additionalArgs: ["-x", "c++"])]),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Default build uses clang++.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LD to use a different linker path - has no effect here.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LD": "/usr/bin/ld"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Override LDPLUSPLUS to use a different linker path
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LDPLUSPLUS": "/usr/bin/ldplusplus"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["/usr/bin/ldplusplus", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // A project which does use C++ but with a non-C++ file extension, overriding the language dialect in a cascade.
        do {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("ClassOne.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "GCC_INPUT_FILETYPE": "fake",
                                            "OTHER_CPLUSPLUSFLAGS": "-x c",
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "Application",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("ClassOne.m", additionalArgs: ["-x", "c++"])]),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Default build uses clang++.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check that there is a warning about the bad value for GCC_INPUT_FILETYPE
                results.checkWarning("unsupported value 'fake' for build setting GCC_INPUT_FILETYPE (in target 'Application' from project 'aProject')")
                results.checkWarning("unsupported value 'fake' for build setting GCC_INPUT_FILETYPE (in target 'Application' from project 'aProject')")
            }

            // Override LD to use a different linker path - has no effect here.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LD": "/usr/bin/ld"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["clang++", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check that there is a warning about the bad value for GCC_INPUT_FILETYPE
                results.checkWarning("unsupported value 'fake' for build setting GCC_INPUT_FILETYPE (in target 'Application' from project 'aProject')")
                results.checkWarning("unsupported value 'fake' for build setting GCC_INPUT_FILETYPE (in target 'Application' from project 'aProject')")
            }

            // Override LDPLUSPLUS to use a different linker path
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LDPLUSPLUS": "/usr/bin/ldplusplus"]), runDestination: .macOS) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["/usr/bin/ldplusplus", "-o", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application"])
                    }
                }

                // Check that there is a warning about the bad value for GCC_INPUT_FILETYPE
                results.checkWarning("unsupported value 'fake' for build setting GCC_INPUT_FILETYPE (in target 'Application' from project 'aProject')")
                results.checkWarning("unsupported value 'fake' for build setting GCC_INPUT_FILETYPE (in target 'Application' from project 'aProject')")
            }
        }
    }


    @Test(.requireSDKs(.macOS))
    func linkMissingProjectReference() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("ClassOne.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["ClassOne.m",]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.namedReference(name: "UIKit.framework", fileTypeIdentifier: "wrapper.framework")),
                            TestBuildFile(.namedReference(name: "libssl.a", fileTypeIdentifier: "archive.ar")),
                            TestBuildFile(.namedReference(name: "libxml2.dylib", fileTypeIdentifier: "compiled.mach-o.dylib")),
                        ])
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("Application") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains(["-framework", "UIKit"])
                    task.checkCommandLineContains(["-lssl"])
                    task.checkCommandLineContains(["-lxml2"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func embeddedInfoPlistLinkerDependency() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("ClassOne.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "OTHER_LDFLAGS": "-sectcreate __TEXT __info_plist /path/of/Info.plist -sectcreate a b /c.plist arg arg -sectcreate c d /e.plist"
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["ClassOne.m",]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()
        try fs.createDirectory(Path("/path/of"), recursive: true)
        try fs.write(Path("/path/of/Info.plist"), contents: "")
        try fs.write(Path("/c.plist"), contents: "")
        try fs.write(Path("/e.plist"), contents: "")

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTarget("Application") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkInputs(contain: [
                        .path("/path/of/Info.plist"),
                        .path("/c.plist"),
                        .path("/e.plist"),
                    ])
                }
            }
        }
    }

    /// Test the logic for determining which language dialect string to pass to clang using -x.
    @Test(.requireSDKs(.macOS))
    func compilerLanguageDialectSelection() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("CFile1.c", fileType: "sourcecode.c.c"),
                    TestFile("CFile2.c", fileType: "sourcecode.c.c.preprocessed"),
                    TestFile("ObjCFile1.m", fileType: "sourcecode.c.objc"),
                    TestFile("ObjCFile2.m", fileType: "sourcecode.c.objc.preprocessed"),
                    TestFile("CPlusPlusFile1.cpp", fileType: "sourcecode.cpp.cpp"),
                    TestFile("CPlusPlusFile2.cpp", fileType: "sourcecode.cpp.cpp.preprocessed"),
                    TestFile("ObjCPlusPlusFile1.mm", fileType: "sourcecode.cpp.objcpp"),
                    TestFile("ObjCPlusPlusFile2.mm", fileType: "sourcecode.cpp.objcpp.preprocessed"),
                    TestFile("Assembly.asm", fileType: "sourcecode.asm.asm"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "CFile1.c",
                            "CFile2.c",
                            "ObjCFile1.m",
                            "ObjCFile2.m",
                            "CPlusPlusFile1.cpp",
                            "CPlusPlusFile2.cpp",
                            "ObjCPlusPlusFile1.mm",
                            "ObjCPlusPlusFile2.mm",
                            "Assembly.asm",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Application") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("CFile1.c")) { task in
                    task.checkCommandLineContains(["clang", "-x", "c"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("CFile2.c")) { task in
                    task.checkCommandLineContains(["clang", "-x", "c"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ObjCFile1.m")) { task in
                    task.checkCommandLineContains(["clang", "-x", "objective-c"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ObjCFile2.m")) { task in
                    task.checkCommandLineContains(["clang", "-x", "objective-c"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("CPlusPlusFile1.cpp")) { task in
                    task.checkCommandLineContains(["clang", "-x", "c++"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("CPlusPlusFile2.cpp")) { task in
                    task.checkCommandLineContains(["clang", "-x", "c++"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ObjCPlusPlusFile1.mm")) { task in
                    task.checkCommandLineContains(["clang", "-x", "objective-c++"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ObjCPlusPlusFile2.mm")) { task in
                    task.checkCommandLineContains(["clang", "-x", "objective-c++"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("Assembly.asm")) { task in
                    task.checkCommandLineContains(["clang", "-x", "assembler-with-cpp"])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test that _vers.c files are correctly excluded by `EXCLUDED_SOURCE_FILE_NAMES` and don't cause the build to still think a binary will be produced even when the sole source file has been excluded.
    @Test(.requireSDKs(.macOS))
    func versionCGeneratedFileIsExcluded() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "CODE_SIGNING_ALLOWED": "NO",
                                        "BUILD_VARIANTS": "normal debug profile",
                                        "EXCLUDED_SOURCE_FILE_NAMES": "*",
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SKIP_INSTALL": "YES",
                                        "VERSIONING_SYSTEM": "apple-generic"
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "SomeFwk",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "Ld", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "RegisterExecutionPolicyException", "SetMode", "SetOwnerAndGroup", "SymLink", "Touch", "WriteAuxiliaryFile"])

            // Check there are no diagnostics.
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Check that the handling of file basename collisions doesn't use characters that have special meaning to file systems, even when the GUIDs are strange.
    @Test(.requireSDKs(.macOS))
    func multipleSourceFilesWithSameBaseName() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("file.m", guid: "PACKAGE:Foo/Bar/Pkg:PHASE_1::REF_1"),
                    TestFile("file.mm", guid: "PACKAGE:Foo/Bar/Pkg:PHASE_2::REF_2"),
                    TestFile("file.c", guid: "PACKAGE:../../..:PHASE_3::REF_3"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "BUILD_VARIANTS": "normal",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "MyLibrary",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "file.m",
                            "file.mm",
                            "file.c",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyLibrary") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let ofiles = task.inputs.filter { $0.name.hasSuffix(".o") }
                    for ofile in ofiles {
                        // We expect the base name to start with "file" — if path separators were added through the GUID, it won't.
                        #expect(ofile.path.basename.hasPrefix("file"))
                        // We expect the base name to not contain colons etc, which will interfere with the .d files.
                        #expect(!ofile.path.basename.contains(":"), "message: \(ofile.path.basename)")
                    }
                }
            }
        }
    }

    // Regression test for rdar://87620702: Regression in storyboard copy bundle resources phase when CONFIGURATION_BUILD_DIR=$(SYMROOT) with legacy build locations
    @Test(.requireSDKs(.macOS))
    func buildRuleAppliedToAnothersOutputWithSameConfigurationBuildDirOverride() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Info.plist"),
                    TestFile("baz.storyboard"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "IBC_EXEC": ibtoolPath.str,
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CONFIGURATION_BUILD_DIR": "$(SYMROOT)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "CODE_SIGN_IDENTITY": "",
                                                "SDKROOT": "macosx",
                                                "INFOPLIST_FILE": "Sources/Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "baz.storyboard",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("App") { target in
                // Check the storyboard compiles.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileStoryboard")) { task in
                    task.checkRuleInfo(["CompileStoryboard", "\(SRCROOT)/Sources/baz.storyboard"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/baz.storyboard"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz-SBPartialInfo.plist"),])
                }

                // Verify that the LinkStoryboards task was created as expected with the storyboardc file as input.
                results.checkTask(.matchTarget(target), .matchRuleType("LinkStoryboards")) { task in
                    task.checkRuleInfo(["LinkStoryboards"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/baz.storyboardc"),
                        .namePattern(.and(.prefix("target"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/App.app/Contents/Resources/baz.storyboardc"),
                    ])
                }
            }

            results.checkNoDiagnostics()
        }
    }
}
