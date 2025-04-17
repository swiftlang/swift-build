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

import class Foundation.ProcessInfo
import struct Foundation.URL
import struct Foundation.UUID

import Testing

import SwiftBuildTestSupport
import func SWBBuildService.commandLineDisplayString
import SWBBuildSystem
import SWBCore
import struct SWBProtocol.RunDestinationInfo
import struct SWBProtocol.TargetDescription
import struct SWBProtocol.TargetDependencyRelationship
import SWBTestSupport
import SWBTaskExecution
@_spi(Testing) import SWBUtil
import SWBTestSupport

@Suite(.requireXcode16())
fileprivate struct BuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory, arguments: ["clang", "swiftc"])
    func commandLineTool(linkerDriver: String) async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                        TestFile("dynamic.swift"),
                        TestFile("static.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": "$(ARCHS_STANDARD)",
                        "CODE_SIGNING_ALLOWED": ProcessInfo.processInfo.hostOperatingSystem() == .macOS ? "YES" : "NO",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "$(HOST_PLATFORM)",
                        "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                        "SWIFT_VERSION": swiftVersion,
                        "LINKER_DRIVER": linkerDriver,
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "LD_RUNPATH_SEARCH_PATHS": "@loader_path/",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("dynamiclib")),
                                TestBuildFile(.target("staticlib")),
                            ])
                        ],
                        dependencies: [
                            "dynamiclib",
                            "staticlib",
                        ]
                    ),
                    TestStandardTarget(
                        "dynamiclib",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "DYLIB_INSTALL_NAME_BASE": "$ORIGIN",
                                "DYLIB_INSTALL_NAME_BASE[sdk=macosx*]": "@rpath",

                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                                "EXECUTABLE_PREFIX[sdk=windows*]": "",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["dynamic.swift"]),
                        ]
                    ),
                    TestStandardTarget(
                        "staticlib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                                "EXECUTABLE_PREFIX[sdk=windows*]": "",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["static.swift"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< "import dynamiclib\n"
                stream <<< "import staticlib\n"
                stream <<< "dynamicLib()\n"
                stream <<< "dynamicLib()\n"
                stream <<< "staticLib()\n"
                stream <<< "print(\"Hello world\")\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("dynamic.swift")) { stream in
                stream <<< "public func dynamicLib() { }"
            }

            try await tester.fs.writeFileContents(projectDir.join("static.swift")) { stream in
                stream <<< "public func staticLib() { }"
            }

            try await tester.fs.writePlist(projectDir.join("Entitlements.plist"), .plDict([:]))

            let provisioningInputs = [
                "dynamiclib": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:])),
                "staticlib": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:])),
                "tool": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))
            ]

            let destination: RunDestinationInfo = .host
            try await tester.checkBuild(runDestination: destination, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoErrors()

                let toolchain = try #require(core.toolchainRegistry.defaultToolchain)
                let environment: Environment
                if destination.imageFormat(core) == .elf {
                    environment = ["LD_LIBRARY_PATH": toolchain.path.join("usr/lib/swift/\(destination.platform)").str]
                } else {
                    environment = .init()
                }

                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join(core.hostOperatingSystem.imageFormat.executableName(basename: "tool")).str), arguments: [], environment: environment)
                #expect(executionResult.exitStatus == .exit(0))
                if core.hostOperatingSystem == .windows {
                    #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello world\r\n")
                } else {
                    #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello world\n")
                }
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }

    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func commandLineToolAutolinkingFoundation() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": "$(ARCHS_STANDARD)",
                        "CODE_SIGNING_ALLOWED": ProcessInfo.processInfo.hostOperatingSystem() == .macOS ? "YES" : "NO",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "$(HOST_PLATFORM)",
                        "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                        "SWIFT_VERSION": swiftVersion,
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< "import Foundation\n"
                stream <<< "let x = JSONDecoder()\n"
            }

            try await tester.fs.writePlist(projectDir.join("Entitlements.plist"), .plDict([:]))

            let provisioningInputs = [
                "tool": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))
            ]

            let destination: RunDestinationInfo = .host
            try await tester.checkBuild(runDestination: destination, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func debuggableCommandLineTool() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                        TestFile("dynamic.swift"),
                        TestFile("static.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": "$(ARCHS_STANDARD)",
                        "CODE_SIGNING_ALLOWED": ProcessInfo.processInfo.hostOperatingSystem() == .macOS ? "YES" : "NO",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "$(HOST_PLATFORM)",
                        "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                        "SWIFT_VERSION": swiftVersion,
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "LD_RUNPATH_SEARCH_PATHS": "@loader_path/",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("dynamiclib")),
                                TestBuildFile(.target("staticlib")),
                            ])
                        ],
                        dependencies: [
                            "dynamiclib",
                            "staticlib",
                        ]
                    ),
                    TestStandardTarget(
                        "dynamiclib",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "DYLIB_INSTALL_NAME_BASE": "$ORIGIN",
                                "DYLIB_INSTALL_NAME_BASE[sdk=macosx*]": "@rpath",

                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                                "EXECUTABLE_PREFIX[sdk=windows*]": "",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["dynamic.swift"]),
                        ]
                    ),
                    TestStandardTarget(
                        "staticlib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                                "EXECUTABLE_PREFIX[sdk=windows*]": "",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["static.swift"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< "import dynamiclib\n"
                stream <<< "import staticlib\n"
                stream <<< "dynamicLib()\n"
                stream <<< "dynamicLib()\n"
                stream <<< "staticLib()\n"
                stream <<< "print(\"Hello world\")\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("dynamic.swift")) { stream in
                stream <<< "public func dynamicLib() { }"
            }

            try await tester.fs.writeFileContents(projectDir.join("static.swift")) { stream in
                stream <<< "public func staticLib() { }"
            }

            try await tester.fs.writePlist(projectDir.join("Entitlements.plist"), .plDict([:]))

            let provisioningInputs = [
                "dynamiclib": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:])),
                "staticlib": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:])),
                "tool": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))
            ]

            let destination: RunDestinationInfo = .host
            try await tester.checkBuild(runDestination: destination, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoErrors()
                if core.hostOperatingSystem.imageFormat.requiresSwiftModulewrap {
                    try results.checkTask(.matchTargetName("tool"), .matchRulePattern(["WriteAuxiliaryFile", .suffix("LinkFileList")])) { task in
                        let auxFileAction = try #require(task.action as? AuxiliaryFileTaskAction)
                        let contents = try tester.fs.read(auxFileAction.context.input).asString
                        let files = contents.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        #expect(files.count == 2)
                        #expect(files[0].hasSuffix("tool.o"))
                        #expect(files[1].hasSuffix("main.o"))
                    }
                    let toolWrap = try #require(results.getTask(.matchTargetName("tool"), .matchRuleType("SwiftModuleWrap")))
                    try results.checkTask(.matchTargetName("tool"), .matchRuleType("Ld")) { task in
                        try results.checkTaskFollows(task, toolWrap)
                    }

                    try results.checkTask(.matchTargetName("dynamiclib"), .matchRulePattern(["WriteAuxiliaryFile", .suffix("LinkFileList")])) { task in
                        let auxFileAction = try #require(task.action as? AuxiliaryFileTaskAction)
                        let contents = try tester.fs.read(auxFileAction.context.input).asString
                        let files = contents.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        #expect(files.count == 2)
                        #expect(files[0].hasSuffix("dynamiclib.o"))
                        #expect(files[1].hasSuffix("dynamic.o"))
                    }
                    let dylibWrap = try #require(results.getTask(.matchTargetName("dynamiclib"), .matchRuleType("SwiftModuleWrap")))
                    try results.checkTask(.matchTargetName("dynamiclib"), .matchRuleType("Ld")) { task in
                        try results.checkTaskFollows(task, dylibWrap)
                    }

                    try results.checkTask(.matchTargetName("staticlib"), .matchRulePattern(["WriteAuxiliaryFile", .suffix("LinkFileList")])) { task in
                        let auxFileAction = try #require(task.action as? AuxiliaryFileTaskAction)
                        let contents = try tester.fs.read(auxFileAction.context.input).asString
                        let files = contents.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        #expect(files.count == 2)
                        #expect(files[0].hasSuffix("staticlib.o"))
                        #expect(files[1].hasSuffix("static.o"))
                    }
                    let staticWrap = try #require(results.getTask(.matchTargetName("staticlib"), .matchRuleType("SwiftModuleWrap")))
                    try results.checkTask(.matchTargetName("staticlib"), .matchRuleType("Libtool")) { task in
                        try results.checkTaskFollows(task, staticWrap)
                    }
                }

                let toolchain = try #require(try await getCore().toolchainRegistry.defaultToolchain)
                let environment: Environment
                if destination.platform == "linux" {
                    environment = ["LD_LIBRARY_PATH": toolchain.path.join("usr/lib/swift/linux").str]
                } else {
                    environment = .init()
                }

                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join(core.hostOperatingSystem.imageFormat.executableName(basename: "tool")).str), arguments: [], environment: environment)
                #expect(executionResult.exitStatus == .exit(0))
                if core.hostOperatingSystem == .windows {
                    #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello world\r\n")
                } else {
                    #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello world\n")
                }
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }

    @Test(.skipHostOS(.macOS), .skipHostOS(.windows, "cannot find testing library"), .requireThreadSafeWorkingDirectory)
    func unitTestWithGeneratedEntryPoint() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("library.swift"),
                        TestFile("test.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": "$(ARCHS_STANDARD)",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "$(HOST_PLATFORM)",
                        "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                        "SWIFT_VERSION": swiftVersion,
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "test",
                        type: .unitTest,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "LD_RUNPATH_SEARCH_PATHS": "@loader_path/",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["test.swift"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("library")),
                            ])
                        ],
                        dependencies: [
                            "library"
                        ]
                    ),
                    TestStandardTarget(
                        "library",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "DYLIB_INSTALL_NAME_BASE": "$ORIGIN",

                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                                "EXECUTABLE_PREFIX[sdk=windows*]": "",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["library.swift"]),
                        ],
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("library.swift")) { stream in
                stream <<< "public func foo() -> Int { 42 }\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("test.swift")) { stream in
                stream <<< """
                    import Testing
                    import library
                    @Suite struct MySuite {
                        @Test func myTest() async throws {
                            #expect(foo() == 42)
                        }
                    }
                """
            }

            let destination: RunDestinationInfo = .host
            try await tester.checkBuild(runDestination: destination, persistent: true) { results in
                results.checkNoErrors()

                let toolchain = try #require(try await getCore().toolchainRegistry.defaultToolchain)
                let environment: Environment
                if destination.platform == "linux" {
                    environment = ["LD_LIBRARY_PATH": toolchain.path.join("usr/lib/swift/linux").str]
                } else {
                    environment = .init()
                }

                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join(core.hostOperatingSystem.imageFormat.executableName(basename: "test.xctest")).str), arguments: ["--testing-library", "swift-testing"], environment: environment)
                #expect(String(decoding: executionResult.stderr, as: UTF8.self).contains("Test run started"))
            }
        }
    }

    /// Check that environment variables are propagated from the user environment correctly.
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireSystemPackages(apt: "yacc", yum: "byacc"))
    func userEnvironment() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("Foo.y")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "USE_HEADERMAP": "NO",
                                "YACC": tmpDirPath.join("yacc-script").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Foo", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["Foo.y"]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Foo.y")) { stream in
                stream <<<
                """
                %{
                static int yylex() { return 0; }
                static int yyerror(const char *format) { return 0; }
                %}
                %%
                list:
                ;
                %%
                """
            }

            guard let yaccPath = tester.findExecutable(basename: "yacc") else {
                Issue.record("couldn't find yacc executable")
                return
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("yacc-script")) {
                let codec = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .fullCommandLine)
                // We filter out any variables that are automatically added by the shell or llbuild
                $0 <<< "#!/bin/bash\n"
                $0 <<< "/usr/bin/env -u DEVELOPER_DIR | /usr/bin/sort | grep -v PWD= | grep -v SHLVL= | grep -v LLBUILD_ | grep -v ANDROID_ | grep -v _= \n"
                $0 <<< codec.encode([yaccPath.str]) <<< " \"$@\"\n"
            }
            try tester.fs.setFilePermissions(tmpDirPath.join("yacc-script"), permissions: 0o755)

            tester.userInfo = UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid:12345, home: Path("/Users/exampleUser"), environment: [
                "ENV_KEY": "ENV_VALUE"])

            try await tester.checkBuild(runDestination: .host) { results in
                // We expect one task with one line of output.
                results.checkTask(.matchRuleType("Yacc")) { task in
                    results.checkTaskOutput(task) { taskOutput in
                        #expect(taskOutput == "ENV_KEY=ENV_VALUE\n")
                    }
                }
                results.checkNoDiagnostics()
            }
        }
    }

    // MARK: Simulated Project Builds

    @Test(.requireSDKs(.host), .skipHostOS(.windows)) // FIXME: Windows: Need to implement /usr/bin/true support for skipped tasks in tests
    func simulatedEmptyTarget() async throws {
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
                                "mock",
                                buildPhases: [])
                        ])
                ])

            try await BuildOperationTester(getCore(), testWorkspace, simulated: true).checkBuild(runDestination: .host) { results in
                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()
            }
        }
    }

    /// Check the handling of shell scripts in different targets which produce the same output files.
    @Test(.requireSDKs(.macOS))
    func multipleProducersEmptyTarget() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("foo.c")]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)"
                            ])
                        ],
                        targets: [
                            TestAggregateTarget(
                                "combo",
                                buildPhases: [],
                                dependencies: ["agg1", "agg2", "agg3"]),
                            TestAggregateTarget(
                                "agg1",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "Script1", originalObjectID: "Script1", contents: "echo Script1", inputs: [],
                                        outputs: [
                                            "/tmp/script-output"
                                        ])
                                ]),
                            TestAggregateTarget(
                                "agg2",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "Script2", originalObjectID: "Script2", contents: "echo Script2", inputs: [],
                                        outputs: [
                                            "/tmp/script-output",
                                            "/tmp/script-output2",
                                        ])
                                ]),
                            TestStandardTarget(
                                "agg3",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["BUILD_VARIANTS": "normal debug"])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase(["foo.c"])
                                ],
                                buildRules: [
                                    TestBuildRule(filePattern: "*.c", script: "cp $INPUT_FILE_PATH /tmp/b", outputs: ["/tmp/b"])
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: true)

            try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that there were was a warning about the duplicate.
                results.checkWarning(.contains("duplicate output file '/tmp/b'"))
                results.checkWarning(.contains("duplicate output file '/tmp/script-output'"))
                results.checkNoWarnings()

                results.checkError("""
Multiple commands produce \'/tmp/b\'
Target \'agg3\' (project \'aProject\') has custom build rule with input \'\(tmpDirPath.str)/Test/aProject/foo.c\'
Target \'agg3\' (project \'aProject\') has custom build rule with input \'\(tmpDirPath.str)/Test/aProject/foo.c\'
Consider making this custom build rule architecture-neutral by unchecking \'Run once per architecture\' in Build Rules, or ensure that it produces distinct output file paths for each architecture and variant combination.
""")
                results.checkError("""
Multiple commands produce '/tmp/script-output'
That command depends on command in Target 'agg1' (project \'aProject\'): script phase “Script1”
That command depends on command in Target 'agg2' (project \'aProject\'): script phase “Script2”
""")
                results.checkNoErrors()

                // Find the two script tasks.
                guard let _ = results.tasks.filter({ (task: ExecutableTask) -> Bool in task.ruleInfo.prefix(2) == ["PhaseScriptExecution", "Script1"] }).first else { Issue.record(); return }
                guard let _ = results.tasks.filter({ (task: ExecutableTask) -> Bool in task.ruleInfo.prefix(2) == ["PhaseScriptExecution", "Script2"] }).first else { Issue.record(); return }

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func wishfullySimulatedMinimalFramework() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                                TestFile("Thing.swift"),
                                TestFile("Info.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "INFOPLIST_FILE": "Info.plist",
                                "DEFINES_MODULE": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_VERSION": swiftVersion,
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m", "Thing.swift"]),
                                    TestFrameworksBuildPhase([]),
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ])
                        ])
                ])

            // FIXME: For now, we cannot actually use simulation here because the symlink tasks don't go through the VFS: <rdar://problem/24976205> [Swift Build] Add llbuild+Swift Build VFS support for missing symlink
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/CoreFoo.h")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/CoreFoo.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Thing.swift")) { _ in }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))

            try await tester.checkBuild(runDestination: .macOS) { results in
                // Find the first CompileC task (there are two).
                let compileTasks = results.checkTasks(.matchRuleType("CompileC")) { $0 }
                #expect(compileTasks.count == 2)

                // Find the linker task.
                let linkerTask = try results.checkTask(.matchRuleType("Ld")) { task throws in task }

                // Find the module map file creation.
                let moduleMapWriteTask = try results.checkTask(.matchRuleType("Copy"), .matchRuleItem(tmpDirPath.join("Test/aProject/build/Debug/CoreFoo.framework/Versions/A/Modules/module.modulemap").str)) { task throws in task }

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                for compileTask in compileTasks {
                    results.check(event: .taskHadEvent(compileTask, event: .started), precedes: .taskHadEvent(compileTask, event: .completed))
                    results.check(event: .taskHadEvent(compileTask, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                }
                results.check(event: .taskHadEvent(linkerTask, event: .started), precedes: .taskHadEvent(linkerTask, event: .completed))

                // Check that the module map file was created.
                results.check(contains: .taskHadEvent(moduleMapWriteTask, event: .started))

                // Check that progress statistics are consistent
                for case let .totalProgressChanged(_, started, max) in results.events {
                    #expect(started <= max)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func moduleMapGetRewrittenIfSourceChanges() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                                TestFile("Thing.swift"),
                                TestFile("Info.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "INFOPLIST_FILE": "Info.plist",
                                "DEFINES_MODULE": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "MODULEMAP_FILE": "module.modulemap",
                                "SWIFT_VERSION": swiftVersion,
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m", "Thing.swift"]),
                                    TestFrameworksBuildPhase([]),
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/CoreFoo.h")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/CoreFoo.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Thing.swift")) { _ in }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<< "framework module CoreFoo {\n"
                stream <<< "umbrella header \"CoreFoo.h\"\n"
                stream <<< "}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Find the module map file creation.
                let moduleMapWriteTask = try results.checkTask(.matchRuleType("Copy"), .matchRuleItem(tmpDirPath.join("Test/aProject/build/Debug/CoreFoo.framework/Versions/A/Modules/module.modulemap").str)) { task throws in task }

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Check that the module map file was created.
                results.check(contains: .taskHadEvent(moduleMapWriteTask, event: .started))
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<< "framework module CoreFoo {\n"
                stream <<< "umbrella header \"CoreFoo.h\"\n"
                stream <<< "export *\n"
                stream <<< "module * { export * }\n"
                stream <<< "}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Find the module map file creation.
                let moduleMapWriteTask = try results.checkTask(.matchRuleType("Copy"), .matchRuleItem(tmpDirPath.join("Test/aProject/build/Debug/CoreFoo.framework/Versions/A/Modules/module.modulemap").str)) { task throws in task }

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Check that the module map file was created.
                results.check(contains: .taskHadEvent(moduleMapWriteTask, event: .started))
            }
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory)
    func missingShellScriptInputs() async throws {
        // Test that shell scripts run, even if their inputs are missing.
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
                                "Target",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "Script", originalObjectID: "X", contents: "true",
                                                              inputs: ["missing-input-file.txt"], alwaysOutOfDate: true),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: true)

            try await tester.checkBuild(runDestination: .host) { results in
                if SWBFeatureFlag.disableShellScriptAllowsMissingInputs.value {
                    results.checkError("Build input file cannot be found: \'\(testWorkspace.sourceRoot.str)/aProject/missing-input-file.txt\' (for task: [\"PhaseScriptExecution\", \"Script\", \"\(testWorkspace.sourceRoot.str)/aProject/build/aProject.build/Debug/Target.build/Script-X.sh\"])")

                    // Check that the delegate was passed build started and build ended events in the right place.
                    results.checkCapstoneEvents()
                } else {
                    // Find the script task.
                    let scriptTask = try results.checkTask(.matchRuleType("PhaseScriptExecution")) { task throws in task }

                    // Check that the delegate was passed build started and build ended events in the right place.
                    results.checkCapstoneEvents()

                    results.check(event: .taskHadEvent(scriptTask, event: .started), precedes: .taskHadEvent(scriptTask, event: .completed))
                }
            }
        }
    }

    /// Check that target dependencies are honored.
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory)
    func simulatedTargetDependencies() async throws {
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
                                "D",
                                buildPhases: [TestShellScriptBuildPhase(name: "D", originalObjectID: "D", contents: "true", alwaysOutOfDate: true)],
                                dependencies: ["C"]
                            ),
                            TestAggregateTarget(
                                "C",
                                buildPhases: [TestShellScriptBuildPhase(name: "C", originalObjectID: "C", contents: "true", alwaysOutOfDate: true)],
                                dependencies: ["B"]),
                            TestAggregateTarget(
                                "B",
                                buildPhases: [TestShellScriptBuildPhase(name: "B", originalObjectID: "B", contents: "true", alwaysOutOfDate: true)],
                                dependencies: ["A"]),
                            TestAggregateTarget(
                                "A",
                                buildPhases: [TestShellScriptBuildPhase(name: "A", originalObjectID: "A", contents: "true", alwaysOutOfDate: true)]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: true)
            let targetD = tester.workspace.projects[0].targets[0]
            let targetC = tester.workspace.projects[0].targets[1]
            let targetB = tester.workspace.projects[0].targets[2]
            let targetA = tester.workspace.projects[0].targets[3]

            try await tester.checkBuild(runDestination: .host) { results in
                // Find the target begin and end.
                func findScript(_ name: String) throws -> Task {
                    return try #require(results.tasks.filter({ (task: ExecutableTask) -> Bool in task.ruleInfo[0] == "PhaseScriptExecution" && task.ruleInfo[1] == name }).only)
                }

                // Verify the targets were built in order.
                //
                // NOTE: This test isn't completely deterministic, it could report a false negative, but in practice this is very unlikely. It should never have a false positive.
                results.checkCapstoneEvents()
                for (first,second) in [("A", "B"), ("B", "C"), ("C", "D")] {
                    // Check the order of the gate tasks.
                    let firstTask = try findScript(first)
                    let secondTask = try findScript(second)
                    results.check(event: .taskHadEvent(firstTask, event: .completed), precedes: .taskHadEvent(secondTask, event: .started))
                }

                // Verify that we received target started-completed pairs for each target.
                //
                // FIXME: We should check more details of these notifications, like their ordering w.r.t. one another, once all tasks are well ordered.
                for target in [targetA, targetB, targetC, targetD] {
                    let ct = ConfiguredTarget(parameters: results.buildRequest.parameters, target: target)
                    results.check(event: .targetHadEvent(ct, event: .started), precedes: .targetHadEvent(ct, event: .completed))
                }
            }
        }
    }

    /// Check that "build targets not in parallel" is honored.
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory)
    func simulatedNonParallelTargetBuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        targets: [
                            TestAggregateTarget("A", buildPhases: [TestShellScriptBuildPhase(name: "A", originalObjectID: "A", contents: "true", alwaysOutOfDate: true)]),
                            TestAggregateTarget("B", buildPhases: [TestShellScriptBuildPhase(name: "B", originalObjectID: "B", contents: "true", alwaysOutOfDate: true)]),
                            TestAggregateTarget("C", buildPhases: [TestShellScriptBuildPhase(name: "C", originalObjectID: "C", contents: "true", alwaysOutOfDate: true)]),
                            TestAggregateTarget("D", buildPhases: [TestShellScriptBuildPhase(name: "D", originalObjectID: "D", contents: "true", alwaysOutOfDate: true)]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: true)

            let parameters = BuildParameters(configuration: "Debug", overrides: ["DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES"])
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(parameters: parameters, runDestination: .host, buildRequest: buildRequest) { results in
                // Find the target begin and end.
                func findScript(_ name: String) throws -> Task {
                    return try #require(results.tasks.filter({ (task: ExecutableTask) -> Bool in task.ruleInfo[0] == "PhaseScriptExecution" && task.ruleInfo[1] == name }).only)
                }

                // Verify the targets were built in order.
                //
                // NOTE: This test isn't completely deterministic, it could report a false negative, but in practice this is very unlikely. It should never have a false positive.
                results.checkCapstoneEvents()
                for (first,second) in [("A", "B"), ("B", "C"), ("C", "D")] {
                    // Check the order of the gate tasks.
                    let firstTask = try findScript(first)
                    let secondTask = try findScript(second)
                    results.check(event: .taskHadEvent(firstTask, event: .completed), precedes: .taskHadEvent(secondTask, event: .started))
                }
            }
        }
    }

    /// Check that build phase order is honored.
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory)
    func simulatedBuildPhaseOrder() async throws {
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
                                    TestShellScriptBuildPhase(name: "A", originalObjectID: "A", contents: "true", alwaysOutOfDate: true),
                                    TestShellScriptBuildPhase(name: "B", originalObjectID: "B", contents: "true", alwaysOutOfDate: true),
                                    TestShellScriptBuildPhase(name: "C", originalObjectID: "C", contents: "true", alwaysOutOfDate: true),
                                    TestShellScriptBuildPhase(name: "D", originalObjectID: "D", contents: "true", alwaysOutOfDate: true),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: true)

            try await tester.checkBuild(runDestination: .host) { results in
                // Find the target begin and end.
                func findScript(_ name: String) throws -> Task {
                    return try #require(results.tasks.filter({ (task: ExecutableTask) -> Bool in task.ruleInfo[0] == "PhaseScriptExecution" && task.ruleInfo[1] == name }).only)
                }

                // Verify the targets were built in order.
                //
                // NOTE: This test isn't completely deterministic, it could report a false negative, but in practice this is very unlikely. It should never have a false positive.
                for (first,second) in [("A", "B"), ("B", "C"), ("C", "D")] {
                    let firstEnd = try findScript(first)
                    let secondBegin = try findScript(second)
                    results.check(event: .taskHadEvent(firstEnd, event: .completed), precedes: .taskHadEvent(secondBegin, event: .started))
                }
            }
        }
    }

    // MARK: Actual Project Builds
    //
    // These perform real builds, including actual dispatch to the underlying
    // tools like the compiler and linker. As such, they are substantially
    // slower than any other tests, and should be used sparingly to test the
    // end-to-end integration of independently tested components.

    /// Test several build scenarios of a small framework, including incremental recompilation scenarios when different pieces change.
    //
    // FIXME: This test should be split up.
    @Test(.requireSDKs(.macOS))
    func actualMinimalFramework() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                                TestFile("Swifty.swift"),
                                TestFile("Info.plist"),
                                TestFile("Settings.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "DEFINES_MODULE": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "SWIFT_VERSION": swiftVersion,
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                // Use this to introduce a file the linker depends on that we don't otherwise see.
                                "OTHER_LDFLAGS": "-exported_symbols_list $(SRCROOT)/Sources/CoreFoo.exports",

                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": GetCurrentUserGroupName()!,
                                "INSTALL_MODE_FLAG": "+w",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["CoreFoo.m", "Swifty.swift"]),
                                    TestResourcesBuildPhase(["Settings.plist"]),
                                    TestFrameworksBuildPhase([]),
                                    // This shell script validates we honor the specified working directory.
                                    TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "Mock", contents: {
                                        let stream = OutputByteStream()
                                        stream <<< "echo \"DIRECTORY: $(basename ${PWD})\"\n"
                                        stream <<< "echo \"TARGET_NAME: ${TARGET_NAME}\"\n"
                                        stream <<< "exit 0\n"
                                        return stream.bytes.asString }(),
                                                              outputs: ["/tmp/mock.txt"]
                                                             ),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.exports")) { contents in
                contents <<< "_f0\n";
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.h")) { contents in
                contents <<< "static inline int f1(int i) { return i + 2; };"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.m")) { contents in
                contents <<< "void f0(void) { };\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Swifty.swift")) { contents in
                contents <<< "public let x = f1(1);\n"
            }
            let settingsContents = ByteString(encodingAsUTF8: "{ \"key\" = \"value\" }\n")
            try tester.fs.write(SRCROOT.join("Sources/Settings.plist"), contents: settingsContents)

            // We enable deployment postprocessing explicitly, to check the full range of basic behaviors.
            let parameters = BuildParameters(action: .install, configuration: "Debug", overrides: [
                "DSTROOT": tmpDirPath.join("dst").str,
            ])

            // Check the initial build.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check that the module session validation file was written.
                if let moduleSessionFilePath = results.buildDescription.moduleSessionFilePath {
                    #expect(tester.fs.exists(moduleSessionFilePath))
                }
                else {
                    Issue.record("No module session validation file path was computed")
                }

                // Find the first CompileC task (there are two)
                let compileTasks = results.checkTasks(.matchRuleType("CompileC")) { $0 }
                #expect(compileTasks.count == 2)

                // Find the linker task.
                let linkerTask = try results.checkTask(.matchRuleType("Ld")) { task throws in task }

                // Find the module map file creation.
                let moduleMapWriteTask = try results.checkTask(.matchRuleType("Copy"), .matchRuleItemPattern(.suffix("CoreFoo.framework/Versions/A/Modules/module.modulemap"))) { task throws in task }

                // Find the Settings.plist copy task.
                let settingsPlistCopyTask = try results.checkTask(.matchRuleType("CopyPlistFile"), .matchRuleItemPattern(.suffix("Sources/Settings.plist"))) { task throws in task }

                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()

                // Check that we no tasks run before the initial target start phase.
                guard results.events.count >= 3 else {
                    Issue.record("unexpected events in initial build: \(results.events)")
                    return
                }

                // Check that we get the expected target names in the progress report.
                let targetNamesInProgressEvents = results.events.reduce(Set<String>(), { (result, event) in
                    var result = result
                    if case .totalProgressChanged(let targetName?, _, _) = event {
                        result.insert(targetName)
                    }
                    return result
                })
                #expect(targetNamesInProgressEvents == ["CoreFoo"])

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

                var idx = 0
                func nextIdx() -> Int {
                    idx += 1
                    return idx
                }

                #expect(events[idx] == .buildStarted)
                guard case .buildReportedPathMap(let copiedPathMap, _) = events[nextIdx()] else {
                    Issue.record("unexpected initial event after build start: \(events[idx])")
                    return
                }
                #expect(copiedPathMap == [tmpDirPath.join("dst/Library/Frameworks/CoreFoo.framework/Versions/A/Headers/CoreFoo.h").str: SRCROOT.join("Sources/CoreFoo.h").str])

                // Check that we received the target started and completed events in a sensible order.
                enum TargetState {
                    case started
                    case completed
                }
                var currentState: TargetState? = nil
                for event in results.events {
                    switch event {
                    case .targetHadEvent(let ct, .started):
                        #expect(currentState == nil)
                        #expect(ct.target == results.buildRequest.buildTargets[0].target)
                        #expect(ct.parameters == results.buildRequest.buildTargets[0].parameters)
                        currentState = .started
                    case .targetHadEvent(let ct, .completed):
                        #expect(currentState == .started)
                        #expect(ct.target == results.buildRequest.buildTargets[0].target)
                        #expect(ct.parameters == results.buildRequest.buildTargets[0].parameters)
                        currentState = .completed
                    case .taskHadEvent(let task, _):
                        if let ct = task.forTarget, !task.isGate {
                            #expect(ct.target == results.buildRequest.buildTargets[0].target)
                            #expect(ct.parameters == results.buildRequest.buildTargets[0].parameters)
                            #expect(currentState == .started)
                        }
                    default:
                        break
                    }
                }

                // Check that both the compiler and the linker ran.
                for compileTask in compileTasks {
                    results.check(event: .taskHadEvent(compileTask, event: .started), precedes: .taskHadEvent(compileTask, event: .completed))
                    results.check(event: .taskHadEvent(compileTask, event: .completed), precedes: .taskHadEvent(linkerTask, event: .started))
                }
                results.check(event: .taskHadEvent(linkerTask, event: .started), precedes: .taskHadEvent(linkerTask, event: .completed))

                // Check that the module map file was created.
                results.check(contains: .taskHadEvent(moduleMapWriteTask, event: .started))

                // Check that the "Info.plist" contents are correct.
                let infoPlistContents = try results.fs.read(SRCROOT.join("build/Debug/CoreFoo.framework/Versions/A/Resources/Info.plist"))
                #expect(infoPlistContents != ByteString())
                #expect(infoPlistContents.bytes.asReadableString().contains("<string>CoreFoo</string>"))

                // Check that the Settings.plist was copied and that its contents are correct.
                results.check(contains: .taskHadEvent(settingsPlistCopyTask, event: .started))
                #expect(try results.fs.read(SRCROOT.join("build/Debug/CoreFoo.framework/Versions/A/Resources/Settings.plist")) == settingsContents)

                // Find the shell script output.
                let shellScriptTask = try results.checkTask(.matchRuleType("PhaseScriptExecution")) { task throws in task }
                results.check(event: .taskHadEvent(shellScriptTask, event: .started), precedes: .taskHadEvent(shellScriptTask, event: .completed))
                results.checkTaskOutput(shellScriptTask) { shellScriptOutput in
                    #expect(shellScriptOutput == "DIRECTORY: aProject\nTARGET_NAME: CoreFoo\n")
                }
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true, excludedTasks: ["SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "Gate", "ClangStatCache"])

            // Change the source, adding a new .h dep, verify it rebuilds properly.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo_Internal.h")) { contents in
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.m")) { contents in
                contents <<< "#include \"CoreFoo_Internal.h\"\n"
                contents <<< "#ifdef COREFOO\n"
                contents <<< "#warning COREFOO is 2\n"
                contents <<< "#endif\n"
                contents <<< "void f0(void) { };\n"
            }

            // We should rebuild the source and relink.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check that the expected tasks ran.
                results.checkTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("CoreFoo.o")) { _ in }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo.o")) { _ in }
                results.checkTask(.matchRule(["Ld", "\(tmpDirPath.str)/dst/Library/Frameworks/CoreFoo.framework/Versions/A/CoreFoo", "normal"])) { _ in }
                results.checkTask(.matchRule(["Strip", "\(tmpDirPath.str)/dst/Library/Frameworks/CoreFoo.framework/Versions/A/CoreFoo"])) { _ in }

                if tester.fs.fileSystemMode == .checksumOnly {
                    // FIXME(nima): add explanation
                    // "GenerateTAPI" is absent under .checksumOnly,
                    // but "Ld" and "Strip" are executed..
                } else {
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                }

                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("ProcessSDKImports")) { _ in }
                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask()
            }

            // Change the internal header, verify it rebuilds properly.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo_Internal.h")) { contents in
                contents <<< "#define COREFOO 2"
            }

            // We should rebuild the source and relink.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                results.checkWarning(.contains("CoreFoo.m:3:2: [User-Defined Issue] COREFOO is 2"))
                // Check that the expected tasks ran.
                results.checkTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("CoreFoo.o")) { _ in }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("CoreFoo.o")) { _ in }

                if tester.fs.fileSystemMode != .checksumOnly {
                    results.checkTask(.matchRule(["Ld", "\(tmpDirPath.str)/dst/Library/Frameworks/CoreFoo.framework/Versions/A/CoreFoo", "normal"])) { _ in }
                    results.checkTask(.matchRule(["Strip", "\(tmpDirPath.str)/dst/Library/Frameworks/CoreFoo.framework/Versions/A/CoreFoo"])) { _ in }
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                }

                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("ProcessSDKImports")) { _ in }
                results.consumeTasksMatchingRuleTypes(["ClangStatCache", "Gate"])
                results.checkNoTask()
            }

            // Change the public header, verify it rebuilds properly.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.h")) { contents in
                // Add a trivial function definition.
                contents <<< "static inline int f1(int i) { return i + 1; };"
            }

            // We should rebuild the Swift sources (they have an implicit import) and recopy the header.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check that the expected tasks ran.
                results.consumeTasksMatchingRuleTypes(["Gate", "Copy", "ExtractAppIntentsMetadata", "ClangStatCache", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports"])

                let driverPlanning = try #require(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                let driverCompilationRequirements = try #require(results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { $0 })
                let driverCompilation = try #require(results.checkTask(.matchRuleType("SwiftDriver Compilation")) { $0 })
                results.checkTaskExists(.matchRule(["SwiftCompile", "normal", "x86_64", "Compiling Swifty.swift", SRCROOT.join("Sources/Swifty.swift").str]))
                results.checkTaskExists(.matchRule(["SwiftEmitModule", "normal", "x86_64", "Emitting module for CoreFoo"]))
                try results.checkTask(.matchRuleType("CpHeader"), .matchRuleItemBasename("CoreFoo.h"), .matchRuleItemPattern(.suffix("Versions/A/Headers/CoreFoo.h"))) { cpHeaderTask in
                    try results.checkTaskFollows(driverCompilationRequirements, cpHeaderTask, resolveDynamicTaskRequests: true)
                    try results.checkTaskFollows(driverCompilation, cpHeaderTask, resolveDynamicTaskRequests: true)
                }
                try results.checkTaskFollows(driverCompilationRequirements, .matchRuleType("SwiftDriver"), resolveDynamicTaskRequests: true)
                try results.checkTaskFollows(driverCompilation, driverPlanning)
                results.checkTaskExists(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix("CoreFoo.framework/Versions/A/CoreFoo")))
                if tester.fs.fileSystemMode != .checksumOnly {
                    results.checkTaskExists(.matchRuleType("GenerateTAPI"))
                }
                results.checkTaskExists(.matchRuleType("Strip"), .matchRuleItemPattern(.suffix("Versions/A/CoreFoo")))

                results.checkNoTask()
            }

            // Change the export list, and verify that we relink.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.exports")) { contents in }
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check that the expected tasks ran.
                results.checkTask(.matchRuleType("Ld")) { _ in }
                results.checkTask(.matchRuleType("Strip")) { _ in }
                results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("ProcessSDKImports")) { _ in }
                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask()
            }

            // This last test is doing some wonky editing of the manifest that does not play well with cached build systems. We shouldn't be doing anything like this 'in the real world', so it should be safe to just disable the caching here.
            tester.userPreferences = tester.userPreferences.with(enableBuildSystemCaching: false)

            // Replace Swift compiler version string in manifest.
            let xcbuildDataDir = SRCROOT.join("build/XCBuildData")
             for item in try tester.fs.listdir(xcbuildDataDir) {
                let path = xcbuildDataDir.join(item)
                if path.basename.hasSuffix("-manifest.xcbuild") {
                    let contents = try tester.fs.read(path).asString
                    let searchContents = String(contents[contents.range(of: "SwiftDriver")!.lowerBound...])
                    let swiftVersion = searchContents.components(separatedBy: "\"signature\":")[1].components(separatedBy: "\"")[1]
                    let newContents = contents.replacingOccurrences(of: swiftVersion, with: "Apple Swift 1.0")
                    try tester.fs.write(path, contents: ByteString(encodingAsUTF8: newContents))
                }
            }

            // We should rebuild the Swift sources, because the Swift compiler changed.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check that the expected tasks ran.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("Copy")) { _ in }
                results.checkTasks(.matchRuleType("Touch")) { _ in }
                results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }
                results.checkNoTask()
            }
        }
    }

    /// Check the handling of headermaps and the VFS.
    ///
    /// This is something of a "shotgun" test for headermaps.
    ///
    /// We currently do not have a good way to isolated parts of the headermap support efficiently. We can do specific checks on the contents of the headermaps, but in practice there are enough subtle details that we also need to ensure that everything works end-to-end including the compiler support and the composition of the headermaps.
    ///
    /// We could potentially test much more of this kind of stuff in isolation if we had:
    ///   <rdar://problem/24504675> RFE: Support external interface to use the InMemoryFileSystem
    //
    // FIXME: Partially disabled due to: <rdar://problem/28138044> BuildOperationTests.testActualHeadermapUse() is broken & disabled
    @Test(.requireSDKs(.macOS))
    func actualHeadermapUse() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // We check with and without modules enabled, which effectively means with and without the VFS>
            for enableModules in ["YES", "NO"] {
                let hiddensCoreFoo = TestFile("CoreFoo.h", guid: "FR_CoreFoo2")
                let hiddensCoreFooInternal = TestFile("CoreFoo_Internal.h", guid: "FR_CoreFoo_Internal2")
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources", path: "Sources", children: [
                                    TestGroup("Foo", path: "Foo", children: [
                                        TestFile("Foo.m"),
                                    ]),
                                    TestGroup("CoreFoo", path: "CoreFoo", children: [
                                        TestGroup("Internal", path: "Internal", children: [
                                            TestFile("CoreFoo_Internal.h", guid: "FR_CoreFoo_Internal1")
                                        ]),
                                        TestFile("CoreFoo.h", guid: "FR_CoreFoo1"),
                                        // We have to hide this in a subdirectory in order to hide it from local header search from CoreFoo.h
                                        TestGroup("Public", path: "Public", children: [
                                            TestFile("CoreFoo_Thing.h"),
                                        ]),
                                        TestFile("CoreFoo.m"),
                                    ]),
                                    TestGroup("StaticFoo", path: "StaticFoo", children: [
                                        TestFile("StaticFoo.h"),
                                        TestFile("StaticFoo_Internal.h"),
                                        TestFile("StaticFoo.m"),
                                    ]),
                                    TestGroup("Hidden", path: "Hidden", children: [
                                        hiddensCoreFoo,
                                        hiddensCoreFooInternal
                                    ]),
                                ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                    "CLANG_ENABLE_MODULES": "\(enableModules)",
                                ]
                            )],
                            targets: [
                                // Main app, which depends on a framework, and the framework depends on a static library.
                                TestStandardTarget(
                                    "Foo", type: .staticLibrary,
                                    buildPhases: [
                                        TestSourcesBuildPhase(["Foo.m"]),
                                        TestHeadersBuildPhase([]),
                                    ],
                                    // FIXME: Reverse this when rdar://problem/28138044 is fixed.
                                    dependencies: ["StaticFoo"]),
                                TestStandardTarget(
                                    "CoreFoo", type: .framework,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug",
                                                               buildSettings: [
                                                                "DEFINES_MODULE": "YES"])],
                                    buildPhases: [
                                        TestSourcesBuildPhase(["CoreFoo.m"]),
                                        TestHeadersBuildPhase([
                                            TestBuildFile("CoreFoo.h", headerVisibility: .public),
                                            TestBuildFile("CoreFoo_Thing.h", headerVisibility: .public),
                                            TestBuildFile("CoreFoo_Internal.h"),
                                        ])],
                                    // FIXME: Reverse this when rdar://problem/28138044 is fixed.
                                    dependencies: []),
                                TestStandardTarget(
                                    "StaticFoo", type: .staticLibrary,
                                    buildPhases: [
                                        TestSourcesBuildPhase(["StaticFoo.m"]),
                                        TestHeadersBuildPhase([
                                            TestBuildFile("StaticFoo.h", headerVisibility: .public),
                                            TestBuildFile("StaticFoo_Internal.h"),
                                        ])],
                                    // FIXME: Reverse this when rdar://problem/28138044 is fixed.
                                    dependencies: ["CoreFoo"]),
                                // Add another target with "duplicate" CoreFoo.h headers, to verify that we pick the right product name in the project headers map.
                                TestStandardTarget(
                                    "Hidden", type: .framework,
                                    buildPhases: [
                                        TestHeadersBuildPhase([
                                            TestBuildFile(hiddensCoreFoo),
                                            TestBuildFile(hiddensCoreFooInternal),
                                        ]),
                                    ]),
                            ])
                    ])
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // Write the source files.

                // Foo target.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/Foo/Foo.m")) { contents in
                    contents <<< "#import <CoreFoo/CoreFoo.h>\n"
                    contents <<< "void foo() {}\n"

                    // Verify that we can import an internal header from another target. This is using the project headermap.
                    contents <<< "#import \"CoreFoo_Internal.h\"\n"
                    contents <<< "#if COREFOO_THING != 1\n"
                    contents <<< "#  error \"invalid header contents\"\n"
                    contents <<< "#endif\n"
                    contents <<< "#if COREFOO_INTERNAL != 1\n"
                    contents <<< "#  error \"invalid header contents\"\n"
                    contents <<< "#endif\n"

                    // Verify that we can import an installed non-framework header using <> style.
                    contents <<< "#import <StaticFoo/StaticFoo.h>\n"
                    contents <<< "#if STATICFOO != 1\n"
                    contents <<< "#  error \"invalid header contents\"\n"
                    contents <<< "#endif\n"

                    // Verify that we *cannot* import non-installed headers using <> style (e.g., the ones in the "own headers" map).
                    for include in ["<CoreFoo_Internal.h>", "<CoreFoo/CoreFoo_Internal.h>", "<StaticFoo_Internal.h>", "<StaticFoo/StaticFoo_Internal.h>"] {
                        contents <<< "#if __has_include(\(include))\n"
                        contents <<< "#  error \"unexpected import: \(include)\"\n"
                        contents <<< "#endif\n"
                    }

                    // Verify that we *cannot* import installed framework headers using <basename.h> style (e.g., the ones in the "own headers" map).
                    for include in ["<CoreFoo.h>"] {
                        contents <<< "#if __has_include(\(include))\n"
                        contents <<< "#  error \"unexpected import: \(include)\"\n"
                        contents <<< "#endif\n"
                    }

                    // Force a couple warnings in CoreFoo files. We use this to verify the "all targets" headermap is in place and we are getting the expected diagnostic remappings.
                    contents <<< "#define COREFOO 2\n"
                    contents <<< "#define COREFOO_THING 2\n"
                }

                // CoreFoo target.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo/CoreFoo.h")) { contents in
                    // Verify we can include an installed header using either syntax.
                    //
                    // This is primarily intended to test that these entries work properly when mapped with the VFS. If they were mapped directly to the source path, the module build would fail. Instead, they must be mapped to a framework style include via the headermap, then mapped via the VFS back to source.
                    contents <<< "#include \"CoreFoo_Thing.h\"\n"
                    contents <<< "#include <CoreFoo/CoreFoo_Thing.h>\n"

                    contents <<< "#define COREFOO 1\n"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo/Public/CoreFoo_Thing.h")) { contents in
                    contents <<< "#define COREFOO_THING 1\n"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo/CoreFoo.m")) { contents in
                    contents <<< "void coreFoo() {}\n"

                    // Verify that we can import one of our own internal headers (which is in a subdirectory). This is using the project headermap.
                    contents <<< "#import \"CoreFoo_Internal.h\"\n"
                    contents <<< "#if COREFOO_INTERNAL != 1\n"
                    contents <<< "#  error \"invalid header contents\"\n"
                    contents <<< "#endif\n"

                    // Verify that we can import one of our own non-installed internal headers using framework style includes. This is supported by Xcode, to allow people to write more consistent header style, and depends on the "own target" headermap.
                    contents <<< "#import <CoreFoo_Internal.h>\n"
                    contents <<< "#import <CoreFoo/CoreFoo_Internal.h>\n"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/CoreFoo/Internal/CoreFoo_Internal.h")) { contents in
                    contents <<< "#define COREFOO_INTERNAL 1\n"
                }

                // StaticFoo target.
                //
                // FIXME: This target was designed to test that we could upward include headers from CoreFoo (a dependent). However, rdar://problem/28138044 prevents this from working completely, so for now we build CoreFoo first.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/StaticFoo/StaticFoo.h")) { contents in
                    contents <<< "#define STATICFOO 1\n"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/StaticFoo/StaticFoo_Internal.h")) { contents in
                    contents <<< "#define STATICFOO_INTERNAL 1\n"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/StaticFoo/StaticFoo.m")) { contents in
                    // Verify that we can import one of our own non-installed internal headers using framework style includes. This is supported by Xcode, even for non-framework targets, to allow people to write more consistent header style, and depends on the "own target" headermap.
                    contents <<< "#import <StaticFoo_Internal.h>\n"
                    contents <<< "#import <StaticFoo/StaticFoo_Internal.h>\n"

                    // Verify that we can import an up-linked header.
                    contents <<< "#import <CoreFoo/CoreFoo.h>\n"

                    if enableModules == "YES" {
                        // Verify that we can perform a module import of the up-linked framework.
                        //
                        // This checks that the VFS contains module map entries which allow the compiler to find the module map even before it is installed.
                        contents <<< "@import CoreFoo;\n"
                    }
                }

                try await tester.checkBuild(runDestination: .macOS) { results in
                    // Find the tasks, there should be three.
                    let compileTasks = results.checkTasks(.matchRuleType("CompileC")) { $0 }
                    #expect(compileTasks.count == 3)

                    // Check that each compilation task ran.
                    for task in compileTasks {
                        results.check(event: .taskHadEvent(task, event: .started), precedes: .taskHadEvent(task, event: .completed))
                    }

                    results.checkWarning(.prefix("\(tmpDirPath.str)/Test/aProject/Sources/Foo/Foo.m:29:9: [Lexical or Preprocessor Issue] 'COREFOO' macro redefined\n\(tmpDirPath.str)/Test/aProject/Sources/CoreFoo/CoreFoo.h:3:9: previous definition is here"))
                    results.checkWarning(.prefix("\(tmpDirPath.str)/Test/aProject/Sources/Foo/Foo.m:30:9: [Lexical or Preprocessor Issue] 'COREFOO_THING' macro redefined\n\(tmpDirPath.str)/Test/aProject/Sources/CoreFoo/Public/CoreFoo_Thing.h:1:9: previous definition is here"))
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    // MARK: Incremental Build Tests

    /// Check that an asset catalog gets an incremental build.
    @Test(.requireSDKs(.macOS))
    func assetCatalogIncrementalRebuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Test that an incremental rebuild of an empty project does nothing.
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("Assets.xcassets"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)"
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Empty", type: .application,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestResourcesBuildPhase(["Assets.xcassets"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the input files.
            try await tester.fs.writeAssetCatalog(SRCROOT.join("Assets.xcassets"), .root, .colorSet("Color", [.sRGB(red: 1, green: 1, blue: 1, alpha: 1, idiom: .universal)]))

            // Check the initial build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { _ in }

            // Do an incremental update of the catalog
            try await tester.fs.writeAssetCatalog(SRCROOT.join("Assets.xcassets"), .appIcon("AppIcon"))

            // Check that the next build is NOT null.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant")) { _ in }
                results.checkTasks { tasks in
                    if tester.fs.fileSystemMode == .checksumOnly {
                        // Although "CompileAssetCatalog" task is present,
                        // the "T-empty-8--fused-phase0-copy-bundle-resources" and "T-empty-8--end" gate tasks are absent
                    } else {
                        #expect(tasks.count > 0)
                        results.consumeTasksMatchingRuleTypes(["Gate"])
                    }
                    results.checkNoTask()
                }
            }

            if tester.fs.fileSystemMode != .checksumOnly {
                try await tester.fs.updateTimestamp(SRCROOT.join("Assets.xcassets"))

                // Check that the next build is NOT null after touching the .xcassets directory.
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("CompileAssetCatalogVariant")) { _ in }
                    results.checkTasks { tasks in
                        #expect(tasks.count > 0)
                    }
                    results.checkNoTask()
                }
            }

            try tester.fs.append(SRCROOT.join("Assets.xcassets/Color.colorset/Contents.json"), contents: "\n\n")

            // Check that the next build is NOT null after touching a file inside the .xcassets directory.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant")) { _ in }
                results.checkTasks { tasks in
                    if tester.fs.fileSystemMode == .checksumOnly {
                        // Although "CompileAssetCatalog" task is present,
                        // the "T-empty-8--fused-phase0-copy-bundle-resources" and "T-empty-8--end" gate tasks are absent
                    } else {
                        #expect(tasks.count > 0)
                        results.consumeTasksMatchingRuleTypes(["Gate"])
                    }
                }
                results.checkNoTask()
            }

            // Remove the .car file
            try tester.fs.removeDirectory(testWorkspace.sourceRoot.join("aProject/build/aProject.build/Debug/Empty.build/assetcatalog_output"))

            // Check that the next build is NOT null.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant")) { _ in }
                results.checkTasks { tasks in
                    if tester.fs.fileSystemMode == .checksumOnly {
                    } else {
                        #expect(tasks.count > 0)
                        results.consumeTasksMatchingRuleTypes(["Gate"])
                    }
                }
                results.checkNoTask()
            }
        }
    }

    /// Check that tasks don't interfere with incremental builds across platforms.
    @Test(.requireSDKs(.iOS, .tvOS),
          .skipDeveloperDirectoryWithEqualSign) // mig will fail on mounts due to rdar://137363780 (env can't handle commands with = signs in the filename)
    func incrementalRebuildAcrossPlatforms() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Test that an incremental rebuild of an empty project does nothing.
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("foo.applescript"),
                            TestFile("foo.defs"),
                            TestFile("foo.iconset"),
                            TestFile("foo.fake-customrule")
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS": "arm64e",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Empty", type: .dynamicLibrary,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestAppleScriptBuildPhase([
                                        TestBuildFile("foo.applescript"),
                                    ]),
                                    TestSourcesBuildPhase([
                                        TestBuildFile("foo.defs", migCodegenFiles: .both),
                                        TestBuildFile("foo.fake-customrule"),
                                    ]),
                                    TestResourcesBuildPhase([
                                        //TestBuildFile("foo.iconset"),
                                    ])
                                ],
                                buildRules: [
                                    TestBuildRule(filePattern: "*.fake-customrule", script: "touch \"${SCRIPT_OUTPUT_FILE_0}\"", outputs: ["$(DERIVED_FILE_DIR)/foo.fake-customruleout"]),
                                ]
                            )
                        ]
                    )
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the input files.
            try tester.fs.createDirectory(SRCROOT, recursive: true)
            try tester.fs.write(SRCROOT.join("foo.applescript"), contents: "")
            try tester.fs.write(SRCROOT.join("foo.defs"), contents: "subsystem foo 1;")
            try tester.fs.write(SRCROOT.join("foo.fake-customrule"), contents: "")

            // Check the initial build.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, persistent: true) { _ in }

            // Check that the next build is null.
            try await tester.checkNullBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, persistent: true, excludedTasks: ["ClangStatCache"])

            // Check that the next build is NOT null when switching to another platform we haven't built for before.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .tvOS, persistent: true) { results in
                results.checkTasks { tasks in
                    #expect(tasks.count > 0)
                }
            }

            // Check that the next build is null again when switching back to the original platform.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(["Gate", "ClangStatCache"])
                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func shellScriptContentAwareIncrementalBehaviorWithTwoPhases() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            TestAggregateTarget("Empty",
                                                buildPhases: [
                                                    TestShellScriptBuildPhase(
                                                        name: "Produce Magic File",
                                                        originalObjectID: "S1",
                                                        contents:
                                            #"""
                                            echo "magic string" > "$SCRIPT_OUTPUT_FILE_0"
                                            """#,
                                                        inputs: [],
                                                        outputs: ["$FAKE_PATH_OUT"]),
                                                    TestShellScriptBuildPhase(
                                                        name: "Extract First Word",
                                                        originalObjectID: "S2",
                                                        contents:
                                            #"""
                                            cat "$SCRIPT_INPUT_FILE_0" | awk '{print $1;}' > "$SCRIPT_OUTPUT_FILE_0"
                                            """#,
                                                        inputs: ["$FAKE_PATH_OUT"],
                                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/first-word.txt"]),
                                                ]
                                               )])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: createFS(simulated: false, fileSystemMode: .checksumOnly))

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/magic.txt")) { stream in
                stream <<< "magic string\n"
            }

            let overriddenParameters = BuildParameters(configuration: "Debug", overrides: [
                "FUSE_BUILD_SCRIPT_PHASES": "NO",
                "FAKE_PATH_OUT": Path(SRCROOT).join("aProject/magic.txt").str
            ])

            // Check the initial build.
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the expected tasks ran.
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Gate"])

                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S1.sh")) { _ in }
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S2.sh")) { _ in }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Produce Magic File"), .matchRuleItemBasename("Script-S1.sh")) { task in
                    // magic.txt as output
                    let path = task.outputPaths[0]
                    let value = try tester.fs.read(path).asString
                    #expect(value == "magic string\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Extract First Word"), .matchRuleItemBasename("Script-S2.sh")) { task in
                    // magic.txt as input
                    let pathIn = task.inputPaths[0]
                    let valueIn = try tester.fs.read(pathIn).asString
                    #expect(valueIn == "magic string\n")

                    // first-word.txt as output
                    let pathOut = task.outputPaths[0]
                    let valueOut = try tester.fs.read(pathOut).asString
                    #expect(valueOut == "magic\n")
                }

                results.checkNoDiagnostics()
            }

            // Scenario (A)
            // Some external tool touches output of a user script, but the contents are the same
            // We should avoid scheduling upstream/downstream tasks.
            try await tester.fs.updateTimestamp(Path(SRCROOT).join("aProject/magic.txt"))

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the script ran.
                results.consumeTasksMatchingRuleTypes(["Gate"])

                // Neither S1 nor S2 should run (change was only in timestamp).
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the script ran.
                results.consumeTasksMatchingRuleTypes(["Gate"])

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // Scenario (B)
            // Some external tool modifies an output of the script phase..
            // We must re-run the script to obtain the correct value.
            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/magic.txt")) { stream in
                stream <<< "modified string"
            }

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the script ran.
                results.consumeTasksMatchingRuleTypes(["Gate"])

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Produce Magic File"), .matchRuleItemBasename("Script-S1.sh")) { task in
                    // magic.txt as output
                    let path = task.outputPaths[0]
                    let value = try tester.fs.read(path).asString
                    #expect(value == "magic string\n")
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // Scenario (C)
            // Some external tool deletes an output of the script phase..
            // We must re-run the script to re-create the file
            try tester.fs.remove(Path(SRCROOT).join("aProject/magic.txt"))

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the script ran.
                results.consumeTasksMatchingRuleTypes(["Gate"])

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Produce Magic File"), .matchRuleItemBasename("Script-S1.sh")) { task in
                    // magic.txt as output
                    let path = task.outputPaths[0]
                    let value = try tester.fs.read(path).asString
                    #expect(value == "magic string\n")
                }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func shellScriptContentAwareIncrementalBehaviors() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "ALL",
                                dependencies: ["TA", "TB", "TC"]
                            ),
                            TestStandardTarget(
                                "TA",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "Read Magic File",
                                        originalObjectID: "S1",
                                        contents:
                                            #"""
                                            set -e; cat "${SCRIPT_INPUT_FILE_0}" > "$SCRIPT_OUTPUT_FILE_0"
                                            """#,
                                        inputs: ["$FAKE_PATH_IN"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/magic.txt"])
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "TB",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "Extract First Word",
                                        originalObjectID: "S2",
                                        contents:
                                            #"""
                                            set -e; cat "$SCRIPT_INPUT_FILE_0" | awk '{print $1;}' > "$SCRIPT_OUTPUT_FILE_0"
                                            """#,
                                        inputs: ["$(SHARED_DERIVED_FILE_DIR)/magic.txt"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/first-word.txt"]),
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "TC",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "Capitalize First Word",
                                        originalObjectID: "S3",
                                        contents:
                                            #"""
                                            set -e; cat "$SCRIPT_INPUT_FILE_0" | tr a-z A-Z > "$SCRIPT_OUTPUT_FILE_0"
                                            """#,
                                        inputs: ["$(SHARED_DERIVED_FILE_DIR)/first-word.txt"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/final.txt"])
                                ],
                                dependencies: ["Other"]
                            ),
                        ])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: createFS(simulated: false, fileSystemMode: .checksumOnly))

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/magic.txt")) { stream in
                stream <<< "magic string\n"
            }

            let overriddenParameters = BuildParameters(configuration: "Debug", overrides: [
                "FAKE_PATH_IN": Path(SRCROOT).join("aProject/magic.txt").str,
                "FUSE_BUILD_SCRIPT_PHASES": "NO"
            ])

            // Check the initial build.
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the expected tasks ran.
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Gate"])

                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S1.sh")) { _ in }
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S2.sh")) { _ in }
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S3.sh")) { _ in }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Read Magic File"), .matchRuleItemBasename("Script-S1.sh")) { task in
                    // magic.txt as output
                    let path = task.outputPaths[0]
                    let value = try tester.fs.read(path).asString
                    #expect(value == "magic string\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Extract First Word"), .matchRuleItemBasename("Script-S2.sh")) { task in
                    // magic.txt as input
                    let pathIn = task.inputPaths[0]
                    let valueIn = try tester.fs.read(pathIn).asString
                    #expect(valueIn == "magic string\n")

                    // first-word.txt as output
                    let pathOut = task.outputPaths[0]
                    let valueOut = try tester.fs.read(pathOut).asString
                    #expect(valueOut == "magic\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Capitalize First Word"), .matchRuleItemBasename("Script-S3.sh")) { task in
                    // final.txt as input
                    let path = task.outputPaths[0]
                    let value = try tester.fs.read(path).asString
                    #expect(value == "MAGIC\n")
                }

                results.checkNoDiagnostics()
            }

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(["Gate"])
                results.checkNoTask()
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/magic.txt")) { stream in
                stream <<< "magic modified string"
            }

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the script ran.
                results.consumeTasksMatchingRuleTypes(["Gate"])

                // S1 should run because contents of $FAKE_PATH_IN has changed
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Read Magic File"), .matchRuleItemBasename("Script-S1.sh")) { _ in }

                // S2 should run because contents of `magic.txt` has changed
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Extract First Word"), .matchRuleItemBasename("Script-S2.sh")) { _ in }

                // S3 should not run because the first word of `magic.txt` is the same
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/magic.txt")) { stream in
                stream <<< "supermagic string"
            }

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that the script ran.
                results.consumeTasksMatchingRuleTypes(["Gate"])

                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Read Magic File"), .matchRuleItemBasename("Script-S1.sh")) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Extract First Word"), .matchRuleItemBasename("Script-S2.sh")) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Capitalize First Word"), .matchRuleItemBasename("Script-S3.sh")) { _ in }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    /// Check that a minimal framework gets an incremental build.
    ///
    /// This checks a number of additional things about the incremental build, for example the handling of symlink tasks.
    @Test(.requireSDKs(.macOS))
    func minimalNullIncrementalRebuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Test that an incremental rebuild of an empty project does nothing.
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("Empty.c"),
                            TestFile("Test.txt"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"])],
                        targets: [
                            TestStandardTarget(
                                "Empty", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestCopyFilesBuildPhase(["Test.txt"], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                    TestSourcesBuildPhase(["Empty.c"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Empty.c")) { stream in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Test.txt")) { stream in }

            // Check the initial build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { _ in }

            // Touch a file inside the directory.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/build/Debug/Empty.framework/Versions/a.txt")) { stream in }

            // Check that the next build is null.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])
        }
    }

    /// Check that output-agnostic compiler flags don't trigger a rebuild.
    @Test(.requireSDKs(.macOS))
    func outputAgnosticsFlagsRebuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("Empty.c"),
                            TestFile("Empty.swift"),
                            TestFile("Test.txt"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "DONT_GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Empty", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestCopyFilesBuildPhase(["Test.txt"], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                    TestSourcesBuildPhase(["Empty.c", "Empty.swift"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Empty.c")) { stream in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Empty.swift")) { stream in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Test.txt")) { stream in }

            // Check the initial build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { _ in }

            // Touch a file inside the directory.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/build/Debug/Empty.framework/Versions/a.txt")) { stream in }


            try await tester.checkNullBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "-fcolor-diagnostics"]), runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])

            try await tester.checkNullBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "-fmessage-length=1234"]), runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])

            try await tester.checkNullBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "-index-store-path \"\(tmpDirPath.join("IndexDataStore"))\""]), runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])

            // Check that the next build is NOT null.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "-DFOO=\"删除所有的\""]), runDestination: .macOS, persistent: true) { results in

                // Check that tasks ran.
                results.checkTasks { tasks in
                    #expect(tasks.count > 0)
                }
            }

            // Reset.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { _ in }

            try await tester.checkNullBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "-index-store-path \"\(tmpDirPath.join("IndexDataStore"))\""]), runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])

            // Check that the next build is NOT null.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "-DFOO=\"删除所有的\""]), runDestination: .macOS, persistent: true) { results in

                // Check that tasks ran.
                results.checkTasks { tasks in
                    #expect(tasks.count > 0)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func infoPlistAffectsCodeSigning() async throws {
        // Ensure that changing Info.plist will re-run the code signing task.
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("CoreFoo.m"),
                                TestFile("Info.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "INFOPLIST_FILE": "Info.plist",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m"]),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/CoreFoo.m")) { _ in }

            let initialPlDict: [String: PropertyListItem] = [
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]
            let infoPlistPath = testWorkspace.sourceRoot.join("aProject/Info.plist")
            try await tester.fs.writePlist(infoPlistPath, .plDict(initialPlDict))

            let provisioningInputs = ["CoreFoo": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))]

            // Check the initial build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkTask(.matchRuleType("CodeSign")) { _ in }
            }

            // Touch the Info.plist file.
            try await tester.fs.writePlist(infoPlistPath, .plDict(initialPlDict.addingContents(of: ["newKey": .plString("newValue")])))

            // Check that CodeSign task runs in the next build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkTask(.matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchRuleType("CodeSign")) { _ in }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func configSwitchNullBuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Test that switching build config should not affect null builds.
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("Source.swift"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)", "SWIFT_VERSION": swiftVersion]),
                            TestBuildConfiguration("Release", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)", "SWIFT_VERSION": swiftVersion]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Foo", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug"), TestBuildConfiguration("Release")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Source.swift"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Source.swift")) { stream in }

            let debug = BuildParameters(configuration: "Debug")
            let release = BuildParameters(configuration: "Release")

            // Check the initial debug and release build.
            try await tester.checkBuild(parameters: debug, runDestination: .macOS, persistent: true) { _ in }
            try await tester.checkBuild(parameters: release, runDestination: .macOS, persistent: true) { _ in }

            // Check that the next debug build is null.
            try await tester.checkNullBuild(parameters: debug, runDestination: .macOS, persistent: true, excludedTasks: ["Gate", "ClangStatCache"])
        }
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func stubAppNullBuild() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources",
                    path: "",
                    children: [
                        // watchOS app files
                        TestFile("watchosApp/Interface.storyboard"),
                        TestFile("watchosApp/Assets.xcassets"),
                        TestFile("watchosApp/Info.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SDKROOT": "iphoneos",
                            "WATCHOS_DEPLOYMENT_TARGET": "6.0",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Watchable WatchKit App",
                        type: .watchKitApp,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                                                    "INFOPLIST_FILE": "watchosApp/Info.plist",
                                                    "SDKROOT": "watchos",
                                                    "SKIP_INSTALL": "YES",
                                                    "TARGETED_DEVICE_FAMILY": "4",
                                                   ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([
                                "watchosApp/Interface.storyboard",
                                "watchosApp/Assets.xcassets",
                            ]),
                        ]
                    )
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let SRCROOT = tmpDirPath

            try await tester.fs.writePlist(SRCROOT.join("watchosApp/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            try await tester.fs.writeAssetCatalog(SRCROOT.join("watchosApp/Assets.xcassets"), .root, .appIcon("AppIcon"))

            try await tester.fs.writeStoryboard(SRCROOT.join("watchosApp/Interface.storyboard"), .watchKit)

            try await tester.checkBuild(runDestination: .watchOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try await tester.checkNullBuild(runDestination: .watchOS, persistent: true)
        }
    }

    /// Check non-UTF8 encoded shell scripts don't cause any unexpected issues.
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireSystemPackages(apt: "xxd", yum: "vim-common"), .requireThreadSafeWorkingDirectory)
    func nonUTF8ShellScript() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        targets: [
                            TestAggregateTarget("Empty",
                                                buildPhases: [
                                                    TestShellScriptBuildPhase(
                                                        name: "Run Script",
                                                        originalObjectID: "S1",
                                                        contents: "echo ��� | xxd",
                                                        alwaysOutOfDate: true
                                                    )])])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Check the build.
            try await tester.checkBuild(runDestination: .host) { results in
                results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                    results.checkTaskOutput(task) { output in
                        XCTAssertMatch(output.unsafeStringValue, .contains("efbf bdef bfbd efbf bd0a"))
                    }
                }
            }
        }
    }

    /// Check that a shell script can find tools in the platform and toolchain
    @Test(.requireSDKs(.macOS))
    func shellScriptPath() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        targets: [
                            TestAggregateTarget("Empty",
                                                buildPhases: [
                                                    TestShellScriptBuildPhase(
                                                        name: "Run Script",
                                                        originalObjectID: "S1",
                                                        contents: "which metal\nwhich clang\n",
                                                        alwaysOutOfDate: true
                                                    )])])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Check the build.
            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                    results.checkTaskOutput(task) { output in
                        XCTAssertMatch(output.unsafeStringValue, .contains("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal"))
                        XCTAssertMatch(output.unsafeStringValue, .contains("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"))
                    }
                }
            }
        }
    }

    /// Check special shell script dependency handling
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory)
    func shellScriptIncrementalBehaviors() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Test that an incremental rebuild of an empty project does nothing.
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        targets: [
                            TestAggregateTarget("Empty",
                                                buildPhases: [
                                                    TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "S1", contents: {
                                                        let stream = OutputByteStream()
                                                        stream <<< "true"
                                                        return stream.bytes.asString }()),
                                                    TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "S2", contents: {
                                                        let stream = OutputByteStream()
                                                        stream <<< "echo 'run-once' > \(tmpDirPath.str)/var/s2-output"
                                                        return stream.bytes.asString }(), inputs: ["\(tmpDirPath.str)/var/s2-input"], outputs: ["\(tmpDirPath.str)/var/s2-output"]),
                                                    TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "S3", contents: {
                                                        let stream = OutputByteStream()
                                                        stream <<< "echo 'always run' > \(tmpDirPath.str)/var/s3-output"
                                                        return stream.bytes.asString }(), inputs: ["\(tmpDirPath.str)/var/s3-input"], outputs: ["\(tmpDirPath.str)/var/s3-output"], alwaysOutOfDate: true),
                                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("\(tmpDirPath.str)/var/s1-input")) { stream in
                stream <<< "input1"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("\(tmpDirPath.str)/var/s2-input")) { stream in
                stream <<< "input2"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("\(tmpDirPath.str)/var/s3-input")) { stream in
                stream <<< "input3"
            }

            // Check the initial build.
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                // Check that the expected tasks ran.
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Gate"])

                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Run Script"), .matchRuleItemBasename("Script-S1.sh")) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Run Script"), .matchRuleItemBasename("Script-S2.sh")) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Run Script"), .matchRuleItemBasename("Script-S3.sh")) { _ in }

                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S1.sh")) { _ in }
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S2.sh")) { _ in }
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Script-S3.sh")) { _ in }

                results.checkNoTask()
                results.checkWarning("Run script build phase 'Run Script' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'Empty' from project 'aProject')")
                results.checkNoDiagnostics()
            }

            // Check that the next build properly reruns the script (since it has no declared outputs).
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                // Check that the script ran.
                results.consumeTasksMatchingRuleTypes(["Gate"])
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Run Script"), .matchRuleItemBasename("Script-S1.sh")) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("Run Script"), .matchRuleItemBasename("Script-S3.sh")) { _ in }
                results.checkNoTask()
                results.checkWarning("Run script build phase 'Run Script' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'Empty' from project 'aProject')")
                results.checkNoDiagnostics()
            }
        }
    }

    /// Check chown/chmod dependency handling.
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory)
    func setFileAttributesIncrementalBehaviors() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Test that an incremental rebuild of an empty project does nothing.
            let groupName = try #require(GetCurrentUserGroupName(), "Could not determine current user group name")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("main.c")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": groupName,
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.c"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }

            // Check the initial build.
            let parameters = BuildParameters(action: .install, configuration: "Debug", activeRunDestination: .host, overrides: [
                "DSTROOT": tmpDirPath.join("dst").str,
                "STRIP_INSTALLED_PRODUCT": "NO",
            ])
            try await tester.checkBuild(parameters: parameters, runDestination: .host, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(["Gate", "Copy", "WriteAuxiliaryFile", "SymLink", "CreateBuildDirectory", "RegisterExecutionPolicyException", "ClangStatCache", "ProcessSDKImports"])
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkTask(.matchRuleType("Ld")) { _ in }
                results.checkTask(.matchRuleType("SetGroup"), .matchRuleItemPattern(.any), .matchRuleItemPattern(.suffix("bin/Tool"))) { _ in }
                results.checkTask(.matchRuleType("SetMode"), .matchRuleItemPattern(.any), .matchRuleItemPattern(.suffix("bin/Tool"))) { _ in }
                results.checkNoTask()
            }

            // Check a null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .host, persistent: true, excludedTasks: ["ClangStatCache"])
        }
    }

    /// Check the actual behavior of mutable tasks in an [incremental] build.
    @Test(.requireSDKs(.macOS))
    func actualMutableBehaviors() async throws {
        func checkScenario(_ name: String, expectedTasks: [String], generic: Bool = false, settings: [String: String] = [:], enableSigning: Bool = false, targetType: TestStandardTarget.TargetType = .commandLineTool) async throws {
            let targetName = targetType == .framework ? "Fwk" : "Tool"
            try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources", path: "Sources", children: [
                                    TestFile("Source.c"),
                                    TestFile("Info.plist"),
                                ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": enableSigning ? "YES" : "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "USE_HEADERMAP": "NO",
                                    "SKIP_INSTALL": "NO",
                                    "INFOPLIST_FILE": "Sources/Info.plist",

                                    // Force stripping and file attribute changes off by default.
                                    "INSTALL_OWNER": "",
                                    "INSTALL_GROUP": "",
                                    "INSTALL_MODE_FLAG": "",
                                    "STRIP_INSTALLED_PRODUCT": "NO",
                                ].addingContents(of: settings)
                            )],
                            targets: [
                                TestStandardTarget(
                                    targetName, type: targetType,
                                    buildPhases: [
                                        TestSourcesBuildPhase([TestBuildFile("Source.c")]),
                                    ])
                            ])
                    ])
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")
                let signableTargets: Set<String> = enableSigning ? [targetName] : []
                let signableTargetInputs: [String: ProvisioningTaskInputs] = enableSigning ? [targetName: ProvisioningTaskInputs(identityHash: "-", identityName: "-", signedEntitlements: .plDict(["com.apple.security.get-task-allow": .plBool(true)]))] : [:]
                let taskTypesToExclude: Set<String>
                if targetType == .framework {
                    taskTypesToExclude = ["ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "Gate", "WriteAuxiliaryFile", "ProcessInfoPlistFile", "SymLink", "MkDir", "Touch", "CreateBuildDirectory", "ClangStatCache", "ProcessSDKImports"]
                } else {
                    taskTypesToExclude = ["ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "Gate", "WriteAuxiliaryFile", "SymLink", "CreateBuildDirectory", "ClangStatCache", "ProcessSDKImports"]
                }

                if targetType == .framework {
                    // Write the Info.plist file.
                    try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                        "CFBundleDevelopmentRegion": .plString("en"),
                        "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
                    ]))
                }

                // Write the source files.
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/Source.c")) { contents in
                    if targetType == .framework {
                        contents <<< "void thing(void) __attribute__((visibility(\"default\")));\n"
                        contents <<< "void thing(void) {}\n"
                    } else {
                        contents <<< "int main(void) {\n";
                        contents <<< "  return 0;\n";
                        contents <<< "}\n";
                    }
                }

                // We enable deployment postprocessing explicitly, to check the full range of basic behaviors.
                let parameters = BuildParameters(configuration: "Debug", overrides: [
                    "DSTROOT": tmpDirPath.join("dst").str,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                ])

                // Check the initial build.
                try await tester.checkBuild(parameters: parameters, runDestination: generic ? .anyMac : .macOS, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs) { results in
                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)
                    for (expectedTask, count) in Dictionary(expectedTasks.map({ ($0, 1) }), uniquingKeysWith: +) {
                        results.checkTasks(.matchRuleType(expectedTask)) { tasks in
                            #expect(tasks.count == count)
                        }
                    }
                    results.checkNoTask()
                }

                // Check that we get a null build.
                try await tester.checkNullBuild(parameters: parameters, runDestination: generic ? .anyMac : .macOS, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs, excludedTasks: ["ClangStatCache"])

                // Check that we get a proper incremental build if we change the source.
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/Source.c")) { contents in
                    if targetType == .framework {
                        contents <<< "void thing2(void) __attribute__((visibility(\"default\")));\n"
                        contents <<< "void thing2(void) {}\n"
                    } else {
                        contents <<< "int main(void) {\n";
                        contents <<< "  return 10;\n";
                        contents <<< "}\n";
                    }
                }
                try await tester.checkBuild(parameters: parameters, runDestination: generic ? .anyMac : .macOS, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs) { results in


                    // We don't expect to rerun any `ProcessProductPackaging` tasks if we just change the source.
                    let expectedTasksSansProcessProductPackaging = Array(expectedTasks.drop(while: { $0 == "ProcessProductPackaging" }))

                    for (expectedTask, count) in Dictionary(expectedTasksSansProcessProductPackaging.map({ ($0, 1) }), uniquingKeysWith: +) {
                        results.checkTasks(.matchRuleType(expectedTask)) { tasks in
                            #expect(tasks.count == count)
                        }
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)
                    results.checkNoTask()
                }

                // Check that we get a second null build.
                try await tester.checkNullBuild(parameters: parameters, runDestination: generic ? .anyMac : .macOS, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs, excludedTasks: ["ClangStatCache"])
            }
        }

        // Check the behavior of chown/chmod.
        try await checkScenario("Tool File Attributes", expectedTasks: ["ScanDependencies", "CompileC", "Ld", "SetGroup", "SetMode"], settings: [
            "INSTALL_GROUP": GetCurrentUserGroupName()!,
            "INSTALL_MODE_FLAG": "+w"])

        // Check the behavior of strip.
        try await checkScenario("Tool Stripping", expectedTasks: ["ScanDependencies", "CompileC", "Ld", "Strip"], settings: [
            "STRIP_INSTALLED_PRODUCT": "YES"])

        // Check the behavior of signing.
        try await checkScenario("Tool Code Signing", expectedTasks: ["ScanDependencies", "CompileC", "Ld", "CodeSign"], enableSigning: true)

        // Check the behavior of mutation of a universal binary.
        try await checkScenario("Universal Tool Mutation", expectedTasks: ["ScanDependencies", "ScanDependencies", "CompileC", "CompileC", "CreateUniversalBinary", "Ld", "Ld", "Strip"], generic: true, settings: [
            "STRIP_INSTALLED_PRODUCT": "YES",
            "ARCHS": "x86_64 x86_64h",
            "VALID_ARCHS[sdk=macosx*]": "$(inherited) x86_64h"])

        // Check the behavior of signing a framework.
        try await checkScenario("Framework Code Signing", expectedTasks: ["ScanDependencies", "CompileC", "Ld", "GenerateTAPI", "CodeSign"], enableSigning: true, targetType: .framework)
    }

    /// Check the handling of a minimal copied bundle.
    @Test(.requireSDKs(.host), .skipHostOS(.windows), .requireThreadSafeWorkingDirectory)
    func minimalCopiedBundle() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("Input-1.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "USE_HEADERMAP": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                            ]
                        )],
                        targets: [
                            TestAggregateTarget(
                                "Dest",
                                buildPhases: [TestCopyFilesBuildPhase(["SourceBundle.bundle"], destinationSubfolder: .frameworks, destinationSubpath: "Dest", onlyForDeployment: false)]),
                            TestStandardTarget(
                                "SourceBundle", type: .bundle,
                                buildPhases: [TestCopyFilesBuildPhase(["Input-1.txt"], destinationSubfolder: .frameworks, onlyForDeployment: false)]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let signableTargets: Set<String> = ["App"]

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Input-1.txt")) { contents in
                contents <<< "Input-1 Contents\n"
            }

            // FIXME: Consider enabling deployment processing in this test.
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: .host)

            // Check the initial build.
            let taskTypesToExclude = Set(["Gate", "MkDir", "CreateBuildDirectory", "RegisterExecutionPolicyException"])
            let request = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            try await tester.checkBuild(parameters: parameters, runDestination: .host, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)
                results.checkTask(.matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchRuleType("Touch")) { _ in }
                results.checkTasks(.matchRuleType("Copy")) { tasks in
                    #expect(tasks.count == 2)
                }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkNoTask()
            }

            // Check that we get a null build.
            try await tester.checkBuild(parameters: parameters, runDestination: .host, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                // Check that no tasks ran.
                //
                // FIXME: This test does not yet necessarily pass on the first iteration (which is why we run it again below), because sometimes the signature of the source bundle is computed before the Touch task runs: <rdar://problem/30640904> Directory touch task interferes with directory tree signatures
                results.checkTasks(.matchRuleType("Copy")) { tasks in
                    #expect(tasks.count == 0 || tasks.count == 1)
                }

                results.checkNoTask()
            }
            try await tester.checkNullBuild(parameters: parameters, runDestination: .host, buildRequest: request, persistent: true, signableTargets: signableTargets)

            // Check that we get a proper incremental build if we change the input source.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Input-1.txt")) { contents in
                contents <<< "Input-1 Modified Contents\n"
            }
            try await tester.checkBuild(parameters: parameters, runDestination: .host, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)
                results.checkTasks(.matchRuleType("Copy")) { tasks in
                    #expect(tasks.count == 2)
                }
                results.checkNoTask()
            }

            // Check that we get a second null build.
            try await tester.checkBuild(parameters: parameters, runDestination: .host, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                // Check that no tasks ran.
                //
                // FIXME: This test does not yet necessarily pass on the first iteration (which is why we run it again below), because sometimes the signature of the source bundle is computed before the Touch task runs: <rdar://problem/30640904> Directory touch task interferes with directory tree signatures
                results.checkTasks(.matchRuleType("Copy")) { tasks in
                    #expect(tasks.count == 0 || tasks.count == 1)
                }

                results.checkNoTask()
            }
            try await tester.checkNullBuild(parameters: parameters, runDestination: .host, buildRequest: request, persistent: true, signableTargets: signableTargets)
        }
    }

    @Test(.requireSDKs(.macOS), .flaky("Occasionally fails in CI due to either Versions/A/Resources/ja.lproj/Localizable.strings and/or Versions/A/Resources/ja.lproj/Localizable.strings not being found"), .bug("rdar://136196464"))
    func installLocEmbeddedFrameworks() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("File.c"),
                                TestFile("Info.plist"),
                                TestVariantGroup("Localizable.strings", children: [
                                    TestFile("ja.lproj/Localizable.strings", regionVariantName: "ja"),
                                ]),
                                TestFile("AResource.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "FRAMEWORK_SEARCH_PATHS": "$(inherited) \(tmpDirPath.str)",
                                "COPY_PHASE_STRIP": "NO",
                                "SDKROOT": "macosx",
                                "INSTALLLOC_LANGUAGE": "ja",
                                "DSTROOT": tmpDirPath.join("DSTROOT").str
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "App", type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        TestBuildFile("File.c")
                                    ]),
                                    TestFrameworksBuildPhase([
                                        TestBuildFile("AFwk.framework"),
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("AFwk.framework", codeSignOnCopy: true, removeHeadersOnCopy: true),
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                ]),
                            TestStandardTarget(
                                "AFwk", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        TestBuildFile("File.c")
                                    ]),
                                    TestResourcesBuildPhase([
                                        TestBuildFile("Localizable.strings")
                                    ])
                                ]
                            )
                        ])
                ])
            let core = try await self.getCore()
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            let sourceFrameworkPath = tmpDirPath.join("AFwk.framework")
            try await tester.fs.writeFramework(sourceFrameworkPath, archs: ["arm64"], platform: .macOS, infoLookup: core, static: false) { _, _, headersDir, resourcesDir in
                try await tester.fs.writeFileContents(headersDir.join("AFwk.h")) { $0 <<< "" }
                try await tester.fs.writePlist(resourcesDir.join("AResource.plist"), .plDict([:]))
                let lproj = resourcesDir.join("ja.lproj")
                try await tester.fs.writeFileContents(lproj.join("Localizable.strings")) { $0 <<< "" }
            }

            let expectedFrameworkFiles = [
                "AFwk",
                "Headers",
                "Resources",
                "Versions",
                "Versions/A",
                "Versions/A/AFwk",
                "Versions/A/Headers",
                "Versions/A/Headers/AFwk.h",
                "Versions/A/Resources",
                "Versions/A/Resources/AResource.plist",
                "Versions/A/Resources/Info.plist",
                "Versions/A/Resources/ja.lproj",
                "Versions/A/Resources/ja.lproj/Localizable.strings",
                "Versions/A/_CodeSignature",
                "Versions/A/_CodeSignature/CodeDirectory",
                "Versions/A/_CodeSignature/CodeRequirements",
                "Versions/A/_CodeSignature/CodeRequirements-1",
                "Versions/A/_CodeSignature/CodeResources",
                "Versions/A/_CodeSignature/CodeSignature",
                "Versions/Current",
            ]

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/File.c")) { contents in
                contents <<< "int main(void) {\n";
                contents <<< "  return 0;\n";
                contents <<< "}\n";
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/AFwk.h")) { $0 <<< "" }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/ja.lproj/Localizable.strings")) { $0 <<< "" }
            try await tester.fs.writePlist(SRCROOT.join("Sources/AResource.plist"), .plDict([:]))

            let parameters = BuildParameters(action: .installLoc, configuration: "Debug", activeRunDestination: .macOS)
            let buildTargets = tester.workspace.projects[0].targets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .build(style: .buildOnly, skipDependencies: false), schemeCommand: .launch)

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest, signableTargets: ["App"]) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes()

                let frameworkDestinationDir = "\(SRCROOT.str)/build/Debug/App.app/Contents/Frameworks"
                let destFrameworkPath = Path("\(frameworkDestinationDir)/AFwk.framework")
                let delta = try Set(expectedFrameworkFiles).diff(against: tester.fs.traverse(destFrameworkPath, { $0.relativeSubpath(from: destFrameworkPath) }))
                XCTAssertEqualSequences(delta.right, [])

                // Check that all the non-localized content has been pruned.
                XCTAssertEqualSequences(delta.left.sorted(), [
                    "AFwk",
                    "Headers",
                    "Resources",
                    "Versions/A/AFwk",
                    "Versions/A/Headers",
                    "Versions/A/Headers/AFwk.h",
                    "Versions/A/Resources/AResource.plist",
                    "Versions/A/Resources/Info.plist",
                    "Versions/A/_CodeSignature",
                    "Versions/A/_CodeSignature/CodeDirectory",
                    "Versions/A/_CodeSignature/CodeRequirements",
                    "Versions/A/_CodeSignature/CodeRequirements-1",
                    "Versions/A/_CodeSignature/CodeResources",
                    "Versions/A/_CodeSignature/CodeSignature",
                    "Versions/Current",
                ])
            }
        }
    }

    /// Tests that content such as headers is removed from frameworks when they are processed by a copy files build phase.
    @Test(.requireSDKs(.macOS, .iOS), arguments: [.anyMac, .anyiOSDevice, .anyMacCatalyst] as [RunDestinationInfo])
    func copiedFrameworkContentPruning(runDestination: RunDestinationInfo) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("App.c"),
                                TestFile("Info.plist"),
                                TestFile("ADynamicFwk.framework", path: tmpDirPath.join("ADynamicFwk.framework").str, sourceTree: .absolute),
                                TestFile("AStaticFwk.framework", path: tmpDirPath.join("AStaticFwk.framework").str, sourceTree: .absolute)
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "FRAMEWORK_SEARCH_PATHS": "$(inherited) \(tmpDirPath.str)",
                                "COPY_PHASE_STRIP": "NO",
                                // Stripping bitcode varies by platform, and since it's not what we're testing here, we just turn it off.
                                "STRIP_BITCODE_FROM_COPIED_FILES": "NO",
                                "SDKROOT": runDestination.sdk,
                                "SUPPORTS_MACCATALYST": runDestination.sdkVariant == MacCatalystInfo.sdkVariantName ? "YES" : "NO"
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "App", type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        TestBuildFile("App.c")
                                    ]),
                                    TestFrameworksBuildPhase([
                                        TestBuildFile("ADynamicFwk.framework"),
                                        TestBuildFile("AStaticFwk.framework"),
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("ADynamicFwk.framework", codeSignOnCopy: true, removeHeadersOnCopy: true),
                                        TestBuildFile("AStaticFwk.framework", codeSignOnCopy: true, removeHeadersOnCopy: true),
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                ]),
                            TestStandardTarget(
                                "App2", type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        TestBuildFile("App.c")
                                    ]),
                                    TestFrameworksBuildPhase([
                                        TestBuildFile("ADynamicFwk.framework"),
                                        TestBuildFile("AStaticFwk.framework"),
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("ADynamicFwk.framework", codeSignOnCopy: false, removeHeadersOnCopy: true),
                                        TestBuildFile("AStaticFwk.framework", codeSignOnCopy: false, removeHeadersOnCopy: true),
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                ]),
                        ])
                ])
            let core = try await self.getCore()
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let signableTargets: Set<String> = ["App", "App2"]

            let sourceDynamicFrameworkPath = tmpDirPath.join("ADynamicFwk.framework")
            try await tester.fs.writeFramework(sourceDynamicFrameworkPath, archs: runDestination.platform == "macosx" ? ["arm64", "x86_64"] : ["arm64"], platform: #require(runDestination.buildVersionPlatform(core)), infoLookup: core, static: false) { _, _, headersDir, resourcesDir in
                try await tester.fs.writeFileContents(headersDir.join("ADynamicFwk.h")) { $0 <<< "" }
                try await tester.fs.writePlist(resourcesDir.join("ADynamicResource.plist"), .plDict([:]))
                try await tester.fs.writePlist(resourcesDir.join("Info.plist"), .plDict([
                    "CFBundleIdentifier": "com.apple.ADynamicFwk",
                ]))
            }

            let sourceDynamicFrameworkFiles = try tester.fs.traverse(sourceDynamicFrameworkPath, { $0.relativeSubpath(from: sourceDynamicFrameworkPath) }).sorted()
            if runDestination.platform == "macosx" {
                XCTAssertEqualSequences(sourceDynamicFrameworkFiles, [
                    "ADynamicFwk",
                    "Headers",
                    "Resources",
                    "Versions",
                    "Versions/A",
                    "Versions/A/ADynamicFwk",
                    "Versions/A/Headers",
                    "Versions/A/Headers/ADynamicFwk.h",
                    "Versions/A/Resources",
                    "Versions/A/Resources/ADynamicResource.plist",
                    "Versions/A/Resources/Info.plist",
                    "Versions/A/_CodeSignature",
                    "Versions/A/_CodeSignature/CodeDirectory",
                    "Versions/A/_CodeSignature/CodeRequirements",
                    "Versions/A/_CodeSignature/CodeRequirements-1",
                    "Versions/A/_CodeSignature/CodeResources",
                    "Versions/A/_CodeSignature/CodeSignature",
                    "Versions/Current",
                ])
            } else {
                XCTAssertEqualSequences(sourceDynamicFrameworkFiles, [
                    "ADynamicFwk",
                    "ADynamicResource.plist",
                    "Headers",
                    "Headers/ADynamicFwk.h",
                    "Info.plist",
                    "_CodeSignature",
                    "_CodeSignature/CodeResources",
                ])
            }

            let platform = core.platformRegistry.lookup(name: runDestination.platform)
            let bundleSupportedPlatforms = try #require(platform?.additionalInfoPlistEntries["CFBundleSupportedPlatforms"])

            let sourceStaticFrameworkPath = tmpDirPath.join("AStaticFwk.framework")
            try await tester.fs.writeFramework(sourceStaticFrameworkPath, archs: runDestination.platform == "macosx" ? ["arm64", "x86_64"] : ["arm64"], platform: #require(runDestination.buildVersionPlatform(core)), infoLookup: core, static: true) { _, _, headersDir, resourcesDir in
                try await tester.fs.writeFileContents(headersDir.join("AStaticFwk.h")) { $0 <<< "" }
                try await tester.fs.writePlist(resourcesDir.join("AStaticResource.plist"), .plDict([:]))
                try await tester.fs.writePlist(resourcesDir.join("Info.plist"), .plDict([
                    "OSMinimumDriverKitVersion": "11.0",
                    "LSMinimumSystemVersion": "11.0",
                    "MinimumOSVersion": "11.0",
                    "CFBundleSupportedPlatforms": bundleSupportedPlatforms,
                    "CFBundleIdentifier": "com.apple.AStaticFwk",
                ]))
            }

            let sourceStaticFrameworkFiles = try tester.fs.traverse(sourceStaticFrameworkPath, { $0.relativeSubpath(from: sourceStaticFrameworkPath) }).sorted()
            if runDestination.platform == "macosx" {
                XCTAssertEqualSequences(sourceStaticFrameworkFiles, [
                    "AStaticFwk",
                    "Headers",
                    "Resources",
                    "Versions",
                    "Versions/A",
                    "Versions/A/AStaticFwk",
                    "Versions/A/Headers",
                    "Versions/A/Headers/AStaticFwk.h",
                    "Versions/A/Resources",
                    "Versions/A/Resources/AStaticResource.plist",
                    "Versions/A/Resources/Info.plist",
                    "Versions/A/_CodeSignature",
                    "Versions/A/_CodeSignature/CodeDirectory",
                    "Versions/A/_CodeSignature/CodeRequirements",
                    "Versions/A/_CodeSignature/CodeRequirements-1",
                    "Versions/A/_CodeSignature/CodeResources",
                    "Versions/A/_CodeSignature/CodeSignature",
                    "Versions/Current",
                ])
            } else {
                XCTAssertEqualSequences(sourceStaticFrameworkFiles, [
                    "AStaticFwk",
                    "AStaticResource.plist",
                    "Headers",
                    "Headers/AStaticFwk.h",
                    "Info.plist",
                    "_CodeSignature",
                    "_CodeSignature/CodeDirectory",
                    "_CodeSignature/CodeRequirements",
                    "_CodeSignature/CodeRequirements-1",
                    "_CodeSignature/CodeResources",
                    "_CodeSignature/CodeSignature",
                ])
            }

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/App.c")) { contents in
                contents <<< "int main(void) {\n";
                contents <<< "  return 0;\n";
                contents <<< "}\n";
            }

            func checkBuild(overrides: [String: String]) async throws {
                let keepStaticBinary = overrides["REMOVE_STATIC_EXECUTABLES_FROM_EMBEDDED_BUNDLES"] == "NO"
                let useAppStoreCodelessFrameworksWorkaround = overrides["ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT"] != "YES"

                let parameters = BuildParameters(configuration: "Debug", activeRunDestination: runDestination, overrides: overrides)
                let buildTargets = tester.workspace.projects[0].targets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
                let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .build(style: .buildOnly, skipDependencies: false), schemeCommand: .launch)

                try await tester.checkBuild(parameters: parameters, runDestination: runDestination, buildRequest: buildRequest, persistent: true, signableTargets: signableTargets) { results in
                    results.checkNoDiagnostics()
                    results.consumeTasksMatchingRuleTypes()

                    let appsToCheck = [
                        "App.app": true,
                        "App2.app": false,
                    ]
                    for (basename, codesign) in appsToCheck {
                        let frameworkDestinationDir: String
                        if runDestination.platform == "macosx" {
                            frameworkDestinationDir = "\(SRCROOT.str)/build/Debug\(runDestination.builtProductsDirSuffix)/\(basename)/Contents/Frameworks"
                        } else {
                            frameworkDestinationDir = "\(SRCROOT.str)/build/Debug\(runDestination.builtProductsDirSuffix)/\(basename)/Frameworks"
                        }

                        // Check that we're matching the deployment target from the Info.plist, not the one of the embedding application.
                        if !keepStaticBinary && useAppStoreCodelessFrameworksWorkaround {
                            let frameworkPath = "\(frameworkDestinationDir)/AStaticFwk.framework/AStaticFwk"
                            let vtoolOutput = try await runHostProcess(["vtool", "-show-build", frameworkPath], interruptible: false, redirectStderr: false)
                            if vtoolOutput.contains("LC_VERSION_MIN_IPHONEOS") {
                                let version = try #require(vtoolOutput.components(separatedBy: "\n").first(where: { $0.contains("version") })?.trimmingPrefix(while: { $0.isWhitespace }))
                                #expect(version == "version 11.0")
                                #expect(try Set(MachO(reader: BinaryReader(data: tester.fs.read(Path(frameworkPath)))).slices().map { $0.arch }) == ["arm64"])
                            } else {
                                let minos = try #require(vtoolOutput.components(separatedBy: "\n").first(where: { $0.contains("minos") })?.trimmingPrefix(while: { $0.isWhitespace }))
                                #expect(minos == (runDestination.buildVersionPlatform(core) == .macCatalyst ? "minos 14.2" : "minos 11.0"))
                                #expect(try Set(MachO(reader: BinaryReader(data: tester.fs.read(Path(frameworkPath)))).slices().map { $0.arch }) == ["arm64", "x86_64"])
                            }
                        }

                        try results.checkTask(.matchRule(["Copy", "\(frameworkDestinationDir)/ADynamicFwk.framework", "\(tmpDirPath.str)/ADynamicFwk.framework"])) { task in
                            task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-exclude", "Headers", "-exclude", "PrivateHeaders", "-exclude", "Modules", "-exclude", "*.tbd", "-resolve-src-symlinks"] + (keepStaticBinary ? [] : ["-remove-static-executable"]) + ["\(tmpDirPath.str)/ADynamicFwk.framework", frameworkDestinationDir])

                            let destDynamicFrameworkPath = Path("\(frameworkDestinationDir)/ADynamicFwk.framework")
                            let delta = try Set(sourceDynamicFrameworkFiles).diff(against: tester.fs.traverse(destDynamicFrameworkPath, { $0.relativeSubpath(from: destDynamicFrameworkPath) }))
                            XCTAssertEqualSequences(delta.right, [])

                            // Check that we removed all the headers
                            if runDestination.platform == "macosx" {
                                XCTAssertEqualSequences(delta.left.sorted(), [
                                    "Headers",
                                    "Versions/A/Headers",
                                    "Versions/A/Headers/ADynamicFwk.h",
                                ])
                            } else {
                                XCTAssertEqualSequences(delta.left.sorted(), [
                                    "Headers",
                                    "Headers/ADynamicFwk.h",
                                ])
                            }
                        }

                        try results.checkTask(.matchRule(["Copy", "\(frameworkDestinationDir)/AStaticFwk.framework", "\(tmpDirPath.str)/AStaticFwk.framework"])) { task in
                            task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-exclude", "Headers", "-exclude", "PrivateHeaders", "-exclude", "Modules", "-exclude", "*.tbd", "-resolve-src-symlinks"] + (keepStaticBinary ? [] : ["-remove-static-executable"]) + ["\(tmpDirPath.str)/AStaticFwk.framework", frameworkDestinationDir])

                            let destStaticFrameworkPath = Path("\(frameworkDestinationDir)/AStaticFwk.framework")
                            let delta = try Set(sourceStaticFrameworkFiles).diff(against: tester.fs.traverse(destStaticFrameworkPath, { $0.relativeSubpath(from: destStaticFrameworkPath) }))
                            XCTAssertEqualSequences(delta.right, [])

                            // Check that we removed all the headers, as well as the binary (since it is static), if configured
                            if runDestination.platform == "macosx" {
                                if keepStaticBinary {
                                    XCTAssertEqualSequences(delta.left.sorted(), [
                                        "Headers",
                                        "Versions/A/Headers",
                                        "Versions/A/Headers/AStaticFwk.h",
                                    ])
                                }
                            } else {
                                if keepStaticBinary {
                                    XCTAssertEqualSequences(delta.left.sorted(), [
                                        "Headers",
                                        "Headers/AStaticFwk.h",
                                    ])
                                } else if useAppStoreCodelessFrameworksWorkaround {
                                    let additionalFiles: [String]
                                    if codesign {
                                        additionalFiles = [
                                            "_CodeSignature/CodeDirectory",
                                            "_CodeSignature/CodeRequirements",
                                            "_CodeSignature/CodeRequirements-1",
                                            "_CodeSignature/CodeSignature",
                                        ]
                                    } else {
                                        additionalFiles = []
                                    }

                                    XCTAssertEqualSequences(delta.left.sorted(), [
                                        "Headers",
                                        "Headers/AStaticFwk.h",
                                    ] + additionalFiles)
                                } else {
                                    XCTAssertEqualSequences(delta.left.sorted(), [
                                        "AStaticFwk",
                                        "Headers",
                                        "Headers/AStaticFwk.h",
                                    ])
                                }
                            }

                            if runDestination.platform == "macosx" {
                                if !keepStaticBinary && useAppStoreCodelessFrameworksWorkaround {
                                    results.checkNote(.prefix("Injecting stub binary into codeless framework"))
                                }
                            } else {
                                if !keepStaticBinary && useAppStoreCodelessFrameworksWorkaround {
                                    results.checkNote(.prefix("Injecting stub binary into codeless framework"))
                                }
                            }
                        }

                        if codesign {
                            let bundleSigningType = keepStaticBinary ? "static" : "codeless"
                            if runDestination.platform == "macosx" {
                                _ = results.checkTask(.matchRule(["CodeSign", "\(frameworkDestinationDir)/AStaticFwk.framework/Versions/A"])) { task in
                                    if keepStaticBinary || !useAppStoreCodelessFrameworksWorkaround {
                                        results.checkNote(.equal("Signing \(bundleSigningType) framework with --generate-pre-encrypt-hashes (for task: \(task.ruleInfo))"))
                                    }
                                }
                            } else {
                                _ = results.checkTask(.matchRule(["CodeSign", "\(frameworkDestinationDir)/AStaticFwk.framework"])) { task in
                                    if keepStaticBinary || !useAppStoreCodelessFrameworksWorkaround {
                                        results.checkNote(.equal("Signing \(bundleSigningType) framework with --generate-pre-encrypt-hashes (for task: \(task.ruleInfo))"))
                                    }
                                }
                            }
                        }
                    }

                    results.checkNoNotes()
                }
            }

            // Run the tests twice, once keeping the binary, and once removing it.
            try await checkBuild(overrides: [:])
            try await checkBuild(overrides: ["REMOVE_STATIC_EXECUTABLES_FROM_EMBEDDED_BUNDLES": "NO"])

            // Turn off the temporary App Store stub binary workaround
            try await checkBuild(overrides: ["ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": "YES"])
        }
    }

    /// Check the handling of copied frameworks.
    @Test(.requireSDKs(.macOS))
    func copiedFrameworks() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("App.c"),
                                TestFile("Fwk.c"),
                                TestFile("Info.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "USE_HEADERMAP": "NO",
                                "SKIP_INSTALL": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",

                                // Force stripping and file attribute changes off by default.
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": "",
                                "INSTALL_MODE_FLAG": "",
                                "STRIP_INSTALLED_PRODUCT": "NO",
                                "SDK_STAT_CACHE_ENABLE": "NO"
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "App", type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("App.c")]),
                                    TestCopyFilesBuildPhase([TestBuildFile("Fwk.framework", codeSignOnCopy: true)], destinationSubfolder: .frameworks),
                                ], dependencies: ["Fwk"]),
                            TestStandardTarget(
                                "Fwk", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("Fwk.c")]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let signableTargets: Set<String> = ["App"]

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Fwk.c")) { contents in
                contents <<< "void thing(void) __attribute__((visibility(\"default\")));\n"
                contents <<< "void thing(void) {}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/App.c")) { contents in
                contents <<< "int main(void) {\n";
                contents <<< "  return 0;\n";
                contents <<< "}\n";
            }

            // We enable deployment postprocessing explicitly, to check the full range of basic behaviors.
            let parameters = BuildParameters(configuration: "Debug", overrides: [
                "DSTROOT": tmpDirPath.join("dst").str,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
            ])

            // Check the initial build.
            let taskTypesToExclude = Set(["Gate", "MkDir", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "RegisterWithLaunchServices", "SymLink", "Touch", "WriteAuxiliaryFile", "CreateBuildDirectory", "ClangStatCache", "ProcessSDKImports"])
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("Ld")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                    #expect(tasks.count == 1)
                }

                results.checkTasks(.matchRuleType("CodeSign")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTask(.matchRuleType("Copy")) { _ in }
                results.checkTask(.matchRuleType("Validate")) { _ in }

                results.checkNoTask()
            }

            // Check that we get a null build.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                // Check that no tasks ran.
                //
                // FIXME: No tasks should run, but the directory tree signature for the copy task isn't correctly computed yet: <rdar://problem/30638921> Directory tree signatures fail when tracking a symbolic link with other mutators
                // results.checkNoTask()
                if !results.uncheckedTasks.isEmpty {
                    results.checkTask(.matchRuleType("Copy")) { _ in }
                    results.checkTasks(.matchRuleType("CodeSign")) { tasks in
                        #expect(tasks.count == 2)
                    }
                    results.checkTask(.matchRuleType("Validate")) { _ in }
                }

                results.checkNoTask()
            }
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                // Check that no tasks ran.
                //
                // FIXME: No tasks should run, but the directory tree signature for the copy task isn't correctly computed yet: <rdar://problem/30638921> Directory tree signatures fail when tracking a symbolic link with other mutators
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)
                results.checkNoTask()
            }

            // Check that we get a proper incremental build if we change the application source.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/App.c")) { contents in
                contents <<< "int main(void) {\n";
                contents <<< "  return 10;\n";
                contents <<< "}\n";
            }
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                // We should recompile, link, and sign the app.
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)
                results.checkTask(.matchRuleType("ScanDependencies")) { _ in }
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkTask(.matchRuleType("Ld")) { _ in }
                results.checkTask(.matchRuleType("CodeSign")) { _ in }
                results.checkTask(.matchRuleType("Validate")) { _ in }
                results.checkNoTask()
            }

            // Check that we get a second null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets, excludedTasks: ["ClangStatCache"])

            // Check that we get a proper incremental build if we change the framework source.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Fwk.c")) { contents in
                contents <<< "void thing2(void) __attribute__((visibility(\"default\")));\n"
                contents <<< "void thing2(void) {}\n"
            }
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                // We should recompile and link the framework, then recopy and resign the app.
                results.consumeTasksMatchingRuleTypes(taskTypesToExclude)
                results.checkTask(.matchRuleType("ScanDependencies")) { _ in }
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkTask(.matchRuleType("Ld")) { _ in }
                results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                results.checkTask(.matchRuleType("Copy")) { _ in }
                results.checkTask(.matchRuleType("Validate")) { _ in }
                results.checkTasks(.matchRuleType("CodeSign")) { tasks in
                    #expect(tasks.count == 2)
                }
                results.checkNoTask()
            }
            // Check that we get a third null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets, excludedTasks: ["ClangStatCache"])
        }
    }

    @Test(.requireSDKs(.macOS), arguments: [nil, false])
    func incrementalArchive(enableBuildSystemCaching: Bool?) async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("App.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",

                                // we don't actually want to change rights here, so we fake that
                                "CHOWN": "true",

                                "DSTROOT": tmpDirPath.join("dstroot").str,
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("App.c")]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            if let enableBuildSystemCaching {
                tester.userPreferences = tester.userPreferences.with(enableBuildSystemCaching: enableBuildSystemCaching)
            }

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/App.c")) { contents in
                contents <<< "int main(void) {\n";
                contents <<< "  return 0;\n";
                contents <<< "}\n";
            }

            let parameters = BuildParameters(action: .archive, configuration: "Debug")

            // Perform the first (clean) build and expect to see a compile task.
            try await confirmation("First archive should succeed.") { firstBuildSucceed in
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleItem("CompileC"), body: { _ in })
                    results.checkTasks { tasks in
                        #expect(tasks.count > 0)
                    }
                    results.checkNoDiagnostics()
                    firstBuildSucceed.confirm()
                }
            }

            // Perform the second (incremental) build, and expect to see no tasks run because we didn't change anything.
            try await confirmation("Second archive should succeed.") { secondBuildSucceed in
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }
                    if tester.userPreferences.enableBuildSystemCaching {
                        results.checkNoTask()
                    } else {
                        // NOTE: Presently the second build will fail checks when EnableBuildSystemCaching is turned off, because many tasks will be shown as having run in what should be a null build.
                        // rdar://62210168 Incremental builds in build operation tests do not work properly when EnableBuildSystemCaching is off.
                    }

                    results.checkNoDiagnostics()
                    secondBuildSucceed.confirm()
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func copySwiftLibs_preSwiftOS_macos() async throws {
        try await _testCopySwiftLibs(deploymentTarget: "10.14.3", shouldFilterSwiftLibs: false, shouldBackDeploySwiftConcurrency: false)
    }

    @Test(.requireSDKs(.macOS))
    func copySwiftLibs_postSwiftOS_macos() async throws {
        try await _testCopySwiftLibs(deploymentTarget: "10.14.4", shouldFilterSwiftLibs: true, shouldBackDeploySwiftConcurrency: true)
    }

    @Test(.requireSDKs(.macOS))
    func copySwiftLibs_postSwiftConcurrency_macos() async throws {
        try await _testCopySwiftLibs(deploymentTarget: "12.0", shouldFilterSwiftLibs: true, shouldBackDeploySwiftConcurrency: false)
    }

    @Test(.requireSDKs(.macOS))
    func copySwiftLibs_postSwiftOS_preSwiftConcurrency_macos() async throws {
        try await _testCopySwiftLibs(deploymentTarget: "11.5", shouldFilterSwiftLibs: true, shouldBackDeploySwiftConcurrency: true)
    }

    func _testCopySwiftLibs(deploymentTarget: String, shouldFilterSwiftLibs: Bool, shouldBackDeploySwiftConcurrency: Bool, file: StaticString = #filePath, line: Int = #line) async throws {
        // Create a temporary test workspace, consisting of:
        // - an application
        // - a framework embedded directly inside the application
        // - a framework embedded inside that framework
        //
        // All use Swift, and the point is to test that the right libswift libs
        // get copied as new import statements are added to the sources that are
        // only indirectly included inside the app.
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "TestProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Info.plist"),
                                TestFile("AppMain.c"),
                                TestFile("FrameworkSource.swift"),
                                TestFile("SubFrameworkSource.swift"),
                                TestFile("SysExMain.swift"),
                                TestFile("Test.swift"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "macosx",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "INFOPLIST_FILE": "Info.plist",
                                    "MACOSX_DEPLOYMENT_TARGET": deploymentTarget,
                                ]
                            )
                        ],
                        targets: [
                            TestAggregateTarget(
                                "All",
                                dependencies: [
                                    "App",
                                    "SwiftlessApp",
                                    "SwiftlessSysExApp",
                                    "UnitTests",
                                ]
                            ),
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                        ]
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "AppMain.c"
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Framework.framework"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "Framework.framework",
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ],
                                dependencies: [
                                    "Framework",
                                ]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "FrameworkSource.swift"
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "SubFramework.framework"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SubFramework.framework",
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ],
                                dependencies: [
                                    "SubFramework",
                                ]
                            ),
                            TestStandardTarget(
                                "SubFramework",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "SubFrameworkSource.swift"
                                    ])
                                ]
                            ),
                            TestStandardTarget(
                                "SwiftlessApp",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                        ]
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "AppMain.c"
                                    ]),
                                ]
                            ),
                            TestStandardTarget(
                                "SwiftlessSysExApp",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                        ]
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "AppMain.c"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SystemExtension.systemextension",
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ],
                                dependencies: [
                                    "SystemExtension"
                                ]
                            ),
                            TestStandardTarget(
                                "SystemExtension",
                                type: .systemExtension,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    )
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "SysExMain.swift"
                                    ]),
                                ]
                            ),
                            TestStandardTarget(
                                "UnitTests",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            // Override the deployment target for tests so we don't get a warning that our deployment target is higher than XCTest's.
                                            "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget
                                        ]
                                    )
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Test.swift"
                                    ]),
                                ]
                            )
                        ]
                    )
                ])

            // Create a tester for driving the build.
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            // Write the source files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/AppMain.c")) { contents in
                contents <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/FrameworkSource.swift")) { contents in
                contents <<< """
                    public import Foundation
                    public func foo() -> NSString { return "Foo" }
                    @available(macOS 10.15, *)
                    public actor A { }
                    """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/SysExMain.swift")) { contents in
                contents <<< """
                    public import Foundation
                    public func foo() -> NSString { return "Foo" }
                    @available(macOS 10.15, *)
                    public actor A { }
                    @main struct Main { public static func main() { } }
                    """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/SubFrameworkSource.swift")) { contents in
                contents <<< "public import Foundation\npublic func Bar() -> NSString { return \"Bar\" }"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/Test.swift")) { contents in
                contents <<< """
                    import XCTest
                    class Tester: XCTestCase {
                    func testMe() { XCTAssert(true) }
                    @available(macOS 10.15, *)
                    public actor A { }
                    }
                    """
            }

            // Write a barebones Info.plist file.
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Read and return the UUIDs out of a Mach-O.  There could be more than one in case there are multiple architectures.
            func uuids(_ p : Path) throws -> Set<UUID> {
                return  Set(try MachO(data: tester.fs.read(p)).slices().map{ try $0.uuid()! })
            }
            let toolchain = try #require(core.toolchainRegistry.defaultToolchain)

            // Get the UUID for the libswiftFoundation.dylib in the toolchain.
            let libSwiftFoundationName = "libswiftFoundation.dylib"
            func libSwiftFoundationPath(_ t : Toolchain) throws -> Path {
                return t.path.join(Path("usr/lib/swift-5.0/macosx/\(libSwiftFoundationName)"))
            }
            let toolchainLibSwiftFoundationUUIDs = shouldFilterSwiftLibs ? [] : try uuids(libSwiftFoundationPath(toolchain))

            // Get the UUID for libswiftCoreLocation.dylib in the toolchain.  We'll use it later.
            let libSwiftCoreLocationName = "libswiftCoreLocation.dylib"
            func libSwiftCoreLocationPath(_ t : Toolchain) throws -> Path {
                return t.path.join(Path("usr/lib/swift-5.0/macosx/\(libSwiftCoreLocationName)"))
            }

            // Do an initial build.  It's a clean build, so we expect all the tasks to run, including the CopySwiftLibs.
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check that CopySwiftLibs ran.
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("App")) { _ in }
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("SwiftlessApp")) { _ in }
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("SwiftlessSysExApp")) { _ in }
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("UnitTests")) { _ in }
                results.checkNoTask(.matchRuleType("CopySwiftLibs"))

                let buildDir = tmpDirPath.join(Path("Test/TestProject/build/\(parameters.configuration!)"))

                do {
                    // Check that we embedded libswiftFoundation.dylib into the app, but that we did not embed libSwiftCoreLocation.dylib.
                    let embeddedLibSwiftFoundationPath = buildDir.join(Path("App.app/Contents/Frameworks/\(libSwiftFoundationName)"))
                    do {
                        let embeddedLibUUIDs = shouldFilterSwiftLibs ? [] : try uuids(embeddedLibSwiftFoundationPath)
                        #expect(toolchainLibSwiftFoundationUUIDs == embeddedLibUUIDs)
                    }
                    catch {
                        Issue.record("\(error)")
                    }
                    let embeddedLibSwiftCoreLocationPath = buildDir.join(Path("App.app/Contents/Frameworks/\(libSwiftCoreLocationName)"))
                    #expect(!tester.fs.exists(embeddedLibSwiftCoreLocationPath))

                    // Check that the dependency-info file contains the expected entries.
                    let swiftDepsPath = tmpDirPath.join(Path("Test/TestProject/build/TestProject.build/Debug/App.build/SwiftStdLibToolInputDependencies.dep"))
                    let dependencyInfo = try DependencyInfo(bytes: tester.fs.read(swiftDepsPath).bytes)

                    let expectedDependencyInfo =  DependencyInfo(
                        version: "swift-stdlib-tool",
                        inputs: ([
                            buildDir.join("App.app/Contents/Frameworks/Framework.framework/Framework").str,
                            buildDir.join("App.app/Contents/Frameworks/Framework.framework/Versions/A/Framework").str,
                            buildDir.join("App.app/Contents/Frameworks/Framework.framework/Versions/A/Frameworks/SubFramework.framework/SubFramework").str,
                            buildDir.join("App.app/Contents/Frameworks/Framework.framework/Versions/A/Frameworks/SubFramework.framework/Versions/A/SubFramework").str,
                            buildDir.join("App.app/Contents/MacOS/App").str,
                            buildDir.join("Framework.framework/Framework").str,
                            buildDir.join("Framework.framework/Versions/A/Framework").str,
                            buildDir.join("Framework.framework/Versions/A/Frameworks/SubFramework.framework/SubFramework").str,
                            buildDir.join("Framework.framework/Versions/A/Frameworks/SubFramework.framework/Versions/A/SubFramework").str
                        ]).sorted(),
                        missing: [],
                        outputs: []
                    )

                    #expect(dependencyInfo.version == expectedDependencyInfo.version)
                    XCTAssertSuperset(Set(dependencyInfo.inputs), Set(expectedDependencyInfo.inputs))

                    // Ensure that the dependency info is correct. Due to the changing nature of how Swift overlays are added, there is no need to be explicit about each one, so only the mechanism is validated by checking a handful of stable Swift overlays.
                    if shouldFilterSwiftLibs && !shouldBackDeploySwiftConcurrency {
                        #expect(dependencyInfo == expectedDependencyInfo)
                    }

                    if !shouldFilterSwiftLibs {
                        #expect(dependencyInfo.inputs.contains(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx/libswiftCore.dylib").str))
                        #expect(dependencyInfo.inputs.contains(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx/libswiftFoundation.dylib").str))
                        #expect(dependencyInfo.outputs.sorted().contains(expectedDependencyInfo.outputs.sorted()))
                        #expect(dependencyInfo.outputs.contains(buildDir.join("App.app/Contents/Frameworks/libswiftCore.dylib").str))
                        #expect(dependencyInfo.outputs.contains(buildDir.join("App.app/Contents/Frameworks/libswiftFoundation.dylib").str))
                    }

                    if shouldBackDeploySwiftConcurrency {
                        // Note all toolchains have this yet...
                        if tester.fs.exists(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib")) {
                            #expect(dependencyInfo.inputs.contains(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib").str))
                            #expect(dependencyInfo.outputs.contains(buildDir.join("App.app/Contents/Frameworks/libswift_Concurrency.dylib").str))
                        }
                    }
                }

                do {
                    // Dependency info file should be "empty" for the target which contains no Swift binaries
                    let swiftlessDepsPath = tmpDirPath.join(Path("Test/TestProject/build/TestProject.build/Debug/SwiftlessApp.build/SwiftStdLibToolInputDependencies.dep"))
                    let swiftlessDependencyInfo = try DependencyInfo(bytes: tester.fs.read(swiftlessDepsPath).bytes)
                    #expect(swiftlessDependencyInfo == DependencyInfo(version: "swift-stdlib-tool", inputs: [buildDir.join("SwiftlessApp.app/Contents/MacOS/SwiftlessApp").str]))

                    // Check that the dependency-info file contains the expected entries.
                    let unitTestsDepsPath = tmpDirPath.join(Path("Test/TestProject/build/TestProject.build/Debug/UnitTests.build/SwiftStdLibToolInputDependencies.dep"))
                    let unitTestsDependencyInfo = try DependencyInfo(bytes: tester.fs.read(unitTestsDepsPath).bytes)

                    let unitTestsExpectedDependencyInfo = DependencyInfo(
                        version: "swift-stdlib-tool",
                        inputs: ([
                            core.developerPath.path.join("Platforms/MacOSX.platform/Developer/usr/lib/libXCTestSwiftSupport.dylib").str,
                            buildDir.join("UnitTests.xctest/Contents/MacOS/UnitTests").str,
                        ]).sorted(),
                        missing: [],
                        outputs: []
                    )

                    #expect(unitTestsDependencyInfo.version == unitTestsExpectedDependencyInfo.version)
                    XCTAssertSuperset(Set(unitTestsDependencyInfo.inputs), Set(unitTestsExpectedDependencyInfo.inputs))

                    // Ensure that the dependency info is correct. Due to the changing nature of how Swift overlays are added, there is no need to be explicit about each one, so only the mechanism is validated by checking a handful of stable Swift overlays.
                    if shouldFilterSwiftLibs && !shouldBackDeploySwiftConcurrency {
                        #expect(unitTestsDependencyInfo == unitTestsExpectedDependencyInfo)
                    }

                    if !shouldFilterSwiftLibs {
                        if (try Version(core.loadSDK(.macOS).defaultDeploymentTarget)) < Version(10, 15) {
                            #expect(unitTestsDependencyInfo.inputs.contains(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx/libswiftCore.dylib").str))
                            #expect(unitTestsDependencyInfo.inputs.contains(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx/libswiftFoundation.dylib").str))
                        }
                        #expect(unitTestsDependencyInfo.outputs.sorted().contains(unitTestsExpectedDependencyInfo.outputs.sorted()))
                        if (try Version(core.loadSDK(.macOS).defaultDeploymentTarget)) < Version(10, 15) {
                            #expect(unitTestsDependencyInfo.outputs.contains(buildDir.join("UnitTests.xctest/Contents/Frameworks/libswiftCore.dylib").str))
                            #expect(unitTestsDependencyInfo.outputs.contains(buildDir.join("UnitTests.xctest/Contents/Frameworks/libswiftFoundation.dylib").str))
                        }
                    }

                    if shouldBackDeploySwiftConcurrency {
                        // NOTE: Tests have their deployment target overridden.
                        if (try Version(core.loadSDK(.macOS).defaultDeploymentTarget)) < Version(10, 15) {
                            // Note all toolchains have this yet...
                            if tester.fs.exists(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib")) {
                                #expect(unitTestsDependencyInfo.inputs.contains(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib").str))
                                #expect(unitTestsDependencyInfo.outputs.contains(buildDir.join("SwiftlessApp.app/Contents/Frameworks/libswift_Concurrency.dylib").str))
                            }
                        }
                    }
                }

                do {
                    // Checks that a Swift-free app which embeds a system extension using Swift Concurrency, embeds the back-deployment dylib.
                    let swiftDepsPath = tmpDirPath.join(Path("Test/TestProject/build/TestProject.build/Debug/SwiftlessSysExApp.build/SwiftStdLibToolInputDependencies.dep"))
                    let dependencyInfo = try DependencyInfo(bytes: tester.fs.read(swiftDepsPath).bytes)

                    if shouldBackDeploySwiftConcurrency {
                        // Note all toolchains have this yet...
                        if tester.fs.exists(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib")) {
                            #expect(dependencyInfo.inputs.contains(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib").str))
                            #expect(dependencyInfo.outputs.contains(buildDir.join("SwiftlessSysExApp.app/Contents/Frameworks/libswift_Concurrency.dylib").str))
                        }
                    }
                }
            }

            // Change the contents of the source file inside the framework in the app extension to also import a library that wasn't previously imported (CoreLocation, in this case).  While we still have to run on file systems that don't have subsecond granularity, we unfortunately have to sleep for one second first.  We could probably get around this by artificially setting the modification time to something different than before making the edit.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/SubFrameworkSource.swift")) { contents in
                contents <<< "public import Foundation\nimport CoreLocation\npublic func Bar() -> NSString { return \"Bar\" }"
            }

            // Do another build without changing anything.  It should be a null build.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check that CopySwiftLibs did not ran.  We could assert that nothing ran, but then we'd get noise for any non-null builds that are also covered by other unit tests, so we limit ourselves to making sure that the CopySwiftLibs task in particular did not run.
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("App")) { _ in }
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("SwiftlessSysExApp")) { _ in }
                results.checkNoTask(.matchRuleType("CopySwiftLibs"))
            }
        }
    }

    func runArchSpecificSwiftInterfacesTest(
        archs: [String],
        body: (BuildOperationTester, BuildOperationTester.BuildResults) throws -> Void
    ) async throws {
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "TestProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Info.plist"),
                                TestFile("AppMain.m"),
                                TestFile("FrameworkSource.swift"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": archs.joined(separator: " "),
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "CODE_SIGN_IDENTITY": "Apple Development",
                                    "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                    "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
                                    "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                                    "SDKROOT": "iphoneos",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "INFOPLIST_FILE": "Info.plist",
                                ]
                            )
                        ],
                        targets: [
                            TestAggregateTarget(
                                "All",
                                dependencies: [
                                    "App",
                                ]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    )
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "FrameworkSource.swift"
                                    ]),
                                ]
                            ),
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                        ]
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "AppMain.m"
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Framework.framework"
                                    ]),
                                ],
                                dependencies: ["Framework"]
                            )
                        ]
                    )
                ])

            // Create a tester for driving the build.
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            // Write the source files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/AppMain.m")) { contents in
                contents <<< "#import <Framework/Framework-Swift.h>\n"
                contents <<< "int main() {\n"
                contents <<< "#if __arm64e__\n"
                contents <<< "    [Foo do_64e];\n"
                contents <<< "#elif __arm64__\n"
                contents <<< "    [Foo do_64];\n"
                contents <<< "#endif\n"
                contents <<< "    return 0;\n"
                contents <<< "}\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/FrameworkSource.swift")) { contents in
                contents <<< "public import Foundation\n"
                contents <<< "@objc public class Foo: NSObject {\n"
                contents <<< "#if _ptrauth(_arm64e)\n"
                contents <<< "    @objc public static func do_64e() { }\n"
                contents <<< "#endif\n"
                contents <<< "#if arch(arm64)\n"
                contents <<< "    @objc public static func do_64() { }\n"
                contents <<< "#endif\n"
                contents <<< "}\n"
            }

            // Write a barebones Info.plist file.
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Entitlements.plist"), .plDict([:]))

            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyiOSDevice, persistent: true) { results in
                try body(tester, results)
            }
        }
    }

    /// Test that exposing different APIs per-architecture in Swift is consumable from Objective-C.
    @Test(.requireSDKs(.iOS))
    func archSpecificSwiftInterfaces() async throws {
        let archs = ["arm64", "arm64e"]
        try await runArchSpecificSwiftInterfacesTest(archs: archs) { (tester, results) in
            let srcroot = tester.workspace.projects[0].sourceRoot
            results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders")) { task in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { tasks in }
            for arch in archs {
                results.checkTask(.matchRule(["WriteAuxiliaryFile", srcroot.join("build/TestProject.build/Debug-iphoneos/Framework.build/Objects-normal/\(arch)/Framework.SwiftFileList").str])) { task in }
            }
            // Swift does provide a condition to distinguish between arm64 and arm64e, but it is considered private and could disappear at any time, so we'll need to think of something.
            results.checkNoErrors()
            results.checkNoWarnings()
            #expect(tester.fs.exists(srcroot.join("build/Debug-iphoneos/App.app/App")))
            results.checkNoDiagnostics()
        }
    }

    /// Test architecture fallback for Swift-generated Objective-C header.
    @Test(.requireSDKs(.iOS))
    func swiftArchitectureFallbackInGeneratedHeader() async throws {
        try await runArchSpecificSwiftInterfacesTest(archs: ["arm64e"]) { (tester, results) in
            try results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders")) { task in
                let contents = try tester.fs.read(Path(task.ruleInfo[1])).asString

                // Ensure that the arm64e content is also available via arm64
                XCTAssertMatch(contents, .contains("#elif defined(__arm64__) && __arm64__"))
            }
        }
    }

    /// Check that external targets work.
    @Test(.requireSDKs(.macOS))
    func externalTargetBuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let projectName = "aProject"
            let dstroot = tmpDirPath.join(projectName + ".dst").str
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        projectName,
                        groupTree: TestGroup("Sources"),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "DSTROOT": dstroot
                            ])
                        ],
                        targets: [
                            TestExternalTarget("mock", toolPath: "echo", arguments: "TARGET = $(TARGET_NAME) $(ALL_SETTINGS)")
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let srcroot = testWorkspace.sourceRoot.join(projectName).str
            let buildDir = testWorkspace.sourceRoot.join("\(projectName)/build").str

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["TEST_ME": "hi", "EVIL": "this seems like a good value ;)"]), runDestination: .macOS, persistent: true) { results in
                // We expect one task with one line of output.
                results.checkTask(.matchRuleType("ExternalBuildToolExecution")) { task in
                    results.checkTaskOutput(task) { output in
                        #expect(output.unsafeStringValue == "TARGET = mock DSTROOT=\(dstroot) EVIL=this\\ seems\\ like\\ a\\ good\\ value\\ \\;\\) OBJROOT=\(buildDir) SRCROOT=\(srcroot) SYMROOT=\(buildDir) TEST_ME=hi\n")
                    }
                }

                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask()
            }

            // Should have run again
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDKROOT": "macosx"]), runDestination: .macOS, persistent: true) { results in
                // We expect one task with one line of output.
                results.checkTask(.matchRuleType("ExternalBuildToolExecution")) { task in
                    results.checkTaskOutput(task) { output in
                        XCTAssertMatch(output.unsafeStringValue, .contains("TARGET = mock DSTROOT=\(dstroot) OBJROOT=\(buildDir) "))
                        XCTAssertMatch(output.unsafeStringValue, .contains("SDKROOT="))
                        XCTAssertMatch(output.unsafeStringValue, .contains("SRCROOT=\(srcroot) SYMROOT=\(buildDir)\n"))
                    }
                }

                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask()
            }
        }
    }

    /// Check that PCH file dependencies are respected.
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func prefixHeaderDependencies() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("Prefix.h"),
                            TestFile("lib.c"),
                            TestFile("main.c")
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "GCC_PREFIX_HEADER": "Sources/Prefix.h",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                "INDEX_ENABLE_DATA_STORE": "YES",
                                "COMPILER_INDEX_STORE_ENABLE": "YES",
                                "CLANG_INDEX_STORE_PATH": "\(tmpDirPath.str)/something"
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.c"]),
                                ],
                                dependencies: ["Library"]),
                            TestStandardTarget(
                                "Library", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["lib.c"]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/Prefix.h")) { stream in
                stream <<< "#include <stdio.h>\n"
                stream <<< "#include \"LocalFile.h\"\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/LocalFile.h")) { stream in
                stream <<< "#define SOME_DEFINE 22\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/lib.c")) { stream in
                stream <<< "int l1 = SOME_DEFINE;\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "void *x1 = (void*) printf;\n"
                stream <<< "int x2 = SOME_DEFINE;\n"
            }

            // FIXME: Note that we're not yet getting precompiled-header sharing, so we end up with two `ProcessPCH` tasks for now.
            let excludedTypes = Set(["Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "RegisterExecutionPolicyException", "ClangStatCache"])
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)

                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("ProcessPCH")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("Libtool")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkNoTask()
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(runDestination: .host, persistent: true, excludedTasks: ["ClangStatCache"])

            // Modify the local header and rebuild.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Sources/LocalFile.h")) { stream in
                stream <<< "#define SOME_DEFINE 20022\n"
            }
            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)

                results.checkTasks(.matchRuleType("CompileC")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("ProcessPCH")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("Libtool")) { tasks in
                    withKnownIssue("Sometimes the task count is 1", isIntermittent: true) {
                        #expect(tasks.count == 2)
                    }
                }

                results.checkNoTask()
            }
        }
    }


    /// Check that we don't have an explicit dependency on build-context dependent headermap or VFS contents.
    ///
    /// While this is a build consistency problem, in practice having this dependency leads to rebuilds on situations which are very important (such as switching schemes in Xcode).
    @Test(.requireSDKs(.macOS))
    func buildContextDependentHeadermapNonDependency() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let mainTarget = TestStandardTarget(
                "MainTarget", type: .framework,
                buildConfigurations: [TestBuildConfiguration("Debug")],
                buildPhases: [
                    TestSourcesBuildPhase(["MainTarget.c"]),
                ])
            let otherTarget = TestStandardTarget(
                "OtherTarget", type: .framework,
                buildConfigurations: [TestBuildConfiguration(
                    "Debug")],
                buildPhases: [
                    TestSourcesBuildPhase(["OtherTarget.c"]),
                    TestHeadersBuildPhase(["OtherTarget.h"])
                ])
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("MainTarget.c"),
                            TestFile("OtherTarget.c"),
                            TestFile("OtherTarget.h")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                            ]
                        )],
                        targets: [mainTarget, otherTarget])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the test files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/MainTarget.c")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/OtherTarget.c")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/OtherTarget.h")) { _ in }

            // Build the main target by itself.
            let excludedTypes = Set(["Gate", "WriteAuxiliaryFile", "SymLink", "MkDir", "Touch", "Copy", "CpHeader", "CreateBuildDirectory", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "ClangStatCache", "ProcessSDKImports"])
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug")
                let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.target(for: mainTarget.guid)!)]
                let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

                try await tester.checkBuild(runDestination: .macOS, buildRequest: request, persistent: true) { results in
                    results.consumeTasksMatchingRuleTypes(excludedTypes)
                    results.checkTask(.matchRuleType("ScanDependencies")) { _ in }
                    results.checkTask(.matchRuleType("CompileC")) { _ in }
                    results.checkTask(.matchRuleType("Ld")) { _ in }
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoTask()
                }

                // Check that we get a null build.
                try await tester.checkNullBuild(runDestination: .macOS, buildRequest: request, persistent: true, excludedTasks: ["ClangStatCache"])
            }

            // Build both targets together.
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug")
                let buildTargets = [
                    BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.target(for: mainTarget.guid)!),
                    BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.target(for: otherTarget.guid)!),
                ]
                let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

                // We should only get two interesting compilation tasks, for the new target.
                try await tester.checkBuild(runDestination: .macOS, buildRequest: request, persistent: true) { results in
                    results.consumeTasksMatchingRuleTypes(excludedTypes)
                    results.checkTask(.matchRuleType("ScanDependencies")) { _ in }
                    results.checkTask(.matchRuleType("CompileC")) { _ in }
                    results.checkTask(.matchRuleType("Ld")) { _ in }
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoTask()
                }

                // Check that we get a null build.
                try await tester.checkNullBuild(runDestination: .macOS, buildRequest: request, persistent: true, excludedTasks: ["ClangStatCache"])
            }
        }
    }

    /// <rdar://problem/31581269> Unexpected cycle building empty target with code signing
    @Test(.requireSDKs(.macOS))
    func codeSignCycleInEmptyTarget() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .commandLineTool,
                                buildPhases: [
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: ["Tool"], signableTargetInputs: ["Tool": ProvisioningTaskInputs(identityHash: "-", identityName: "-", signedEntitlements: .plDict(["com.apple.security.get-task-allow": .plBool(true)]))]) { results in
                results.consumeTasksMatchingRuleTypes(["Gate", "WriteAuxiliaryFile", "CreateBuildDirectory"])
                results.checkNoTask()

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func codeSignCycleWithInstallAPI() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("main.c")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "EXECUTABLE_EXTENSION": "dylib",
                                "EXECUTABLE_PREFIX": "lib",
                                "CODE_SIGN_IDENTITY": "-",
                                "CODE_SIGNING_ALLOWED": "YES",
                                "LD_DYLIB_INSTALL_NAME": "@rpath/libTool.dylib",
                                "MACH_O_TYPE": "mh_dylib",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SUPPORTS_TEXT_BASED_API": "YES",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.c"])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c"), body: { $0 <<< "" })

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: ["Tool"], signableTargetInputs: ["Tool": ProvisioningTaskInputs(identityHash: "-", identityName: "-", signedEntitlements: .plDict(["com.apple.security.get-task-allow": .plBool(true)]))]) { results in
                results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` runs when doing a test build after a normal build for macOS since it needs to embed additional content in the entitlements file.
    @Test(.requireSDKs(.macOS), .bug("rdar://48903372"), .disabled("llbuild needs to consult Swift Build for the rule signature on each build"))
    func macOSTestingEntitlements() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                // App sources
                                TestFile("main.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INFOPLIST_FILE": "Info.plist",
                                "CODE_SIGN_IDENTITY": "-",
                                "SDKROOT": "macosx"
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.c",
                                    ]),
                                    TestFrameworksBuildPhase([
                                    ]),
                                ]
                            )]
                    )
                ]
            )
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main(){}"
            }

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict([:]))

            // Perform the initial for-launch build.
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let entitlements: PropertyListItem = [
                "com.apple.security.app-sandbox": 1,
                "com.apple.security.files.user-selected.read-only": 1,
            ]
            let provisioningInputs = ["App": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: entitlements, simulatedEntitlements: [:])]
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                // Make sure that the entitlements processing task ran.
                results.checkTask(.matchRuleType("ProcessProductPackaging")) { _ in }

                results.checkNoDiagnostics()
            }

            // Now perform the for-test build.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, schemeCommand: .test, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                // Make sure that the entitlements processing task ran again.
                results.checkTask(.matchRuleType("ProcessProductPackaging")) { _ in }

                // Make sure that the signing task ran again.
                results.checkTask(.matchRuleType("CodeSign")) { _ in }

                // Only 2 tasks should have run.
                results.checkNoTask()

                results.checkNoDiagnostics()
            }
        }
    }

    /// Check that Yacc projects which require a rename build correctly.
    @Test(.requireSDKs(.macOS))
    func yaccRenaming() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("yacc.ym"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)"])],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "yacc.ym",
                                    ])])])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/yacc.ym")) { stream in
                stream <<<
                """
                %{
                int yylex(void);
                void yyerror(const char *s);
                %}
                %%
                null : ;
                """
            }

            // Perform the initial for-launch build.
            let excludedTypes = Set(["Gate", "WriteAuxiliaryFile", "SymLink", "MkDir", "Touch", "Copy", "CreateBuildDirectory", "RegisterExecutionPolicyException", "ClangStatCache"])
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()

                results.consumeTasksMatchingRuleTypes(excludedTypes)
                results.checkTask(.matchRuleType("Yacc")) { _ in }
                results.checkTask(.matchRuleType("Rename")) { _ in }
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkTask(.matchRuleType("Libtool")) { _ in }
                results.checkNoTask()
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])
        }
    }

    // FIXME: Right now this test doesn't seem very useful: rdar://92483952 (Figure out what to do about virtual subtasks from the integrated driver frontend in BuildOperationTests)
    //
    /// Check that subtask spawned by the Swift compiler report their progress.
    @Test(.requireSDKs(.macOS))
    func swiftSubtaskReporting() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                                TestFile("file3.swift"),
                                TestFile("file4.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Dep",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                        "file3.swift",
                                        "file4.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            for i in (1...4) {
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/file\(i).swift")) { _ in }
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Integrated Swift driver doesn't record jobs as subtasks.
                results.check(notContains: .subtaskDidReportProgress(.scanning, count: 4))
                results.check(notContains: .subtaskDidReportProgress(.started, count: 1))
                results.check(notContains: .subtaskDidReportProgress(.finished, count: 1))
                results.check(notContains: .subtaskDidReportProgress(.upToDate, count: 1))
            }

            // Test that incremental building reports upToDate progress events.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) {
                $0 <<< "func foo() {}"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Integrated Swift driver doesn't show jobs as subtasks
                results.check(notContains: .subtaskDidReportProgress(.scanning, count: 4))
                results.check(notContains: .subtaskDidReportProgress(.upToDate, count: 1))
            }

            // We expect there will be only one subtask reported for the entire module when using WMO.
            let parameters = BuildParameters(configuration: "Debug", overrides: [
                "SWIFT_WHOLE_MODULE_OPTIMIZATION": "true",
            ])
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Integrated Swift driver doesn't record jobs as subtasks.
                results.check(notContains: .subtaskDidReportProgress(.scanning, count: 1))
                results.check(notContains: .subtaskDidReportProgress(.started, count: 1))
                results.check(notContains: .subtaskDidReportProgress(.finished, count: 1))
                results.check(notContains: .subtaskDidReportProgress(.upToDate, count: 1))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func progressReportingWithCachedBuildSystem() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Dep",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file.swift"
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            // Ensure build system caching is enabled.
            tester.userPreferences = tester.userPreferences.with(enableBuildSystemCaching: true)

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write an initial version of the source with an error so the build fails.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file.swift")) { stream in
                stream.write("let y = \"missing delimiter")
            }

            // Build the project and verify that it fails. Record the highest maximum task count reported during the build.
            var build1HighestMaxTaskCount: Int?
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                if !SWBFeatureFlag.performOwnershipAnalysis.value {
                    for _ in 0..<4 {
                        results.checkError(.contains("No such file or directory (2) (for task: [\"Copy\""))
                    }
                }
                results.checkError(.contains("unterminated string literal"))
                results.checkNoDiagnostics()

                build1HighestMaxTaskCount = results.events.compactMap {
                    guard case .totalProgressChanged(targetName: _, startedCount: _, maxCount: let maxCount) = $0 else {
                        return nil
                    }
                    return maxCount
                }.max()
            }

            // Write a fixed version of the source.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file.swift")) { stream in
                stream.write("let y = \"fixed\"")
            }

            // Check that a second build succeeds and record the highest maximum task count recorded.
            var build2HighestMaxTaskCount: Int?
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()

                build2HighestMaxTaskCount = results.events.compactMap {
                    guard case .totalProgressChanged(targetName: _, startedCount: _, maxCount: let maxCount) = $0 else {
                        return nil
                    }
                    return maxCount
                }.max()
            }

            #expect(try #require(build2HighestMaxTaskCount) <= #require(build1HighestMaxTaskCount),
                          "Using a cached build system, the second build reported a higher max task count (\(String(describing: build2HighestMaxTaskCount))) compared to the initial failing build (\(String(describing: build1HighestMaxTaskCount)))!")
        }
    }
    /// Check that TBD files can be generated and signed, end-to-end, for both Objective-C and Swift.
    func checkTBDSigning(useStubify: Bool, productType: TestStandardTarget.TargetType, buildVariants: [String] = ["normal"]) async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let useFramework = productType == .framework || productType == .staticFramework
            let target = try await TestStandardTarget(
                "Core", type: productType,
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "INFOPLIST_FILE": useFramework ? "Info.plist" : "",
                        "SUPPORTS_TEXT_BASED_API": useStubify ? "NO" : "YES",
                        "GENERATE_TEXT_BASED_STUBS": useStubify ? "YES" : "NO",
                        "CODE_SIGN_IDENTITY": "-",
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "TAPI_EXEC": tapiToolPath.str,
                        "BUILD_VARIANTS": buildVariants.joined(separator: " "),
                    ])],
                buildPhases: [
                    TestSourcesBuildPhase(["Core.c"]),
                    TestHeadersBuildPhase(["Core.h"])
                ])
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup("Sources", children: [
                    TestFile("Core.c"),
                    TestFile("Core.h")]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CLANG_ENABLE_MODULES": "YES",
                    ]
                )],
                targets: [target])
            let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the test files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Core.c")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Core.h")) { _ in }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")]))

            // Configure the provisioning inputs.
            let entitlements: PropertyListItem = [
                "com.apple.security.app-sandbox": 1,
                "com.apple.security.files.user-selected.read-only": 1,
            ]
            let provisioningInputs = ["Core": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: entitlements, simulatedEntitlements: [:])]
            let excludedTypes = Set(["Gate", "WriteAuxiliaryFile", "SymLink", "MkDir", "Touch", "Copy", "CreateBuildDirectory", "ProcessInfoPlistFile", "ClangStatCache", "ProcessSDKImports"])
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTypes)

                if productType == .framework || productType == .dynamicLibrary {
                    results.checkTask(.matchRuleType("ProcessProductPackaging")) { _ in }
                    results.checkTask(.matchRuleType("ProcessProductPackagingDER")) { _ in }

                    results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                        #expect(tasks.count == buildVariants.count)
                    }

                    results.checkTasks(.matchRuleType("CompileC")) { tasks in
                        #expect(tasks.count == buildVariants.count)
                    }

                    results.checkTasks(.matchRuleType("Ld")) { tasks in
                        #expect(tasks.count == buildVariants.count)
                    }

                    results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                        #expect(tasks.count == buildVariants.count)
                    }

                    results.checkTasks(.matchRuleType("CodeSign")) { tasks in
                        #expect(tasks.count == 2 * buildVariants.count)
                    }

                    results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { tasks in
                        #expect(tasks.count == (useFramework ? 1 : buildVariants.count))
                    }
                } else {
                    results.checkTasks(.matchRuleType("ScanDependencies")) { tasks in
                        #expect(tasks.count == buildVariants.count)
                    }

                    results.checkTasks(.matchRuleType("CompileC")) { tasks in
                        #expect(tasks.count == buildVariants.count)
                    }

                    results.checkTasks(.matchRuleType("Libtool")) { tasks in
                        #expect(tasks.count == buildVariants.count)
                    }

                    if productType == .staticFramework {
                        results.checkTask(.matchRuleType("ProcessProductPackaging")) { _ in }
                        results.checkTask(.matchRuleType("ProcessProductPackagingDER")) { _ in }

                        results.checkTasks(.matchRuleType("CodeSign")) { tasks in
                            #expect(tasks.count == buildVariants.count)
                        }
                    }
                }

                results.checkNoTask()
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs, excludedTasks: ["ClangStatCache"])
        }
    }

    @Test(.requireSDKs(.macOS), .requireXcode16())
    func frameworkInstallAPITBDSigning() async throws {
        try await checkTBDSigning(useStubify: false, productType: .framework)
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func frameworkInstallAPITBDSigningWithBuildVariants() async throws {
        // FIXME: <rdar://problem/42261905> We should do this at the task construction tests layer, once we have good automatic cycle detection there.
        try await checkTBDSigning(useStubify: false, productType: .framework, buildVariants: ["normal", "profile"])
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func frameworkStubifyTBDSigning() async throws {
        try await checkTBDSigning(useStubify: true, productType: .framework)
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func staticFrameworkInstallAPITBDSigning() async throws {
        try await checkTBDSigning(useStubify: false, productType: .staticFramework)
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func staticFrameworkInstallAPITBDSigningWithBuildVariants() async throws {
        try await checkTBDSigning(useStubify: false, productType: .staticFramework, buildVariants: ["normal", "profile"])
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func staticFrameworkStubifyTBDSigning() async throws {
        try await checkTBDSigning(useStubify: true, productType: .staticFramework)
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func dylibInstallAPITBDSigning() async throws {
        try await checkTBDSigning(useStubify: false, productType: .dynamicLibrary)
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func dylibInstallAPITBDSigningWithBuildVariants() async throws {
        try await checkTBDSigning(useStubify: false, productType: .dynamicLibrary, buildVariants: ["normal", "profile"])
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func dylibStubifyTBDSigning() async throws {
        try await checkTBDSigning(useStubify: true, productType: .dynamicLibrary)
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func staticlibInstallAPITBDSigning() async throws {
        try await checkTBDSigning(useStubify: false, productType: .staticLibrary)
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func staticlibInstallAPITBDSigningWithBuildVariants() async throws {
        try await checkTBDSigning(useStubify: false, productType: .staticLibrary, buildVariants: ["normal", "profile"])
    }
    @Test(.requireSDKs(.macOS), .requireXcode16())
    func staticlibStubifyTBDSigning() async throws {
        try await checkTBDSigning(useStubify: true, productType: .staticLibrary)
    }

    @Test(.requireSDKs(.macOS), .requireXcode16())
    func incrementalFwkTAPI() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let target = TestStandardTarget(
                "Core", type: .framework,
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "DEFINES_MODULE": "YES",
                        "SUPPORTS_TEXT_BASED_API": "YES",
                    ])],
                buildPhases: [
                    TestSourcesBuildPhase(["Core.c"]),
                    TestHeadersBuildPhase([TestBuildFile("Core.h", headerVisibility: .public)]),
                ])
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup("Sources", children: [
                    TestFile("Core.c"),
                    TestFile("Core.h")]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CLANG_ENABLE_MODULES": "YES",
                    ]
                )],
                targets: [target])
            let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the test files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Core.c")) {
                $0 <<< "void func() {}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Core.h")) {
                $0 <<< "void func(void);"
            }

            // First build should contain TAPI task.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
            }

            // Mutate a file and check that TAPI task runs again.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Core.c")) {
                $0 <<< "void func() {} // does nothing"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
            }

            // This should be a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])
        }
    }

    @Test(.requireSDKs(.macOS))
    func compileMissingInputs() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("File.c"),
                            TestFile("File.swift"),
                            TestFile("File.m"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                            "SWIFT_VERSION": swiftVersion])],
                        targets: [
                            TestStandardTarget(
                                "aFramework", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["File.c", "File.swift", "File.m"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            let cFile = testWorkspace.sourceRoot.join("aProject/File.c")
            try await tester.fs.writeFileContents(cFile) { stream in }
            let objcFile = testWorkspace.sourceRoot.join("aProject/File.m")
            try await tester.fs.writeFileContents(objcFile) { stream in }


            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                for ruleType in ["SwiftDriver Compilation Requirements", "SwiftDriver Compilation"] {
                    results.checkError("Build input file cannot be found: \'\(tmpDirPath.str)/Test/aProject/File.swift\'. Did you forget to declare this file as an output of a script phase or custom build rule which produces it? (for task: [\"\(ruleType)\", \"aFramework\", \"normal\", \"x86_64\", \"com.apple.xcode.tools.swift.compiler\"])")
                }
                if !SWBFeatureFlag.performOwnershipAnalysis.value {
                    for fname in ["aFramework.swiftmodule", "aFramework.swiftdoc", "aFramework.swiftsourceinfo", "aFramework.abi.json"] {
                        results.checkError(.contains("\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/aFramework.build/Objects-normal/x86_64/\(fname)): No such file or directory (2)"))
                    }
                }
                results.checkError("Build input file cannot be found: \'\(tmpDirPath.str)/Test/aProject/File.swift\'. Did you forget to declare this file as an output of a script phase or custom build rule which produces it? (for task: [\"ExtractAppIntentsMetadata\"])")
                results.checkNoDiagnostics()
            }
        }
    }

    // Tests that when installing, we end up setting the correct library in the dependencies of the link action.
    // rdar://58021911 for more info.
    @Test(.requireSDKs(.macOS))
    func linkingAgainstSymlinks() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let SRCROOT = tmpDirPath.join("Test")

            let testProject = TestProject(
                "aProject",
                sourceRoot: SRCROOT,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("shared.c"),
                        TestFile("main.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "DEBUG_INFORMATION_FORMAT": "dwarf",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "DSTROOT": "$(SRCROOT)/installable",
                        // Disable the SetOwnerAndGroup action by setting them to empty values.
                        "INSTALL_GROUP": "",
                        "INSTALL_OWNER": "",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.c"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("Shared"))]),
                        ],
                        dependencies: ["Shared"]
                    ),
                    TestStandardTarget(
                        "Shared",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["shared.c"]),
                        ]
                    ),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let mainFile = SRCROOT.join("main.c")
            let sharedFile = SRCROOT.join("shared.c")

            try tester.fs.createDirectory(SRCROOT)
            try tester.fs.write(sharedFile, contents: "int shared = 1;")
            try tester.fs.write(mainFile, contents: "int main() { return 0; }")

            try await tester.checkBuild(parameters: BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, persistent: true) { _ in }

            let ldDepsPath = SRCROOT.join(
                "build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/Tool_dependency_info.dat"
            )

            let dependencyInfo: DependencyInfo = try DependencyInfo(bytes: tester.fs.read(ldDepsPath).bytes)

            let linkedLibrary = SRCROOT.join("installable/usr/local/lib/libShared.a")
            let symlinkLibrary = SRCROOT.join("build/Debug/libShared.a")

            var destinationExists = false
            #expect(tester.fs.isSymlink(symlinkLibrary, &destinationExists))
            #expect(destinationExists)
            #expect(!tester.fs.isSymlink(linkedLibrary, &destinationExists))

            #expect(linkedLibrary != symlinkLibrary)
            #expect(try linkedLibrary == tester.fs.realpath(symlinkLibrary))

            XCTAssertMatch(dependencyInfo.inputs, [.contains(linkedLibrary.str)])
            XCTAssertMatch(dependencyInfo.inputs, [.contains(symlinkLibrary.str)])
        }
    }

    @Test(.requireSDKs(.macOS))
    func copyXCAppExtensionPointsFile() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("myext.xcappextensionpoints")
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)"])],
                targets: [
                    TestStandardTarget(
                        "Foo",
                        type: .application,
                        buildConfigurations: [TestBuildConfiguration("Debug")],
                        buildPhases: [
                            TestResourcesBuildPhase([
                                "myext.xcappextensionpoints",
                            ])
                        ]),
                ]
            )

            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.str
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/myext.xcappextensionpoints")) { stream in
                stream <<< "{ Foo = Bar; }"
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                results.checkNoTask(.matchRuleType("CpResource"))

                results.checkTask(.matchTargetName("Foo"), .matchRule(["CopyAppExtensionPoints", "\(buildDirectory)/aProject/build/Debug/Foo.app/Contents/Extensions/myext.appextensionpoints", "\(SRCROOT)/aProject/myext.xcappextensionpoints"])) { task in
                    task.checkCommandLineMatches(["builtin-copyPlist", "--validate", "--convert", "binary1", "--outdir", "\(buildDirectory)/aProject/build/Debug/Foo.app/Contents/Extensions/", "--outfilename", "myext.appextensionpoints", "--", "\(SRCROOT)/aProject/myext.xcappextensionpoints"])
                }

                try results.checkPropertyListContents(Path("\(buildDirectory)/aProject/build/Debug/Foo.app/Contents/Extensions/myext.appextensionpoints")) { plist in
                    #expect(plist == PropertyListItem.plDict(["Foo": .plString("Bar")]))
                }
            }
        }
    }

    /// Check that various tasks don't get tripped up by multiple architectures or variants.
    /// DTrace, Iig are arch-neutral and variant-neutral.
    /// Mig is arch-specific and variant-specific.
    @Test(.requireSDKs(.macOS), .skipDeveloperDirectoryWithEqualSign)
    func multiArchAndVariantNeutrality() async throws {
        let core = try await getCore()
        let clangCompilerPath = try await self.clangCompilerPath
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("dtrace.d"),
                                TestFile("interface.iig"),
                                TestFile("lex.l"),
                                TestFile("mig.defs"),
                                TestFile("yacc.y"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS": "x86_64 x86_64h",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "BUILD_VARIANTS": "normal debug profile",
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "CLANG_WARN_IMPLICIT_FALLTHROUGH": "NO",
                                "SDK_STAT_CACHE_ENABLE": "NO",
                                "CLANG_USE_RESPONSE_FILE": "NO",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "dtrace.d",
                                        "interface.iig",
                                        "lex.l",
                                        "mig.defs",
                                        "yacc.y",
                                    ])])])
                ])
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/dtrace.d")) { stream in
                stream <<< "provider foo { };"
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/interface.iig")) { stream in
                stream <<< ""
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/lex.l")) { stream in
                stream <<< "%%"
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mig.defs")) { stream in
                stream <<< "subsystem foo 1;"
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/yacc.y")) { stream in
                stream <<<
                """
                %{
                static int yylex() { return 0; }
                static int yyerror(const char *format) { return 0; }
                %}
                %%
                list:
                ;
                %%
                """
            }

            let iigPath = try await self.iigPath
            let migPath = try await self.migPath

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .anyMac, persistent: true) { results in
                results.checkNoWarnings()
                results.checkNoErrors()

                results.checkTask(.matchRule(["Iig", "\(SRCROOT)/aProject/interface.iig"])) { task in
                    let iigDeploymentTargetArgs: [StringPattern] = core.xcodeVersion >= Version(12, 3) ? ["--deployment-target", .equal(core.loadSDK(.macOS).version)] : []
                    task.checkCommandLineMatches([.equal(iigPath.str), "--def", .equal("\(SRCROOT)/aProject/interface.iig"), "--header", .equal("\(SRCROOT)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Tool/interface.h"), "--impl", .equal("\(SRCROOT)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Tool/interface.iig.cpp")] + iigDeploymentTargetArgs + ["--", "-isysroot", .any, "-x", "c++", "-D__IIG=1"])
                }

                for arch in ["x86_64", "x86_64h"] {
                    for variant in ["normal", "debug", "profile"] {
                        let variantSuffix = variant != "normal" ? "-\(variant)" : ""

                        results.checkTask(.matchRule(["Mig", "\(SRCROOT)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources\(variantSuffix)/\(arch)/mig.h", "\(SRCROOT)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources\(variantSuffix)/\(arch)/migUser.c", "\(SRCROOT)/aProject/mig.defs", variant, arch])) { task in
                            task.checkCommandLine([migPath.str, "-arch", arch, "-target", "\(arch)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-header", "\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources\(variantSuffix)/\(arch)/mig.h", "-user", "\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources\(variantSuffix)/\(arch)/migUser.c", "-sheader", Path.null.str, "-server", Path.null.str, "-I\(buildDirectory)/aProject/build/Debug/include", "\(SRCROOT)/aProject/mig.defs"])
                        }

                        results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/Objects-\(variant)/\(arch)/migUser.o", "\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources\(variantSuffix)/\(arch)/migUser.c", variant, arch, "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in
                            let variantSuffix = variant != "normal" ? "-\(variant)" : ""
                            task.checkCommandLineMatches([
                                .equal(clangCompilerPath.str), "-x", "c", "-target", .prefix("\(arch)-apple-macos"), .anySequence,
                                .equal("-I\(buildDirectory)/aProject/build/Debug/include"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources-\(variant)/\(arch)"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/\(arch)"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Tool"),
                                .equal("-F\(buildDirectory)/aProject/build/Debug"),
                                .anySequence,
                                "-c",
                                .equal("\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources\(variantSuffix)/\(arch)/migUser.c"),
                                "-o",
                                .equal("\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/Objects-\(variant)/\(arch)/migUser.o"),
                            ])
                        }

                        results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/Objects-\(variant)/\(arch)/y.tab.o", "\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/y.tab.c", variant, arch, "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in
                            task.checkCommandLineMatches([
                                .equal(clangCompilerPath.str), "-x", "c", "-target", .prefix("\(arch)-apple-macos"), .anySequence,
                                .equal("-I\(buildDirectory)/aProject/build/Debug/include"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources-\(variant)/\(arch)"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/\(arch)"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources"),
                                .equal("-I\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Tool"),
                                .equal("-F\(buildDirectory)/aProject/build/Debug"),
                                .anySequence,
                                "-c",
                                .equal("\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/y.tab.c"),
                                "-o",
                                .equal("\(buildDirectory)/aProject/build/aProject.build/Debug/Tool.build/Objects-\(variant)/\(arch)/y.tab.o"),
                            ])
                        }
                    }
                }
            }
        }
    }

    /// Test that target-level diagnostics are properly restored from serialized build descriptions.
    @Test(.requireSDKs(.macOS))
    func targetDiagnosticsRestoration() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [TestFile("main.c")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS": "",
                                "VALID_ARCHS": "none",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.c"])])])
                ])

            // Disable the memory cache by setting its limit to zero, to make sure we're actually going to reload the build description from disk.
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, buildDescriptionMaxCacheSize: (0, 1))

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkWarning(.equal("There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (none). (in target 'Tool' from project 'aProject')"))
                results.checkNoDiagnostics()
            }

            // Building a second time should have restored the warning from the serialized build description.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkWarning(.equal("There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (none). (in target 'Tool' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func deeplyLinkedStaticLibraryIncrementalBuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("tool.c"),
                                TestFile("lib.c"),
                                TestFile("deeplib.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool.c"]),
                                    TestFrameworksBuildPhase(["libLib.a"]),
                                ],
                                dependencies: ["Lib"]),
                            TestStandardTarget(
                                "Lib",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["lib.c"]),
                                    TestFrameworksBuildPhase(["libDeepLib.a"]),
                                ],
                                dependencies: ["DeepLib"]),
                            TestStandardTarget(
                                "DeepLib",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["deeplib.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/lib.c")) { stream in
                stream <<< "int dalib() { return 1; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/deeplib.c")) { stream in
                stream <<< "int dadeeplib() { return 2; }\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Verify that the .o files are compiled.
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/DeepLib.build/Objects-normal/x86_64/deeplib.o", "\(SRCROOT)/aProject/deeplib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/lib.o", "\(SRCROOT)/aProject/lib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }

                // Verify that the .a files are created.
                results.checkTask(.matchRuleType("Libtool"), .matchRuleItem("\(buildDirectory)/Debug/libDeepLib.a")) { task in
                    task.checkCommandLineContains(["-dependency_info", "\(buildDirectory)/aProject.build/Debug/DeepLib.build/Objects-normal/x86_64/DeepLib_libtool_dependency_info.dat"])
                }
                results.checkTask(.matchRuleType("Libtool"), .matchRuleItem("\(buildDirectory)/Debug/libLib.a")) { task in
                    task.checkCommandLineContains(["-lDeepLib"])
                    task.checkCommandLineContains(["-dependency_info", "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/Lib_libtool_dependency_info.dat"])
                }

                // Verify that everything is linked together properly. Note that the "deep lib" is linked into the static archive above.
                results.checkTask(.matchRuleType("Ld"), .matchRuleItem("\(buildDirectory)/Debug/Tool")) { task in
                    task.checkCommandLineContains(["-lLib"])
                    task.checkCommandLineContains(["-dependency_info", "\(buildDirectory)/aProject.build/Debug/Tool.build/Objects-normal/x86_64/Tool_dependency_info.dat"])
                }

                // Verify that the dependency info indeed has the libraries we expected.
                let actual = try DependencyInfo(bytes: try tester.fs.read(Path("\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/Lib_libtool_dependency_info.dat")).bytes)
                #expect(actual.inputs.sorted() == [
                    "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/lib.o",
                    "\(buildDirectory)/Debug/libDeepLib.a"
                ].sorted())
                #expect(actual.outputs.sorted() == [
                    "\(buildDirectory)/Debug/libLib.a"
                ].sorted())
            }

            // Validate a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])

            // Test that updating lib.c causes the correct recompile.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/lib.c")) { stream in
                stream <<< "int dalib1() { return 11; }\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(["RegisterExecutionPolicyException", "Gate", "ClangStatCache", "ProcessSDKImports"])
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/lib.o", "\(SRCROOT)/aProject/lib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Libtool", "\(buildDirectory)/Debug/libLib.a", "normal"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(buildDirectory)/Debug/Tool", "normal"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating deeplib.c causes the correct recompile.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/deeplib.c")) { stream in
                stream <<< "int dadeeplib1() { return 22; }\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(["RegisterExecutionPolicyException", "Gate", "ClangStatCache", "ProcessSDKImports"])
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/DeepLib.build/Objects-normal/x86_64/deeplib.o", "\(SRCROOT)/aProject/deeplib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Libtool", "\(buildDirectory)/Debug/libDeepLib.a", "normal"])) { _ in }
                results.checkTask(.matchRule(["Libtool", "\(buildDirectory)/Debug/libLib.a", "normal"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(buildDirectory)/Debug/Tool", "normal"])) { _ in }
                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func deeplyLinkedStaticLibraryIncrementalBuildForInstallBuilds() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("tool.c"),
                                TestFile("lib.c"),
                                TestFile("deeplib.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": GetCurrentUserGroupName()!,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["DSTROOT": "$(SRCROOT)/installable"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool.c"]),
                                    TestFrameworksBuildPhase(["libLib.a"]),
                                ],
                                dependencies: ["Lib"]),
                            TestStandardTarget(
                                "Lib",
                                type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SKIP_INSTALL": "YES"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["lib.c"]),
                                    TestFrameworksBuildPhase(["libDeepLib.a"]),
                                ],
                                dependencies: ["DeepLib"]),
                            TestStandardTarget(
                                "DeepLib",
                                type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SKIP_INSTALL": "YES"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["deeplib.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/lib.c")) { stream in
                stream <<< "int dalib() { return 1; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/deeplib.c")) { stream in
                stream <<< "int dadeeplib() { return 2; }\n"
            }

            let excludingTypes: Set<String> = ["SetGroup", "SetMode", "Strip", "RegisterExecutionPolicyException", "Gate", "ClangStatCache", "ProcessSDKImports"]

            let parameters = BuildParameters(action: .install, configuration: "Debug")
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Verify that the .o files are compiled.
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/DeepLib.build/Objects-normal/x86_64/deeplib.o", "\(SRCROOT)/aProject/deeplib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/lib.o", "\(SRCROOT)/aProject/lib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }

                // Verify that the .a files are created.
                results.checkTask(.matchRuleType("Libtool"), .matchRuleItem("\(buildDirectory)/UninstalledProducts/macosx/libDeepLib.a")) { task in
                    task.checkCommandLineContains(["-dependency_info", "\(buildDirectory)/aProject.build/Debug/DeepLib.build/Objects-normal/x86_64/DeepLib_libtool_dependency_info.dat"])
                }
                results.checkTask(.matchRuleType("Libtool"), .matchRuleItem("\(buildDirectory)/UninstalledProducts/macosx/libLib.a")) { task in
                    task.checkCommandLineContains(["-lDeepLib"])
                    task.checkCommandLineContains(["-dependency_info", "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/Lib_libtool_dependency_info.dat"])
                }

                // Verify that everything is linked together properly. Note that the "deep lib" is linked into the static archive above.
                results.checkTask(.matchRuleType("Ld"), .matchRuleItem("\(SRCROOT)/aProject/installable/usr/local/bin/Tool")) { task in
                    task.checkCommandLineContains(["-lLib"])
                    task.checkCommandLineContains(["-dependency_info", "\(buildDirectory)/aProject.build/Debug/Tool.build/Objects-normal/x86_64/Tool_dependency_info.dat"])
                }

                // Verify that the dependency info indeed has the libraries we expected.
                let actual = try DependencyInfo(bytes: try tester.fs.read(Path("\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/Lib_libtool_dependency_info.dat")).bytes)
                #expect(actual.inputs.sorted() == [
                    "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/lib.o",
                    "\(buildDirectory)/UninstalledProducts/macosx/libDeepLib.a",
                    "\(buildDirectory)/Debug/libDeepLib.a",
                ].sorted())
                #expect(actual.outputs.sorted() == [
                    "\(buildDirectory)/UninstalledProducts/macosx/libLib.a"
                ].sorted())
            }

            // Validate a null build.
            try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"])

            // Test that updating lib.c causes the correct recompile.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/lib.c")) { stream in
                stream <<< "int dalib1() { return 11; }\n"
            }
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(excludingTypes)
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Lib.build/Objects-normal/x86_64/lib.o", "\(SRCROOT)/aProject/lib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Libtool", "\(buildDirectory)/UninstalledProducts/macosx/libLib.a", "normal"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(SRCROOT)/aProject/installable/usr/local/bin/Tool", "normal"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating deeplib.c causes the correct recompile.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/deeplib.c")) { stream in
                stream <<< "int dadeeplib1() { return 22; }\n"
            }
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(excludingTypes)
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/DeepLib.build/Objects-normal/x86_64/deeplib.o", "\(SRCROOT)/aProject/deeplib.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Libtool", "\(buildDirectory)/UninstalledProducts/macosx/libDeepLib.a", "normal"])) { _ in }
                results.checkTask(.matchRule(["Libtool", "\(buildDirectory)/UninstalledProducts/macosx/libLib.a", "normal"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(SRCROOT)/aProject/installable/usr/local/bin/Tool", "normal"])) { _ in }
                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func customLocationForBuildDatabase() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [TestFile("main.c")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "BUILD_DESCRIPTION_CACHE_DIR": "\(tmpDirPath.str)/cache"
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.c"])])])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                #expect("\(tmpDirPath.str)/cache/XCBuildData" == results.buildDescription.dir.str)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func customLocationForBuildDatabaseWithinTargets() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("tool1.c"),
                                TestFile("tool2.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool1", type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "BUILD_DESCRIPTION_CACHE_DIR": "\(tmpDirPath.str)/tool1_ignored",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool1.c"])]),
                            TestStandardTarget(
                                "Tool2", type: .staticLibrary,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "BUILD_DESCRIPTION_CACHE_DIR": "\(tmpDirPath.str)/tool2_ignored",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool2.c"])])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool1.c")) { stream in
                stream <<< "int tool1() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool2.c")) { stream in
                stream <<< "int tool2() { return 0; }\n"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                #expect("\(tmpDirPath.str)/Test/aProject/build/XCBuildData" == results.buildDescription.dir.str)
            }

            let parameters = BuildParameters(configuration: "Debug", overrides: [
                "BUILD_DESCRIPTION_CACHE_DIR": "\(tmpDirPath.str)/cache",
            ])
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                #expect("\(tmpDirPath.str)/cache/XCBuildData" == results.buildDescription.dir.str)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalMetalLinkWithCodeSign() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("SwiftFile.swift"),
                            TestFile("Metal.metal"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",
                                            "CODE_SIGN_IDENTITY": "-",
                                            "INFOPLIST_FILE": "Info.plist",
                                            "CODESIGN": "/usr/bin/true",
                                            "SWIFT_VERSION": swiftVersion])],
                        targets: [
                            TestStandardTarget(
                                "aFramework", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["SwiftFile.swift", "Metal.metal"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)
            let signableTargets: Set<String> = ["aFramework"]

            // Create the input files.
            let swiftFile = testWorkspace.sourceRoot.join("aProject/SwiftFile.swift")
            try await tester.fs.writeFileContents(swiftFile) { stream in }
            let metalFile = testWorkspace.sourceRoot.join("aProject/Metal.metal")
            try await tester.fs.writeFileContents(metalFile) { stream in
                stream <<< """
                    float2 shaderPass(float2 const fragCoords) {
                    return fragCoords;
                    }
                    """
            }
            let infoPlistFile = testWorkspace.sourceRoot.join("aProject/Info.plist")
            try await tester.fs.writePlist(infoPlistFile, .plDict([:]))

            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.checkTask(.matchRule(["CompileMetalFile", "\(testWorkspace.sourceRoot.str)/aProject/Metal.metal"])) { _ in }
                results.checkTask(.matchRule(["MetalLink", "\(testWorkspace.sourceRoot.str)/aProject/build/Debug/aFramework.framework/Versions/A/Resources/default.metallib"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(testWorkspace.sourceRoot.str)/aProject/build/Debug/aFramework.framework/Versions/A"])) { _ in }
                results.checkNoDiagnostics()
            }

            // Modify the metal file and ensure that we get codesign to happen.
            try await tester.fs.writeFileContents(metalFile) { stream in
                stream <<< """
                    float2 shaderPass(float2 const fragCoords) {
                    return fragCoords;
                    }

                    float2 shaderPassAnother(float2 const fragCoords) {
                    return fragCoords;
                    }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.checkTask(.matchRule(["CompileMetalFile", "\(testWorkspace.sourceRoot.str)/aProject/Metal.metal"])) { _ in }
                results.checkTask(.matchRule(["MetalLink", "\(testWorkspace.sourceRoot.str)/aProject/build/Debug/aFramework.framework/Versions/A/Resources/default.metallib"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(testWorkspace.sourceRoot.str)/aProject/build/Debug/aFramework.framework/Versions/A"])) { _ in }
                results.checkNoDiagnostics()
            }
        }
    }

    // Regression test for rdar://84617718 - linker dependency info should be tracked as an output so the containing directory is created if needed.
    @Test(.requireSDKs(.macOS))
    func linkerDependencyFileDirectoryCreation() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject("aProject",
                                groupTree: TestGroup("Sources",
                                                     children: [TestFile("main.swift")]),
                                buildConfigurations: [TestBuildConfiguration("Debug",
                                                                             buildSettings: [
                                                                                "CODE_SIGNING_ALLOWED": "NO",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SWIFT_VERSION": swiftVersion,
                                                                                "LD_DEPENDENCY_INFO_FILE": tmpDir.join("foo/bar/baz").str
                                                                             ])],
                                targets: [TestStandardTarget("Tool", type: .commandLineTool,
                                                             buildConfigurations: [TestBuildConfiguration("Debug")],
                                                             buildPhases: [TestSourcesBuildPhase(["main.swift"])])])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)

            // create the files
            let projectDir = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<<
                """
                struct Foo { }
                """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                // We shouldn't see a 'failed to create dependency file' error here.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalCodesignForCopyFileChanges() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("tool.c"),
                                TestFile("other.c"),
                                TestFile("resource.txt"),
                                TestFile("other.txt"),
                                TestFile("nope.txt"),
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
                                "CODESIGN": "/usr/bin/true",

                                // NOTE: THIS IS THE IMPORTANT SETTING! Ensure that opt-in is on, regardless of the default value.
                                "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING": "YES",
                                "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool.c"]),
                                    TestCopyFilesBuildPhase(["resource.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["other.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["nope.txt"], destinationSubfolder: .builtProductsDir, destinationSubpath: "DerivedSources", onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "Run Me", shellPath: "/bin/bash", originalObjectID: "RunMe1", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input1.txt"], outputs: ["$(DERIVED_FILE_DIR)/out1"]),
                                    TestShellScriptBuildPhase(name: "Run Me (Outputs)", shellPath: "/bin/bash", originalObjectID: "RunMe2", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input2.txt"], outputs: ["$(TARGET_BUILD_DIR)/Tool.app/Contents/Resources/out2.txt"]),
                                    TestShellScriptBuildPhase(name: "Run Me (FileList)", shellPath: "/bin/bash", originalObjectID: "RunMe3", contents: #"cat "${SCRIPT_INPUT_FILE_LIST_0}" | xargs cat > "$TARGET_BUILD_DIR/Tool.app/Contents/Resources/out3.txt""#, inputs: [], inputFileLists: ["$(SRCROOT)/in3.xcfilelist"], outputs: [], outputFileLists: ["$(SRCROOT)/out3.xcfilelist"]),
                                    TestCopyFilesBuildPhase([TestBuildFile("Other.framework", codeSignOnCopy: true)], destinationSubfolder: .plugins, onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "Cycle Creator", shellPath: "/bin/bash", originalObjectID: "CycleMe", contents: "mkdir -p $BUILT_PRODUCTS_DIR/Tool.app/Contents/TestDir", inputs: [], outputs: ["$(BUILT_PRODUCTS_DIR)/Tool.app/Contents/TestDir"])
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "Other",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["other.c"])
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.c")) { stream in
                stream <<< "int other() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "hello\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "world\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/nope.txt")) { stream in
                stream <<< "nada\n"
            }

            // For Script Phase: Run Me
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input1.txt")) { stream in
                stream <<< "input file 1\n"
            }

            // For Script Phase: Run Me (Outputs)
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input2.txt")) { stream in
                stream <<< "input file 2\n"
            }

            // For Script Phase: Run Me (FileList)
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input3.txt")) { stream in
                stream <<< "input file 3\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/in3.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/input3.txt\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/out3.xcfilelist")) { stream in
                stream <<< "$(TARGET_BUILD_DIR)/Tool.app/Contents/Resources/out3.txt\n"
            }

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))

            let signableTargets: Set<String> = ["Tool", "Other"]
            let excludedTasks: Set<String> = ["CreateBuildDirectory", "MkDir", "WriteAuxiliaryFile", "ProcessInfoPlistFile", "SymLink", "Validate", "RegisterWithLaunchServices", "Touch", "Gate", "RegisterExecutionPolicyException", "ClangStatCache", "ProcessSDKImports"]

            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Other.build/Objects-normal/x86_64/other.o", "\(SRCROOT)/aProject/other.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Tool.build/Objects-normal/x86_64/tool.o", "\(SRCROOT)/aProject/tool.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(buildDirectory)/Debug/Other.framework/Versions/A/Other", "normal"])) { _ in }
                results.checkTask(.matchRule(["GenerateTAPI", "\(buildDirectory)/EagerLinkingTBDs/Debug/Other.framework/Versions/A/Other.tbd"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(buildDirectory)/Debug/Tool.app/Contents/MacOS/Tool", "normal"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/DerivedSources/nope.txt", "\(SRCROOT)/aProject/nope.txt"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/PlugIns/Other.framework", "\(buildDirectory)/Debug/Other.framework"])) { _ in }
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe1.sh"])) { _ in }
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (Outputs)", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe2.sh"])) { _ in }
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (FileList)", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe3.sh"])) { _ in }
                results.checkTask(.matchRule(["PhaseScriptExecution", "Cycle Creator", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-CycleMe.sh"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app/Contents/PlugIns/Other.framework/Versions/A"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Other.framework/Versions/A"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()

                // NOTE: The "Cycle Creator" script ensures that no additional edges are being added into the copy phases (bug in original implementation). It doesn't actually create a cycle now, but it is an important test to have as it is attempting to create one!

                results.checkNoDiagnostics()
            }

            // Need to re-codesign based on the embed; existing behavior that we should address too.
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { _ in }

            // Validate a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets, excludedTasks: ["ClangStatCache"], diagnosticsToValidate: [.error, .warning])

            // Test updating just one resource file triggers a copy and codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the other resource file also triggers a copy and codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating both resources triggers a copy and only one codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "goodbye.. one last time\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "goodbye.. one last time\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that content going outside of the app wrapper does *not* trigger a codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/nope.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/DerivedSources/nope.txt", "\(SRCROOT)/aProject/nope.txt"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the script that has no output in the wrapper does not trigger codesign
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input1.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe1.sh"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the script that has an output in the wrapper triggers codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input2.txt")) { stream in
                stream <<< "goodbye.. this time I mean it\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (Outputs)", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe2.sh"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the script's xcfilelist file triggers codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input3.txt")) { stream in
                stream <<< "goodbye.. we are over\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (FileList)", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe3.sh"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that changing an embedded framework (but NOT linked!!!) properly causes a codesign to trigger for the app.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.c")) { stream in
                stream <<< "int other() { return 0; }\n"
                stream <<< "int another() { return 0; }\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Other.build/Objects-normal/x86_64/other.o", "\(SRCROOT)/aProject/other.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(buildDirectory)/Debug/Other.framework/Versions/A/Other", "normal"])) { _ in }
                results.checkTask(.matchRule(["GenerateTAPI", "\(buildDirectory)/EagerLinkingTBDs/Debug/Other.framework/Versions/A/Other.tbd"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Other.framework/Versions/A"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/PlugIns/Other.framework", "\(buildDirectory)/Debug/Other.framework"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app/Contents/PlugIns/Other.framework/Versions/A"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func incrementalCodesignForCopyFileChanges_iOS() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
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
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CODE_SIGN_IDENTITY": "Apple Developer",
                                "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                "CODESIGN": "/usr/bin/true",   // Codesign will otherwise fail; the only important part is that the task is run.
                                "INFOPLIST_FILE": "Info.plist",
                                "SDKROOT": "iphoneos",

                                // NOTE: THIS IS THE IMPORTANT SETTING! Ensure that opt-in is on, regardless of the default value.
                                "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING": "YES",
                                "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool.c"]),
                                    TestCopyFilesBuildPhase(["resource.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["other.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["nope.txt"], destinationSubfolder: .builtProductsDir, destinationSubpath: "DerivedSources", onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "Run Me", shellPath: "/bin/bash", originalObjectID: "RunMe1", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input1.txt"], outputs: ["$(DERIVED_FILE_DIR)/out1"]),
                                    TestShellScriptBuildPhase(name: "Run Me (Outputs)", shellPath: "/bin/bash", originalObjectID: "RunMe2", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input2.txt"], outputs: ["$(TARGET_BUILD_DIR)/Tool.app/out2.txt"]),
                                    TestShellScriptBuildPhase(name: "Run Me (FileList)", shellPath: "/bin/bash", originalObjectID: "RunMe3", contents: #"cat "${SCRIPT_INPUT_FILE_LIST_0}" | xargs cat > "$TARGET_BUILD_DIR/Tool.app/out3.txt""#, inputs: [], inputFileLists: ["$(SRCROOT)/in3.xcfilelist"], outputs: [], outputFileLists: ["$(SRCROOT)/out3.xcfilelist"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "hello\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "world\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/nope.txt")) { stream in
                stream <<< "nada\n"
            }

            // For Script Phase: Run Me
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input1.txt")) { stream in
                stream <<< "input file 1\n"
            }

            // For Script Phase: Run Me (Outputs)
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input2.txt")) { stream in
                stream <<< "input file 2\n"
            }

            // For Script Phase: Run Me (FileList)
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input3.txt")) { stream in
                stream <<< "input file 3\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/in3.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/input3.txt\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/out3.xcfilelist")) { stream in
                stream <<< "$(TARGET_BUILD_DIR)/Tool.app/out3.txt\n"
            }

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Entitlements.plist"), .plDict([:]))

            let excludedTasks: Set<String> = ["CreateBuildDirectory", "MkDir", "WriteAuxiliaryFile", "ProcessInfoPlistFile", "Validate", "RegisterWithLaunchServices", "Touch", "Gate", "RegisterExecutionPolicyException", "ClangStatCache", "ProcessSDKImports"]

            let provisioningInputs = [
                "Tool": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["ProcessProductPackaging", "\(SRCROOT)/aProject/Entitlements.plist", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Tool.app.xcent"])) { _ in }
                results.checkTask(.matchRule(["ProcessProductPackagingDER", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Tool.app.xcent", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Tool.app.xcent.der"])) { _ in }
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Objects-normal/arm64/tool.o", "\(SRCROOT)/aProject/tool.c", "normal", "arm64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(buildDirectory)/Debug-iphoneos/Tool.app/Tool", "normal"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/Tool.app/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                results.checkTask(.matchRule(["GenerateDSYMFile", "\(buildDirectory)/Debug-iphoneos/Tool.app.dSYM", "\(buildDirectory)/Debug-iphoneos/Tool.app/Tool"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/Tool.app/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/DerivedSources/nope.txt", "\(SRCROOT)/aProject/nope.txt"])) { _ in }
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Script-RunMe1.sh"])) { _ in }
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (Outputs)", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Script-RunMe2.sh"])) { _ in }
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (FileList)", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Script-RunMe3.sh"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug-iphoneos/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Validate a null build.
            try await tester.checkNullBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs, excludedTasks: ["ClangStatCache"], diagnosticsToValidate: [.error, .warning])

            // Test updating just one resource file triggers a copy and codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/Tool.app/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug-iphoneos/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the other resource file also triggers a copy and codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/Tool.app/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug-iphoneos/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating both resources triggers a copy and only one codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "goodbye.. for the second time\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "goodbye.. for the second time\n"
            }
            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/Tool.app/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/Tool.app/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug-iphoneos/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that content going outside of the app wrapper does *not* trigger a codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/nope.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug-iphoneos/DerivedSources/nope.txt", "\(SRCROOT)/aProject/nope.txt"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the script that has no output in the wrapper does not trigger codesign
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input1.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Script-RunMe1.sh"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the script that has an output in the wrapper triggers codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input2.txt")) { stream in
                stream <<< "goodbye.. yet another time\n"
            }
            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (Outputs)", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Script-RunMe2.sh"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug-iphoneos/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Test that updating the script's xcfilelist file triggers codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input3.txt")) { stream in
                stream <<< "goodbye.. one final time\n"
            }
            try await tester.checkBuild(runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["PhaseScriptExecution", "Run Me (FileList)", "\(buildDirectory)/aProject.build/Debug-iphoneos/Tool.build/Script-RunMe3.sh"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug-iphoneos/Tool.app"])) { _ in }
                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalCodesignForCopyFileChanges_MixedOnOff() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
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
                                TestFile("Info.plist"),

                                // For Script Phase: Run Me
                                TestFile("input1.txt"),

                                // For Script Phase: Run Me (Outputs)
                                TestFile("input2.txt"),

                                // For Script Phase: Run Me (FileLists)
                                TestFile("in3.xcfilelist"),
                                TestFile("out3.xcfilelist"),
                                TestFile("out3_no.xcfilelist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CODE_SIGN_IDENTITY": "-",
                                "INFOPLIST_FILE": "Info.plist",
                            ])],
                        targets: [
                            TestAggregateTarget("All", dependencies: ["Tool", "NoTool"]),
                            TestStandardTarget(
                                "Tool",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug",
                                                           buildSettings: [
                                                            "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING": "YES",
                                                            "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS": "YES",
                                                           ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool.c"]),
                                    TestCopyFilesBuildPhase(["resource.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["other.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["nope.txt"], destinationSubfolder: .builtProductsDir, destinationSubpath: "DerivedSources/Tool", onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "Run Me", shellPath: "/bin/bash", originalObjectID: "RunMe1", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input1.txt"], outputs: ["$(DERIVED_FILE_DIR)/out1"]),
                                    TestShellScriptBuildPhase(name: "Run Me (Outputs)", shellPath: "/bin/bash", originalObjectID: "RunMe2", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input2.txt"], outputs: ["$(TARGET_BUILD_DIR)/Tool.app/Contents/Resources/out2.txt"]),
                                    TestShellScriptBuildPhase(name: "Run Me (FileList)", shellPath: "/bin/bash", originalObjectID: "RunMe3", contents: #"cat "${SCRIPT_INPUT_FILE_LIST_0}" | xargs cat > "$TARGET_BUILD_DIR/Tool.app/Contents/Resources/out3.txt""#, inputs: [], inputFileLists: ["$(SRCROOT)/in3.xcfilelist"], outputs: [], outputFileLists: ["$(SRCROOT)/out3.xcfilelist"]),
                                ]),
                            TestStandardTarget(
                                "NoTool",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug",
                                                           buildSettings: [
                                                            "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING": "NO",
                                                           ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool.c"]),
                                    TestCopyFilesBuildPhase(["resource.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["other.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase(["nope.txt"], destinationSubfolder: .builtProductsDir, destinationSubpath: "DerivedSources/NoTool", onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "Run Me", shellPath: "/bin/bash", originalObjectID: "RunMe1", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input1.txt"], outputs: ["$(DERIVED_FILE_DIR)/out1"]),
                                    TestShellScriptBuildPhase(name: "Run Me (Outputs)", shellPath: "/bin/bash", originalObjectID: "RunMe2", contents: #"cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/input2.txt"], outputs: ["$(TARGET_BUILD_DIR)/NoTool.app/Contents/Resources/out2.txt"]),
                                    TestShellScriptBuildPhase(name: "Run Me (FileList)", shellPath: "/bin/bash", originalObjectID: "RunMe3", contents: #"cat "${SCRIPT_INPUT_FILE_LIST_0}" | xargs cat > "$TARGET_BUILD_DIR/NoTool.app/Contents/Resources/out3.txt""#, inputs: [], inputFileLists: ["$(SRCROOT)/in3.xcfilelist"], outputs: [], outputFileLists: ["$(SRCROOT)/out3_no.xcfilelist"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "hello\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "world\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/nope.txt")) { stream in
                stream <<< "nada\n"
            }

            // For Script Phase: Run Me
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input1.txt")) { stream in
                stream <<< "input file 1\n"
            }

            // For Script Phase: Run Me (Outputs)
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input2.txt")) { stream in
                stream <<< "input file 2\n"
            }

            // For Script Phase: Run Me (FileList)
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input3.txt")) { stream in
                stream <<< "input file 3\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/in3.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/input3.txt\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/out3.xcfilelist")) { stream in
                stream <<< "$(TARGET_BUILD_DIR)/Tool.app/Contents/Resources/out3.txt\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/out3_no.xcfilelist")) { stream in
                stream <<< "$(TARGET_BUILD_DIR)/NoTool.app/Contents/Resources/out3_no.txt\n"
            }

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))

            let excludedTasks: Set<String> = ["CreateBuildDirectory", "MkDir", "WriteAuxiliaryFile", "ProcessInfoPlistFile", "Validate", "RegisterWithLaunchServices", "Touch", "Gate", "RegisterExecutionPolicyException", "ClangStatCache", "ProcessSDKImports"]

            let signableTargets: Set<String> = ["Tool", "NoTool"]

            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // For the first pass, these should be the same for both targets.

                for targetName in signableTargets {
                    results.checkTask(.matchTargetName(targetName), .matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/tool.o", "\(SRCROOT)/aProject/tool.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["Ld", "\(buildDirectory)/Debug/\(targetName).app/Contents/MacOS/\(targetName)", "normal"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["Copy", "\(buildDirectory)/Debug/\(targetName).app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["Copy", "\(buildDirectory)/Debug/\(targetName).app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["Copy", "\(buildDirectory)/Debug/DerivedSources/\(targetName)/nope.txt", "\(SRCROOT)/aProject/nope.txt"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["PhaseScriptExecution", "Run Me", "\(buildDirectory)/aProject.build/Debug/\(targetName).build/Script-RunMe1.sh"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["PhaseScriptExecution", "Run Me (Outputs)", "\(buildDirectory)/aProject.build/Debug/\(targetName).build/Script-RunMe2.sh"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["PhaseScriptExecution", "Run Me (FileList)", "\(buildDirectory)/aProject.build/Debug/\(targetName).build/Script-RunMe3.sh"])) { _ in }
                    results.checkTask(.matchTargetName(targetName), .matchRule(["CodeSign", "\(buildDirectory)/Debug/\(targetName).app"])) { _ in }
                }

                results.checkNoTask()
            }

            // Validate a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets, excludedTasks: ["ClangStatCache"], diagnosticsToValidate: [.error, .warning])

            // Test updating just one resource file triggers a copy and codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = YES
                do {
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                }

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = NO
                do {
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["Copy", "\(buildDirectory)/Debug/NoTool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }

                    // No codesign expected here due ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING=NO.
                    results.checkNoTask(.matchTargetName("NoTool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"]))
                }

                results.checkNoTask()
            }

            // Test that updating the other resource file also triggers a copy and codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = YES
                do {
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                }

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = NO
                do {
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["Copy", "\(buildDirectory)/Debug/NoTool.app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }

                    // No codesign expected here due ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING=NO.
                    results.checkNoTask(.matchTargetName("NoTool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"]))
                }

                results.checkNoTask()
            }

            // Test that updating both resources triggers a copy and only one codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "goodbye.. i don't want to see you again'\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "goodbye.. i don't want to see you again'\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = YES
                do {
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                }

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = NO
                do {
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["Copy", "\(buildDirectory)/Debug/NoTool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["Copy", "\(buildDirectory)/Debug/NoTool.app/Contents/Resources/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }

                    // No codesign expected here due ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING=NO.
                    results.checkNoTask(.matchTargetName("NoTool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"]))
                }

                results.checkNoTask()
            }

            // Test that content going outside of the app wrapper does *not* trigger a codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/nope.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = YES
                do {
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["Copy", "\(buildDirectory)/Debug/DerivedSources/Tool/nope.txt", "\(SRCROOT)/aProject/nope.txt"])) { _ in }
                }

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = NO
                do {
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["Copy", "\(buildDirectory)/Debug/DerivedSources/NoTool/nope.txt", "\(SRCROOT)/aProject/nope.txt"])) { _ in }
                }

                results.checkNoTask()
            }

            // Test that updating the script that has no output in the wrapper does not trigger codesign
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input1.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = YES
                do {
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["PhaseScriptExecution", "Run Me", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe1.sh"])) { _ in }
                }

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = NO
                do {
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["PhaseScriptExecution", "Run Me", "\(buildDirectory)/aProject.build/Debug/NoTool.build/Script-RunMe1.sh"])) { _ in }
                }

                results.checkNoTask()
            }

            // Test that updating the script that has an output in the wrapper triggers codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input2.txt")) { stream in
                stream <<< "goodbye.. one last time\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = YES
                do {
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["PhaseScriptExecution", "Run Me (Outputs)", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe2.sh"])) { _ in }
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                }

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = NO
                do {
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["PhaseScriptExecution", "Run Me (Outputs)", "\(buildDirectory)/aProject.build/Debug/NoTool.build/Script-RunMe2.sh"])) { _ in }

                    // No codesign expected here due ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING=NO.
                    results.checkNoTask(.matchTargetName("NoTool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"]))
                }

                results.checkNoTask()
            }

            // Test that updating the script's xcfilelist file triggers codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/input3.txt")) { stream in
                stream <<< "goodbye.. i'm over this\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = YES
                do {
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["PhaseScriptExecution", "Run Me (FileList)", "\(buildDirectory)/aProject.build/Debug/Tool.build/Script-RunMe3.sh"])) { _ in }
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                }

                // When ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = NO
                do {
                    results.checkTask(.matchTargetName("NoTool"), .matchRule(["PhaseScriptExecution", "Run Me (FileList)", "\(buildDirectory)/aProject.build/Debug/NoTool.build/Script-RunMe3.sh"])) { _ in }

                    // No codesign expected here due ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING=NO.
                    results.checkNoTask(.matchTargetName("NoTool"), .matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"]))
                }

                results.checkNoTask()
            }
        }
    }

    func disabled_testPseudoEmbeddingOfContentFromAnotherTarget() async throws {
        // This test needs directory tree signatures as another target is invalidating a different target with a copy phase. We could potentially track this for all known targets, but that gets pretty ugly.
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("tool.c"),
                                TestFile("resource.txt"),
                                TestFile("other.txt"),
                                TestFile("Info.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CODE_SIGN_IDENTITY": "-",
                                "INFOPLIST_FILE": "Info.plist",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "Embed",
                                buildPhases: [
                                    TestCopyFilesBuildPhase(["other.txt"], destinationSubfolder: .builtProductsDir, destinationSubpath: "Tool.app/Contents", onlyForDeployment: false),
                                ],
                                dependencies: ["Tool"]),
                            TestStandardTarget(
                                "Tool",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase(["tool.c"]),
                                    TestCopyFilesBuildPhase(["resource.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.c")) { stream in
                stream <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/resource.txt")) { stream in
                stream <<< "hello\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "friend\n"
            }

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))

            let excludedTasks: Set<String> = ["CreateBuildDirectory", "MkDir", "WriteAuxiliaryFile", "ProcessInfoPlistFile", "Validate", "RegisterWithLaunchServices", "Touch", "Gate", "RegisterExecutionPolicyException"]

            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: ["Tool"]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/Tool.build/Objects-normal/x86_64/tool.o", "\(SRCROOT)/aProject/tool.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["Ld", "\(buildDirectory)/Debug/Tool.app/Contents/MacOS/Tool", "normal", "x86_64"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/Resources/resource.txt", "\(SRCROOT)/aProject/resource.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }

            // Validate a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, signableTargets: ["Tool"])

            // Update other.txt and ensure that it's copied.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.txt")) { stream in
                stream <<< "friend\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true, signableTargets: ["Tool"]) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)
                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/Tool.app/Contents/other.txt", "\(SRCROOT)/aProject/other.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/Tool.app"])) { _ in }
                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func pointerAuthenticationBuildSetting() async throws {
        func test(buildSettings: [String: String], expectedArchs: [String], line: UInt = #line) async throws {

            try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                let testWorkspace = try await TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup("Sources", children: [
                                TestFile("File.c"),
                                TestFile("File.swift"),
                                TestFile("File.m"),
                            ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "iphoneos",
                                    "DONT_GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                ])],
                            targets: [
                                TestStandardTarget(
                                    "aFramework", type: .framework,
                                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: buildSettings)],
                                    buildPhases: [
                                        TestSourcesBuildPhase(["File.c", "File.swift", "File.m"]),
                                    ])])])

                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // create the files
                for file in ["File.swift", "File.c", "File.m"] {
                    let swiftFile = testWorkspace.sourceRoot.join("aProject/\(file)")
                    try await tester.fs.writeFileContents(swiftFile) { stream in }
                }

                try await tester.checkBuild(runDestination: .anyiOSDevice) { results in
                    results.checkNoErrors()

                    for arch in expectedArchs {
                        results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("File.c")), .matchRuleItem(arch)) { _ in }
                        results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("File.m")), .matchRuleItem(arch)) { _ in }
                        results.checkTask(.matchRuleType("SwiftCompile"), .matchRuleItem(arch)) { _ in }
                        results.checkTask(.matchRuleType("SwiftEmitModule"), .matchRuleItem(arch)) { _ in }
                    }
                }
            }
        }

        try await test(buildSettings: ["ENABLE_POINTER_AUTHENTICATION": "YES"], expectedArchs: ["arm64", "arm64e"])
        try await test(buildSettings: ["ENABLE_POINTER_AUTHENTICATION": "NO"], expectedArchs: ["arm64"])
    }

    @Test(.requireSDKs(.macOS))
    func wrapperFileTypeMonitoring() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("File.swift"),
                            TestFile("Model.xcdatamodel"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "macosx",
                                    "DONT_GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                ]
                            )
                        ],
                        targets: [
                            TestStandardTarget(
                                "aFramework", type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["File.swift", "Model.xcdatamodel"]),
                                ],
                                buildRules: [
                                    TestBuildRule(fileTypeIdentifier: "wrapper.xcdatamodel", script: "echo \"should run!\"", outputs: ["$(DERIVED_FILE_DIR)/$(INPUT_FILE_BASE).mom"])
                                ]
                            )
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)

            // create the files
            let projectDir = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(projectDir.join("File.swift")) { stream in }
            try tester.fs.writeCoreDataModel(projectDir.join("Model.xcdatamodel"), language: .swift)

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemPattern(.suffix("DerivedSources/Model.mom"))) { _ in }
            }


            // Verify null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache"], diagnosticsToValidate: [.error, .warning])

            // Verify incremental build when changing content of a nested file type.
            try tester.fs.writeCoreDataModel(projectDir.join("Model.xcdatamodel"), language: .swift)
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchRule(["RuleScriptExecution", "\(projectDir.str)/build/aProject.build/Debug/aFramework.build/DerivedSources/Model.mom", "\(projectDir.str)/Model.xcdatamodel", "normal", results.runDestinationTargetArchitecture])) { _ in }
                results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }

                results.checkNoTask()
            }
        }
    }


    // rdar://97564149 (ER: add support for xcfilelists in build rules)

    // This test implements the following scenario:
    // Suppose
    //   * "fake-typescript-compiler.fake-sh" is a shell script that compiles "*.fake-ts" files into "*.fake-ts.fake-js" files
    //
    // In doing so, it consults "{prefix,suffix}.txt" and "license-{text-year}.txt"
    // We list those files in "extra-input-files.xcfilelist" and "license.xcfilelist"
    //
    // Our goal is to compile "example.fake-ts" into "example.fake-ts.fake-js"
    // This will invoke the following command
    // $ ./fake-typescript-compiler.sh example.fake-ts
    // ... and will produce "example.fake-ts.fake-js"
    //
    // It also produces mock "{one,two,three,four}.txt" files listed in "extra-output-files-{odd,even}.xcfilelist"
    //
    // This script tests both input file lists and output file lists.

    @Test(.requireSDKs(.macOS))
    func customBuildRulesInputAndOutputFileList() async throws {
        try await withTemporaryDirectory { tmpDir in
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
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "TypeScriptApp",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("example.fake-ts"),
                            ]),
                        ],
                        buildRules: [
                            TestBuildRule(filePattern: "*.fake-ts",
                                          script: #"bash "${SRCROOT}/fake-typescript-compiler.fake-sh""#,
                                          inputs: ["$(SRCROOT)/fake-typescript-compiler.fake-sh"],
                                          inputFileLists: ["$(SRCROOT)/extra-input-files.xcfilelist", "$(SRCROOT)/license.xcfilelist"],
                                          outputs: ["$(INPUT_FILE_PATH).fake-js"],
                                          outputFileLists: ["$(SRCROOT)/extra-output-files-odd.xcfilelist", "$(SRCROOT)/extra-output-files-even.xcfilelist"]),
                            TestBuildRule(filePattern: "*.fake-js",
                                          script: #"bash "${SRCROOT}/fake-uglifier.fake-sh""#,
                                          inputs: ["$(SRCROOT)/fake-uglifier.fake-sh"],
                                          inputFileLists: ["$(SRCROOT)/uglifier-input-files.xcfilelist"],
                                          outputs: ["$(INPUT_FILE_PATH).fake-uglified"],
                                          outputFileLists: []),
                        ]
                    ),
                ])

            let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir.join("Test"), projects: [testProject])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = tester.fs
            try fs.createDirectory(Path(SRCROOT), recursive: true)

            try await fs.writeFileContents(Path(SRCROOT).join("fake-typescript-compiler.fake-sh")) { stream in
                // Read contents of typescript-configuration-{prefix,suffix}.txt
                // then prefix and suffix each line with the contents of prefix.txt and suffix.txt
                // also, add license text and year to the beginning of the generated file.
                // also generate {one,two,three,four}.txt listed in output file lists
                let script = #"""
                    set -o errexit
                    set -o xtrace
                    set -o nounset
                    set -o pipefail


                    cat "${INPUT_FILE_PATH}" | sed -e "s/^/$(cat "${FAKE_PATH_PREFIX}")/g" -e "s/$/$(cat "${FAKE_PATH_SUFFIX}")/g" | cat "${FAKE_PATH_LICENSE_TEXT}" "${FAKE_PATH_LICENSE_YEAR}" - > "${SCRIPT_OUTPUT_FILE_0}"

                    while read path_to_odd_file; do
                        echo "ODD" > "${path_to_odd_file}"
                    done < "${SCRIPT_OUTPUT_FILE_LIST_0}"

                    while read path_to_even_file; do
                        echo "EVEN" > "${path_to_even_file}"
                    done < "${SCRIPT_OUTPUT_FILE_LIST_1}"
                """#
                stream <<< script
            }

            try await fs.writeFileContents(Path(SRCROOT).join("fake-uglifier.fake-sh")) { stream in
                let script = #"""
                    set -o errexit
                    set -o xtrace
                    set -o nounset
                    set -o pipefail


                    cat "${INPUT_FILE_PATH}" | sed -e "s/^/UGLIFIED /g" > "${SCRIPT_OUTPUT_FILE_0}"
                """#
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

            try await fs.writeFileContents(Path(SRCROOT).join("extra-output-files-odd.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/one.txt\n"
                stream <<< "$(SRCROOT)/three.txt\n"
            }

            try await fs.writeFileContents(Path(SRCROOT).join("extra-output-files-even.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/two.txt\n"
                stream <<< "$(SRCROOT)/four.txt\n"
            }

            try await fs.writeFileContents(Path(SRCROOT).join("uglifier-input-files.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/example.fake-ts.fake-js\n"
            }

            let overrides = [
                "FAKE_PATH_LICENSE_YEAR": Path(SRCROOT).join("license-year.txt").str,
                "FAKE_PATH_LICENSE_TEXT": Path(SRCROOT).join("license-text.txt").str,
                "FAKE_PATH_PREFIX": Path(SRCROOT).join("prefix.txt").str,
                "FAKE_PATH_SUFFIX": Path(SRCROOT).join("suffix.txt").str
            ]
            // Check the build.
            for enableSandboxingInTest in [true, false] {
                try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: overrides.addingContents(of: ["ENABLE_USER_SCRIPT_SANDBOXING": enableSandboxingInTest ? "YES" : "NO"])), runDestination: .macOS) { results in
                    results.checkNoDiagnostics()

                    try results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("example.fake-ts"), .matchRuleItemBasename("example.fake-ts.fake-js")) { task in
                        task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/example.fake-ts.fake-js", "\(SRCROOT)/example.fake-ts", "debug", "x86_64"])

                        if enableSandboxingInTest {
                            #expect(task.commandLine.first == "/usr/bin/sandbox-exec")
                        } else {
                            task.checkCommandLine(["/bin/sh", "-c", #"bash "${SRCROOT}/fake-typescript-compiler.fake-sh""#])
                        }

                        let path = task.outputPaths[0]
                        let output = try fs.read(path).asString
                        let expectedOutput = """
                        LICENSE TEXT
                        2021
                        PREFIX Fake typescript code SUFFIX
                        PREFIX Fake typescript code line 2 SUFFIX
                        """
                        XCTAssertMatch(output, .contains(expectedOutput))

                        func check(pathFragment: String, expectedOutput: consuming sending Regex<Substring>, sourceLocation: SourceLocation = #_sourceLocation) throws {
                            let output = try fs.read(Path(SRCROOT).join("\(pathFragment).txt")).asString
                            XCTAssertMatch(output, .regex(expectedOutput), sourceLocation: sourceLocation)
                        }

                        // check contents of files listed in extra-output-files-{odd,even}.xcfilelist
                        try check(pathFragment: "one", expectedOutput: #/ODD/#)
                        try check(pathFragment: "two", expectedOutput: #/EVEN/#)
                        try check(pathFragment: "three", expectedOutput: #/ODD/#)
                        try check(pathFragment: "four", expectedOutput: #/EVEN/#)
                    }

                    try results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("example.fake-ts.fake-js"), .matchRuleItemBasename("example.fake-ts.fake-js.fake-uglified")) { task in
                        task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/example.fake-ts.fake-js.fake-uglified", "\(SRCROOT)/example.fake-ts.fake-js", "debug", "x86_64"])

                        let path = task.outputPaths[0]
                        let output = try fs.read(path).asString
                        let expectedOutput = """
                        UGLIFIED LICENSE TEXT
                        UGLIFIED 2021
                        UGLIFIED PREFIX Fake typescript code SUFFIX
                        UGLIFIED PREFIX Fake typescript code line 2 SUFFIX
                        """
                        XCTAssertMatch(output, .contains(expectedOutput))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func multipleInvocationsOfCustomBuildRuleWithFileList() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "coolWebsite",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("fake-typescript-compiler.fake-sh"),
                        TestFile("extra-output-files-A-B.xcfilelist"),
                        TestFile("extra-output-files-C-D.xcfilelist"),
                        TestFile("extra-input-files.xcfilelist"),
                        TestFile("prefix.txt"),
                        TestFile("example-1.fake-ts"),
                        TestFile("example-2.fake-ts"),
                        TestFile("mock.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "BUILD_VARIANTS": "debug",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "ENABLE_USER_SCRIPT_SANDBOXING": "NO", // This test will run with both ON/OFF configurations
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        "TypeScriptApp",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("example-1.fake-ts"),
                                TestBuildFile("example-2.fake-ts"),
                            ]),
                        ],
                        buildRules: [
                            TestBuildRule(filePattern: "*.fake-ts",
                                          script: #"bash "${SRCROOT}/fake-typescript-compiler.fake-sh""#,
                                          inputs: ["$(SRCROOT)/fake-typescript-compiler.fake-sh"],
                                          inputFileLists: ["$(SRCROOT)/extra-input-files.xcfilelist"],
                                          outputs: ["${INPUT_FILE_PATH}.E.fake-js", "${INPUT_FILE_PATH}.F.fake-js"],
                                          outputFileLists: ["$(SRCROOT)/extra-output-files-A-B.xcfilelist", "$(SRCROOT)/extra-output-files-C-D.xcfilelist"]),
                        ]
                    ),
                ])

            let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir.join("Test"), projects: [testProject])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = tester.fs
            try fs.createDirectory(Path(SRCROOT), recursive: true)

            try await fs.writeFileContents(Path(SRCROOT).join("fake-typescript-compiler.fake-sh")) { stream in
                let script = #"""
                    set -o errexit
                    set -o xtrace
                    set -o nounset
                    set -o pipefail

                    for outputAlphaCode in {A..F}
                    do
                        cat "${INPUT_FILE_PATH}" | sed -e "s/^/$(basename "${INPUT_FILE_PATH}"): /g" |  sed -e "s/^/$(cat "${FAKE_PATH_PREFIX}") ${outputAlphaCode}: /g" > "${INPUT_FILE_PATH}.${outputAlphaCode}.fake-js"
                    done
                """#
                stream <<< script
            }

            try await fs.writeFileContents(Path(SRCROOT).join("example-1.fake-ts")) { stream in
                stream <<< "Example 1, line 1\n"
                stream <<< "Example 1, line 2\n"
            }

            try await fs.writeFileContents(Path(SRCROOT).join("example-2.fake-ts")) { stream in
                stream <<< "Example 2, line 1\n"
                stream <<< "Example 2, line 2\n"
            }

            try await fs.writeFileContents(Path(SRCROOT).join("extra-input-files.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/prefix.txt\n"
            }

            try await fs.writeFileContents(Path(SRCROOT).join("extra-output-files-A-B.xcfilelist")) { stream in
                stream <<< "$(INPUT_FILE_PATH).A.fake-js\n"
                stream <<< "$(INPUT_FILE_PATH).B.fake-js\n"
            }

            try await fs.writeFileContents(Path(SRCROOT).join("extra-output-files-C-D.xcfilelist")) { stream in
                stream <<< "$(INPUT_FILE_PATH).C.fake-js\n"
                stream <<< "$(INPUT_FILE_PATH).D.fake-js\n"
            }

            try await fs.writeFileContents(Path(SRCROOT).join("prefix.txt")) { stream in
                stream <<< "PREFIX"
            }

            let overrides = [
                "FAKE_PATH_PREFIX": Path(SRCROOT).join("prefix.txt").str,
            ]
            // Check the build.
            for enableSandboxingInTest in [true, false] {
                try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: overrides.addingContents(of: ["ENABLE_USER_SCRIPT_SANDBOXING": enableSandboxingInTest ? "YES" : "NO"])), runDestination: .macOS) { results in
                    results.checkNoDiagnostics()

                    try results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("example-1.fake-ts")) { task in
                        task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/example-1.fake-ts.E.fake-js", "\(SRCROOT)/example-1.fake-ts.F.fake-js", "\(SRCROOT)/example-1.fake-ts", "debug", "x86_64"])

                        if enableSandboxingInTest {
                            #expect(task.commandLine.first == "/usr/bin/sandbox-exec")
                        } else {
                            task.checkCommandLine(["/bin/sh", "-c", #"bash "${SRCROOT}/fake-typescript-compiler.fake-sh""#])
                        }

                        for elem in ["A", "B", "C", "D", "E", "F"] {
                            let output = try fs.read(Path(SRCROOT).join("example-1.fake-ts.\(elem).fake-js")).asString
                            let expectedOutput = """
                            PREFIX \(elem): example-1.fake-ts: Example 1, line 1
                            PREFIX \(elem): example-1.fake-ts: Example 1, line 2
                            """
                            XCTAssertMatch(output, .contains(expectedOutput))
                        }
                    }

                    try results.checkTask(.matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("example-2.fake-ts")) { task in
                        task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/example-2.fake-ts.E.fake-js", "\(SRCROOT)/example-2.fake-ts.F.fake-js", "\(SRCROOT)/example-2.fake-ts", "debug", "x86_64"])

                        if enableSandboxingInTest {
                            #expect(task.commandLine.first == "/usr/bin/sandbox-exec")
                        } else {
                            task.checkCommandLine(["/bin/sh", "-c", #"bash "${SRCROOT}/fake-typescript-compiler.fake-sh""#])
                        }

                        for elem in ["A", "B", "C", "D", "E", "F"] {
                            let output = try fs.read(Path(SRCROOT).join("example-2.fake-ts.\(elem).fake-js")).asString
                            let expectedOutput = """
                            PREFIX \(elem): example-2.fake-ts: Example 2, line 1
                            PREFIX \(elem): example-2.fake-ts: Example 2, line 2
                            """
                            XCTAssertMatch(output, .contains(expectedOutput))
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func safariExtensionLaunchServicesRegistration() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "SafariExt",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("File.swift"),
                            TestFile("Extension.swift"),
                            TestFile("resources.js"),
                            TestFile("Info.plist")
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "macosx",
                                    "CODE_SIGN_IDENTITY": "-",
                                    "COPY_PHASE_STRIP": "NO",
                                    "INFOPLIST_FILE": "Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                ]
                            )
                        ],
                        targets: [
                            TestStandardTarget(
                                "anApp", type: .application,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["File.swift"]),
                                    TestCopyFilesBuildPhase([TestBuildFile("anExtension.appex", codeSignOnCopy: true)], destinationSubfolder: .frameworks, destinationSubpath: "PlugIns", onlyForDeployment: false)
                                ],
                                dependencies: ["anExtension"]
                            ),
                            TestStandardTarget(
                                "anExtension", type: .applicationExtension,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Extension.swift"]),
                                    TestCopyFilesBuildPhase(["resources.js"], destinationSubfolder: .resources, onlyForDeployment: false)
                                ])
                        ])
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)

            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            // create the files
            let projectDir = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(projectDir.join("File.swift")) { stream in
                stream <<< "import Cocoa\n"
                stream <<< "@main\n"
                stream <<< "class AppDelegate: NSObject, NSApplicationDelegate {}\n"
            }
            try await tester.fs.writeFileContents(projectDir.join("Extension.swift")) { stream in
                stream <<< "public struct Ext {}"
            }
            try await tester.fs.writeFileContents(projectDir.join("resources.js")) { stream in
                stream <<< "// hello"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))

            let signableTargets: Set<String> = ["anApp", "anExtension"]

            let params = BuildParameters(action: .build, configuration: "Debug")
            try await tester.checkBuild(parameters: params, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.checkTask(.matchRule(["RegisterWithLaunchServices", "\(buildDirectory)/Debug/anApp.app"])) { _ in }
                results.checkNoDiagnostics()
            }

            // Verify that the build updates the appex and registers with launch services again.
            try await tester.fs.writeFileContents(projectDir.join("resources.js")) { stream in
                stream <<< "// world"
            }
            try await tester.checkBuild(parameters: params, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                results.checkTask(.matchRule(["RegisterWithLaunchServices", "\(buildDirectory)/Debug/anApp.app"])) { _ in }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that optimization remarks are properly generated and parsed as diagnostics.
    @Test(.requireSDKs(.macOS), .enabled(if: Diagnostic.libRemarksAvailable, "Skipping because libRemarks.dylib is not available."))
    func optimizationRemarksDiagnostics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject( "aProject",
                                 groupTree: TestGroup("Sources",
                                                      children: [TestFile("main.c")]),
                                 buildConfigurations: [TestBuildConfiguration("Debug",
                                                                              buildSettings: [
                                                                                "CODE_SIGNING_ALLOWED": "NO",
                                                                                "CLANG_GENERATE_OPTIMIZATION_REMARKS": "YES",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                              ])],
                                 targets: [TestStandardTarget("Tool", type: .commandLineTool,
                                                              buildConfigurations: [TestBuildConfiguration("Debug")],
                                                              buildPhases: [TestSourcesBuildPhase(["main.c"])])])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)

            // create the files
            let projectDir = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< "int main(void) { return 0; }"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkRemark(.contains("instructions in function"))
            }
        }
    }

    /// Test that optimization remarks are properly generated and parsed as diagnostics.
    @Test(.requireSDKs(.macOS), .enabled(if: Diagnostic.libRemarksAvailable, "Skipping because libRemarks.dylib is not available."))
    func optimizationRemarksLTODiagnostics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject( "aProject",
                                 groupTree: TestGroup("Sources",
                                                      children: [TestFile("main.c")]),
                                 buildConfigurations: [TestBuildConfiguration("Debug",
                                                                              buildSettings: [
                                                                                "CODE_SIGNING_ALLOWED": "NO",
                                                                                "LTO": "YES",
                                                                                "CLANG_GENERATE_OPTIMIZATION_REMARKS": "YES",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                              ])],
                                 targets: [TestStandardTarget("Tool", type: .commandLineTool,
                                                              buildConfigurations: [TestBuildConfiguration("Debug")],
                                                              buildPhases: [TestSourcesBuildPhase(["main.c"])])])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)

            // create the files
            let projectDir = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< "int main(void) { return 0; }"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkRemark(.contains("instructions in function"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func missingInputFailsBuild() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject("aProject",
                                groupTree: TestGroup("Sources",
                                                     children: [TestFile("main.c")]),
                                buildConfigurations: [TestBuildConfiguration("Debug",
                                                                             buildSettings: [
                                                                                "CODE_SIGNING_ALLOWED": "NO",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",

                                                                                // Specify some file that doesn't exist to provoke missing input
                                                                                "CLANG_USE_OPTIMIZATION_PROFILE": "YES",
                                                                                "CLANG_OPTIMIZATION_PROFILE_FILE": tmpDir.join("Test").join("profile.txt").str,
                                                                             ])],
                                targets: [TestStandardTarget("Tool", type: .commandLineTool,
                                                             buildConfigurations: [TestBuildConfiguration("Debug")],
                                                             buildPhases: [TestSourcesBuildPhase(["main.c"])])])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)

            // create the files
            let projectDir = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< "int main(void) { return 0; }"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkError(.prefix("Build input file cannot be found"), failIfNotFound: true)
                results.checkedWarnings = true

                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    // The given CLANG_OPTIMIZATION_PROFILE_FILE does not exist, so the command should fail
                    results.checkTaskResult(compileTask, expected: .failedSetup)

                    results.check(contains: .buildCompleted)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func progress() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject("aProject",
                                groupTree: TestGroup("Sources",
                                                     children: [TestFile("main.swift")]),
                                buildConfigurations: [TestBuildConfiguration("Debug",
                                                                             buildSettings: [
                                                                                "CODE_SIGNING_ALLOWED": "NO",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SWIFT_VERSION": swiftVersion,

                                                                                // this will spawn some dynamic tasks
                                                                                "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                                                             ])],
                                targets: [TestStandardTarget("Tool", type: .commandLineTool,
                                                             buildConfigurations: [TestBuildConfiguration("Debug")],
                                                             buildPhases: [TestSourcesBuildPhase(["main.swift"])])])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)

            // create the files
            let projectDir = testWorkspace.sourceRoot.join("aProject")
            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<<
                    """
                    struct Foo { }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                for target in results.buildDescription.allConfiguredTargets {
                    results.check(contains: .targetHadEvent(target, event: .started), count: 1)
                    results.check(contains: .targetHadEvent(target, event: .preparationStarted), count: 1)
                    results.check(contains: .targetHadEvent(target, event: .completed), count: 1)
                }

                for task in results.uncheckedTasks {
                    results.check(contains: .taskHadEvent(task, event: .started), count: 1)
                    results.check(contains: .taskHadEvent(task, event: .completed), count: 1)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func dependencyInfoDebugActivityLogs() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("Source.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "OTHER_SWIFT_FLAGS": "$(inherited) -Xfrontend -disable-implicit-string-processing-module-import"
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Source.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")

            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Source.swift")) { file in
                file <<< "struct A {}\n"
            }

            tester.userPreferences = .defaultForTesting.with(enableDebugActivityLogs: true)

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                results.checkNoWarnings()

                func checkDependencyInfoNote(_ task: BuildOperationTester.BuildResults.Task, _ expectedInputs: [String], _ expectedOutputs: [String], sourceLocation: SourceLocation = #_sourceLocation) {
                    let displayString = commandLineDisplayString(task.commandLineAsByteStrings, additionalOutput: task.additionalOutput, workingDirectory: task.workingDirectory, environment: task.environment, dependencyInfo: .init(task: task))

                    guard let inputRange = displayString.range(of: "Task input dependencies:\n") else {
                        Issue.record("Unable to find dependency information for task \(task) in log.", sourceLocation: sourceLocation)
                        return
                    }

                    guard let outputRange = displayString.range(of: "Task output dependencies:\n") else {
                        Issue.record("Unable to find dependency information for task \(task) in log.", sourceLocation: sourceLocation)
                        return
                    }

                    let inputsArea = String(displayString[inputRange.lowerBound..<outputRange.lowerBound])
                    let outputsArea = String(displayString[outputRange.upperBound...])

                    for expectedInput in expectedInputs {
                        XCTAssertMatch(inputsArea, .contains(expectedInput))
                    }

                    for expectedOutput in expectedOutputs {
                        XCTAssertMatch(outputsArea, .contains(expectedOutput))
                    }
                }

                // Checking output for SwiftDriver (no inputs/outputs defined)
                results.checkTask(.matchRuleType("SwiftDriver")) { driverTask in
                    checkDependencyInfoNote(driverTask, [], [])
                }

                results.checkTask(.matchRuleType("Ld")) { linkerTask in
                    checkDependencyInfoNote(
                        linkerTask,
                        [
                            "\(SRCROOT.str)/build/aProject.build/Debug/TargetA.build/Objects-normal/arm64e/Source.o",
                            "\(SRCROOT.str)/build/aProject.build/Debug/TargetA.build/Objects-normal/arm64e/TargetA.LinkFileList",
                            "\(SRCROOT.str)/build/Debug",
                        ],
                        [
                            "\(SRCROOT.str)/build/Debug/TargetA.framework/Versions/A/TargetA",
                            "\(SRCROOT.str)/build/aProject.build/Debug/TargetA.build/Objects-normal/arm64e/TargetA_dependency_info.dat",
                        ])
                }
            }
        }
    }
}
