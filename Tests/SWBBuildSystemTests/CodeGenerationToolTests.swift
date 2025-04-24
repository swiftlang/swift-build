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

import class Foundation.Bundle

import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Testing
import SWBProtocol

@Suite
fileprivate struct CodeGenerationToolTests: CoreBasedTests {
    @Test(.requireSDKs(.iOS))
    func coreDataCodeGeneration() async throws {

        let core = try await getCore()

        // Test building a framework with a series of file types which also produce generated files.
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                                TestFile("CoreBaz.h"),
                                TestFile("CoreBaz.m"),
                                TestFile("CoreFoo.swift"),
                                TestFile("Info.plist"),
                                TestFile("CoreFoo.xcdatamodel"),
                                TestFile("CoreBar.xcdatamodel"),
                                TestFile("CoreBaz.xcdatamodeld"),
                                TestFile("CoreQux.xcdatamodeld"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "DEFINES_MODULE": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "INFOPLIST_FILE": "Sources/Info.plist",

                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": GetCurrentUserGroupName()!,
                                "INSTALL_MODE_FLAG": "+w",
                                "SWIFT_VERSION": "5.0",
                            ]
                        )],
                        targets: [
                            TestAggregateTarget("All", dependencies: ["CoreFoo", "CoreBar", "CoreBaz", "CoreQux"]),
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreFoo.m",
                                        "CoreFoo.xcdatamodel",
                                    ]),
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ]),
                            TestStandardTarget(
                                "CoreBar", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreFoo.swift",
                                        "CoreBar.xcdatamodel",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "CoreBaz", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreBaz.m",
                                        "CoreBaz.xcdatamodeld",
                                    ]),
                                    TestHeadersBuildPhase([TestBuildFile("CoreBaz.h", headerVisibility: .public)]),
                                ]),
                            TestStandardTarget(
                                "CoreQux", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreFoo.swift",
                                        "CoreQux.xcdatamodeld",
                                    ]),
                                ])
                        ])
                ])

            // Create the tester.
            let fs = localFS
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false, fileSystem: fs)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.h")) { contents in
                contents <<< "#include \"CoreQuux.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.m")) { contents in
                contents <<< "void f0(void) { };\n"
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreBaz.h")) { contents in
                contents <<< "#include \"CoreQuux.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreBaz.m")) { contents in
                contents <<< "void f0(void) { };\n"
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.swift")) { _ in }

            // CoreData encodes its codegen language in the data file itself, so we need two
            try tester.fs.writeCoreDataModel(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo.xcdatamodel"), language: .objectiveC, .entity("EntityOne"))
            try tester.fs.writeCoreDataModel(testWorkspace.sourceRoot.join("aProject/Sources/CoreBar.xcdatamodel"), language: .swift, .entity("EntityOne"))
            // It also uses two formats (flat file and directory), so we need two more
            try tester.fs.writeCoreDataModelD(testWorkspace.sourceRoot.join("aProject/Sources/CoreBaz.xcdatamodeld"), language: .objectiveC, .entity("EntityOne"))
            try tester.fs.writeCoreDataModelD(testWorkspace.sourceRoot.join("aProject/Sources/CoreQux.xcdatamodeld"), language: .swift, .entity("EntityOne"))

            // We enable deployment postprocessing explicitly, to check the full range of basic behaviors.
            let parameters = BuildParameters(action: .install, configuration: "Debug", overrides: [
                "DSTROOT": tmpDirPath.join("dst").str,
            ])

            // Check the build.
            try await tester.checkBuild(parameters: parameters, runDestination: .iOS, persistent: true) { results in
                // Check that the module session validation file was written.
                if let moduleSessionFilePath = results.buildDescription.moduleSessionFilePath {
                    #expect(tester.fs.exists(moduleSessionFilePath))
                }
                else {
                    Issue.record("No module session validation file path was computed")
                }

                results.checkNoDiagnostics()

                for targetName in ["CoreFoo", "CoreBar"] {
                    // Find the code generation tasks.
                    let coreDataCodeGenTask = try #require(results.getTask(.matchRuleType("DataModelCodegen"), .matchTargetName(targetName)))

                    // Find the compilation tasks.
                    let momcTask = try #require(results.getTask(.matchRuleType("DataModelCompile"), .matchTargetName(targetName)))

                    // Find the first CompileC task.
                    let compileTasks = results.getTasks(.matchRuleType("CompileC"), .matchTargetName(targetName))

                    switch targetName {
                    case "CoreFoo":
                        #expect(compileTasks.count == 5)
                    case "CoreBar":
                        #expect(compileTasks.count == 1)
                    default:
                        break
                    }

                    let compileTask = compileTasks[0]

                    if targetName == "CoreFoo" {
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo+CoreDataModel.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("EntityOne+CoreDataClass.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("EntityOne+CoreDataProperties.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo_vers.c"), .matchTargetName(targetName)).count == 1)
                    }

                    // Find the linker task.
                    let linkerTask = try #require(results.getTask(.matchRuleType("Ld"), .matchTargetName(targetName)))

                    // Find the module map file creation.
                    let moduleMapWriteTask = results.getTask(.matchRuleType("Copy"), .matchRuleItemPattern(.suffix("\(targetName).framework/Modules/module.modulemap")))

                    // Check that the delegate was passed build started and build ended events in the right place.
                    results.checkCapstoneEvents()

                    let events = results.events.filter {
                        switch $0 {
                        case .totalProgressChanged:
                            return false
                        case .taskHadEvent(let task, event: _):
                            if task.ruleInfo.first == "CreateBuildDirectory" {
                                return false
                            }
                        default:
                            break
                        }
                        return true
                    }

                    // Check that we no tasks run before the initial target start phase.
                    guard events.count >= 3 else {
                        Issue.record("unexpected events in initial build: \(events)")
                        return
                    }

                    var idx = 0
                    func nextIdx() -> Int {
                        idx += 1
                        return idx
                    }

                    #expect(events[idx] == .buildStarted)
                    guard case .buildReportedPathMap = events[nextIdx()] else {
                        Issue.record("unexpected initial event after build start: \(events[idx])")
                        return
                    }

                    // Check that both the compiler and the linker ran.
                    results.check(event: .taskHadEvent(compileTask, event: .started), precedes: .taskHadEvent(compileTask, event: .completed))
                    results.check(event: .taskHadEvent(compileTask, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                    results.check(event: .taskHadEvent(linkerTask, event: .started), precedes: .taskHadEvent(linkerTask, event: .completed))

                    // Check that the codegen tasks ran.
                    results.check(event: .taskHadEvent(coreDataCodeGenTask, event: .started), precedes: .taskHadEvent(coreDataCodeGenTask, event: .completed))
                    results.check(event: .taskHadEvent(coreDataCodeGenTask, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                    results.check(event: .taskHadEvent(momcTask, event: .started), precedes: .taskHadEvent(momcTask, event: .completed))

                    // Check that the module map file was created.
                    try results.check(contains: .taskHadEvent(#require(moduleMapWriteTask), event: .started))

                    // Check that the "Info.plist" contents are correct.
                    let infoPlistContents = try results.fs.read(SRCROOT.join("build/Debug-iphoneos/\(targetName).framework/Info.plist"))
                    #expect(try PropertyList.fromBytes(infoPlistContents.bytes).dictValue?["CFBundleExecutable"]?.stringValue == targetName)
                }
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .iOS, persistent: true, excludedTasks: ["ClangStatCache"])

            // Modifying .xcdatamodel and ensure Swift Build is rerunning code generation
            try tester.fs.writeCoreDataModel(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo.xcdatamodel"), language: .objectiveC, .entity("EntityTwo"))
            try tester.fs.writeCoreDataModel(testWorkspace.sourceRoot.join("aProject/Sources/CoreBar.xcdatamodel"), language: .swift, .entity("EntityTwo"))

            try await tester.checkBuild(parameters: parameters, runDestination: .iOS, persistent: true) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreFoo")) { _ in }
                results.checkTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreBar")) { _ in }

                results.checkNoTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreBaz"))
                results.checkNoTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreQux"))
            }

            try await tester.checkNullBuild(parameters: parameters, runDestination: .iOS, persistent: true, excludedTasks: ["ClangStatCache"])

            // We want to modify the CoreData model such that the content of the file is changed, but still it produces the same set of output files as previous step
            // (i.e. Keeping .entity("EntityOne") instead of changing it to .entity("EntityTwo"))
            // If the output files are changed, the task signature will change, which will cause the rebuild. That will not test the scenario that we are interested in
            for targetName in ["CoreBaz", "CoreQux"] {
                let contentsPath = testWorkspace.sourceRoot.join("aProject/Sources/\(targetName).xcdatamodeld").join("\(targetName).xcdatamodel").join("contents")
                try await tester.fs.writeFileContents(contentsPath) {
                    $0 <<< (try tester.fs.read(contentsPath) + " ")
                }
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .iOS, persistent: true) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreBaz")) { _ in }
                results.checkTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreQux")) { _ in }

                results.checkNoTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreFoo"))
                results.checkNoTask(.matchRuleType("DataModelCodegen"), .matchTargetName("CoreBar"))
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func coreMLCodeGeneration() async throws {
        let core = try await getCore()
        // Test building a framework with a series of file types which also produce generated files.
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                                TestFile("CoreFoo.swift"),
                                TestFile("Info.plist"),
                                TestFile("CoreBaz.mlmodel"),
                                TestFile("CoreBaz2.mlpackage"),
                            ].compactMap { $0 }),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "DEFINES_MODULE": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "INFOPLIST_FILE": "Sources/Info.plist",

                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": GetCurrentUserGroupName()!,
                                "INSTALL_MODE_FLAG": "+w",
                                "SWIFT_VERSION": "5.0",
                            ]
                        )],
                        targets: [
                            TestAggregateTarget("All", dependencies: ["CoreFoo", "CoreBar"]),
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "COREML_CODEGEN_LANGUAGE": "Objective-C",
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreFoo.m",
                                        TestBuildFile("CoreBaz.mlmodel", intentsCodegenVisibility: .public),
                                        TestBuildFile("CoreBaz2.mlpackage", intentsCodegenVisibility: .public),
                                    ].compactMap { $0 }),
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ]),
                            TestStandardTarget(
                                "CoreBar", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "COREML_CODEGEN_LANGUAGE": "Swift",
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreFoo.swift",
                                        TestBuildFile("CoreBaz.mlmodel", intentsCodegenVisibility: .public),
                                        TestBuildFile("CoreBaz2.mlpackage", intentsCodegenVisibility: .public),
                                    ].compactMap { $0 }),
                                ])
                        ])
                ])

            // Create the tester.
            let fs = localFS
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false, fileSystem: fs)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.h")) { contents in
                contents <<< "#include \"CoreBaz.h\"\n"
                contents <<< "#include \"CoreBaz2.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.m")) { contents in
                contents <<< "void f0(void) { };\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.swift")) { _ in }

            // CoreML codegen language is specified at build time via an argument to the tool
            let modelSourcePath = try #require(Bundle.module.path(forResource: "WordTagger", ofType: "mlmodel", inDirectory: "TestData"))
            try tester.fs.copy(Path(modelSourcePath), to: testWorkspace.sourceRoot.join("aProject/Sources/CoreBaz.mlmodel"))

            let mlpackageSourcePath = try #require(Bundle.module.path(forResource: "WordTagger", ofType: "mlpackage", inDirectory: "TestData"))
            try tester.fs.copy(Path(mlpackageSourcePath), to: testWorkspace.sourceRoot.join("aProject/Sources/CoreBaz2.mlpackage"))

            // We enable deployment postprocessing explicitly, to check the full range of basic behaviors.
            let parameters = BuildParameters(action: .install, configuration: "Debug", overrides: [
                "DSTROOT": tmpDirPath.join("dst").str,
            ])

            // Check the build.
            try await tester.checkBuild(parameters: parameters, runDestination: .iOS, persistent: true) { results in
                // Check that the module session validation file was written.
                if let moduleSessionFilePath = results.buildDescription.moduleSessionFilePath {
                    #expect(tester.fs.exists(moduleSessionFilePath))
                }
                else {
                    Issue.record("No module session validation file path was computed")
                }

                // <rdar://problem/62147857> CoreML compiler produces generated code with warnings
                results.checkWarning(.contains("conflicting nullability specifier on return types"), failIfNotFound: false)
                results.checkWarning(.contains("conflicting nullability specifier on return types"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)

                results.checkNoDiagnostics()

                for targetName in ["CoreFoo", "CoreBar"] {
                    // Find the code generation tasks.
                    let coreMLCodeGenTaskMLModel = try #require(results.getTask(.matchRuleType("CoreMLModelCodegen"), .matchTargetName(targetName), .matchRuleItemBasename("CoreBaz.mlmodel")))
                    let coreMLCodeGenTaskMLPackage = try #require(results.getTask(.matchRuleType("CoreMLModelCodegen"), .matchTargetName(targetName), .matchRuleItemBasename("CoreBaz2.mlpackage")))

                    // Find the compilation tasks.
                    let coreMLTaskMLModel = try #require(results.getTask(.matchRuleType("CoreMLModelCompile"), .matchTargetName(targetName), .matchRuleItemBasename("CoreBaz.mlmodel")))
                    let coreMLTaskMLPackage = try #require(results.getTask(.matchRuleType("CoreMLModelCompile"), .matchTargetName(targetName), .matchRuleItemBasename("CoreBaz2.mlpackage")))

                    // Find the first CompileC task.
                    let compileTasks = results.getTasks(.matchRuleType("CompileC"), .matchTargetName(targetName))

                    switch targetName {
                    case "CoreFoo":
                        #expect(compileTasks.count == 4)
                    case "CoreBar":
                        #expect(compileTasks.count == 1)
                    default:
                        break
                    }

                    let compileTask = compileTasks[0]

                    if targetName == "CoreFoo" {
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreBaz.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreBaz2.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo_vers.c"), .matchTargetName(targetName)).count == 1)
                    }

                    // Find the linker task.
                    let linkerTask = try #require(results.getTask(.matchRuleType("Ld"), .matchTargetName(targetName)))

                    // Find the module map file creation.
                    let moduleMapWriteTask = results.getTask(.matchRuleType("Copy"), .matchRuleItemPattern(.suffix("\(targetName).framework/Modules/module.modulemap")))

                    // Check that the delegate was passed build started and build ended events in the right place.
                    results.checkCapstoneEvents()

                    let events = results.events.filter {
                        switch $0 {
                        case .totalProgressChanged:
                            return false
                        case .taskHadEvent(let task, event: _):
                            if task.ruleInfo.first == "CreateBuildDirectory" {
                                return false
                            }
                        default:
                            break
                        }
                        return true
                    }

                    // Check that we no tasks run before the initial target start phase.
                    guard events.count >= 3 else {
                        Issue.record("unexpected events in initial build: \(events)")
                        return
                    }

                    var idx = 0
                    func nextIdx() -> Int {
                        idx += 1
                        return idx
                    }

                    #expect(events[idx] == .buildStarted)
                    guard case .buildReportedPathMap = events[nextIdx()] else {
                        Issue.record("unexpected initial event after build start: \(events[idx])")
                        return
                    }

                    // Check that both the compiler and the linker ran.
                    results.check(event: .taskHadEvent(compileTask, event: .started), precedes: .taskHadEvent(compileTask, event: .completed))
                    results.check(event: .taskHadEvent(compileTask, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                    results.check(event: .taskHadEvent(linkerTask, event: .started), precedes: .taskHadEvent(linkerTask, event: .completed))

                    results.check(event: .taskHadEvent(coreMLCodeGenTaskMLModel, event: .started), precedes: .taskHadEvent(coreMLCodeGenTaskMLModel, event: .completed))
                    results.check(event: .taskHadEvent(coreMLCodeGenTaskMLModel, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                    results.check(event: .taskHadEvent(coreMLTaskMLModel, event: .started), precedes: .taskHadEvent(coreMLTaskMLModel, event: .completed))

                    results.check(event: .taskHadEvent(coreMLCodeGenTaskMLPackage, event: .started),
                                  precedes: .taskHadEvent(coreMLCodeGenTaskMLPackage, event: .completed))
                    results.check(event: .taskHadEvent(coreMLCodeGenTaskMLPackage, event: .completed),
                                  precedes: .taskHadEvent(linkerTask, event: .started))
                    results.check(event: .taskHadEvent(coreMLTaskMLPackage, event: .started),
                                  precedes: .taskHadEvent(coreMLTaskMLPackage, event: .completed))

                    // Check that the module map file was created.
                    try results.check(contains: .taskHadEvent(#require(moduleMapWriteTask), event: .started))

                    // Check that the "Info.plist" contents are correct.
                    let infoPlistContents = try results.fs.read(SRCROOT.join("build/Debug-iphoneos/\(targetName).framework/Info.plist"))
                    #expect(try PropertyList.fromBytes(infoPlistContents.bytes).dictValue?["CFBundleExecutable"]?.stringValue == targetName)
                }
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .iOS, persistent: true)
        }
    }

    @Test(.requireSDKs(.iOS))
    func intentsCodeGeneration() async throws {
        let core = try await getCore()

        // Test building a framework with a series of file types which also produce generated files.
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                                TestFile("CoreFoo.swift"),
                                TestFile("Info.plist"),
                                TestFile("Intents.intentdefinition"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "DEFINES_MODULE": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "INFOPLIST_FILE": "Sources/Info.plist",

                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": GetCurrentUserGroupName()!,
                                "INSTALL_MODE_FLAG": "+w",
                                "SWIFT_VERSION": "5.0",
                            ]
                        )],
                        targets: [
                            TestAggregateTarget("All", dependencies: ["CoreFoo", "CoreBar"]),
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "INTENTS_CODEGEN_LANGUAGE": "Objective-C",
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreFoo.m",
                                        TestBuildFile("Intents.intentdefinition", intentsCodegenVisibility: .public)
                                    ]),
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ]),
                            TestStandardTarget(
                                "CoreBar", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "INTENTS_CODEGEN_LANGUAGE": "Swift",
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "CoreFoo.swift",
                                        TestBuildFile("Intents.intentdefinition", intentsCodegenVisibility: .public)
                                    ]),
                                ])
                        ])
                ])

            // Create the tester.
            let fs = localFS
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false, fileSystem: fs)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.h")) { contents in
                contents <<< "#include \"IntentIntent.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.m")) { contents in
                contents <<< "void f0(void) { };\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.swift")) { _ in }

            // Intents codegen language is specified at build time via an argument to the tool
            try await tester.fs.writeIntentDefinition(testWorkspace.sourceRoot.join("aProject/Sources/Intents.intentdefinition"))

            // We enable deployment postprocessing explicitly, to check the full range of basic behaviors.
            let parameters = BuildParameters(action: .install, configuration: "Debug", overrides: [
                "DSTROOT": tmpDirPath.join("dst").str,
            ])

            // Check the build.
            try await tester.checkBuild(parameters: parameters, runDestination: .iOS, persistent: true) { results in
                // Check that the module session validation file was written.
                if let moduleSessionFilePath = results.buildDescription.moduleSessionFilePath {
                    #expect(tester.fs.exists(moduleSessionFilePath))
                }
                else {
                    Issue.record("No module session validation file path was computed")
                }

                results.checkNoDiagnostics()

                for targetName in ["CoreFoo", "CoreBar"] {
                    // Find the code generation tasks.
                    let intentDefCodeGenTask = try #require(results.getTask(.matchRuleType("IntentDefinitionCodegen"), .matchTargetName(targetName)))

                    // Find the compilation tasks.
                    let intentDefTask = try #require(results.getTask(.matchRuleType("IntentDefinitionCompile"), .matchTargetName(targetName)))

                    // Find the first CompileC task.
                    let compileTasks = results.getTasks(.matchRuleType("CompileC"), .matchTargetName(targetName))

                    switch targetName {
                    case "CoreFoo":
                        #expect(compileTasks.count == 3)
                    case "CoreBar":
                        #expect(compileTasks.count == 1)
                    default:
                        break
                    }

                    let compileTask = compileTasks[0]

                    if targetName == "CoreFoo" {
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo.m"), .matchTargetName(targetName)).count == 1)
                        #expect(results.getTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo_vers.c"), .matchTargetName(targetName)).count == 1)
                    }

                    // Find the linker task.
                    let linkerTask = try #require(results.getTask(.matchRuleType("Ld"), .matchTargetName(targetName)))

                    // Find the module map file creation.
                    let moduleMapWriteTask = results.getTask(.matchRuleType("Copy"), .matchRuleItemPattern(.suffix("\(targetName).framework/Modules/module.modulemap")))

                    // Check that the delegate was passed build started and build ended events in the right place.
                    results.checkCapstoneEvents()

                    let events = results.events.filter {
                        switch $0 {
                        case .totalProgressChanged:
                            return false
                        case .taskHadEvent(let task, event: _):
                            if task.ruleInfo.first == "CreateBuildDirectory" {
                                return false
                            }
                        default:
                            break
                        }
                        return true
                    }

                    // Check that we no tasks run before the initial target start phase.
                    guard events.count >= 3 else {
                        Issue.record("unexpected events in initial build: \(events)")
                        return
                    }

                    var idx = 0
                    func nextIdx() -> Int {
                        idx += 1
                        return idx
                    }

                    #expect(events[idx] == .buildStarted)
                    guard case .buildReportedPathMap = events[nextIdx()] else {
                        Issue.record("unexpected initial event after build start: \(events[idx])")
                        return
                    }

                    // Check that both the compiler and the linker ran.
                    results.check(event: .taskHadEvent(compileTask, event: .started), precedes: .taskHadEvent(compileTask, event: .completed))
                    results.check(event: .taskHadEvent(compileTask, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                    results.check(event: .taskHadEvent(linkerTask, event: .started), precedes: .taskHadEvent(linkerTask, event: .completed))

                    // Check that the codegen tasks ran.
                    results.check(event: .taskHadEvent(intentDefCodeGenTask, event: .started), precedes: .taskHadEvent(intentDefCodeGenTask, event: .completed))
                    results.check(event: .taskHadEvent(intentDefCodeGenTask, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                    results.check(event: .taskHadEvent(intentDefTask, event: .started), precedes: .taskHadEvent(intentDefTask, event: .completed))

                    // Check that the module map file was created.
                    try results.check(contains: .taskHadEvent(#require(moduleMapWriteTask), event: .started))

                    // Check that the "Info.plist" contents are correct.
                    let infoPlistContents = try results.fs.read(SRCROOT.join("build/Debug-iphoneos/\(targetName).framework/Info.plist"))
                    #expect(try PropertyList.fromBytes(infoPlistContents.bytes).dictValue?["CFBundleExecutable"]?.stringValue == targetName)
                }
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .iOS, persistent: true)
        }
    }
}
