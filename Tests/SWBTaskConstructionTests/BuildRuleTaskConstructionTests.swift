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
import enum SWBProtocol.BuildAction
import enum SWBProtocol.ExternalToolResult
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct BuildRuleTaskConstructionTests: CoreBasedTests {
    /// Test custom build rules.
    @Test(.requireSDKs(.macOS))
    func customBuildRules() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SomeProj.fake-project"),
                    TestFile("SomeProj.fake-neutral"),
                    TestFile("OtherProj.fake-project"),
                    TestFile("file.m"),
                    TestFile("file.mm"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "IBC_EXEC": ibtoolPath.str,
                                        "BUILD_VARIANTS": "normal debug profile",
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "SomeFwk",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SomeProj.fake-neutral",
                            "file.m",
                            "file.mm",
                        ]),
                        TestResourcesBuildPhase([
                            "SomeProj.fake-project",
                        ]),
                        TestCopyFilesBuildPhase([
                            "OtherProj.fake-project",
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*.fake-project", compilerIdentifier: "com.apple.compilers.pbxcp"),
                        TestBuildRule(filePattern: "*.fake-neutral", script: "cp ${SCRIPT_INPUT_FILE} ${SCRIPT_OUTPUT_FILE_0}", outputs: [
                            "$(DERIVED_FILES_DIR)/$(INPUT_FILE_NAME).c"
                        ], runOncePerArchitecture: false),
                        TestBuildRule(fileTypeIdentifier: "sourcecode.c.objc", script: "cp ${SCRIPT_INPUT_FILE} ${SCRIPT_OUTPUT_FILE_0}", outputs: [
                            "$(DERIVED_FILES_DIR)/$(INPUT_FILE_NAME).x"
                        ], runOncePerArchitecture: false),
                        TestBuildRule(fileTypeIdentifier: "sourcecode.cpp.objcpp", compilerIdentifier: "com.apple.xcode.tools.ibtool.compiler"),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "Ld", "GenerateTAPI", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "WriteAuxiliaryFile"])

            results.checkTarget("SomeFwk") { target in
                // Check that there is a Copy task to copy the .fake-project file to the Resources phase.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/SomeFwk.framework/Versions/A/Resources/SomeProj.fake-project", "\(SRCROOT)/Sources/SomeProj.fake-project"])) { _ in }

                // Check that there is a Copy task to copy the .fake-project file to the Frameworks phase.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/SomeFwk.framework/Versions/A/Frameworks/OtherProj.fake-project", "\(SRCROOT)/Sources/OtherProj.fake-project"])) { _ in }

                // Check that there's only one RuleScriptExecution for fake-neutral, since it's architecture-independent
                results.checkTask(.matchTarget(target), .matchRule(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeProj.fake-neutral.c", "\(SRCROOT)/Sources/SomeProj.fake-neutral", "normal", "undefined_arch"])) { _ in }

                // Check that the architecture-neutral rule's outputs are still varianted per architecture
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/Objects-normal/x86_64/SomeProj.fake-neutral.o", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeProj.fake-neutral.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/Objects-debug/x86_64/SomeProj.fake-neutral.o", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeProj.fake-neutral.c", "debug", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/Objects-profile/x86_64/SomeProj.fake-neutral.o", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeProj.fake-neutral.c", "profile", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["RuleScriptExecution", "/tmp/Test/aProject/build/aProject.build/Debug/SomeFwk.build/DerivedSources/file.m.x", "/tmp/Test/aProject/Sources/file.m", "normal", "undefined_arch"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "/tmp/Test/aProject/Sources/file.mm"])) { _ in }
            }

            // Check there are no diagnostics.
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    // Build a command line tool, that uses custom build rules, to validate
    // input and output file lists.
    @Test(.requireSDKs(.host))
    func customBuildRulesInputAndOutputFileList() async throws {
        let testProject = TestProject(
            "coolWebsite",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("fake-typescript-compiler.fake-sh"),
                    TestFile("extra-input-files.xcfilelist"),
                    TestFile("license.xcfilelist"),
                    TestFile("license-text.txt"),
                    TestFile("license-year.txt"),
                    TestFile("prefix.txt"),
                    TestFile("suffix.txt"),
                    TestFile("example.fake-ts"),
                    TestFile("mock.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "BUILD_VARIANTS": "debug",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "TypeScriptApp",
                    type: .commandLineTool,  // Use a target that is buildable on all platforms
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("example.fake-ts"),
                            TestBuildFile("mock.c"),
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*.fake-ts",
                                      script: #"bash "${SRCROOT}/fake-typescript-compiler.fake-sh""#,
                                      inputs: ["$(SRCROOT)/fake-typescript-compiler.fake-sh"],
                                      inputFileLists: ["$(SRCROOT)/extra-input-files.xcfilelist", "$(SRCROOT)/license.xcfilelist"],
                                      outputs: ["$(INPUT_FILE_PATH).fake-js"],
                                      outputFileLists: ["$(SRCROOT)/extra-output-files-odd.xcfilelist", "$(SRCROOT)/extra-output-files-even.xcfilelist"]),
                    ]
                )
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)

        try await fs.writeFileContents(Path(SRCROOT).join("fake-typescript-compiler.fake-sh")) { stream in
            let script = "# content of shell script is irrelevant in CoreBasedTests because it is not executed"
            stream <<< script
        }

        try await fs.writeFileContents(Path(SRCROOT).join("license.xcfilelist")) { stream in
            stream <<< "$(SRCROOT)/license-year.txt\n"
            stream <<< "$(SRCROOT)/license-text.txt\n"
        }

        try await fs.writeFileContents(Path(SRCROOT).join("extra-input-files.xcfilelist")) { stream in
            stream <<< "$(SRCROOT)/prefix.txt\n"
            stream <<< "$(SRCROOT)/suffix.txt\n"
        }

        try await fs.writeFileContents(Path(SRCROOT).join("extra-output-files-odd.xcfilelist")) { stream in
            stream <<< "$(SRCROOT)/one.txt\n"
            stream <<< "$(SRCROOT)/three.txt\n"
        }

        try await fs.writeFileContents(Path(SRCROOT).join("extra-output-files-even.xcfilelist")) { stream in
            stream <<< "$(SRCROOT)/two.txt\n"
            stream <<< "$(SRCROOT)/four.txt\n"
        }

        try await fs.writeFileContents(Path(SRCROOT).join("example.fake-ts")) { stream in
            stream <<< "Fake typescript code\n"
            stream <<< "Fake typescript code line 2\n"
        }

        try await fs.writeFileContents(Path(SRCROOT).join("license-text.txt")) { stream in
            stream <<< "LICENSE TEXT\n"
        }

        try await fs.writeFileContents(Path(SRCROOT).join("license-year.txt")) { stream in
            stream <<< "2021\n"
        }

        try await fs.writeFileContents(Path(SRCROOT).join("prefix.txt")) { stream in
            stream <<< "PREFIX "
        }

        try await fs.writeFileContents(Path(SRCROOT).join("suffix.txt")) { stream in
            stream <<< " SUFFIX"
        }

        let overrides = [
            "FAKE_PATH_LICENSE_YEAR": Path(SRCROOT).join("license-year.txt").str,
            "FAKE_PATH_LICENSE_TEXT": Path(SRCROOT).join("license-text.txt").str,
            "FAKE_PATH_PREFIX": Path(SRCROOT).join("prefix.txt").str,
            "FAKE_PATH_SUFFIX": Path(SRCROOT).join("suffix.txt").str
        ]

        // Check the build.
        for enableSandboxingInTest in [true, false] {
            await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: overrides.addingContents(of: ["ENABLE_USER_SCRIPT_SANDBOXING": enableSandboxingInTest ? "YES" : "NO"])), runDestination: .host, fs: fs) { results in
                results.checkTarget("TypeScriptApp") { target in
                    results.checkNoDiagnostics()
                    let effectivePlatformName = results.builtProductsDirSuffix(target)
                    results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("example.fake-ts"), .matchRuleItemBasename("example.fake-ts.fake-js")) { task in

                        let inputFileListPath = Path(SRCROOT).join("build/coolWebsite.build/Debug\(effectivePlatformName)/TypeScriptApp.build/InputFileList").str
                        let outputFileListPath = Path(SRCROOT).join("build/coolWebsite.build/Debug\(effectivePlatformName)/TypeScriptApp.build/OutputFileList").str
                        task.checkRuleInfo(["RuleScriptExecution",
                                            Path(SRCROOT).join("example.fake-ts.fake-js").str,
                                            Path(SRCROOT).join("example.fake-ts").str,
                                            "debug",
                                            results.runDestinationTargetArchitecture])
                        if enableSandboxingInTest {
                            #expect(task.commandLine.first == "/usr/bin/sandbox-exec")
                        } else {
                            task.checkCommandLine(["/bin/sh", "-c", #"bash "${SRCROOT}/fake-typescript-compiler.fake-sh""#])
                        }

                        // Check that we normalized the path passed to the script.
                        var inputs: [NodePattern] = [
                            .path(Path(SRCROOT).join("example.fake-ts").str),
                            .path(Path(SRCROOT).join("fake-typescript-compiler.fake-sh").str),
                            .path(Path(SRCROOT).join("extra-input-files.xcfilelist").str),
                            .path(Path(SRCROOT).join("license.xcfilelist").str),
                            .path(Path(SRCROOT).join("extra-output-files-odd.xcfilelist").str),
                            .path(Path(SRCROOT).join("extra-output-files-even.xcfilelist").str),
                            .path(Path(SRCROOT).join("prefix.txt").str),
                            .path(Path(SRCROOT).join("suffix.txt").str),
                            .pathPattern(.and(
                                .prefix(inputFileListPath),
                                .suffix("-extra-input-files-resolved.xcfilelist"))),
                            .path(Path(SRCROOT).join("license-year.txt").str),
                            .path(Path(SRCROOT).join("license-text.txt").str),
                            .pathPattern(.and(
                                .prefix(inputFileListPath),
                                .suffix("-license-resolved.xcfilelist"))),
                            .pathPattern(.and(
                                .prefix(outputFileListPath), .suffix("-extra-output-files-odd-resolved.xcfilelist"))),
                            .pathPattern(.and(
                                .prefix(outputFileListPath), .suffix("-extra-output-files-even-resolved.xcfilelist"))),
                            .any
                        ]

                        if enableSandboxingInTest {
                            inputs.append(.pathPattern(.and(
                                .prefix(Path(SRCROOT).join("build/coolWebsite.build/Debug\(effectivePlatformName)/TypeScriptApp.build/").str),
                                .suffix(".sb"))))
                        }

                        inputs.append(.any)
                        inputs.append(.any)
                        task.checkInputs(inputs)

                        task.checkOutputs([
                            // Verify the command has a virtual output node that can be used as a dependency.
                            .path(Path(SRCROOT).join("example.fake-ts.fake-js").str),
                            .path(Path(SRCROOT).join("one.txt").str),
                            .path(Path(SRCROOT).join("three.txt").str),
                            .path(Path(SRCROOT).join("two.txt").str),
                            .path(Path(SRCROOT).join("four.txt").str),
                        ])

                        // Validate that the task has a reasonable environment.
                        // This check is used both to verify behaviors specific to this test, and also important behaviors which apply to all scripts which we want to ensure are tested.
                        let scriptVariables: [String: StringPattern?] = [
                            "ACTION": .equal("build"),
                            "TARGET_NAME": .equal("TypeScriptApp"),
                            "SCRIPT_INPUT_FILE_0": .equal(Path(SRCROOT).join("fake-typescript-compiler.fake-sh").str),
                            "SCRIPT_INPUT_FILE_COUNT": .equal("1"),

                            "SCRIPT_OUTPUT_FILE_0": .equal(Path(SRCROOT).join("example.fake-ts.fake-js").str),
                            "SCRIPT_OUTPUT_FILE_COUNT": .equal("1"),

                            "SCRIPT_INPUT_FILE_LIST_COUNT": .equal("2"),
                            "SCRIPT_INPUT_FILE_LIST_0": .and(.prefix(inputFileListPath), .suffix("-extra-input-files-resolved.xcfilelist")),
                            "SCRIPT_INPUT_FILE_LIST_1": .and(.prefix(inputFileListPath), .suffix("-license-resolved.xcfilelist")),


                            "SCRIPT_OUTPUT_FILE_LIST_COUNT": .equal("2"),
                            "SCRIPT_OUTPUT_FILE_LIST_0": .and(.prefix(outputFileListPath), .suffix("-extra-output-files-odd-resolved.xcfilelist")),
                            "SCRIPT_OUTPUT_FILE_LIST_1": .and(.prefix(outputFileListPath), .suffix("-extra-output-files-even-resolved.xcfilelist")),
                        ]
                        task.checkEnvironment(scriptVariables)
                    }
                }
            }
        }
    }

    /// Test some special behaviors in custom build rules, including:
    /// - That a custom build rule can define flags to be passed to the tool which processes its output files.
    /// - Rules with multiple file patterns.
    /// - Rules matching header files.
    /// - That if a build rule generates multiple output files with the same name, which would be processed by another tool to generate the same file, then a uniquing suffix is appended to the file root.
    @Test(.requireSDKs(.macOS))
    func customBuildRulesSpecialBehaviors() async throws {
        let genC1 = TestFile("Gen.fake-c", guid: "FR_Gen1")
        let genC2 = TestFile("Gen.fake-c", guid: "FR_Gen2")
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Custom.fake-lang"),
                    TestFile("regular.defs"),
                    TestFile("custom.defs"),
                    TestFile("special.defs"),
                    TestFile("header.h"),
                    genC1,
                    TestGroup(
                        "Subdir", path: "Subdir",
                        children: [
                            genC2,
                        ]),
                ]),
            targets: [
                TestStandardTarget(
                    "Tool", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MIG_EXEC": migPath.str,
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Custom.fake-lang"),
                            TestBuildFile("regular.defs"),
                            TestBuildFile("custom.defs"),
                            TestBuildFile("special.defs"),
                            TestBuildFile("header.h"),
                            TestBuildFile(genC1),
                            TestBuildFile(genC2),
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*/*.fake-lang", script: "true", outputs: [
                            "$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)/foo1.c",
                            "$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)/foo2.c",
                        ], outputFilesCompilerFlags: [
                            ["-flag1"],
                            ["-flag2", "-flag3"],
                        ]),
                        TestBuildRule(filePattern: "*/custom.defs */special.defs", script: "true", outputs: [
                            "$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)/$(INPUT_FILE_BASE)User.c",
                        ], outputFilesCompilerFlags: [
                            ["-specialFlag"],
                        ]),
                        TestBuildRule(filePattern: "*.h", script: "true", outputs: [
                            "$(DERIVED_FILES_DIR)$(CURRENT_ARCH)/$(INPUT_FILE_BASE)_gen.cpp",
                        ], outputFilesCompilerFlags: [
                            ["-DHEADER_GEN=1"],
                        ]),
                        TestBuildRule(filePattern: "*.fake-c", script: "true", outputs: [
                            "$(DERIVED_FILES_DIR)/$(INPUT_FILE_DIR)/$(INPUT_FILE_BASE).c",
                        ]),
                    ]
                )])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            // Check that the clang tasks which process the output of the .fake-lang task add the appropriate flags.
            results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("Custom.fake-lang")) { task in
                task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources-normal/x86_64/foo1.c", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources-normal/x86_64/foo2.c", "\(SRCROOT)/Sources/Custom.fake-lang", "normal", "x86_64"])
            }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo1.c")) { task in
                task.checkCommandLineContains(["-flag1"])
            }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo2.c")) { task in
                task.checkCommandLineContains(["-flag2", "-flag3"])
            }

            // Check that regular.defs is processed by MiG (there's no custom build rule for it).
            results.checkTask(.matchRuleType("Mig")) { task in
                task.checkRuleInfo(["Mig", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/regular.h", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/regularUser.c", "\(SRCROOT)/Sources/regular.defs", "normal", "x86_64"])
            }

            // Check that the custom and special .defs files are processed by the build rule.
            results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("custom.defs")) { task in
                task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources-normal/x86_64/customUser.c", "\(SRCROOT)/Sources/custom.defs", "normal", "x86_64"])
            }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("customUser.c")) { task in
                task.checkCommandLineContains(["-specialFlag"])
            }
            results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("special.defs")) { task in
                task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources-normal/x86_64/specialUser.c", "\(SRCROOT)/Sources/special.defs", "normal", "x86_64"])
            }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("specialUser.c")) { task in
                task.checkCommandLineContains(["-specialFlag"])
            }

            // Check that the .h file is processed by the build rule.
            // This is tested because early in Swift Build's existence header files were explicitly skipped when matching build rules because the file types specified by compiler specs weren't yet respected.
            results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("header.h")) { task in
                task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSourcesx86_64/header_gen.cpp", "\(SRCROOT)/Sources/header.h", "normal", "x86_64"])
            }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("header_gen.cpp")) { task in
                task.checkCommandLineContains(["-DHEADER_GEN=1"])
            }

            // Check that the two Gen.fake-c files are compiled to .o files with the uniquing suffix applied.
            results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItem("\(SRCROOT)/Sources/Gen.fake-c")) { task in
                task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/tmp/Test/aProject/Sources/Gen.c", "\(SRCROOT)/Sources/Gen.fake-c", "normal", "x86_64"])
                task.checkOutputs(contain: [
                    .path("\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/tmp/Test/aProject/Sources/Gen.c"),
                ])
            }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/tmp/Test/aProject/Sources/Gen.c")) { task in
                task.checkOutputs(contain: [
                    .path("\(SRCROOT)/build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/Gen-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: Path("\(SRCROOT)/Sources/Gen.fake-c"))).o"),
                ])
            }
            results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItem("\(SRCROOT)/Sources/Subdir/Gen.fake-c")) { task in
                task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/tmp/Test/aProject/Sources/Subdir/Gen.c", "\(SRCROOT)/Sources/Subdir/Gen.fake-c", "normal", "x86_64"])
                task.checkOutputs(contain: [
                    .path("\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/tmp/Test/aProject/Sources/Subdir/Gen.c"),
                ])
            }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/tmp/Test/aProject/Sources/Subdir/Gen.c")) { task in
                task.checkOutputs(contain: [
                    .path("\(SRCROOT)/build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/Gen-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: Path("\(SRCROOT)/Sources/Subdir/Gen.fake-c"))).o"),
                ])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptRuleWithNoOutputs() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Foo.fake-bar"),
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Release")],
                    buildPhases: [TestSourcesBuildPhase(["Foo.fake-bar", "main.c"])],
                    buildRules: [TestBuildRule(filePattern: "*.fake-bar", script: "echo foo", outputs: [])]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Release"), runDestination: .macOS) { results in
            results.checkError(.equal("shell script build rule for '\(SRCROOT)/Foo.fake-bar' must declare at least one output file (in target 'App' from project 'aProject')"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildRuleWithDuplicateFileReferences() async throws {
        let targetName = "AppTarget"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Multiple.fake-lang"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "CODE_SIGN_IDENTITY": ""
                ]),
            ],
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Multiple.fake-lang",
                            "Multiple.fake-lang",
                        ]),
                    ],
                    buildRules: [TestBuildRule(filePattern: "*/*.fake-lang", script: "echo hi", outputs: [
                        "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_DIR)/$(INPUT_FILE_BASE).data",
                    ])]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget(targetName) { target in
                // There should only be one task to process Multiple.fake-lang, since there are erroneously two build files for one file reference.
                results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("Multiple.fake-lang")) { task in
                    task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/Debug/Multiple.data", "\(SRCROOT)/Sources/Multiple.fake-lang", "normal", "x86_64"])
                }

                // There should also be a warning emitted about the duplicate file references.
                results.checkWarning(.prefix("Skipping duplicate build file in Compile Sources build phase: \(SRCROOT)/Sources/Multiple.fake-lang"))
            }

            // Check there are no other diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test some special behaviors in custom build rules and files existing in your project.
    @Test(.requireSDKs(.macOS))
    func multipleFileProcessedError() async throws {
        let srcroot = Path("/var/tmp/aProject")

        let testProject = TestProject(
            "aProject",
            sourceRoot: srcroot,
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                    TestFile("error.c", path: "\(srcroot.str)/build/aProject.build/Debug/Tool.build/DerivedSources/error.c"),
                    TestFile("custom.fake-lang"),
                ]),
            targets: [
                TestStandardTarget(
                    "Tool", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            // NOTE: The order in which the `error.c` appears matters. If it comes after the `custom.fake-lang`, the error will not present itself.
                            TestBuildFile("error.c"),
                            TestBuildFile("custom.fake-lang"),
                            TestBuildFile("main.c"),
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*/*.fake-lang", script: "true", outputs: [
                            "$(DERIVED_FILE_DIR)/error.c",
                        ]),
                    ]
                )])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError(.equal("the file group with identifier '\(srcroot.str)/build/aProject.build/Debug/Tool.build/DerivedSources/error.c' has already been processed. (in target 'Tool' from project 'aProject')"))
            results.checkNoDiagnostics()
        }
    }

    /// Test a build rule which overrides the _vers.c file compilation.
    @Test(.requireSDKs(.macOS))
    func overrideVersionCBuildRule() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("file.fake-x"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "BUILD_VARIANTS": "normal debug profile",
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "VERSIONING_SYSTEM": "apple-generic"
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "SomeFwk",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "file.fake-x",
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "$(DERIVED_FILE_DIR)/$(PRODUCT_NAME)_vers.c", script: "touch \"$SCRIPT_OUTPUT_FILE_0\"", outputs: [
                            "$(DERIVED_FILE_DIR)/$(FULL_PRODUCT_NAME)_vers1.c"
                        ], runOncePerArchitecture: false)
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "Ld", "GenerateTAPI", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "WriteAuxiliaryFile"])

            results.checkTarget("SomeFwk") { target in
                // Check that there's only one RuleScriptExecution for fake-neutral, since it's architecture-independent
                results.checkTask(.matchTarget(target), .matchRule(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeFwk.framework_vers1.c", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeFwk_vers.c", "normal", "undefined_arch"])) { _ in }

                // Check that the architecture-neutral rule's outputs are still varianted per architecture
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/Objects-normal/x86_64/SomeFwk.framework_vers1.o", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeFwk.framework_vers1.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/Objects-debug/x86_64/SomeFwk.framework_vers1.o", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeFwk.framework_vers1.c", "debug", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/Objects-profile/x86_64/SomeFwk.framework_vers1.o", "\(SRCROOT)/build/aProject.build/Debug/SomeFwk.build/DerivedSources/SomeFwk.framework_vers1.c", "profile", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
            }

            results.checkWarning(.equal("no rule to process file '/tmp/Test/aProject/Sources/file.fake-x' of type 'file' for architecture 'x86_64' (in target 'SomeFwk' from project 'aProject')"))
            results.checkWarning(.equal("no rule to process file '/tmp/Test/aProject/Sources/file.fake-x' of type 'file' for architecture 'x86_64' (in target 'SomeFwk' from project 'aProject')"))
            results.checkWarning(.equal("no rule to process file '/tmp/Test/aProject/Sources/file.fake-x' of type 'file' for architecture 'x86_64' (in target 'SomeFwk' from project 'aProject')"))

            // Check there are no diagnostics.
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildRulesWithUnsupportedPhases() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("test.c"),
                    TestFile("test.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["test.c", "test.swift"])
                    ],
                    buildRules: [
                        TestBuildRule(fileTypeIdentifier: "sourcecode.c", compilerIdentifier: "com.apple.compilers.pbxcp")
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: PseudoFS()) { results in
            results.checkWarning(.equal("The file \"/tmp/Test/aProject/test.c\" cannot be processed by the Compile Sources build phase using the \"PBXCp\" rule. (in target 'App' from project 'aProject')"))
            results.checkNoDiagnostics()
        }
    }
}
