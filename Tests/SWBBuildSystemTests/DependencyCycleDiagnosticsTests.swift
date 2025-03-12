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

import Testing

import SWBCore
import SWBTestSupport
@_spi(Testing) import SWBUtil

@_spi(Testing) import SWBBuildSystem
import SWBTaskConstruction
import SWBTaskExecution

@Suite
fileprivate struct DependencyCycleDiagnosticsTests: CoreBasedTests {
    /// Test a very simple cycle involving two script phases which depend on each other.
    @Test(.requireSDKs(.macOS))
    func simpleCycle() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        targets: [
                            TestAggregateTarget(
                                "A",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "A", originalObjectID: "A", contents: "true",
                                                              inputs: ["/tmp/B-output"], outputs: ["/tmp/A-output"]),
                                    TestShellScriptBuildPhase(name: "B", originalObjectID: "B", contents: "true",
                                                              inputs: ["/tmp/A-output"], outputs: ["/tmp/B-output"]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: true)

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkError(.prefix("Cycle inside A; building could produce unreliable results. This usually can be resolved by moving the shell script phase 'B' so that it runs before the build phase that depends on its outputs."))
                results.checkNoDiagnostics()
            }
        }
    }

    /// Checks our pretty printing for ruleInfo of various kinds.
    /// - remark: This is the most expensive test in this suite to tun, because it runs tasks of many different types.
    @Test(.requireSDKs(.macOS))
    func prettyPrintingRuleInfo() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Files", children: [
                        TestFile("A.c"),
                        TestFile("A.swift"),
                        TestFile("A.metal"),
                        TestFile("A.h"),
                        TestFile("A.png"),
                        TestFile("A.plist"),
                        TestFile("A.xcassets"),
                        TestFile("A.storyboard"),
                        TestFile("A.xib"),
                        TestFile("A.xcdatamodel"),
                        TestFile("A.pch"),
                        TestFile("A.pch++"),
                        TestFile("A.cpp"),
                        TestFile("A.tiff"),
                        TestFile("A.xcconfig"),
                        TestFile("A.strings"),
                        TestFile("B.xcconfig"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "A",
                            "INFOPLIST_PREPROCESS": "YES",
                            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                            "GCC_PREFIX_HEADER": "\(tmpDir.str)/A.pch",
                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                            "ARCHS": "x86_64",
                        ]
                    ),
                    TestBuildConfiguration(
                        "Other",
                        buildSettings: [
                            "PRODUCT_NAME": "A",
                            "GCC_PREFIX_HEADER": "\(tmpDir.str)/A.pch++",
                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "A-foo-bar",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: ["DONT_GENERATE_INFOPLIST_FILE": "YES"]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("A.c"), TestBuildFile("A.swift"), TestBuildFile("A.metal"), TestBuildFile("A.cpp")]),
                            TestShellScriptBuildPhase(name: "Script", originalObjectID: "bestID", contents: "true"),
                            TestResourcesBuildPhase([TestBuildFile("A.png"), TestBuildFile("A.plist"), TestBuildFile("A.xcassets"), TestBuildFile("A.storyboard"), TestBuildFile("A.xib"), TestBuildFile("A.xcdatamodel"), TestBuildFile("A.tiff"), TestBuildFile("A.xcconfig"), TestBuildFile("A.strings")]),
                            TestCopyFilesBuildPhase([TestBuildFile("B.xcconfig")], destinationSubfolder: .frameworks),
                        ]
                    )])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)

            try await tester.checkBuildDescription(BuildParameters(configuration: "Other"), runDestination: .macOS) { results in
                let tasks = results.buildDescription.tasks.filter { $0.ruleInfo.first == "ProcessPCH++" }
                #expect(tasks.count == 1)
                #expect(tasks.first?.formattedRuleInfo(for: .dependencyCycle) == "Target 'A-foo-bar' has process command with input '\(tmpDir.str)/A.pch++'")
            }

            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug"), runDestination: .macOS, buildCommand: .generatePreprocessedFile(buildOnlyTheseFiles: [Path("\(tmpDir.str)/A.plist")])) { results in
                let tasks = results.buildDescription.tasks.filter { $0.ruleInfo.first == "Preprocess" }
                #expect(tasks.count == 2)
                for task in tasks {
                    #expect(task.formattedRuleInfo(for: .dependencyCycle)?.hasPrefix("Target 'A-foo-bar' has preprocess command with input '\(tmpDir.str)/A") == true)
                }
            }

            try await tester.checkBuildDescription(runDestination: .macOS) { results in
                for task in results.buildDescription.tasks {
                    let formattedOutput = task.formattedRuleInfo(for: .dependencyCycle)
                    switch task.ruleInfo.first {
                    case "CompileAssetCatalog", "CompileAssetCatalogVariant":
                        #expect(formattedOutput == "Target 'A-foo-bar' has compile command with input '\(tmpDir.str)/A.xcassets'")
                    case "GenerateAssetSymbols":
                        #expect(formattedOutput == "Target 'A-foo-bar': GenerateAssetSymbols \(tmpDir.str)/A.xcassets")
                    case "CompileC":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar' has compile command with input '\(tmpDir.str)/A.c") == true)
                    case "CompileMetalFile":
                        #expect(formattedOutput == "Target 'A-foo-bar' has compile command with input '\(tmpDir.str)/A.metal'")
                    case "CompileStoryboard":
                        #expect(formattedOutput == "Target 'A-foo-bar' has compile command with input '\(tmpDir.str)/A.storyboard'")
                    case "CompileSwiftSources":
                        #expect(formattedOutput == "Target 'A-foo-bar' has compile command for Swift source files")
                    case "SwiftDriver":
                        #expect(formattedOutput == "Target 'A-foo-bar' has Swift driver planning command for Swift source files")
                    case "SwiftDriver Compilation Requirements":
                        #expect(formattedOutput == "Target 'A-foo-bar' has Swift tasks blocking downstream compilation")
                    case "SwiftDriver Compilation":
                        #expect(formattedOutput == "Target 'A-foo-bar' has Swift tasks not blocking downstream targets")
                    case "CompileXIB":
                        #expect(formattedOutput == "Target 'A-foo-bar' has compile command with input '\(tmpDir.str)/A.xib'")
                    case "CopyPlistFile":
                        #expect(formattedOutput == "Target 'A-foo-bar' has copy command from '\(tmpDir.str)/A.plist' to '\(tmpDir.str)/build/Debug/A.framework/Versions/A/Resources/A.plist'")
                    case "CopyPNGFile":
                        #expect(formattedOutput == "Target 'A-foo-bar' has copy command from '\(tmpDir.str)/A.png' to '\(tmpDir.str)/build/Debug/A.framework/Versions/A/Resources/A.png'")
                    case "CopyTiffFile":
                        #expect(formattedOutput == "Target 'A-foo-bar' has copy command from '\(tmpDir.str)/A.tiff' to '\(tmpDir.str)/build/Debug/A.framework/Versions/A/Resources/A.tiff'")
                    case "CopyStringsFile":
                        #expect(formattedOutput == "Target 'A-foo-bar' has copy command from '\(tmpDir.str)/A.strings' to '\(tmpDir.str)/build/Debug/A.framework/Versions/A/Resources/A.strings'")
                    case "CpHeader":
                        #expect(formattedOutput == "Target 'A-foo-bar' has copy command from '\(tmpDir.str)/A.h' to '\(tmpDir.str)/build/Debug/A.framework/Versions/A/Headers/A.h'")
                    case "CpResource":
                        #expect(formattedOutput == "Target 'A-foo-bar' has copy command from '\(tmpDir.str)/A.xcconfig' to '\(tmpDir.str)/build/Debug/A.framework/Versions/A/Resources/A.xcconfig'")
                    case "CreateUniversalBinary":
                        #expect(formattedOutput == "target 'A-foo-bar': create universal binary \(tmpDir.str)/build/Debug/A.framework/Versions/A/A")
                    case "DataModelCompile":
                        #expect(formattedOutput == "Target 'A-foo-bar' has compile command with input '\(tmpDir.str)/A.xcdatamodel'")
                    case "Gate", "CreateBuildDirectory":
                        if task.ruleInfo[1].hasPrefix("target-") && (task.ruleInfo[1].hasSuffix("-entry") || task.ruleInfo[1].hasSuffix("-begin-compiling")) {
                            #expect(task.forTarget?.target.name == "A-foo-bar")
                        } else {
                            #expect(task.ruleInfo.filter({ $0.hasSuffix("entry") }).count == 0)
                        }
                        #expect(formattedOutput == nil)
                    case "GenerateDSYMFile":
                        #expect(formattedOutput == "Target 'A-foo-bar' has a command with output '\(tmpDir.str)/build/Debug/A.framework.dSYM'")
                    case "Ld":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar' has link command with output '\(tmpDir.str)/") == true)
                    case "MkDir":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar' has create directory command with output") == true)
                    case "PhaseScriptExecution":
                        #expect(formattedOutput == "That command depends on command in Target 'A-foo-bar': script phase “Script”")
                    case "ProcessPCH++", "ProcessPCH":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar' has process command with input '\(tmpDir.str)/A.pch") == true)
                    case "SymLink":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar' has symlink command from ") == true)
                    case "Copy":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar' has copy command from '\(tmpDir.str)/build/aProject.build/Debug/A-foo-bar.build/Objects-normal/x86_64") == true)
                    case "Touch", "LinkStoryboards", "MetalLink", "RegisterExecutionPolicyException", "SwiftMergeGeneratedHeaders", "GenerateTAPI":
                        #expect(formattedOutput == "Target 'A-foo-bar': \(task.ruleInfo.joined(separator: " "))")
                    case "WriteAuxiliaryFile":
                        if task.ruleInfo.last?.hasSuffix("sh") == true {
                            #expect(formattedOutput == nil)
                        } else {
                            #expect(task.ruleInfo.count == 2)
                            if task.ruleInfo.last?.hasSuffix("yaml") == true {
                                #expect(formattedOutput == "Command")
                            } else if task.ruleInfo.last?.hasSuffix("LinkFileList") == true {
                                #expect(formattedOutput == "Target 'A-foo-bar'")
                            } else {
                                #expect(formattedOutput == "Target 'A-foo-bar'")
                            }
                        }
                    case "ExtractAppIntentsMetadata":
                        #expect(formattedOutput == "Target \'A-foo-bar\': ExtractAppIntentsMetadata")
                    case "ClangStatCache":
                        #expect(formattedOutput?.hasPrefix("Command: ClangStatCache") == true)
                    case "LinkAssetCatalog":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar': LinkAssetCatalog") == true)
                    case "LinkAssetCatalogSignature":
                        #expect(formattedOutput?.hasPrefix("Target 'A-foo-bar': LinkAssetCatalogSignature") == true)
                    case "ProcessSDKImports":
                        #expect(formattedOutput == "Target 'A-foo-bar' has process command with output '\(tmpDir.str)/build/aProject.build/Debug/A-foo-bar.build/Objects-normal/x86_64/A_normal_x86_64_sdk_imports.json'")
                    default:
                        Issue.record("unhandled rule info: \(task.ruleInfo)")
                    }
                }
            }
        }
    }

    /// Test a simple target dependency cycle using explicit target dependencies.
    ///
    /// The cycle here is: A depends on B depends on C which in turn depends on A again.
    @Test(.requireSDKs(.macOS))
    func targetDependencyCycle() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("A.h"),
                        TestFile("B.h"),
                        TestFile("C.h"),
                        TestFile("A.m"),
                        TestFile("B.m"),
                        TestFile("C.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "EAGER_LINKING": "YES",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "A",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("A.m")]),
                        ],
                        dependencies: ["B"]
                    ),
                    TestStandardTarget(
                        "B",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("B.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("B.m")]),
                        ],
                        dependencies: ["C"]
                    ),
                    TestStandardTarget(
                        "C",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("C.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("C.m")]),
                        ],
                        dependencies: ["A"]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            for f in ["A.h", "B.h", "C.h", "A.m", "B.m", "C.m"] {
                let file = Path("\(tmpDir.str)").join("\(f)")
                try await tester.fs.writeFileContents(file) { _ in }
            }

            // FIXME: We should be able to eliminate the final task, as it is irrelevant to the cycle.
            try await tester.checkBuild(runDestination: .macOS) { results in
                try await results.checkDependencyCycle(.prefix("Cycle in dependencies between targets"), failIfNotFound: true) { cycle in
                    #expect(cycle.header == "Cycle in dependencies between targets 'A' and 'C'; building could produce unreliable results.")
                    #expect(cycle.path == "Cycle path: A → B → C → A")
                    #expect(!cycle.usingManualOrder)
                    #expect(cycle.lines == [
                        "→ Target \'A\' has an explicit dependency on Target \'B\'",
                        "→ Target \'B\' has an explicit dependency on Target \'C\'",
                        "→ Target \'C\' has an explicit dependency on Target \'A\'",
                    ])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test a target dependency cycle which includes implicit target dependencies.
    ///
    /// The cycle here is: A depends on B depends on C which in turn depends on A again.
    @Test(.requireSDKs(.macOS))
    func implicitTargetDependencyCycle() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("A.h"),
                        TestFile("B.h"),
                        TestFile("C.h"),
                        TestFile("A.m"),
                        TestFile("B.m"),
                        TestFile("C.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "EAGER_LINKING": "YES",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "A",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("A.m")]),
                        ],
                        dependencies: ["B"]
                    ),
                    TestStandardTarget(
                        "B",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "OTHER_LDFLAGS": "-framework C",
                            ]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("B.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("B.m")]),
                        ],
                        dependencies: []
                    ),
                    TestStandardTarget(
                        "C",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("C.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("C.m")]),
                            TestFrameworksBuildPhase([TestBuildFile("A.framework")])
                        ],
                        dependencies: []
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            for f in ["A.h", "B.h", "C.h", "A.m", "B.m", "C.m"] {
                let file = Path("\(tmpDir.str)").join("\(f)")
                try await tester.fs.writeFileContents(file) { _ in }
            }

            // FIXME: We should be able to eliminate the final task, as it is irrelevant to the cycle.
            let parameters = BuildParameters(configuration: "Debug")
            let request = BuildRequest(parameters: parameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])], dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            try await tester.checkBuild(runDestination: .macOS, buildRequest: request) { results in
                try await results.checkDependencyCycle(.prefix("Cycle in dependencies between targets"), failIfNotFound: true) { cycle in
                    #expect(cycle.header == "Cycle in dependencies between targets 'A' and 'C'; building could produce unreliable results.")
                    #expect(cycle.path == "Cycle path: A → B → C → A")
                    #expect(!cycle.usingManualOrder)
                    #expect(cycle.lines == [
                        "→ Target \'A\' has an explicit dependency on Target \'B\'",
                        "→ Target \'B\' has an implicit dependency on Target \'C\' because \'B\' defines the option \'-framework C\' in the build setting \'OTHER_LDFLAGS\'",
                        "→ Target \'C\' has an implicit dependency on Target \'A\' because \'C\' references the file \'A.framework\' in the build phase \'Link Binary\'",
                    ])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that any targets which are how the dependency logic "got to" the cycle are not included in the path.
    ///
    /// The cycle here is between C and D, but the raw cycle includes A and B because A is the "entry" to the dependency graph so the path to get to the cycle goes through A and B.
    @Test(.requireSDKs(.macOS))
    func leadingTargetsAreElidedFromCyclePath() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("A.h"),
                        TestFile("A.m"),
                        TestFile("B.h"),
                        TestFile("B.m"),
                        TestFile("C.h"),
                        TestFile("C.m"),
                        TestFile("D.h"),
                        TestFile("D.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "EAGER_LINKING": "YES",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "A",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("A.m")]),
                        ],
                        dependencies: ["B"]
                    ),
                    TestStandardTarget(
                        "B",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("B.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("B.m")]),
                        ],
                        dependencies: ["C"]
                    ),
                    TestStandardTarget(
                        "C",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("C.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("C.m")]),
                        ],
                        dependencies: ["D"]
                    ),
                    TestStandardTarget(
                        "D",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("D.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("D.m")]),
                        ],
                        dependencies: ["C"]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            for f in ["A.h", "A.m", "B.h", "B.m", "C.h", "C.m", "D.h", "D.m"] {
                let file = Path("\(tmpDir.str)").join("\(f)")
                try await tester.fs.writeFileContents(file) { _ in }
            }

            // Check that the cycle path includes C and D, but not A and B.
            try await tester.checkBuild(runDestination: .macOS) { results in
                try await results.checkDependencyCycle(.prefix("Cycle in dependencies between targets"), failIfNotFound: true) { cycle in
                    #expect(cycle.header == "Cycle in dependencies between targets 'C' and 'D'; building could produce unreliable results.")
                    #expect(cycle.path == "Cycle path: C → D → C")
                    #expect(!cycle.usingManualOrder)
                    #expect(cycle.lines == [
                        "→ Target \'C\' has an explicit dependency on Target \'D\'",
                        "→ Target \'D\' has an explicit dependency on Target \'C\'",
                    ])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test a cycle which occurs because of generated files.
    ///
    /// The cycle here is:
    /// - A depends on B
    /// - B compiles B.m
    /// - B is generated by a shell script phase in A
    @Test(.requireSDKs(.macOS))
    func generatedFilesCycle() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("A.h"),
                        TestFile("B.h"),
                        TestFile("A.m"),
                        TestFile("B.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "EAGER_LINKING": "YES",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "A",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("A.m")]),
                            TestShellScriptBuildPhase(name: "Generate B.m", originalObjectID: "bestID", contents: "touch \(tmpDir.str)/B.m", outputs: ["\(tmpDir.str)/B.m"]),
                        ],
                        dependencies: [ "B" ]
                    ),
                    TestStandardTarget(
                        "B",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("B.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("B.m")]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            for f in ["A.h", "B.h", "A.m"] {
                let file = Path("\(tmpDir.str)").join("\(f)")
                try await tester.fs.writeFileContents(file) { _ in }
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                try await results.checkDependencyCycle(.prefix("Cycle in dependencies between targets"), failIfNotFound: true) { cycle in
                    #expect(cycle.header == "Cycle in dependencies between targets 'B' and 'A'; building could produce unreliable results.")
                    #expect(cycle.path == "Cycle path: B → A → B")
                    #expect(!cycle.usingManualOrder)
                    #expect(cycle.lines == [
                        "→ Target \'B\' has compile command with input \'\(tmpDir.str)/B.m\'",
                        "→ That command depends on command in Target \'A\': script phase “Generate B.m”",
                        "→ Target \'A\' has an explicit dependency on Target \'B\'",
                    ])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test a cycle which occurs because of the order of targets in a scheme, where manual order is enabled.
    ///
    /// The cycle here is:
    /// - A depends on B because of scheme ordering
    /// - B compiles B.m
    /// - B is generated by a shell script phase in A
    @Test(.requireSDKs(.macOS))
    func schemeOrderCycle() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("A.h"),
                        TestFile("B.h"),
                        TestFile("C.h"),
                        TestFile("A.m"),
                        TestFile("B.m"),
                        TestFile("C.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "A",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("A.m")]),
                            TestShellScriptBuildPhase(name: "Generate B.m", originalObjectID: "bestID", contents: "touch \(tmpDir.str)/B.m", outputs: ["\(tmpDir.str)/B.m"]),
                        ]
                    ),
                    TestStandardTarget(
                        "B",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("B.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("B.m")]),
                        ]
                    ),
                    TestStandardTarget(
                        "C",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("C.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase([TestBuildFile("C.m")]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            for f in ["A.h", "B.h", "C.h", "A.m", "C.m"] {
                let file = Path("\(tmpDir.str)").join("\(f)")
                try await tester.fs.writeFileContents(file) { _ in }
            }

            let buildParameters = BuildParameters(configuration: "Debug")
            let project = tester.workspace.projects.first!
            let targetA = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
            let targetB = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
            let targetC  = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[2])
            let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [targetC, targetB, targetA], dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest) { results in
                try await results.checkDependencyCycle(.prefix("Cycle in dependencies between targets"), failIfNotFound: true) { cycle in
                    #expect(cycle.header == "Cycle in dependencies between targets 'A' and 'B'; building could produce unreliable results.")
                    #expect(cycle.path == "Cycle path: A → B → A")
                    #expect(cycle.usingManualOrder)
                    #expect(cycle.lines == [
                        "→ Target \'A\' is ordered after Target \'B\' in a “Target Dependencies” build phase or in the scheme",
                        "○ Target \'B\' has compile command with input \'\(tmpDir.str)/B.m\'",
                        "→ That command depends on command in Target \'A\': script phase “Generate B.m”",
                    ])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Check the behavior of a cycle appearing through an upward include of a framework which defines a module.
    ///
    /// This is behavior which historically was acceptable because the headermap would satisfy the upward inclusion.
    @Test(.requireSDKs(.macOS), .userDefaults(["AttemptDependencyCycleResolution": "0"]), arguments: [true, false])
    func upwardIncludeModuleCycle(eagerParallelCompilation: Bool) async throws {
        try await withTemporaryDirectory { tmpDir async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestGroup("BaseFoo", path: "BaseFoo", children: [
                                    TestFile("BaseFoo.m"),
                                ]),
                                TestGroup("CoreFoo", path: "CoreFoo", children: [
                                    TestFile("CoreFoo.h"),
                                    TestFile("CoreFoo.m"),
                                ]),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                // Autolinking introduces a nondeterministic timing-based dependency cycle in this test.
                                "CLANG_MODULES_AUTOLINK": "NO",

                                // Eager parallel compilation prevents this cycle by removing dependencies between compiling tasks.
                                // BaseFoo only depends on the header map creation, not the compilation.
                                "EAGER_PARALLEL_COMPILATION_DISABLE": "\(!eagerParallelCompilation)",
                                "DIAGNOSE_MISSING_TARGET_DEPENDENCIES": "NO"
                            ]
                        )],
                        targets: [
                            // Main app, which depends on a framework, and the framework depends on a static library.
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug",
                                                           buildSettings: [
                                                            "DEFINES_MODULE": "YES"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("CoreFoo.h", headerVisibility: .public)])],
                                dependencies: ["BaseFoo"]),
                            TestStandardTarget(
                                "BaseFoo", type: .framework,
                                buildPhases: [TestSourcesBuildPhase(["BaseFoo.m"])]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the source files.

            // BaseFoo upwardly includes CoreFoo.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/BaseFoo/BaseFoo.m")) { contents in
                contents <<< "#import <CoreFoo/CoreFoo.h>\n"
                contents <<< "void foo() {}\n"
            }

            // CoreFoo target.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo/CoreFoo.h")) { contents in
                contents <<< "#define COREFOO 1\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo/CoreFoo.m")) { contents in
                contents <<< "void coreFoo() {}\n"
            }

            // Check the initial build.
            //
            // This should always work, because the module map for the downstream dependency won't have been laid down.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Check we ran the appropriate tasks.
                results.consumeTasksMatchingRuleTypes(["SymLink", "MkDir", "WriteAuxiliaryFile", "Gate", "CreateBuildDirectory", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "ClangStatCache", "PrecompileModule", "ProcessSDKImports"])

                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("Ld")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("Touch")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTask(.matchRuleType("CpHeader")) { _ in }
                results.checkTask(.matchRuleType("Copy")) { _ in }

                results.checkNoTask()
            }

            // Check a null build.
            if tester.fs.fileSystemMode == .checksumOnly {
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    // FIXME: (ChecksumOnlyFileSystem)
                    // null build seems to be erroneously spawning a
                    // ["CompileC", "*/BaseFoo.o", "*/BaseFoo.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"]
                    // Surprisingly "results.checkTask" does not catch the "CompileC" task, but "results.checkTasks" does.
                    results.checkTasks(.matchRuleType("CompileC")) { _ in }
                    results.checkNoTask()
                }
            } else {
                try await tester.checkNullBuild(runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])
            }

            // Force a rebuild followed by another incremental build. Because we eagerly write out the module map, there should be no cycle.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/BaseFoo/BaseFoo.m")) { contents in
                contents <<< "#import <CoreFoo/CoreFoo.h>\n"
                contents <<< "void foo() {}\n"
                contents <<< "void foo2() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
