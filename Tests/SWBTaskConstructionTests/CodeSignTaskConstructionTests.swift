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
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction
import SWBTaskExecution

@Suite
fileprivate struct CodeSignTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, comment: "Code signing is only available on macOS"))
    func codesignWithKeychainPathOverride() async throws {
        // Test that an empty tool target behaves properly.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                    "INFOPLIST_FILE": "Tool.plist",
                    "INFOPLIST_PREPROCESS": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [TestBuildConfiguration("Release")],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m"])]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let provisioningOverrides = ProvisioningTaskInputs(keychainPath: "~/keychainPath")
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS, provisioningOverrides: provisioningOverrides) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineContains(["--keychain", "~/keychainPath"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, comment: "Code signing is only available on macOS"))
    func codeSignOnCopyShallowBundleHandling() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("SourceFile.m"),
                        TestFile("External.framework"),
                        TestFile("ExternalDeep.framework"),
                        TestFile("External.bundle"),
                        TestFile("ExternalDeep.bundle"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestAggregateTarget(
                        "All",
                        dependencies: ["ToolTarget", "ToolTargetDeep"]
                    ),
                    TestStandardTarget(
                        "ToolTarget",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_PKGINFO_FILE": "YES",
                                "SHALLOW_BUNDLE": "YES",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.m",
                            ]),
                            TestCopyFilesBuildPhase([
                                TestBuildFile("AppCore.framework", codeSignOnCopy: true),
                                TestBuildFile("AppCoreDeep.framework", codeSignOnCopy: true),
                                TestBuildFile("External.framework", codeSignOnCopy: true),
                                TestBuildFile("ExternalDeep.framework", codeSignOnCopy: true),
                                TestBuildFile("External.bundle", codeSignOnCopy: true),
                                TestBuildFile("ExternalDeep.bundle", codeSignOnCopy: true),
                            ], destinationSubfolder: .frameworks, destinationSubpath: "Shallow", onlyForDeployment: false),
                        ],
                        dependencies: ["AppCore", "AppCoreDeep"]
                    ),
                    TestStandardTarget(
                        "ToolTargetDeep",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_PKGINFO_FILE": "YES",
                                "SHALLOW_BUNDLE": "NO",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.m",
                            ]),
                            TestCopyFilesBuildPhase([
                                TestBuildFile("AppCore.framework", codeSignOnCopy: true),
                                TestBuildFile("AppCoreDeep.framework", codeSignOnCopy: true),
                                TestBuildFile("External.framework", codeSignOnCopy: true),
                                TestBuildFile("ExternalDeep.framework", codeSignOnCopy: true),
                                TestBuildFile("External.bundle", codeSignOnCopy: true),
                                TestBuildFile("ExternalDeep.bundle", codeSignOnCopy: true),
                            ], destinationSubfolder: .frameworks, destinationSubpath: "Deep", onlyForDeployment: false),
                        ],
                        dependencies: ["AppCore", "AppCoreDeep"]
                    ),
                    TestStandardTarget(
                        "AppCore",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SHALLOW_BUNDLE": "YES",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.m"]),
                        ]),
                    TestStandardTarget(
                        "AppCoreDeep",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SHALLOW_BUNDLE": "NO",
                                "FRAMEWORK_VERSION": "B",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.m"]),
                        ])
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = localFS

            try fs.createDirectory(Path(SRCROOT).join("External.framework"), recursive: true)
            try fs.write(Path(SRCROOT).join("External.framework/External"), contents: "binary")

            try fs.createDirectory(Path(SRCROOT).join("ExternalDeep.framework/Versions/C"), recursive: true)
            try fs.write(Path(SRCROOT).join("ExternalDeep.framework/Versions/C/ExternalDeep"), contents: "binary")
            try fs.symlink(Path(SRCROOT).join("ExternalDeep.framework/ExternalDeep"), target: Path("Versions/Current/ExternalDeep"))
            try fs.symlink(Path(SRCROOT).join("ExternalDeep.framework/Versions/Current"), target: Path("C"))

            try fs.createDirectory(Path(SRCROOT).join("External.bundle"), recursive: true)
            try fs.write(Path(SRCROOT).join("External.bundle/External"), contents: "binary")

            try fs.createDirectory(Path(SRCROOT).join("ExternalDeep.bundle/Contents/MacOS"), recursive: true)
            try fs.write(Path(SRCROOT).join("ExternalDeep.bundle/Contents/MacOS/ExternalDeep"), contents: "binary")

            // Check the debug build.
            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                // There shouldn't be any task construction diagnostics.
                results.checkNoDiagnostics()

                results.checkTarget("ToolTarget") { target in
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/AppCore.framework"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/AppCore.framework"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCore.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCore.framework"),
                            .name("Copy \(SRCROOT)/build/Debug/Shallow/AppCore.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCore.framework/AppCore"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCore.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCore.framework/AppCore"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCore.framework/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Shallow/AppCore.framework"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B"),
                            .name("Copy \(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B/AppCoreDeep"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B/AppCoreDeep"),
                            .path("\(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Shallow/AppCoreDeep.framework/Versions/B"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/External.framework"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/External.framework"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/External.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.framework"),
                            .name("Copy \(SRCROOT)/build/Debug/Shallow/External.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.framework/External"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/External.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.framework/External"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.framework/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Shallow/External.framework"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C"),
                            .name("Copy \(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C/ExternalDeep"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C/ExternalDeep"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Shallow/ExternalDeep.framework/Versions/C"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/External.bundle"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/External.bundle"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/External.bundle"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.bundle"),
                            .name("Copy \(SRCROOT)/build/Debug/Shallow/External.bundle"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.bundle/External"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/External.bundle"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.bundle/External"),
                            .path("\(SRCROOT)/build/Debug/Shallow/External.bundle/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Shallow/External.bundle"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle"),
                            .name("Copy \(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle/Contents/MacOS/ExternalDeep"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle/Contents/MacOS/ExternalDeep"),
                            .path("\(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Shallow/ExternalDeep.bundle"),
                        ])
                    }
                }

                results.checkTarget("ToolTargetDeep") { target in
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Deep/AppCore.framework"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Deep/AppCore.framework"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Deep/AppCore.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCore.framework"),
                            .name("Copy \(SRCROOT)/build/Debug/Deep/AppCore.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCore.framework/AppCore"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Deep/AppCore.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCore.framework/AppCore"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCore.framework/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Deep/AppCore.framework"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B"),
                            .name("Copy \(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B/AppCoreDeep"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B/AppCoreDeep"),
                            .path("\(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Deep/AppCoreDeep.framework/Versions/B"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Deep/External.framework"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Deep/External.framework"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Deep/External.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.framework"),
                            .name("Copy \(SRCROOT)/build/Debug/Deep/External.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.framework/External"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Deep/External.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.framework/External"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.framework/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Deep/External.framework"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C"),
                            .name("Copy \(SRCROOT)/build/Debug/Deep/ExternalDeep.framework"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C/ExternalDeep"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C/ExternalDeep"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Deep/ExternalDeep.framework/Versions/C"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Deep/External.bundle"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Deep/External.bundle"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Deep/External.bundle"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.bundle"),
                            .name("Copy \(SRCROOT)/build/Debug/Deep/External.bundle"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.bundle/External"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Deep/External.bundle"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.bundle/External"),
                            .path("\(SRCROOT)/build/Debug/Deep/External.bundle/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Deep/External.bundle"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle"])) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle"),
                            .name("Copy \(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle/Contents/MacOS/ExternalDeep"),
                            .namePattern(.suffix("-phase0-compile-sources")),
                            .namePattern(.suffix("-entry"))
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle/Contents/MacOS/ExternalDeep"),
                            .path("\(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle/_CodeSignature"),
                            .name("CodeSign \(SRCROOT)/build/Debug/Deep/ExternalDeep.bundle"),
                        ])
                    }
                }

                results.checkTarget("AppCore") { target in
                    // There should be the expected mkdir tasks for the framework.
                    results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { (tasks) -> Void in
                        let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                        #expect(sortedTasks.count == 1)
                        sortedTasks[0].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework")])

                        // Validate we also construct command lines.
                        sortedTasks[0].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework"])
                    })
                }

                results.checkTarget("AppCoreDeep") { target in
                    // There should be the expected mkdir tasks for the framework.
                    results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { (tasks) -> Void in
                        let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                        #expect(sortedTasks.count == 4)
                        sortedTasks[0].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCoreDeep.framework")])
                        sortedTasks[1].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCoreDeep.framework/Versions")])
                        sortedTasks[2].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCoreDeep.framework/Versions/B")])

                        // Validate we also construct command lines.
                        sortedTasks[0].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCoreDeep.framework"])
                        sortedTasks[1].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCoreDeep.framework/Versions"])
                        sortedTasks[2].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCoreDeep.framework/Versions/B"])
                    })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])
            }
        }
    }

    @Test(.requireSDKs(.macOS, comment: "Code signing is only available on macOS"))
    func additionalCodeSignInputs() async throws {
        let testWorkspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("tool.c"),
                            TestFile("resource.txt"),
                            TestFile("other.txt"),
                            TestFile("nope.txt"),
                            // This is a special handling issue due to the inability to have inputs that do not actually exist on disk. See TaskProducer.addAdditionalCodeSignInput for more info.
                            TestFile("doesnotexist.txt"),
                            TestFile("Info.plist"),

                            // For Script Phase: Run Me
                            TestFile("input1.txt"),

                            // For Script Phase: Run Me (Outputs)
                            TestFile("input2.txt"),

                            // For Script Phase: Run Me (FileLists)
                            TestFile("in3.xcfilelist"),
                            TestFile("out3.xcfilelist"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "-",
                            "INFOPLIST_FILE": "Info.plist",

                            "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING": "YES",
                            "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS": "YES",

                            "OTHER_CODE_SIGN_FLAGS": "--entitlements /tmp/Test/aProject/build/aProject.build/custom-entitlements.plist",
                        ])],
                    targets: [
                        TestStandardTarget(
                            "Tool",
                            type: .application,
                            buildPhases: [
                                TestSourcesBuildPhase(["tool.c"]),
                                TestCopyFilesBuildPhase(["resource.txt", "other.txt", "doesnotexist.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                TestCopyFilesBuildPhase(["nope.txt"], destinationSubfolder: .builtProductsDir, destinationSubpath: "DerivedSources", onlyForDeployment: false),
                                TestShellScriptBuildPhase(name: "Run Me", shellPath: "/bin/bash", originalObjectID: "RunMe1", contents: "touch ${SCRIPT_OUTPUT_FILE_0}", inputs: ["$(SRCROOT)/input1.txt"], outputs: ["$(DERIVED_FILE_DIR)/out1"]),
                                TestShellScriptBuildPhase(name: "Run Me (Outputs)", shellPath: "/bin/bash", originalObjectID: "RunMe2", contents: "touch ${SCRIPT_OUTPUT_FILE_0}", inputs: ["$(SRCROOT)/input2.txt"], outputs: ["$(TARGET_BUILD_DIR)/Tool.app/Contents/Resources/out2.txt"]),
                                TestShellScriptBuildPhase(name: "Run Me (FileList)", shellPath: "/bin/bash", originalObjectID: "RunMe3", contents: "touch $TARGET_BUILD_DIR/Tool.app/Contents/Resources/out3.txt", inputs: [], inputFileLists: ["$(SRCROOT)/in3.xcfilelist"], outputs: [], outputFileLists: ["$(SRCROOT)/out3.xcfilelist"]),
                            ]),
                    ])])

        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)

        try fs.write(Path(SRCROOT).join("resource.txt"), contents: "should be an input\n")
        try fs.write(Path(SRCROOT).join("other.txt"), contents: "should be an input\n")
        try fs.write(Path(SRCROOT).join("nope.txt"), contents: "should NOT be an input\n")

        // DO NOT CREATE 'doesnotexist.txt'. See above for comments.

        try fs.write(Path(SRCROOT).join("input3.txt"), contents: "hi\n")
        try fs.write(Path(SRCROOT).join("in3.xcfilelist"), contents: "$(SRCROOT)/input3.txt\n")
        try fs.write(Path(SRCROOT).join("out3.xcfilelist"), contents: "$(TARGET_BUILD_DIR)/Tool.app/Contents/Resources/out3.txt\n")

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in

                    // Ensure that the codesign task is actually tracking all of the additional inputs.
                    task.checkInputs([
                        .path("/tmp/Test/aProject/build/Debug/Tool.app"),
                        .path("/tmp/Test/aProject/build/Debug/Tool.app"),
                        .path("/tmp/Test/aProject/build/Debug/Tool.app/Contents/Info.plist"),
                        .path("/tmp/Test/aProject/build/Debug/Tool.app/Contents/Resources/out2.txt"),
                        .path("/tmp/Test/aProject/build/Debug/Tool.app/Contents/Resources/out3.txt"),
                        .path("/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/Tool.app.xcent"),
                        .path("/tmp/Test/aProject/build/aProject.build/custom-entitlements.plist"),
                        .path("\(SRCROOT)/other.txt"),
                        .path("\(SRCROOT)/resource.txt"),
                        .path("/tmp/Test/aProject/build/Debug/Tool.app/Contents/MacOS/Tool"),
                        .namePattern(.and(.prefix("target-"), .suffix("ChangeAlternatePermissions"))),
                        .namePattern(.and(.prefix("target-"), .suffix("--will-sign"))),
                        .namePattern(.and(.prefix("target-"), .suffix("--entry"))),
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, comment: "Code signing is only available on MacOS"))
    func codesignOptionFlags() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "GENERATE_INFOPLIST_FILE": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "macOSFramework",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Release", buildSettings: ["SDKROOT": "macosx"])],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m"])]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        // Check that the dedicated build settings add the option flags.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "YES", "ENABLE_HARDENED_RUNTIME": "YES", "CODE_SIGN_RESTRICT": "YES"]), runDestination: .macOS) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "-o", "library,restrict,runtime", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
            }

            results.checkNoDiagnostics()
        }

        // Check that the dedicated build settings do not add the option flags.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "NO", "ENABLE_HARDENED_RUNTIME": "NO", "CODE_SIGN_RESTRICT": "NO"]), runDestination: .macOS) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
            }

            results.checkNoDiagnostics()
        }

        // Check that the union of the dedicated build settings and flags in OTHER_CODE_SIGN_FLAGS adds the right options.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "NO", "ENABLE_HARDENED_RUNTIME": "NO", "CODE_SIGN_RESTRICT": "YES", "OTHER_CODE_SIGN_FLAGS": "-o library,restrict"]), runDestination: .macOS) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "-o", "library,restrict", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
            }

            results.checkNoDiagnostics()
        }

        // Check that OTHER_CODE_SIGN_FLAGS still adds the option flags even if the dedicated build settings are disabled.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "NO", "ENABLE_HARDENED_RUNTIME": "NO", "CODE_SIGN_RESTRICT": "NO", "OTHER_CODE_SIGN_FLAGS": "-o library,restrict,runtime"]), runDestination: .macOS) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "-o", "library,restrict,runtime", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
            }

            results.checkNoDiagnostics()
        }

        // Check that DISABLE_FREEFORM_CODE_SIGN_OPTION_FLAGS removes the flags added in OTHER_CODE_SIGN_FLAGS and emits warnings.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "NO", "ENABLE_HARDENED_RUNTIME": "NO", "CODE_SIGN_RESTRICT": "NO", "OTHER_CODE_SIGN_FLAGS": "-o library,restrict,runtime", "DISABLE_FREEFORM_CODE_SIGN_OPTION_FLAGS": "YES"]), runDestination: .macOS) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
            }

            results.checkWarning(.equal("The 'library' codesign option flag must be set using the ENABLE_LIBRARY_VALIDATION build setting, not via OTHER_CODE_SIGN_FLAGS. It will be ignored. (in target 'macOSFramework' from project 'aProject')"))
            results.checkWarning(.equal("The 'restrict' codesign option flag must be set using the CODE_SIGN_RESTRICT build setting, not via OTHER_CODE_SIGN_FLAGS. It will be ignored. (in target 'macOSFramework' from project 'aProject')"))
            results.checkWarning(.equal("The 'runtime' codesign option flag must be set using the ENABLE_HARDENED_RUNTIME build setting, not via OTHER_CODE_SIGN_FLAGS. It will be ignored. (in target 'macOSFramework' from project 'aProject')"))
            results.checkNoDiagnostics()
        }

        // Check that flags without a dedicated build setting are passed through as expected.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "YES", "ENABLE_HARDENED_RUNTIME": "YES", "CODE_SIGN_RESTRICT": "YES", "OTHER_CODE_SIGN_FLAGS": "--options kill,hard,host,expires,linker-signed"]), runDestination: .macOS) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "expires,hard,host,kill,library,linker-signed,restrict,runtime", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
            }

            results.checkNoDiagnostics()
        }

        // Check that flags without a dedicated build setting are passed through as expected, in conjunction with DISABLE_FREEFORM_CODE_SIGN_OPTION_FLAGS removing disabled, known ones.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "NO", "ENABLE_HARDENED_RUNTIME": "NO", "CODE_SIGN_RESTRICT": "YES", "OTHER_CODE_SIGN_FLAGS": "--options kill,hard,host,expires,linker-signed"]), runDestination: .macOS) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "expires,hard,host,kill,linker-signed,restrict", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
            }

            results.checkNoDiagnostics()
        }
    }

    /// Test that the entitlements processing in `ProductPackagingToolSpec` works as expected.
    /// - remark: Ideally all of that processing would move to `ProcessProductEntitlementsTaskAction` where it could be tested in `ProcessProductEntitlementsTaskActionTests`, but presently that's now how it works.
    @Test(.requireSDKs(.macOS, comment: "Code signing is only available on macOS"))
    func entitlementsDictionaryProcessing() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                    "GENERATE_INFOPLIST_FILE": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                               ]
                                              ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                        ]),
                    ]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let srcRoot = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try fs.createDirectory(srcRoot, recursive: true)
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/"), recursive: true)

        try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "")
        try await fs.writePlist(Path("/tmp/aWorkspace/aProject/Entitlements.plist"), .plDict([:]))

        // The provisioning inputs used here come from TaskConstructionTester.computeProvisioningInputs(), as augmented by the given provisioningOverrides.

        // ------------------------------------
        // Testing removing the com.apple.security.get-task-allow in certain circumstances.

        do {
            func checkEntitlementsDictionary(action: BuildAction, overrides: [String: String] = [:], check: ([String: PropertyListItem]) throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async throws {
                // These provisioning overrides replace the default ones that come from TaskConstructionTester.computeProvisioningInputs().
                let appIdentifierPrefix = "F154D0C"
                let provisioningOverrides = ProvisioningTaskInputs(signedEntitlements: .plDict([
                    "application-identifier": .plString("\(appIdentifierPrefix).com.apple.dt.App"),
                    "com.apple.developer.team-identifier": .plString(appIdentifierPrefix),
                    "com.apple.security.get-task-allow": "YES",
                ]))

                // Test that it does not get removed in a debug build.
                try await tester.checkBuild(BuildParameters(action: action, configuration: "Config", overrides: overrides), runDestination: .macOS, provisioningOverrides: provisioningOverrides, fs: fs) { results in
                    try results.checkTarget("App") { target in
                        try results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Entitlements.plist")) { task, contents in
                            guard let plist = try? PropertyList.fromBytes(contents.bytes) else {
                                Issue.record("could not read entitlements file as plist", sourceLocation: sourceLocation)
                                return
                            }
                            guard let dict = plist.dictValue else {
                                Issue.record("entitlements file is not a dictionary", sourceLocation: sourceLocation)
                                return
                            }
                            #expect(!dict.isEmpty, "entitlements dictionary is unexpectedly empty", sourceLocation: sourceLocation)

                            try check(dict)
                        }
                    }
                    results.checkNoDiagnostics()
                }
            }

            // Test that it does not get removed in a debug build.
            try await checkEntitlementsDictionary(action: .build) { dict in
                #expect(dict["com.apple.security.get-task-allow"] == "YES")
            }

            // Test that it does get removed when DEPLOYMENT_POSTPROCESSING is YES (i.e., when doing an install build).
            try await checkEntitlementsDictionary(action: .install) { dict in
                #expect(dict["com.apple.security.get-task-allow"] == nil, "expected com.apple.security.get-task-allow entitlement to be nil but it is '\(dict["com.apple.security.get-task-allow"] ?? "<unknown>")'")
            }

            // Test that it does not get removed when ENTITLEMENTS_DONT_REMOVE_GET_TASK_ALLOW is YES, even if DEPLOYMENT_POSTPROCESSING is YES.
            try await checkEntitlementsDictionary(action: .install, overrides: ["ENTITLEMENTS_DONT_REMOVE_GET_TASK_ALLOW": "YES"]) { dict in
                #expect(dict["com.apple.security.get-task-allow"] == "YES")
            }
        }
    }

    @Test(.requireSDKs(.macOS), .userDefaults(["AppSandboxConflictingValuesEmitsWarning":"1"]))
    func appSandboxEntitlementAndBuildSettingConflictEmitsExpectedDiagnostics() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                    "GENERATE_INFOPLIST_FILE": "YES"
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                               ]
                                              ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                        ]),
                    ]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let srcRoot = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try fs.createDirectory(srcRoot, recursive: true)

        try await fs.writePlist(Path("/tmp/aWorkspace/aProject/Entitlements.plist"), .plDict([:]))

        func results(action: BuildAction, overrides: [String: String] = [:], appSandboxEntitlementValueOverride: Bool, resultsCompletion: (TaskConstructionTester.PlanningResults) -> Void, sourceLocation: SourceLocation = #_sourceLocation) async throws {

            let provisioningOverrides = ProvisioningTaskInputs(signedEntitlements: .plDict([
                "com.apple.security.app-sandbox": .plBool(appSandboxEntitlementValueOverride),
            ]))

            await tester.checkBuild(BuildParameters(action: action, configuration: "Config", overrides: overrides), runDestination: .macOS, provisioningOverrides: provisioningOverrides, fs: fs) { results in
                results.checkTarget("App") { target in
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Entitlements.plist")) { _, _ in }
                    resultsCompletion(results)
                }
            }
        }

        // When build setting and entitlement values agree, then there should be no diagnostics
        try await results(action: .build, overrides: ["ENABLE_APP_SANDBOX":"YES"], appSandboxEntitlementValueOverride: true) { results in
            results.checkNoDiagnostics()
        }

        // When build setting and entitlement values agree, then there should be no diagnostics
        try await results(action: .build, overrides: ["ENABLE_APP_SANDBOX":"NO"], appSandboxEntitlementValueOverride: false) { results in
            results.checkNoDiagnostics()
        }

        // When build setting and entitlement values disagree, we expect diagnostics
        try await results(action: .build, overrides: ["ENABLE_APP_SANDBOX":"YES"], appSandboxEntitlementValueOverride: false) { results in
            results.checkWarning(
                .equal(
                    "The \'ENABLE_APP_SANDBOX\' build setting is set to \'YES\', but entitlement \'com.apple.security.app-sandbox\' is set to \'NO\' in your entitlements file.\n/tmp/aWorkspace/aProject/Entitlements.plist: To enable \'ENABLE_APP_SANDBOX\', remove the entitlement from your entitlements file.\nTo disable \'ENABLE_APP_SANDBOX\', remove the entitlement from your entitlements file and disable \'ENABLE_APP_SANDBOX\' in  build settings. (in target \'App\' from project \'aProject\')"
                )
            )
        }

        // When build setting and entitlement values disagree, we expect diagnostics
        try await results(action: .build, overrides: ["ENABLE_APP_SANDBOX":"NO"], appSandboxEntitlementValueOverride: true) { results in
            results.checkWarning(
                .equal(
                    "The \'ENABLE_APP_SANDBOX\' build setting is set to \'NO\', but entitlement \'com.apple.security.app-sandbox\' is set to \'YES\' in your entitlements file.\nTo enable \'ENABLE_APP_SANDBOX\', remove the entitlement from your entitlements file, and enable \'ENABLE_APP_SANDBOX\' in build settings.\n/tmp/aWorkspace/aProject/Entitlements.plist: To disable \'ENABLE_APP_SANDBOX\', remove the entitlement from your entitlements file. (in target \'App\' from project \'aProject\')"
                )
            )
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS, comment: "Code signing is only available on macOS"))
    func codesignHardenedRuntimeForSupportedDestinations() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                    "GENERATE_INFOPLIST_FILE": "YES",
                ]),
            ],
            targets: [
                TestAggregateTarget("All", dependencies: ["App", "macOSFramework", "watchOSFramework"]),
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Release", buildSettings: ["SDKROOT": "iphoneos",
                                                                                            "SUPPORTS_MACCATALYST": "YES"])],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m"])]
                ),
                TestStandardTarget(
                    "macOSFramework",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Release", buildSettings: ["SDKROOT": "macosx"])],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m"])]
                ),
                TestStandardTarget(
                    "watchOSFramework",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Release", buildSettings: ["SDKROOT": "watchos"])],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m"])]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let srcRoot = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try fs.createDirectory(srcRoot, recursive: true)
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/"), recursive: true)

        try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "")
        try await fs.writePlist(Path("/tmp/aWorkspace/aProject/Entitlements.plist"), .plDict([:]))

        // Check hardened runtime option is specified for non-simulator destinations.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_HARDENED_RUNTIME": "YES"]), runDestination: .macCatalyst, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "3ACDE4E702E4", "-o", "runtime", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["OTHER_CODE_SIGN_FLAGS": "-o library,restrict,runtime"]), runDestination: .macCatalyst, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "3ACDE4E702E4", "-o", "library,restrict,runtime", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "YES", "ENABLE_HARDENED_RUNTIME": "YES", "CODE_SIGN_RESTRICT": "YES"]), runDestination: .iOS, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "-o", "library,restrict,runtime", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_HARDENED_RUNTIME": "YES"]), runDestination: .iOS, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "-o", "runtime", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_HARDENED_RUNTIME": "YES"]), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("macOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "3ACDE4E702E4", "-o", "runtime", "--entitlements", .suffix("macOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/macOSFramework.framework/Versions/A"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_HARDENED_RUNTIME": "YES"]), runDestination: .watchOS, fs: fs) { results in
            results.checkTarget("watchOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "-o", "runtime", "--entitlements", .suffix("watchOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/watchOSFramework.framework"])
                }
                results.checkNoDiagnostics()
            }
        }

        // Check hardened runtime option is ignored for unsupported (simulator) destinations.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_HARDENED_RUNTIME": "YES"]), runDestination: .iOSSimulator, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_LIBRARY_VALIDATION": "YES", "ENABLE_HARDENED_RUNTIME": "YES", "CODE_SIGN_RESTRICT": "YES"]), runDestination: .iOSSimulator, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "-o", "library,restrict", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["OTHER_CODE_SIGN_FLAGS": "-o runtime"]), runDestination: .iOSSimulator, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["OTHER_CODE_SIGN_FLAGS": "-o library,restrict,runtime"]), runDestination: .iOSSimulator, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "-o", "library,restrict", "--entitlements", .suffix("App.app.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Applications/App.app"])
                }
                results.checkNoDiagnostics()
            }
        }
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["ENABLE_HARDENED_RUNTIME": "YES"]), runDestination: .watchOSSimulator, fs: fs) { results in
            results.checkTarget("watchOSFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", .suffix("watchOSFramework.framework.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/Library/Frameworks/watchOSFramework.framework"])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, comment: "Code signing is only available on macOS"))
    func codesignWithLaunchConstraints() async throws {
        // Test that an empty tool target behaves properly.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                    TestFile("SelfLaunchConstraint.plist"),
                    TestFile("ParentLaunchConstraint.plist"),
                    TestFile("ResponsibleLaunchConstraint.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                    "INFOPLIST_FILE": "Tool.plist",
                    "INFOPLIST_PREPROCESS": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [TestBuildConfiguration("Release")],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m"])]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        // Check --launch-constraint-self is passed when the build setting is configured
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["LAUNCH_CONSTRAINT_SELF": "/tmp/SelfLaunchConstraint.plist"]), runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("Tool.xcent"), "--generate-entitlement-der", "--launch-constraint-self", .suffix("SelfLaunchConstraint.plist"), "/tmp/aProject.dst/usr/local/bin/Tool"])
                }
            }
        }

        // Check --launch-constraint-parent is passed when the build setting is configured
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["LAUNCH_CONSTRAINT_PARENT": "/tmp/ParentLaunchConstraint.plist"]), runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("Tool.xcent"), "--generate-entitlement-der", "--launch-constraint-parent", .suffix("ParentLaunchConstraint.plist"), "/tmp/aProject.dst/usr/local/bin/Tool"])
                }
            }
        }


        // Check --launch-constraint-responsible is passed when the build setting is configured
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["LAUNCH_CONSTRAINT_RESPONSIBLE": "/tmp/ResponsibleLaunchConstraint.plist"]), runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("Tool.xcent"), "--generate-entitlement-der", "--launch-constraint-responsible", .suffix("ResponsibleLaunchConstraint.plist"), "/tmp/aProject.dst/usr/local/bin/Tool"])
                }
            }
        }

        // Check that all launch constraint arguments are passed when the build settings are configured
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["LAUNCH_CONSTRAINT_SELF": "/tmp/SelfLaunchConstraint.plist", "LAUNCH_CONSTRAINT_PARENT": "/tmp/ParentLaunchConstraint.plist", "LAUNCH_CONSTRAINT_RESPONSIBLE": "/tmp/ResponsibleLaunchConstraint.plist"]), runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("Tool.xcent"), "--generate-entitlement-der", "--launch-constraint-self", .suffix("SelfLaunchConstraint.plist"), "--launch-constraint-parent", .suffix("ParentLaunchConstraint.plist"), "--launch-constraint-responsible", .suffix("ResponsibleLaunchConstraint.plist"), "/tmp/aProject.dst/usr/local/bin/Tool"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, comment: "Code signing is only available on macOS"))
    func codesignWithLibraryConstraints() async throws {
        // Test that an empty tool target behaves properly.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                    TestFile("SelfLaunchConstraint.plist"),
                    TestFile("ParentLaunchConstraint.plist"),
                    TestFile("ResponsibleLaunchConstraint.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                    "INFOPLIST_FILE": "Tool.plist",
                    "INFOPLIST_PREPROCESS": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [TestBuildConfiguration("Release")],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m"])]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        // Check --library-constraint is passed when the build setting is configured on macOS 14
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["LIBRARY_LOAD_CONSTRAINT": "/tmp/LibraryLoadConstraint.plist"]), runDestination: .macOS, systemInfo: SystemInfo(operatingSystemVersion: Version(14), productBuildVersion: "99A98", nativeArchitecture: "arm64")) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("Tool.xcent"), "--generate-entitlement-der", "--library-constraint", .suffix("LibraryLoadConstraint.plist"), "/tmp/aProject.dst/usr/local/bin/Tool"])
                }
            }
        }

        // Check --library-constraint is *not* passed when the build setting is configured on macOS 13
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["LIBRARY_LOAD_CONSTRAINT": "/tmp/LibraryLoadConstraint.plist"]), runDestination: .macOS, systemInfo: SystemInfo(operatingSystemVersion: Version(13), productBuildVersion: "99A98", nativeArchitecture: "arm64")) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkCommandLineMatches(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", .suffix("Tool.xcent"), "--generate-entitlement-der", "/tmp/aProject.dst/usr/local/bin/Tool"])
                }
            }
        }
    }
}
